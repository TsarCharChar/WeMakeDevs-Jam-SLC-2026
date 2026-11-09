import 'dart:async';
import 'dart:convert';

import 'package:conversation_garden/attendee_api.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStorage implements TranscriptStorage {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('storage failed');
    this.value = value;
  }

  Map<String, dynamic> get json => jsonDecode(value!) as Map<String, dynamic>;
}

class FakeApi extends AttendeeApi {
  FakeApi({super.baseUrl});
  final List<Map<String, dynamic>> writes = [];
  int profiles = 0, reads = 0;
  Future<void> Function(Map<String, dynamic>)? onWrite;
  Map<String, dynamic> remote = {};
  @override
  Future<Map<String, dynamic>> profile(
    String handle,
    String conference, {
    String? token,
  }) async {
    profiles++;
    return {
      'handle': handle,
      'conference': conference,
      if (token == null) 'token': 'synthetic-attendee-token',
    };
  }

  @override
  Future<void> writeSegment(
    String token,
    String stream,
    int sequence,
    Map<String, dynamic> payload,
  ) async {
    expect(token, 'synthetic-attendee-token');
    writes.add({...payload, 'sequence': sequence});
    await onWrite?.call(payload);
  }

  @override
  Future<Map<String, dynamic>> segment(
    String token,
    String stream,
    int sequence,
  ) async {
    reads++;
    return remote;
  }
}

void main() {
  late FakeApi api;
  late MemoryStorage storage;
  late TranscriptSync sync;
  setUp(() async {
    api = FakeApi();
    storage = MemoryStorage();
    sync = TranscriptSync(api: api, storage: storage, startTimer: false);
    await sync.initialize();
  });
  tearDown(() => sync.dispose());
  Future<void> connect() => sync.connect('test-phone', 'cnh');

  test('local mode sends nothing; consented setup persists identity', () async {
    await sync.begin();
    sync.updateText('local only');
    await sync.finish('local only');
    await sync.flush();
    expect(api.writes, isEmpty);
    expect(api.profiles, 0);
    await connect();
    expect(storage.json['enabled'], isTrue);
    expect(
      (storage.json['account'] as Map)['token'],
      'synthetic-attendee-token',
    );
  });

  test(
    'coalesces partials, persists exact request first, finalizes and advances',
    () async {
      await connect();
      await sync.begin();
      sync.updateText('first guess');
      sync.updateText('corrected words');
      api.onWrite = (payload) async {
        expect((storage.json['segments'] as List).first['pending'], payload);
      };
      await sync.flush();
      expect(api.writes.single['transcript'], 'corrected words');
      expect(api.writes.single['finalized'], false);
      await sync.finish('final words');
      await sync.flush();
      expect(api.writes.last['revision'], 2);
      expect(api.writes.last['finalized'], true);
      expect(sync.hasPending, false);
      expect(storage.json['segments'], isEmpty);
      await sync.begin();
      await sync.finish('second recording');
      await sync.flush();
      expect(api.writes.last['sequence'], 1);
    },
  );

  test(
    'one request in flight; newer text is durable during slow upload',
    () async {
      await connect();
      await sync.begin();
      final started = Completer<void>(), release = Completer<void>();
      api.onWrite = (_) async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      sync.updateText('partial');
      final sending = sync.flush();
      await started.future;
      sync.updateText('newer partial');
      unawaited(sync.flush());
      await Future<void>.delayed(Duration.zero);
      expect(
        (storage.json['segments'] as List).single['text'],
        'newer partial',
      );
      await sync.finish('final');
      expect(api.writes.length, 1);
      release.complete();
      await sending;
      expect(api.writes.length, 2);
      expect(api.writes.last['transcript'], 'final');
      expect(api.writes.last['finalized'], true);
      expect(sync.hasPending, false);
    },
  );

  test(
    'lost response retries identical payload before sending newer final',
    () async {
      await connect();
      await sync.begin();
      sync.updateText('original');
      api.onWrite = (_) async =>
          throw const AttendeeApiException('offline', retryable: true);
      await sync.flush();
      await sync.finish('corrected final');
      await sync.flush();
      expect(api.writes.length, 1); // Backoff is respected.
      api.onWrite = null;
      await sync.retry();
      expect(api.writes[0], api.writes[1]);
      expect(api.writes[2]['revision'], 2);
      expect(api.writes[2]['transcript'], 'corrected final');
      expect(sync.hasPending, false);
    },
  );

  test(
    'restart replays persisted request and finalizes interrupted recording',
    () async {
      await connect();
      await sync.begin();
      sync.updateText('interrupted speech');
      api.onWrite = (_) async =>
          throw const AttendeeApiException('offline', retryable: true);
      await sync.flush();
      final original = api.writes.single;
      final restoredApi = FakeApi();
      final restored = TranscriptSync(
        api: restoredApi,
        storage: storage,
        startTimer: false,
      );
      await restored.initialize();
      expect(restoredApi.profiles, 0);
      expect(restoredApi.writes.first, original);
      expect(restoredApi.writes.last['finalized'], true);
      expect(restored.hasPending, false);
      await restored.begin();
      expect(storage.json['nextSequence'], 2);
      restored.dispose();
    },
  );

  test(
    'conflict reads server state and never blindly increments revision',
    () async {
      await connect();
      await sync.begin();
      sync.updateText('my text');
      api.onWrite = (_) async =>
          throw const AttendeeApiException('conflict', status: 409);
      api.remote = {
        'sequence': 0,
        'revision': 8,
        'transcript': 'other text',
        'finalized': false,
      };
      await sync.flush();
      await sync.flush();
      expect(api.reads, 1);
      expect(api.writes.length, 1);
      expect(sync.hasPending, true);
      expect(sync.canBegin, false);
      expect(
        (storage.json['segments'] as List).single['pending']['revision'],
        1,
      );
    },
  );

  test(
    'matching conflict read confirms a previously accepted request',
    () async {
      await connect();
      await sync.begin();
      sync.updateText('my text');
      api.onWrite = (_) async =>
          throw const AttendeeApiException('conflict', status: 409);
      api.remote = {
        'sequence': 0,
        'revision': 1,
        'transcript': 'my text',
        'finalized': false,
      };
      await sync.flush();
      expect(sync.hasPending, false);
      expect(sync.error, null);
    },
  );

  test(
    'storage failure prevents sending and retry keeps captured text',
    () async {
      await connect();
      await sync.begin();
      storage.fail = true;
      sync.updateText('must not disappear');
      await sync.flush();
      expect(api.writes, isEmpty);
      expect(sync.canBegin, false);
      storage.fail = false;
      await sync.retry();
      expect(api.writes.single['transcript'], 'must not disappear');
    },
  );

  test(
    'failed credential persistence retries without claiming another profile',
    () async {
      storage.fail = true;
      await expectLater(connect(), throwsA(isA<AttendeeApiException>()));
      expect(sync.canBegin, false);
      storage.fail = false;
      await sync.retry();
      expect(api.profiles, 1);
      expect(sync.canBegin, true);
      expect(
        (storage.json['account'] as Map)['token'],
        'synthetic-attendee-token',
      );
    },
  );

  test(
    'different backend origin never receives saved credentials or text',
    () async {
      await connect();
      final original = storage.value;
      final otherApi = FakeApi(baseUrl: Uri.parse('https://other.example'));
      final other = TranscriptSync(
        api: otherApi,
        storage: storage,
        startTimer: false,
      );
      await other.initialize();
      await other.retry();
      expect(other.loaded, false);
      expect(other.connected, false);
      expect(otherApi.writes, isEmpty);
      expect(storage.value, original);
      other.dispose();
    },
  );

  test(
    'outbox is bounded and pausing retains previously consented text',
    () async {
      await connect();
      api.onWrite = (_) async =>
          throw const AttendeeApiException('offline', retryable: true);
      for (var i = 0; i < TranscriptSync.maxSegments; i++) {
        await sync.begin();
        await sync.finish('recording $i');
        await sync.flush();
      }
      expect(sync.canBegin, false);
      await expectLater(sync.begin(), throwsA(isA<AttendeeApiException>()));
      await sync.setEnabled(false);
      final count = api.writes.length;
      await sync.retry();
      expect(api.writes.length, count);
      expect(
        (storage.json['segments'] as List).length,
        TranscriptSync.maxSegments,
      );
      expect(sync.canBegin, true); // Local recording remains possible.
    },
  );

  test('empty recording is not uploaded', () async {
    await connect();
    await sync.begin();
    await sync.finish('   ');
    await sync.flush();
    expect(api.writes, isEmpty);
    expect(sync.hasPending, false);
  });

  test(
    'automatic retries stop after five attempts until explicitly resumed',
    () async {
      var now = DateTime.utc(2026);
      final boundedApi = FakeApi();
      final bounded = TranscriptSync(
        api: boundedApi,
        storage: MemoryStorage(),
        startTimer: false,
        now: () => now,
      );
      await bounded.initialize();
      await bounded.connect('bounded-phone', 'cnh');
      await bounded.begin();
      boundedApi.onWrite = (_) async =>
          throw const AttendeeApiException('offline', retryable: true);
      bounded.updateText('pending');
      for (var i = 0; i < 10; i++) {
        await bounded.flush();
        now = now.add(const Duration(minutes: 1));
      }
      expect(boundedApi.writes.length, 5);
      expect(bounded.status, contains('five attempts'));
      expect(bounded.hasPending, true);
      boundedApi.onWrite = null;
      await bounded.retry();
      expect(bounded.hasPending, false);
      bounded.dispose();
    },
  );

  test(
    'expired session stops automatic uploads and retains pending text',
    () async {
      await connect();
      await sync.begin();
      api.onWrite = (_) async =>
          throw const AttendeeApiException('renew', status: 401);
      await sync.finish('private text');
      await sync.flush();
      await sync.flush();
      expect(api.writes.length, 1);
      expect(sync.hasPending, true);
      api.onWrite = null;
      await sync.renewSession();
      expect(sync.hasPending, false);
      expect(api.profiles, 2);
    },
  );
}
