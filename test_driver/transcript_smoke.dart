// Opt-in live check: creates one synthetic attendee and two tiny recordings.
// No microphone access, tokens, response bodies or real attendee data in logs.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:conversation_garden/attendee_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Testing private transcript storage…')),
      ),
    ),
  );
  const key = 'synthetic_transcript_smoke_v1';
  const secure = FlutterSecureStorage();
  await secure.delete(key: key);
  final storage = SecureTranscriptStorage(key: key);
  final sync = TranscriptSync(storage: storage, startTimer: false);
  TranscriptSync? restored;
  var passed = false;
  var stage = 'secure storage';
  try {
    await sync.initialize();
    stage = 'attendee setup';
    await sync.connect(
      'smoke-${randomDeviceId().substring(0, 16)}',
      'flutter-smoke',
    );
    if (!sync.connected) throw StateError('setup');
    stage = 'partial write';
    await sync.begin();
    sync.updateText('Synthetic Flutter realtime partial.');
    await sync.flush();
    if (sync.hasPending) throw StateError('partial write');
    stage = 'partial read';
    final partial = (await sync.history())['segments'] as List;
    if (partial.length != 1 ||
        partial.single['finalized'] != false ||
        partial.single['transcript'] != 'Synthetic Flutter realtime partial.') {
      throw StateError('partial read');
    }
    stage = 'final write';
    await sync.finish('Synthetic Flutter realtime final.');
    await sync.flush();
    if (sync.hasPending) throw StateError('final write');
    // A new controller must recover the secure token and sequence, not claim
    // another profile or overwrite the previous recording.
    stage = 'secure restore';
    restored = TranscriptSync(storage: storage, startTimer: false);
    await restored.initialize();
    if (!restored.connected) throw StateError('secure restore');
    stage = 'second write';
    await restored.begin();
    await restored.finish('Synthetic Flutter second recording.');
    await restored.flush();
    if (restored.hasPending) throw StateError('second write');
    stage = 'ordered history';
    final history = (await restored.history())['segments'] as List;
    if (history.length != 2 ||
        history[0]['sequence'] != 0 ||
        history[1]['sequence'] != 1 ||
        history[0]['transcript'] != 'Synthetic Flutter realtime final.' ||
        history.any((dynamic entry) => entry['finalized'] != true)) {
      throw StateError('ordered history');
    }
    passed = true;
    debugPrint(
      'TRANSCRIPT_SMOKE PASS: partial, final, secure restore, append and history',
    );
  } catch (e) {
    final status = e is AttendeeApiException ? e.status : null;
    debugPrint(
      'TRANSCRIPT_SMOKE FAIL at $stage (HTTP ${status ?? "n/a"}); no private details logged',
    );
  } finally {
    sync.dispose();
    restored?.dispose();
    await secure.delete(key: key);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              passed
                  ? 'Transcript smoke test passed'
                  : 'Transcript smoke test failed',
            ),
          ),
        ),
      ),
    );
  }
}
