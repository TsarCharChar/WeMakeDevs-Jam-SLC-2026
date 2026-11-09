import 'dart:convert';
import 'dart:io';

import 'package:conversation_garden/attendee_api.dart';
import 'package:conversation_garden/conversation_api.dart';
import 'package:conversation_garden/phone_profile_store.dart';
import 'package:conversation_garden/schedule_data.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _MemoryTranscriptStorage implements TranscriptStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<void> write(String value) async {
    raw = value;
  }

  Map<String, dynamic>? get decoded =>
      raw == null ? null : jsonDecode(raw!) as Map<String, dynamic>;
}

const String _sampleScheduleJson = '''
[
  {
    "id": "coat-bag-check-2026-11-09-0700",
    "title": "Coat + Bag Check",
    "abstract": "",
    "time": "Mon, Nov 9, 2026 · 7:00 AM – 7:00 PM",
    "day": "2026-11-09",
    "start": "2026-11-09T07:00:00",
    "end": "2026-11-09T19:00:00",
    "room": "Salt Palace | Level 2 | East Registration",
    "tags": []
  },
  {
    "id": "agent-memory-otel-2026-11-10-1100",
    "title": "Just Keep Swimming: Benchmarking OSS Agent Memory on Kubernetes with OpenTelemetry",
    "abstract": "Evaluating agentic memory tracing and observability pipelines in production.",
    "time": "Tue, Nov 10, 2026 · 11:00 AM – 11:35 AM",
    "day": "2026-11-10",
    "start": "2026-11-10T11:00:00",
    "end": "2026-11-10T11:35:00",
    "room": "Salt Palace | Level 2 | 250 A-C",
    "speakers": ["Alice Example", "Bob Example"],
    "tags": [
      "AI Inference + Agentic",
      "Observability",
      "OpenTelemetry",
      "Advanced",
      "End User Talk"
    ]
  },
  {
    "id": "cilium-policy-opa-2026-11-11-1400",
    "title": "Zero-Trust Network Enforcement with Cilium and Open Policy Agent (OPA)",
    "abstract": "Combining Cilium datapath enforcement with OPA admission guardrails.",
    "time": "Wed, Nov 11, 2026 · 2:00 PM – 2:35 PM",
    "day": "2026-11-11",
    "start": "2026-11-11T14:00:00",
    "end": "2026-11-11T14:35:00",
    "room": "Salt Palace | Level 1 | 155",
    "tags": [
      "Cilium",
      "Open Policy Agent (OPA)",
      "Security",
      "Network",
      "Network Nook",
      "Intermediate",
      "🚨 Contribfest"
    ]
  },
  {
    "id": "istio-day-mesh-2026-11-10-1500",
    "title": "Istio at Scale: Lessons, Pitfalls, and Observability",
    "abstract": "Ambient mesh operations across clusters.",
    "time": "Tue, Nov 10, 2026 · 3:00 PM – 3:25 PM",
    "day": "2026-11-10",
    "start": "2026-11-10T15:00:00",
    "end": "2026-11-10T15:25:00",
    "room": "Salt Palace | Cloud Native Theater",
    "tags": [
      "Cloud Native Theater",
      "Istio Day",
      "Istio",
      "Argo",
      "Helm",
      "CLI",
      "Node",
      "Auth",
      "Sponsored",
      "Sponsor Demo Theater",
      "Keynote Sessions",
      "Separate Registration Required",
      "Sponsor-hosted Co-located Events",
      "Solutions Showcase",
      "Experiences",
      "Project Lightning Talks",
      "Maintainer Track",
      "Beginner",
      "Any Level"
    ]
  }
]
''';

void main() {
  group('ScheduleCatalog, ScopeGraphData & ScheduleTalk', () {
    test('parses real session shapes, omits speaker names, and filters meta-tags', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
      expect(catalog.talks, hasLength(4));

      final agentTalk = catalog.talkById('agent-memory-otel-2026-11-10-1100')!;
      expect(agentTalk.room, 'Salt Palace | Level 2 | 250 A-C');
      expect(agentTalk.day, '2026-11-10');
      expect(
        '${agentTalk.title} ${agentTalk.abstractText}',
        isNot(contains('Alice Example')),
      );

      for (final meta in [
        'Any Level',
        'Beginner',
        'Intermediate',
        'Advanced',
        'End User Talk',
        'Sponsored',
        'Sponsor Demo Theater',
        'Keynote Sessions',
        'Separate Registration Required',
        'Sponsor-hosted Co-located Events',
        'Solutions Showcase',
        'Experiences',
        'Project Lightning Talks',
        'Cloud Native Theater',
        'Maintainer Track',
        '🚨 Contribfest',
        'Network Nook',
        'Istio Day',
      ]) {
        expect(catalog.topicVocabulary, isNot(contains(meta)));
      }

      expect(
        catalog.topicVocabulary,
        containsAll([
          'AI Inference + Agentic',
          'Argo',
          'Auth',
          'Cilium',
          'CLI',
          'Helm',
          'Istio',
          'Network',
          'Node',
          'Observability',
          'Open Policy Agent (OPA)',
          'OpenTelemetry',
          'Security',
        ]),
      );
    });

    test('bundled kubecon_schedule.json exists with 600 sessions, 109 topics, and zero speakers keys (S10)', () {
      final assetFile = File('assets/data/kubecon_schedule.json');
      expect(assetFile.existsSync(), isTrue);

      final raw = assetFile.readAsStringSync();
      final decoded = jsonDecode(raw) as List<Object?>;
      expect(decoded.length, 600);
      for (final entry in decoded) {
        expect(entry, isA<Map<Object?, Object?>>());
        expect((entry as Map).containsKey('speakers'), isFalse);
      }

      final catalog = ScheduleCatalog.fromJsonString(raw);
      expect(catalog.talks.length, 600);
      expect(catalog.topicVocabulary.length, 109);
      for (final topic in catalog.topicVocabulary) {
        expect(ScheduleCatalog.isMetaTag(topic), isFalse);
      }
      // 017: Unlisted topics never fall back to Kubernetes or popular tags.
      expect(
        catalog.extractMatchedTopics('python and rust and machine learning'),
        isEmpty,
      );
    });

    test('extractMatchedTopics matches deterministically without inventing topics or substring false positives', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);

      expect(
        catalog.extractMatchedTopics(
          'Exploring on-device Whisper models and eBPF probes',
        ),
        isEmpty,
      );

      expect(
        catalog.extractMatchedTopics(
          'Building agentic services with OTel observability, OPA policy, and Argo CD!',
        ),
        [
          'AI Inference + Agentic',
          'OpenTelemetry',
          'Observability',
          'Open Policy Agent (OPA)',
          'Argo',
        ],
      );

      expect(
        catalog.extractMatchedTopics(
          'Cargo cultists overwhelmed by client clicks and node.js authors',
        ),
        isEmpty,
      );
    });

    test('rankSpaces sets peopleCount == 0 locally (B3) and omits %, nearby, and conversation', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);

      final spaces = catalog.rankSpaces(
        activeTopics: {'Observability', 'AI Inference + Agentic'},
        noteTexts: ['Tracing agentic memory with OTel and Cilium'],
        goingTalkIds: {'istio-day-mesh-2026-11-10-1500'},
      );

      expect(spaces, isNotEmpty);
      expect(
        spaces.where((s) => s.id == 'talk:coat-bag-check-2026-11-09-0700'),
        isEmpty,
      );

      for (final space in spaces) {
        expect(space.why, isNotEmpty);
        expect(space.why, isNot(contains('%')));
        expect(space.why.toLowerCase(), isNot(contains('nearby')));
        expect(space.why.toLowerCase(), isNot(contains('conversation')));
        expect(space.peopleCount, 0);
      }
    });

    test('coOccurringEdgesForTopics, topicsLinkedTo, recommendedBubbleTopics, and buildScopeGraph satisfy S3 and B3', () {
      final raw = File('assets/data/kubecon_schedule.json').readAsStringSync();
      final catalog = ScheduleCatalog.fromJsonString(raw);
      final sampleCatalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);

      // 1. topicsLinkedTo & coOccurringEdgesForTopics & recommendedBubbleTopics
      final linked = sampleCatalog.topicsLinkedTo(['Cilium']);
      expect(
        linked,
        equals({'Open Policy Agent (OPA)', 'Security', 'Network'}),
      );
      expect(linked, isNot(contains('Cilium')));

      final edges = sampleCatalog.coOccurringEdgesForTopics(
        ['Cilium', 'Security', 'Open Policy Agent (OPA)', 'Observability'],
      );
      expect(edges, isNotEmpty);
      expect(
        edges.any(
          (e) =>
              (e.source == 'Cilium' && e.target == 'Security') ||
              (e.source == 'Security' && e.target == 'Cilium'),
        ),
        isTrue,
      );

      final bubbles = sampleCatalog.recommendedBubbleTopics(
        selectedTopics: ['Cilium'],
      );
      expect(bubbles.first, 'Cilium');
      expect(
        bubbles.sublist(1, 4).toSet(),
        equals({'Open Policy Agent (OPA)', 'Security', 'Network'}),
      );

      // 2. Cold start buildScopeGraph: 0 on ring 0, 4 on ring 1, 5 on ring 2.
      final coldScope = catalog.buildScopeGraph(
        selectedTopics: const {},
        noteTopicLists: const [],
        goingTalkIds: const {},
      );
      expect(coldScope.topics, hasLength(9));
      expect(coldScope.topics.where((t) => t.ring == 0), isEmpty);
      expect(coldScope.topics.where((t) => t.ring == 1), hasLength(4));
      expect(coldScope.topics.where((t) => t.ring == 2), hasLength(5));
      expect(coldScope.talks, hasLength(9));
      expect(coldScope.edges.length, lessThanOrEqualTo(15));

      // Unique non-logistics talks across all shown topics.
      final coldTalkIds = coldScope.talks.map((t) => t.talk.id).toSet();
      expect(coldTalkIds, hasLength(9));
      for (final t in coldScope.talks) {
        expect(t.talk.isLogistics, isFalse);
      }
      for (final topic in coldScope.topics) {
        expect(topic.people, 0);
        expect(topic.why, isNot(contains('%')));
        expect(topic.why.toLowerCase(), isNot(contains('nearby')));
        expect(topic.why.toLowerCase(), isNot(contains('conversation')));
      }

      // 3. Warm buildScopeGraph with 6 direct topics: caps ring == 0 at <= 4 (S3)
      //    and prefers goingTalkIds.
      final ciliumTalks = catalog.talksForTopic('Cilium');
      final chosenGoingTalk = ciliumTalks.last;
      final warmScope = catalog.buildScopeGraph(
        selectedTopics: {
          'Cilium',
          'OpenTelemetry',
          'Observability',
          'Argo',
          'Istio',
          'Security',
        },
        noteTopicLists: const [
          ['Cilium', 'OpenTelemetry'],
        ],
        goingTalkIds: {chosenGoingTalk.id},
        livePeopleByTopic: const {'Cilium': 3},
      );
      expect(warmScope.topics, hasLength(9));
      final ring0 = warmScope.topics.where((t) => t.ring == 0).toList();
      expect(ring0.length, lessThanOrEqualTo(4));
      expect(ring0.length, 4);
      expect(
        ring0.map((t) => t.id),
        containsAll(['Cilium', 'OpenTelemetry']),
      );

      final ciliumEntry = warmScope.topics.firstWhere((t) => t.id == 'Cilium');
      expect(ciliumEntry.people, 3);
      expect(ciliumEntry.featuredTalk?.id, chosenGoingTalk.id);
      final ciliumTalkEntry = warmScope.talks.firstWhere(
        (t) => t.topicId == 'Cilium',
      );
      expect(ciliumTalkEntry.going, isTrue);
      expect(ciliumTalkEntry.talk.id, chosenGoingTalk.id);
    });
  });

  group('PhoneProfileStore (S1 & S8)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('confellow_profile_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('never writes attendeeToken to disk JSON (S8) and never puts note text into interests (S1)', () async {
      final profileFile = File('${tempDir.path}/confellow_profile.json');
      // Seed a legacy file with a plaintext attendeeToken to verify scrubbing on load.
      await profileFile.writeAsString(
        jsonEncode({
          'handle': 'cf_0123456789abcdef0123',
          'conference': 'cnh',
          'attendeeToken': 'legacy_plaintext_token_must_be_scrubbed',
          'selectedTopics': ['Cilium'],
        }),
      );

      final store1 = PhoneProfileStore(directoryProvider: () async => tempDir);
      final initial = await store1.load();
      await store1.flush();

      expect(initial.handle, 'cf_0123456789abcdef0123');
      expect(PhoneProfile.handlePattern.hasMatch(initial.handle), isTrue);

      await store1.setReviewBeforeSending(true);
      await store1.setInterests('Service mesh\nand eBPF\tdataplanes');
      await store1.toggleGoingTalk('cilium-policy-opa-2026-11-11-1400');
      await store1.recordNote(
        LocalNoteSummary(
          conversationId: 'note_unshared_1',
          topics: const ['Cilium', 'Security'],
          why: 'Tuned: Cilium, Security',
          shared: false,
          sharedText: 'raw unshared voice note that must stay private',
        ),
      );
      await store1.recordNote(
        LocalNoteSummary(
          conversationId: 'note_shared_2',
          topics: const ['OpenTelemetry'],
          why: 'Tuned: OpenTelemetry',
          shared: true,
          sharedText: 'explicitly shared note snippet excluded from PUT /me interests',
        ),
      );
      await store1.flush();

      final rawDisk = await profileFile.readAsString();
      final decodedDisk = jsonDecode(rawDisk) as Map<String, Object?>;
      expect(decodedDisk.containsKey('attendeeToken'), isFalse);
      expect(rawDisk, isNot(contains('legacy_plaintext_token_must_be_scrubbed')));
      expect(rawDisk, isNot(contains('raw unshared voice note that must stay private')));

      final reloadedStore = PhoneProfileStore(
        directoryProvider: () async => tempDir,
      );
      final reloaded = await reloadedStore.load();
      expect(reloaded.interests, 'Service mesh and eBPF dataplanes');

      final putMeInterests = reloaded.buildProfileInterests();
      expect(putMeInterests, contains('Service mesh and eBPF dataplanes'));
      expect(putMeInterests, contains('Topics: Cilium, Security, OpenTelemetry'));
      expect(putMeInterests, isNot(contains('private')));
      expect(
        putMeInterests,
        isNot(contains('explicitly shared note snippet excluded from PUT /me interests')),
      );
    });
  });

  group('NoteSubmission & LabeledFakeWavelengthBackend', () {
    test('returns honest local statusLabel and strips unshared note text in search', () async {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
      final fixedNow = DateTime.utc(2026, 11, 10, 18, 0);
      final fake = LabeledFakeWavelengthBackend(
        catalog: catalog,
        clock: () => fixedNow,
      );
      addTearDown(fake.close);

      final privateSub = NoteSubmission.create(
        ownerId: 'cf_0123456789abcdef0123',
        transcript: 'Private thought about Cilium policy enforcement',
        now: fixedNow,
        shared: false,
      );
      final sharedSub = NoteSubmission.create(
        ownerId: 'cf_0123456789abcdef0123',
        transcript: 'Happy to chat about Cilium and OPA!',
        now: fixedNow,
        shared: true,
      );

      final receipt1 = await fake.submitNote(privateSub);
      final receipt2 = await fake.submitNote(sharedSub);

      final expectedDocId = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                privateSub.conference,
                privateSub.handle,
                privateSub.conversationId,
              ]),
            ),
          )
          .toString();
      expect(receipt1.documentId, expectedDocId);
      expect(receipt1.matchedTopics, ['Cilium']);
      expect(receipt1.isLocalFallback, isTrue);
      expect(receipt1.transcriptSavedRemotely, isFalse);
      expect(receipt1.statusLabel, 'Saved on this phone. Not sent.');
      expect(receipt2.statusLabel, 'Saved on this phone. Not sent.');

      final search = await fake.searchContent('Cilium');
      expect(search.moments, hasLength(2));

      final privateHit = search.moments.firstWhere(
        (m) => m.id == receipt1.documentId,
      );
      expect(privateHit.shared, isFalse);
      expect(privateHit.sharedText, isNull);

      final sharedHit = search.moments.firstWhere((m) => m.shared);
      expect(sharedHit.sharedText, 'Happy to chat about Cilium and OPA!');

      final refresh = await fake.refreshRecommendations();
      expect(refresh.liveSuccess, isFalse);
    });
  });

  group('AttendeeWavelengthBackend + real TranscriptSync + AttendeeApi', () {
    late Directory tempDir;
    late ScheduleCatalog catalog;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'confellow_attendee_seam_',
      );
      catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('auto-claims cf_ handle (retrying 409 once), stores token in TranscriptStorage only (S8), uploads segment via TranscriptSync, enforces S1 on PUT /me, and gates POST /moments on shared == true', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      final initial = await store.load();
      expect(RegExp(r'^cf_[0-9a-f]{20}$').hasMatch(initial.handle), isTrue);

      final memoryStorage = _MemoryTranscriptStorage();
      var putMeCalls = 0;
      final putMeBodies = <Map<String, dynamic>>[];
      final segmentUploads = <Map<String, dynamic>>[];
      final momentBodies = <Map<String, dynamic>>[];

      final api = AttendeeApi(
        client: MockClient((request) async {
          expect(request.url.toString(), isNot(contains('tok_live_secret')));

          if (request.method == 'PUT' && request.url.path == '/me') {
            putMeCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            putMeBodies.add(body);
            expect(
              body.keys.toSet(),
              {'handle', 'conference', 'interests', 'topics', 'starred_talks'},
            );

            if (putMeCalls == 1) {
              expect(request.headers.containsKey('Authorization'), isFalse);
              expect(body['handle'], initial.handle);
              return http.Response(
                '{"detail":"That handle is already taken"}',
                409,
              );
            }
            if (putMeCalls == 2) {
              expect(request.headers.containsKey('Authorization'), isFalse);
              expect(body['handle'], isNot(equals(initial.handle)));
              expect(
                RegExp(r'^cf_[0-9a-f]{20}$').hasMatch(body['handle'] as String),
                isTrue,
              );
              return http.Response(
                jsonEncode({
                  ...body,
                  'last_active': '2026-11-10T18:00:00+00:00',
                  'expires_at': '2026-11-17T18:00:00+00:00',
                  'created': true,
                  'token': 'tok_live_secret',
                }),
                201,
              );
            }
            expect(request.headers['Authorization'], 'Bearer tok_live_secret');
            return http.Response(
              jsonEncode({
                ...body,
                'last_active': '2026-11-10T18:01:00+00:00',
                'expires_at': '2026-11-17T18:01:00+00:00',
                'created': false,
              }),
              200,
            );
          }

          if (request.method == 'PUT' &&
              request.url.path.endsWith('/sharing')) {
            expect(request.headers['Authorization'], 'Bearer tok_live_secret');
            final parts = request.url.pathSegments;
            final streamId = parts[1];
            final sequence = int.parse(parts[3]);
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            momentBodies.add({
              'stream_id': streamId,
              'sequence': sequence,
              ...body,
            });
            return http.Response(
              jsonEncode({
                'stream_id': streamId,
                'sequence': sequence,
                'shared': body['shared'],
              }),
              200,
            );
          }

          if (request.method == 'PUT' &&
              request.url.path.startsWith('/transcripts/')) {
            expect(request.headers['Authorization'], 'Bearer tok_live_secret');
            final parts = request.url.pathSegments;
            final streamId = parts[1];
            final sequence = int.parse(parts[3]);
            final payload = jsonDecode(request.body) as Map<String, dynamic>;
            segmentUploads.add({
              'stream_id': streamId,
              'sequence': sequence,
              ...payload,
            });
            return http.Response(
              jsonEncode({
                'stream_id': streamId,
                'sequence': sequence,
                'revision': payload['revision'],
                'result': 'created',
              }),
              200,
            );
          }

          if (request.method == 'POST' && request.url.path == '/moments') {
            expect(request.headers['Authorization'], 'Bearer tok_live_secret');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            momentBodies.add(body);
            return http.Response(
              jsonEncode({
                'id': 'moment_abc',
                'conference': 'cnh',
                'at': '2026-11-10T18:01:00+00:00',
                'expires_at': '2026-11-17T18:01:00+00:00',
              }),
              201,
            );
          }

          return http.Response('unexpected route', 404);
        }),
      );

      final sync = TranscriptSync(
        api: api,
        storage: memoryStorage,
        startTimer: false,
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      // 1. Unshared note: claims handle (409 -> 201), uploads segment 0 once,
      //    updates PUT /me without note text in `interests`, skips POST /moments.
      const privateTranscript =
          'Private debugging note on Cilium\nand OpenTelemetry secret details';
      final unsharedReceipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: initial.handle,
          transcript: privateTranscript,
          shared: false,
        ),
      );

      expect(unsharedReceipt.transcriptSavedRemotely, isTrue);
      expect(unsharedReceipt.isLocalFallback, isFalse);
      expect(unsharedReceipt.statusLabel, 'Saved to your wavelength.');
      expect(unsharedReceipt.momentId, isNull);
      expect(momentBodies, isEmpty);

      expect(segmentUploads, hasLength(1));
      expect(segmentUploads.single['sequence'], 0);
      expect(segmentUploads.single['revision'], 1);
      expect(segmentUploads.single['finalized'], isTrue);
      expect(segmentUploads.single['consent'], isTrue);
      expect(segmentUploads.single['transcript'], privateTranscript);

      // Token is in TranscriptStorage, NEVER in confellow_profile.json on disk (S8).
      expect(sync.token, 'tok_live_secret');
      expect(sync.conference, 'cnh');
      expect(
        (memoryStorage.decoded!['account'] as Map)['token'],
        'tok_live_secret',
      );
      await store.flush();
      final diskProfileRaw = await File(
        '${tempDir.path}/confellow_profile.json',
      ).readAsString();
      expect(diskProfileRaw, isNot(contains('tok_live_secret')));
      expect(diskProfileRaw, isNot(contains('attendeeToken')));

      // 2. Shared note: uploads segment 1, updates PUT /me (still zero note text
      //    in `interests` per S1, and EVERY PUT /me body includes `topics`!),
      //    and calls PUT /transcripts/{stream}/segments/1/sharing (011).
      const sharedTranscript =
          'Comparing Cilium\nand OPA\tfor multi-tenant clusters!';
      final sharedReceipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: store.profile!.handle,
          transcript: sharedTranscript,
          shared: true,
          source: 'spoken',
        ),
      );

      expect(sharedReceipt.transcriptSavedRemotely, isTrue);
      expect(sharedReceipt.statusLabel, 'Saved to your wavelength.');
      expect(sharedReceipt.momentId, isNotNull);
      expect(segmentUploads, hasLength(2));
      expect(segmentUploads.last['sequence'], 1);

      // S1 + 014 check across EVERY PUT /me payload ever sent:
      for (final body in putMeBodies) {
        expect(body.containsKey('topics'), isTrue);
        expect(body['topics'], isA<List<Object?>>());
        expect(body['topics'], isNotEmpty);
        final interests = body['interests'] as String;
        expect(interests, isNot(contains('Private debugging note')));
        expect(interests, isNot(contains('secret details')));
        expect(interests, isNot(contains('Comparing Cilium')));
        expect(interests, isNot(contains('multi-tenant clusters')));
      }
      expect(
        putMeBodies.last['topics'],
        containsAll(['Cilium', 'OpenTelemetry', 'Open Policy Agent (OPA)']),
      );

      expect(momentBodies, hasLength(1));
      expect(momentBodies.single['sequence'], 1);
      expect(momentBodies.single['shared'], isTrue);
      expect(momentBodies.single['participants_consented'], isTrue);
    });

    test('PUT /me retries without display_name on 422/503 keeping topics intact, and POST /matches caps excerpts at 280 chars without scores', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      await store.load();
      await store.completeOnboarding(
        displayName: 'Ada Lovelace',
        selectedTopics: const ['Cilium', 'Observability'],
        interests: 'Kernel observability',
      );

      final putMeAttempts = <Map<String, dynamic>>[];
      final matchBodies = <Map<String, dynamic>>[];

      final sync = TranscriptSync(
        storage: _MemoryTranscriptStorage(),
        startTimer: false,
        api: AttendeeApi(
          client: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              // Fail immediately if ANY PUT /me request omits `topics` (014).
              expect(body.containsKey('topics'), isTrue);
              expect(body['topics'], equals(['Cilium', 'Observability']));
              putMeAttempts.add(body);
              if (body.containsKey('display_name')) {
                return http.Response('{"detail":"mapping missing"}', 503);
              }
              final isInitial = request.headers['Authorization'] == null;
              return http.Response(
                jsonEncode({
                  ...body,
                  'last_active': '2026-11-10T18:00:00+00:00',
                  'expires_at': '2026-11-17T18:00:00+00:00',
                  'created': isInitial,
                  if (isInitial) 'token': 'tok_disp_1',
                }),
                isInitial ? 201 : 200,
              );
            }
            if (request.method == 'POST' && request.url.path == '/matches') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              matchBodies.add(body);
              return http.Response(
                jsonEncode({
                  'matches': [
                    {
                      'id': 'm_shared_1',
                      'excerpt': 'y' * 340,
                      'topics': ['Cilium'],
                      'updated_at': '2026-11-10T18:05:00+00:00',
                      'score': 0.91,
                      'similarity': 0.82,
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        ),
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      final synced = await backend.syncProfile(store.profile!);
      expect(synced.syncedRemotely, isTrue);
      // Tried with display_name first, retried without display_name on 503,
      // and retained displayName locally on the phone!
      expect(putMeAttempts.first['display_name'], 'Ada Lovelace');
      expect(putMeAttempts.any((b) => !b.containsKey('display_name')), isTrue);
      expect(store.profile!.displayName, 'Ada Lovelace');

      final lookup = await backend.findSharedNoteMatches(
        queryText: 'z' * 620,
      );
      expect(matchBodies.single['conference'], 'cnh');
      expect((matchBodies.single['interests'] as String).length, 500);
      expect(lookup.matches.single.id, 'm_shared_1');
      expect(lookup.matches.single.excerpt.length, 280);
      expect(lookup.matches.single.topics, ['Cilium']);
    });

    test('503 / offline returns "Saved on this phone. Not sent." and retains segment in TranscriptSync outbox for retry', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      final profile = await store.load();
      final memoryStorage = _MemoryTranscriptStorage();
      var failUploads = true;

      final api = AttendeeApi(
        client: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/me') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                ...body,
                'last_active': '2026-11-10T18:00:00+00:00',
                'expires_at': '2026-11-17T18:00:00+00:00',
                'created': request.headers['Authorization'] == null,
                if (request.headers['Authorization'] == null)
                  'token': 'tok_outbox_1',
              }),
              request.headers['Authorization'] == null ? 201 : 200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path.startsWith('/transcripts/')) {
            if (failUploads) {
              return http.Response('{"detail":"service unavailable"}', 503);
            }
            final parts = request.url.pathSegments;
            final payload = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'stream_id': parts[1],
                'sequence': int.parse(parts[3]),
                'revision': payload['revision'],
                'result': 'created',
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final sync = TranscriptSync(
        api: api,
        storage: memoryStorage,
        startTimer: false,
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      final receipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: profile.handle,
          transcript: 'Offline OpenTelemetry note retained in outbox',
          shared: false,
        ),
      );

      expect(receipt.transcriptSavedRemotely, isFalse);
      expect(receipt.isLocalFallback, isTrue);
      expect(receipt.statusLabel, 'Saved on this phone. Not sent.');
      expect(sync.hasPending, isTrue);
      expect((memoryStorage.decoded!['segments'] as List), hasLength(1));

      // Recover network and verify retained outbox segment flushes cleanly.
      failUploads = false;
      await sync.retry();
      expect(sync.hasPending, isFalse);
      expect((memoryStorage.decoded!['segments'] as List), isEmpty);
    });

    test('GET /search SearchMomentHit strips speakers and does NOT exempt __setup_smoke__ (S2)', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      await store.load();
      final memoryStorage = _MemoryTranscriptStorage();

      final sync = TranscriptSync(
        storage: memoryStorage,
        startTimer: false,
        api: AttendeeApi(
          client: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  ...body,
                  'last_active': '2026-11-10T18:00:00+00:00',
                  'expires_at': '2026-11-17T18:00:00+00:00',
                  'created': true,
                  'token': 'tok_search_1',
                }),
                201,
              );
            }
            if (request.method == 'GET' && request.url.path == '/search') {
              expect(
                request.headers['Authorization'],
                'Bearer tok_search_1',
              );
              return http.Response(
                jsonEncode({
                  'query': 'Cilium',
                  'conference': 'cnh',
                  'mode': 'hybrid',
                  'results': [
                    {
                      'type': 'talk',
                      'id': 'remote-talk-99',
                      'score': 9.2,
                      'topics': ['Cilium'],
                      'title': 'Cilium Deep Dive',
                      'abstract': 'Packet walk.',
                      'speakers': ['Speaker Should Be Stripped'],
                      'room': 'Hall B',
                      'start': '2026-11-11T10:00:00Z',
                      'end': '2026-11-11T10:35:00Z',
                    },
                    {
                      'type': 'moment',
                      'id': 'moment-smoke-unshared',
                      'conference': '__setup_smoke__',
                      'score': 2.0,
                      'topics': ['Cilium'],
                      'gist': 'smoke conference must NOT bypass shared==true in /search',
                      'source': 'spoken',
                    },
                    {
                      'type': 'moment',
                      'id': 'moment-shared',
                      'score': 1.1,
                      'topics': ['Cilium'],
                      'gist': 'explicitly shared attendee\ngist',
                      'shared': true,
                      'source': 'notes',
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('unexpected', 404);
          }),
        ),
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      final result = await backend.searchContent('Cilium');
      expect(result.mode, PublicSearchMode.hybrid);
      expect(result.talks.single.title, 'Cilium Deep Dive');
      expect(
        '${result.talks.single.title} ${result.talks.single.abstractText}',
        isNot(contains('Speaker Should Be Stripped')),
      );

      expect(result.moments, hasLength(2));
      expect(result.moments[0].id, 'moment-smoke-unshared');
      expect(result.moments[0].shared, isFalse);
      expect(result.moments[0].sharedText, isNull);

      expect(result.moments[1].id, 'moment-shared');
      expect(result.moments[1].shared, isTrue);
      expect(result.moments[1].sharedText, 'explicitly shared attendee gist');
    });

    test('refreshRecommendations runs PUT /me -> GET /graph + GET /search (when /recommendations is 404) and returns honest fallback message on 503', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      await store.load();
      await store.toggleTopic('Cilium');

      var serviceDown = false;
      final visitedPaths = <String>[];

      final sync = TranscriptSync(
        storage: _MemoryTranscriptStorage(),
        startTimer: false,
        api: AttendeeApi(
          client: MockClient((request) async {
            visitedPaths.add('${request.method} ${request.url.path}');
            if (serviceDown) {
              return http.Response('{"detail":"unavailable"}', 503);
            }
            if (request.method == 'PUT' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final isInitial = request.headers['Authorization'] == null;
              return http.Response(
                jsonEncode({
                  ...body,
                  'last_active': '2026-11-10T18:00:00+00:00',
                  'expires_at': '2026-11-17T18:00:00+00:00',
                  'created': isInitial,
                  if (isInitial) 'token': 'tok_refresh_1',
                }),
                isInitial ? 201 : 200,
              );
            }
            if (request.method == 'GET' &&
                request.url.path == '/recommendations') {
              return http.Response('{"detail":"not found"}', 404);
            }
            if (request.method == 'GET' && request.url.path == '/graph') {
              return http.Response(
                jsonEncode({
                  'conference': 'cnh',
                  'nodes': [
                    {'id': 'Cilium', 'label': 'Cilium', 'count': 9},
                    {'id': 'Security', 'label': 'Security', 'count': 6},
                  ],
                  'edges': [
                    {'source': 'Cilium', 'target': 'Security', 'weight': 4},
                  ],
                }),
                200,
              );
            }
            if (request.method == 'GET' && request.url.path == '/search') {
              return http.Response(
                jsonEncode({
                  'query': request.url.queryParameters['q'],
                  'conference': 'cnh',
                  'mode': 'hybrid',
                  'results': [
                    {
                      'type': 'moment',
                      'id': 'm1',
                      'score': 3.1,
                      'topics': ['Cilium'],
                    },
                    {
                      'type': 'moment',
                      'id': 'm2',
                      'score': 2.7,
                      'topics': ['Cilium', 'Security'],
                    },
                  ],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        ),
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      final ok = await backend.refreshRecommendations(
        typedInterests: 'Dataplane security',
      );
      expect(
        ok.liveSuccess,
        isTrue,
        reason: 'visited=$visitedPaths fallback=${ok.fallbackMessage}',
      );
      expect(ok.fallbackMessage, isNull);
      expect(ok.liveTopicCounts, {'Cilium': 9, 'Security': 6});
      expect(ok.livePeopleByTopic, {'Cilium': 2, 'Security': 1});
      expect(ok.liveEdges, [
        (source: 'Cilium', target: 'Security', weight: 4),
      ]);
      expect(visitedPaths, containsAll(['PUT /me', 'GET /graph', 'GET /search']));

      // Now simulate 503 outage and verify honest fallback message.
      serviceDown = true;
      final fallback = await backend.refreshRecommendations();
      expect(fallback.liveSuccess, isFalse);
      expect(
        fallback.fallbackMessage,
        'Could not reach ConFellow. Showing the schedule on this phone.',
      );
    });

    test('refreshRecommendations uses GET /recommendations when deployed (200) and treats empty GET /graph 200 as live', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      await store.load();

      final sync = TranscriptSync(
        storage: _MemoryTranscriptStorage(),
        startTimer: false,
        api: AttendeeApi(
          client: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final isInitial = request.headers['Authorization'] == null;
              return http.Response(
                jsonEncode({
                  ...body,
                  'last_active': '2026-11-10T18:00:00+00:00',
                  'expires_at': '2026-11-17T18:00:00+00:00',
                  'created': isInitial,
                  if (isInitial) 'token': 'tok_rec_1',
                }),
                isInitial ? 201 : 200,
              );
            }
            if (request.method == 'GET' &&
                request.url.path == '/recommendations') {
              return http.Response(
                jsonEncode({
                  'conference': 'cnh',
                  'mode': 'hybrid',
                  'based_on': {
                    'notes': 2,
                    'topics': ['Cilium'],
                    'interests': true,
                  },
                  'topics': [
                    {
                      'id': 'Observability',
                      'label': 'Observability',
                      'talks': 7,
                      'moments': 1,
                      'people': 2,
                      'mine': false,
                    },
                  ],
                  'results': <Object?>[],
                }),
                200,
              );
            }
            if (request.method == 'GET' && request.url.path == '/graph') {
              return http.Response(
                jsonEncode({
                  'conference': 'cnh',
                  'nodes': <Object?>[],
                  'edges': <Object?>[],
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          }),
        ),
      );
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        sync: sync,
        catalog: catalog,
        ownsSync: true,
      );
      addTearDown(backend.close);

      final emptyGraph = await backend.fetchGraph();
      expect(emptyGraph.isLocalFallback, isFalse);
      expect(emptyGraph.nodes, isEmpty);

      final res = await backend.refreshRecommendations();
      expect(res.liveSuccess, isTrue);
      expect(res.liveTopicCounts['Observability'], 8);
      expect(res.livePeopleByTopic['Observability'], 2);
      expect(res.recommendedTopicOrder, ['Observability']);
      expect(res.basedOnSummary, 'Based on 2 notes, Cilium, and your interests');
    });
  });
}
