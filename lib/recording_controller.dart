import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'attendee_api.dart';
import 'transcript_sync.dart';

enum RecordingPhase { idle, preparing, recording, stopping }

class RecordingController extends ChangeNotifier {
  RecordingController({this.sync});
  final TranscriptSync? sync;
  Future<void> closed = Future.value();
  final _recorder = AudioRecorder();
  WhisperLiveSession? _session;
  StreamSubscription<Uint8List>? _audio;
  StreamSubscription<String>? _text;
  Timer? _limit;
  Future<void>? _finishing;
  Completer<void>? _preparation;
  bool _disposed = false, _cancelled = false;
  RecordingPhase phase = RecordingPhase.idle;
  String transcript = '', status = 'Your next good conversation starts here.';
  String? error;
  bool get busy =>
      phase == RecordingPhase.preparing || phase == RecordingPhase.stopping;
  void update() {
    if (!_disposed) notifyListeners();
  }

  Future<String> _model() async {
    const name = 'ggml-large-v3-turbo-q5_0.bin';
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    if (await file.exists() && await file.length() == 574041195) {
      return file.path;
    }
    status = 'Preparing offline model. First launch takes a moment.';
    update();
    final bytes = await rootBundle.load('assets/models/$name');
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() !=
        '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2') {
      await partial.delete();
      throw StateError('Speech model damaged. Reinstall the app.');
    }
    await partial.rename(file.path);
    return file.path;
  }

  Future<void> start() async {
    if (phase != RecordingPhase.idle) return;
    phase = RecordingPhase.preparing;
    _preparation = Completer<void>();
    _cancelled = false;
    transcript = '';
    error = null;
    status = 'Checking microphone access…';
    update();
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Enable microphone access in your device settings.');
      }
      await sync?.begin();
      final path = await _model();
      if (_cancelled || _disposed) return;
      status = 'Loading Whisper on your device…';
      update();
      _session = await startWhisperLiveSession(modelPath: path, lang: 'en');
      if (_cancelled || _disposed) return;
      _text = _session!.partials.listen(
        (value) {
          transcript = value;
          sync?.updateText(value);
          update();
          if (value.runes.length >= 18000) unawaited(stop());
        },
        onError: (Object e) {
          error = 'Transcription interrupted: $e';
          unawaited(stop());
        },
      );
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _audio = stream.listen(
        (bytes) => _session?.feed(bytes),
        onError: (Object e) {
          error = 'Microphone interrupted: $e';
          unawaited(stop());
        },
      );
      if (_cancelled || _disposed) return;
      phase = RecordingPhase.recording;
      status = 'Listening on this device · tap to stop';
      _limit = Timer(const Duration(minutes: 3), () => unawaited(stop()));
    } catch (e) {
      error = e is AttendeeApiException
          ? e.message
          : 'Could not start recording: $e';
      _cancelled = true;
    } finally {
      if (_cancelled || _disposed) {
        try {
          await _cleanup();
          await sync?.finish(transcript);
        } catch (e) {
          error ??= 'Could not finish: $e';
        }
        phase = RecordingPhase.idle;
        status = 'Ready when you are.';
        if (_disposed) await _recorder.dispose();
      }
      update();
      _preparation?.complete();
    }
  }

  Future<void> _cleanup() async {
    _limit?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    await _audio?.cancel();
    _audio = null;
    final session = _session;
    _session = null;
    try {
      if (session != null) {
        final finalText = await session.stop();
        if (finalText.trim().isNotEmpty) transcript = finalText;
      }
    } finally {
      await _text?.cancel();
      _text = null;
    }
  }

  Future<void> stop() {
    if (phase == RecordingPhase.preparing) {
      _cancelled = true;
      return Future.value();
    }
    if (phase == RecordingPhase.stopping) return _finishing!;
    if (phase != RecordingPhase.recording) return Future.value();
    phase = RecordingPhase.stopping;
    status = 'Finishing your transcript…';
    _finishing = _finish();
    update();
    return _finishing!;
  }

  Future<void> _finish() async {
    try {
      await _cleanup();
    } catch (e) {
      error = 'Could not finish transcription: $e';
    } finally {
      await sync?.finish(transcript);
    }
    phase = RecordingPhase.idle;
    status = transcript.isEmpty
        ? 'No speech detected. Try again.'
        : sync?.enabled == true
        ? 'Conversation captured · check cloud saving status below'
        : 'Conversation captured · kept for this session';
    update();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    if (phase == RecordingPhase.preparing) {
      closed = _preparation!.future;
    } else {
      closed = (phase == RecordingPhase.stopping ? _finishing! : _cleanup())
          .then((_) => sync?.finish(transcript))
          .catchError((Object _) {})
          .whenComplete(_recorder.dispose);
      unawaited(closed);
    }
    super.dispose();
  }
}
