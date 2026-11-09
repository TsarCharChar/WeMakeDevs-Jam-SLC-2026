import 'dart:convert';
import 'dart:io';

import 'package:conversation_garden/conversation_api.dart';
import 'package:conversation_garden/phone_profile_store.dart';
import 'package:conversation_garden/schedule_data.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
  group('ScheduleCatalog & ScheduleTalk', () {
    test('parses real session shapes, omits speaker names, and filters meta-tags', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
      expect(catalog.talks, hasLength(4));

      final agentTalk = catalog.talkById('agent-memory-otel-2026-11-10-1100')!;
      expect(agentTalk.room, 'Salt Palace | Level 2 | 250 A-C');
      expect(agentTalk.day, '2026-11-10');
      expect('${agentTalk.title} ${agentTalk.abstractText}', isNot(contains('Alice Example')));

      // Format, level, venue, and mini-summit wrapper meta-tags are excluded.
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

    test('parses full bundled kubecon_schedule.json asset when present', () {
      final assetFile = File('assets/data/kubecon_schedule.json');
      if (!assetFile.existsSync()) return;

      final catalog = ScheduleCatalog.fromJsonString(assetFile.readAsStringSync());
      expect(catalog.talks.length, 600);
      expect(catalog.topicVocabulary.length, 109);
      for (final topic in catalog.topicVocabulary) {
        expect(ScheduleCatalog.isMetaTag(topic), isFalse);
      }
    });

    test('extractMatchedTopics matches deterministically without inventing topics or substring false positives', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);

      // Unmatched terms (including eBPF or Whisper when absent from schedule tags)
      // never invent topics.
      expect(
        catalog.extractMatchedTopics('Exploring on-device Whisper models and eBPF probes'),
        isEmpty,
      );

      // Case-insensitive phrases + safe aliases only to existing schedule tags.
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

      // Word boundaries block substring traps ("cargo" != Argo, "overwhelmed" != Helm,
      // "client" != CLI, "authors" != Auth, "node.js" != Node).
      expect(
        catalog.extractMatchedTopics(
          'Cargo cultists overwhelmed by client clicks and node.js authors',
        ),
        isEmpty,
      );
    });

    test('rankSpaces produces qualitative Topic and Talk Spaces without percentages or "nearby"', () {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);

      final spaces = catalog.rankSpaces(
        activeTopics: {'Observability', 'AI Inference + Agentic'},
        noteTexts: ['Tracing agentic memory with OTel and Cilium'],
        goingTalkIds: {'istio-day-mesh-2026-11-10-1500'},
      );

      expect(spaces, isNotEmpty);
      expect(spaces.any((s) => s.kind == SpaceKind.topic && s.id.startsWith('topic:')), isTrue);
      expect(spaces.any((s) => s.kind == SpaceKind.talk && s.id.startsWith('talk:')), isTrue);

      // Coat + Bag Check logistics block is never surfaced as a Talk Space.
      expect(
        spaces.where((s) => s.id == 'talk:coat-bag-check-2026-11-09-0700'),
        isEmpty,
      );

      final goingSpace = spaces.firstWhere(
        (s) => s.id == 'talk:istio-day-mesh-2026-11-10-1500',
      );
      expect(goingSpace.isGoing, isTrue);
      expect(goingSpace.closeness, ClosenessRing.inner);
      expect(goingSpace.talk?.room, 'Salt Palace | Cloud Native Theater');

      for (final space in spaces) {
        expect(space.why, isNotEmpty);
        expect(space.why, isNot(contains('%')));
        expect(space.why.toLowerCase(), isNot(contains('nearby')));
        expect(space.why.toLowerCase(), isNot(contains('conversation')));
        expect(space.peopleCount, greaterThan(0));
        for (final topic in space.recentTopics) {
          expect(catalog.topicVocabulary, contains(topic));
        }
      }
    });
  });

  group('PhoneProfileStore', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('confellow_profile_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('auto-generates <=32-char handle and persists preferences and notes across restarts without leaking private text', () async {
      final store1 = PhoneProfileStore(directoryProvider: () async => tempDir);
      final initial = await store1.load();

      expect(initial.handle, startsWith('cf_'));
      expect(initial.handle.length, lessThanOrEqualTo(32));
      expect(PhoneProfile.handlePattern.hasMatch(initial.handle), isTrue);
      expect(PhoneProfile.identifierPattern.hasMatch(initial.ownerId), isTrue);
      expect(initial.conference, 'cnh');
      expect(initial.reviewBeforeSending, isFalse);

      await store1.setReviewBeforeSending(true);
      await store1.toggleTopic('Cilium');
      await store1.toggleGoingTalk('cilium-policy-opa-2026-11-11-1400');
      await store1.saveAttendeeToken('secret_bearer_token_123');
      await store1.recordNote(
        LocalNoteSummary(
          conversationId: 'note_unshared_1',
          topics: const ['Cilium', 'Security'],
          why: 'Tuned: Cilium, Security',
          shared: false,
          sharedText: 'raw unshared voice note that must stay private',
        ),
      );

      final rawDisk = await File('${tempDir.path}/confellow_profile.json').readAsString();
      expect(rawDisk, isNot(contains('raw unshared voice note that must stay private')));

      final store2 = PhoneProfileStore(directoryProvider: () async => tempDir);
      final reloaded = await store2.load();
      expect(reloaded.handle, initial.handle);
      expect(reloaded.reviewBeforeSending, isTrue);
      expect(reloaded.attendeeToken, 'secret_bearer_token_123');
      expect(reloaded.toString(), isNot(contains('secret_bearer_token_123')));
      expect(reloaded.selectedTopics, containsAll(['Cilium', 'Security']));
      expect(reloaded.goingTalkIds, ['cilium-policy-opa-2026-11-11-1400']);
      expect(reloaded.savedNotes.single.sharedText, isNull);
      expect(reloaded.savedNotes.single.toString(), isNot(contains('private')));
    });
  });

  group('NoteSubmission & LabeledFakeWavelengthBackend', () {
    test('creates unique conversationId per note, matches store.mjs fields/hash, and strips unshared note text in search', () async {
      final catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
      final fixedNow = DateTime.utc(2026, 11, 10, 18, 0);
      final fake = LabeledFakeWavelengthBackend(
        catalog: catalog,
        clock: () => fixedNow,
        smokeSearchApi: ConversationApi(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'conversations': [
                  {
                    'id': 'smoke-1',
                    'conference': '__setup_smoke__',
                    'transcript': 'synthetic smoke demo note',
                  },
                ],
              }),
              200,
            ),
          ),
        ),
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

      expect(privateSub.conversationId, isNot(equals(sharedSub.conversationId)));
      expect(privateSub.toString(), isNot(contains('Private thought')));

      final receipt1 = await fake.submitNote(privateSub);
      await fake.submitNote(sharedSub);

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

      final recorded = fake.submittedPayloads.first;
      expect(recorded['conference'], 'cnh');
      expect(recorded['handle'], 'cf_0123456789abcdef0123');
      expect(recorded['revision'], 1);
      expect(recorded['consent'], isTrue);
      expect(recorded['visibility'], 'conference');
      expect(recorded['isFinal'], isTrue);
      expect(recorded['shared'], isFalse);

      final searchHits = await fake.searchNotes('Cilium');
      expect(searchHits, hasLength(3));

      final smokeHit = searchHits.firstWhere((c) => c.id == 'smoke-1');
      expect(smokeHit.isDemo, isTrue);
      expect(smokeHit.sharedText, 'synthetic smoke demo note');

      final privateHit = searchHits.firstWhere((c) => c.id == receipt1.documentId);
      expect(privateHit.shared, isFalse);
      expect(privateHit.sharedText, isNull);
      expect(privateHit.topics, ['Cilium']);
      expect(privateHit.why, contains('Cilium'));

      final sharedHit = searchHits.firstWhere((c) => c.shared);
      expect(sharedHit.sharedText, 'Happy to chat about Cilium and OPA!');
    });
  });

  group('AttendeeWavelengthBackend (live Attendee API + local fallback)', () {
    late Directory tempDir;
    late ScheduleCatalog catalog;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('confellow_attendee_test_');
      catalog = ScheduleCatalog.fromJsonString(_sampleScheduleJson);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('claims handle on PUT /me (retrying 409 collision), omits POST /moments for private notes, and publishes sanitized gist when shared', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      final initial = await store.load();

      var putMeCalls = 0;
      final momentBodies = <Map<String, Object?>>[];

      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        catalog: catalog,
        client: MockClient((request) async {
          // Token must never appear in query parameters or URLs.
          expect(request.url.toString(), isNot(contains('tok_live')));

          if (request.method == 'PUT' && request.url.path == '/me') {
            putMeCalls++;
            final body = jsonDecode(request.body) as Map<String, Object?>;
            expect(
              body.keys.toSet(),
              {'handle', 'conference', 'interests', 'topics', 'starred_talks'},
            );
            if (putMeCalls == 1) {
              // Simulate handle collision on first unauthenticated claim.
              expect(request.headers.containsKey('Authorization'), isFalse);
              expect(body['handle'], initial.handle);
              return http.Response('{"detail":"That handle is already taken"}', 409);
            }
            if (putMeCalls == 2) {
              expect(request.headers.containsKey('Authorization'), isFalse);
              expect(body['handle'], isNot(equals(initial.handle)));
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

          if (request.method == 'POST' && request.url.path == '/moments') {
            expect(request.headers['Authorization'], 'Bearer tok_live_secret');
            final body = jsonDecode(request.body) as Map<String, Object?>;
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
      addTearDown(backend.close);

      // 1. Unshared note updates PUT /me (with 409 claim retry -> 201) and NEVER calls POST /moments.
      final unsharedReceipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: initial.handle,
          transcript: 'Private debugging note on Cilium\nand OpenTelemetry',
          shared: false,
        ),
      );
      expect(putMeCalls, 2);
      expect(momentBodies, isEmpty);
      expect(unsharedReceipt.momentId, isNull);
      expect(store.profile!.attendeeToken, 'tok_live_secret');

      // 2. Shared note updates PUT /me with Bearer token AND calls POST /moments with sanitized one-line gist.
      final sharedReceipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: store.profile!.handle,
          transcript: 'Comparing Cilium\nand OPA\tfor multi-tenant clusters!',
          shared: true,
          source: 'spoken',
        ),
      );
      expect(putMeCalls, 3);
      expect(sharedReceipt.momentId, 'moment_abc');
      expect(momentBodies, hasLength(1));
      expect(momentBodies.single, {
        'conference': 'cnh',
        'gist': 'Comparing Cilium and OPA for multi-tenant clusters!',
        'topics': ['Cilium', 'Open Policy Agent (OPA)'],
        'source': 'spoken',
        'approved': true,
      });
      expect(momentBodies.single.containsKey('transcript'), isFalse);
      expect(momentBodies.single.containsKey('handle'), isFalse);
    });

    test('GET /search sends Bearer token, strips speakers from talks, and strips moment gist unless explicitly shared', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      await store.load();
      await store.saveAttendeeToken('tok_search_live');
      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        catalog: catalog,
        client: MockClient((request) async {
          expect(request.url.path, '/search');
          expect(request.headers['Authorization'], 'Bearer tok_search_live');
          expect(request.url.queryParameters['q'], 'Cilium');
          expect(request.url.queryParameters['conference'], 'cnh');
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
                  'id': 'moment-unmarked',
                  'score': 1.4,
                  'topics': ['Cilium'],
                  'gist': 'unmarked moment text should stay hidden',
                  'source': 'spoken',
                },
                {
                  'type': 'moment',
                  'id': 'moment-shared',
                  'score': 1.1,
                  'topics': ['Cilium'],
                  'gist': 'explicitly shared attendee gist',
                  'shared': true,
                  'source': 'notes',
                },
              ],
            }),
            200,
          );
        }),
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
      expect(result.moments[0].id, 'moment-unmarked');
      expect(result.moments[0].sharedText, isNull);
      expect(result.moments[0].topics, ['Cilium']);
      expect(result.moments[1].id, 'moment-shared');
      expect(result.moments[1].sharedText, 'explicitly shared attendee gist');
    });

    test('503 / 404 from undeployed Attendee API falls back cleanly to local bundled KubeCon schedule', () async {
      final store = PhoneProfileStore(directoryProvider: () async => tempDir);
      final profile = await store.load();

      final backend = AttendeeWavelengthBackend(
        profileStore: store,
        catalog: catalog,
        client: MockClient((_) async => http.Response('{"detail":"disabled"}', 503)),
      );
      addTearDown(backend.close);

      final receipt = await backend.submitNote(
        NoteSubmission.create(
          ownerId: profile.handle,
          transcript: 'Testing OpenTelemetry fallback while Elastic is disabled',
        ),
      );
      expect(receipt.isLocalFallback, isTrue);
      expect(receipt.matchedTopics, ['OpenTelemetry']);
      expect(backend.isUsingLocalFallback, isTrue);

      final search = await backend.searchContent('OpenTelemetry');
      expect(search.mode, PublicSearchMode.localScheduleFallback);
      expect(search.talks, isNotEmpty);
      expect(search.moments.single.sharedText, isNull);

      final graph = await backend.fetchGraph(limit: 10);
      expect(graph.isLocalFallback, isTrue);
      expect(graph.nodes, isNotEmpty);
    });
  });
}
