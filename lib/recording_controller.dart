import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'attendee_api.dart';
import 'transcript_sync.dart';

enum RecordingPhase { idle, preparing, recording, stopping }

/// Computes normalized perceptual mic energy (0.0..1.0) from 16-bit LE PCM.
double computePcmLevel(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  if (sampleCount == 0) return 0;
  final data = ByteData.sublistView(bytes);
  var sumSquares = 0.0;
  // Stride by up to 4 samples on large chunks to keep UI callback ultra-light.
  final step = sampleCount > 512 ? 4 : 1;
  var counted = 0;
  for (var i = 0; i < sampleCount; i += step) {
    final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
    sumSquares += sample * sample;
    counted++;
  }
  if (counted == 0) return 0;
  final rms = math.sqrt(sumSquares / counted);
  if (rms < 0.002) return 0;
  // Map roughly -48 dBFS .. -6 dBFS onto 0.0 .. 1.0 with gentle curve.
  final db = 20.0 * (math.log(rms) / math.ln10);
  return ((db + 48.0) / 42.0).clamp(0.0, 1.0);
}

class RecordingController extends ChangeNotifier {
  RecordingController({this.onNoteCompleted, this.sync});

  static const Duration maxDuration = Duration(minutes: 3);
  static const int waveformBarCount = 28;

  final ValueChanged<String>? onNoteCompleted;
  final TranscriptSync? sync;
  Future<void> closed = Future.value();
  final _recorder = AudioRecorder();
  WhisperLiveSession? _session;
  StreamSubscription<Uint8List>? _audio;
  StreamSubscription<String>? _text;
  Timer? _limit;
  Timer? _clock;
  DateTime? _startedAt;
  Future<void>? _finishing;
  Completer<void>? _preparation;
  bool _disposed = false, _cancelled = false;
  RecordingPhase phase = RecordingPhase.idle;
  String transcript = '', status = 'Ready to capture your next note.';
  String? error;
  double micLevel = 0;
  Duration elapsed = Duration.zero;
  final List<double> _bars = List<double>.filled(
    waveformBarCount,
    0,
    growable: true,
  );

  List<double> get waveformBars => List<double>.unmodifiable(_bars);

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
        (bytes) {
          _session?.feed(bytes);
          final rawLevel = computePcmLevel(bytes);
          // Smooth attack/decay for fluid wave physics.
          micLevel = rawLevel > micLevel
              ? micLevel * 0.35 + rawLevel * 0.65
              : micLevel * 0.72 + rawLevel * 0.28;
          if (_bars.length >= waveformBarCount) _bars.removeAt(0);
          _bars.add(micLevel);
          update();
        },
        onError: (Object e) {
          error = 'Microphone interrupted: $e';
          unawaited(stop());
        },
      );
      if (_cancelled || _disposed) return;
      phase = RecordingPhase.recording;
      _startedAt = DateTime.now();
      elapsed = Duration.zero;
      status = 'Listening on this device · tap to stop';
      _limit = Timer(maxDuration, () => unawaited(stop()));
      _clock = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final started = _startedAt;
        if (started == null || phase != RecordingPhase.recording) return;
        elapsed = DateTime.now().difference(started);
        if (elapsed > maxDuration) elapsed = maxDuration;
        update();
      });
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
    _clock?.cancel();
    _clock = null;
    _startedAt = null;
    micLevel = 0;
    for (var i = 0; i < _bars.length; i++) {
      _bars[i] = 0;
    }
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
    status = 'Finishing your note…';
    _finishing = _finish();
    update();
    return _finishing!;
  }

  Future<void> _finish() async {
    var notifyCompleted = false;
    try {
      await _cleanup();
      notifyCompleted = transcript.trim().isNotEmpty;
    } catch (e) {
      error = 'Could not finish transcription: $e';
    } finally {
      await sync?.finish(transcript);
    }
    phase = RecordingPhase.idle;
    elapsed = Duration.zero;
    status = transcript.isEmpty
        ? 'No speech detected. Try again.'
        : sync?.enabled == true
        ? 'Note captured · check private saving status'
        : 'Note captured · kept on this phone';
    update();
    if (notifyCompleted && !_disposed) {
      onNoteCompleted?.call(transcript.trim());
    }
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
