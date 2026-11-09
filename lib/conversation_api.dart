import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

import 'attendee_api.dart';
import 'phone_profile_store.dart';
import 'schedule_data.dart';
import 'transcript_sync.dart';

/// Matched note returned by legacy `/querysession` search.
///
/// Enforces at both JSON-parsing and constructor level that [sharedText] is
/// `null` unless [shared] is `true` or [conference] is [demoConference].
@immutable
class Conversation {
  const Conversation({
    required this.id,
    String? sharedText,
    this.topics = const [],
    this.why,
    this.conference,
    this.shared = false,
  }) : _sharedText =
           (shared || conference == demoConference) ? sharedText : null;

  static const String demoConference = '__setup_smoke__';

  final String id;
  final String? _sharedText;

  /// Only populated when the note was explicitly shared or comes from the
  /// backend's synthetic `__setup_smoke__` demo document.
  String? get sharedText =>
      (shared || conference == demoConference) ? _sharedText : null;

  final List<String> topics;
  final String? why;
  final String? conference;
  final bool shared;

  bool get isDemo => conference == demoConference;

  factory Conversation.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Invalid note response');
    }
    final String id;
    if (json.containsKey('id')) {
      final rawId = json['id'];
      if (rawId is! String || rawId.isEmpty) {
        throw const FormatException('Invalid note id');
      }
      id = rawId;
    } else if (json['conversation_id'] case final String convId
        when convId.isNotEmpty) {
      id = convId;
    } else {
      throw const FormatException('Invalid note response');
    }

    final conference = json['conference'];
    if (conference != null && conference is! String) {
      throw const FormatException('Invalid note conference');
    }
    final sharedFlag = json['shared'];
    if (sharedFlag != null && sharedFlag is! bool) {
      throw const FormatException('Invalid shared flag');
    }
    final rawText = json['transcript'] ?? json['shared_text'] ?? json['gist'];
    if (rawText != null && rawText is! String) {
      throw const FormatException('Invalid note text');
    }
    final rawWhy = json['why'];
    if (rawWhy != null && rawWhy is! String) {
      throw const FormatException('Invalid match reason');
    }
    final rawTopics = json['topics'];
    final topics = <String>[];
    if (rawTopics != null) {
      if (rawTopics is! List) {
        throw const FormatException('Invalid note topics');
      }
      for (final item in rawTopics) {
        if (item is! String) {
          throw const FormatException('Invalid note topic');
        }
        final trimmed = item.trim();
        if (trimmed.isNotEmpty) topics.add(trimmed);
      }
    }
    if (rawText == null && rawTopics == null && rawWhy == null) {
      throw const FormatException('Missing note fields');
    }
    final isDemo = conference == demoConference;
    final isShared = sharedFlag == true;
    return Conversation(
      id: id,
      conference: conference as String?,
      shared: isShared,
      sharedText: (isShared || isDemo) ? rawText as String? : null,
      topics: List.unmodifiable(topics),
      why: rawWhy as String?,
    );
  }

  @override
  String toString() =>
      'Conversation(id: $id, topics: $topics, shared: $shared, isDemo: $isDemo)';
}

class SearchException implements Exception {
  const SearchException(this.message);
  final String message;
}

class NoteSubmissionException implements Exception {
  const NoteSubmissionException(this.message);
  final String message;
}

/// Legacy `/querysession` client kept intact for smoke-note verification and
/// existing `SearchScreen` compatibility.
class ConversationApi {
  ConversationApi({
    http.Client? client,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _baseUrl =
           baseUrl ??
           Uri.parse(
             const String.fromEnvironment(
               'API_BASE_URL',
               defaultValue: 'https://grindset.cnh.radarhq.io',
             ),
           );

  final http.Client _client;
  final Uri _baseUrl;
  final Duration timeout;

  Future<List<Conversation>> search(String interests) async {
    final topic = interests.trim();
    if (topic.runes.length < 2 || topic.runes.length > 120) {
      throw const SearchException('Enter between 2 and 120 characters.');
    }
    if (!_isValidHttpsBaseUrl(_baseUrl)) {
      throw const SearchException(
        'The search server address is not configured correctly.',
      );
    }
    try {
      final response = await _client
          .get(
            _baseUrl
                .resolve('/querysession')
                .replace(queryParameters: {'topic': topic}),
            headers: {'Accept': 'application/json'},
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw SearchException(switch (response.statusCode) {
          401 || 403 => 'Search access is unavailable. Please try again later.',
          422 => 'Enter between 2 and 120 characters.',
          429 => 'Too many searches. Please wait a moment and try again.',
          _ => 'Note search is unavailable. Please try again.',
        });
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body case {'conversations': final List<Object?> conversations}) {
        return conversations.map(Conversation.fromJson).toList(growable: false);
      }
      throw const FormatException('Missing conversations');
    } on TimeoutException {
      throw const SearchException('Search took too long. Please try again.');
    } on http.ClientException {
      throw const SearchException(
        'Could not reach search. Check your connection and try again.',
      );
    } on FormatException {
      throw const SearchException(
        'The server returned an unexpected response. Please try again later.',
      );
    }
  }

  void close() => _client.close();
}

/// Dedicated `GET /search` moment hit model.
///
/// Enforces at construction that [sharedText] is populated **ONLY** when
/// [shared] is `true`, capped at 280 runes, with zero `__setup_smoke__`
/// exemption.
@immutable
class SearchMomentHit {
  SearchMomentHit({
    required this.id,
    Iterable<String> topics = const [],
    required this.why,
    this.shared = false,
    String? sharedText,
  }) : topics = List.unmodifiable(topics),
       sharedText = shared && sharedText != null
           ? _nullIfEmpty(_collapseSingleLine(sharedText, maxRunes: 280))
           : null;

  final String id;
  final List<String> topics;
  final String why;
  final bool shared;
  final String? sharedText;

  @override
  String toString() =>
      'SearchMomentHit(id: $id, topics: $topics, shared: $shared)';
}

/// One-shot finished note submission DTO supporting both the `store.mjs`
/// adapter contract and the Attendee API (`TranscriptSync` + `PUT /me` +
/// opt-in `POST /moments`).
@immutable
class NoteSubmission {
  NoteSubmission({
    required this.conference,
    required this.ownerId,
    required this.conversationId,
    required String transcript,
    required DateTime expiresAt,
    Iterable<String> topics = const [],
    this.revision = 1,
    this.consent = true,
    this.visibility = 'conference',
    this.isFinal = true,
    this.shared = false,
    this.source = 'spoken',
  }) : transcript = transcript.trim(),
       expiresAt = expiresAt.toUtc(),
       topics = List.unmodifiable(_normalizeSubmissionTopics(topics));

  /// Creates a one-shot note submission with a unique [conversationId] per note,
  /// `consent: true`, `visibility: 'conference'`, `revision: 1`, and
  /// `isFinal: true`.
  factory NoteSubmission.create({
    required String ownerId,
    required String transcript,
    String conference = PhoneProfile.defaultConference,
    String? conversationId,
    Iterable<String> topics = const [],
    bool shared = false,
    String source = 'spoken',
    DateTime? now,
    Duration ttl = const Duration(days: 7),
    Random? random,
  }) {
    final currentUtc = (now ?? DateTime.now()).toUtc();
    return NoteSubmission(
      conference: conference.trim(),
      ownerId: ownerId.trim(),
      conversationId:
          conversationId?.trim() ??
          generateConversationId(random: random ?? Random.secure()),
      transcript: transcript,
      topics: topics,
      expiresAt: currentUtc.add(ttl),
      shared: shared,
      source: source == 'notes' ? 'notes' : 'spoken',
    );
  }

  final String conference;
  final String ownerId;

  /// Attendee handle alias matching `server/elastic/store.mjs` and `PUT /me`.
  String get handle => ownerId;

  final String conversationId;
  final int revision;
  final String transcript;
  final bool consent;
  final String visibility;
  final bool isFinal;
  final List<String> topics;
  final DateTime expiresAt;
  final bool shared;

  /// `'spoken'` or `'notes'`, used when publishing an approved shared moment.
  final String source;

  static String generateConversationId({Random? random}) {
    final rng = random ?? Random.secure();
    final buffer = StringBuffer('note_');
    for (var i = 0; i < 10; i++) {
      buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Validates all fields against `server/elastic/store.mjs` and
  /// `backend/models.py` constraints before leaving the seam.
  void validate({DateTime? now}) {
    if (!PhoneProfile.identifierPattern.hasMatch(conference)) {
      throw const NoteSubmissionException('Invalid conference identifier.');
    }
    if (!PhoneProfile.identifierPattern.hasMatch(ownerId)) {
      throw const NoteSubmissionException('Invalid note owner handle.');
    }
    if (!PhoneProfile.identifierPattern.hasMatch(conversationId)) {
      throw const NoteSubmissionException('Invalid note conversationId.');
    }
    if (revision < 1) {
      throw const NoteSubmissionException('Note revision must be at least 1.');
    }
    final runeLength = transcript.runes.length;
    if (runeLength < 1 || runeLength > 20000) {
      throw const NoteSubmissionException(
        'Note text must be between 1 and 20,000 characters.',
      );
    }
    if (!consent) {
      throw const NoteSubmissionException(
        'Note submission requires explicit consent: true.',
      );
    }
    if (visibility != 'conference') {
      throw const NoteSubmissionException(
        'Matched notes must use visibility: "conference".',
      );
    }
    if (!isFinal) {
      throw const NoteSubmissionException(
        'Partial transcripts cannot be streamed; send finished notes only.',
      );
    }
    final referenceNow = (now ?? DateTime.now()).toUtc();
    if (!expiresAt.isAfter(referenceNow)) {
      throw const NoteSubmissionException(
        'expiresAt must be a future UTC timestamp.',
      );
    }
  }

  /// Computes the exact SHA-256 document ID used by `server/elastic/store.mjs`:
  /// `sha256(JSON.stringify([conference, handle, conversationId]))`.
  String computeStoreDocumentId() {
    final encoded = utf8.encode(
      jsonEncode([conference, handle, conversationId]),
    );
    return sha256.convert(encoded).toString();
  }

  /// Outgoing payload matching `server/elastic/store.mjs` `ConversationStore.upsert`.
  Map<String, Object?> toStorePayload({DateTime? now}) {
    validate(now: now);
    return {
      'conference': conference,
      'handle': handle,
      'ownerId': ownerId,
      'conversationId': conversationId,
      'revision': revision,
      'transcript': transcript,
      'consent': consent,
      'visibility': visibility,
      'isFinal': isFinal,
      'topics': topics,
      'expiresAt': expiresAt.toUtc().toIso8601String(),
      'shared': shared,
    };
  }

  /// Builds the `POST /moments` request body (`MomentWrite`, `extra="forbid"`).
  ///
  /// Returns `null` whenever [shared] is `false` so unshared raw note text is
  /// never published to the public `moments` index, or when fewer than 1
  /// schedule topic is available.
  Map<String, dynamic>? toMomentPayload({
    required Iterable<String> effectiveTopics,
  }) {
    if (!shared) return null;
    final momentTopics = _normalizeSubmissionTopics(
      effectiveTopics,
      maxCount: 5,
    );
    if (momentTopics.isEmpty) return null;
    final gist = _collapseSingleLine(transcript, maxRunes: 280);
    if (gist.isEmpty) return null;
    return <String, dynamic>{
      'conference': conference,
      'gist': gist,
      'topics': momentTopics,
      'source': source == 'notes' ? 'notes' : 'spoken',
      'approved': true,
    };
  }

  /// Redacted string representation: never logs [transcript].
  @override
  String toString() =>
      'NoteSubmission(conversationId: $conversationId, topics: $topics, '
      'shared: $shared, revision: $revision)';
}

@immutable
class NoteReceipt {
  const NoteReceipt({
    required this.documentId,
    required this.conversationId,
    required this.revision,
    required this.matchedTopics,
    required this.isLocalFallback,
    this.transcriptSavedRemotely = false,
    required this.statusLabel,
    this.momentId,
  });

  static const String savedRemotelyLabel = 'Saved to your wavelength.';
  static const String savedLocallyLabel = 'Saved on this phone. Not sent.';

  final String documentId;
  final String conversationId;
  final int revision;
  final List<String> matchedTopics;
  final bool isLocalFallback;
  final bool transcriptSavedRemotely;
  final String statusLabel;

  /// Populated only when [NoteSubmission.shared] was `true` and `POST /moments`
  /// succeeded on the live Attendee API.
  final String? momentId;
}

@immutable
class ProfileSyncResult {
  const ProfileSyncResult({
    required this.profile,
    required this.syncedRemotely,
    required this.created,
  });

  final PhoneProfile profile;
  final bool syncedRemotely;
  final bool created;
}

@immutable
class TopicGraphNode {
  const TopicGraphNode({
    required this.id,
    required this.label,
    required this.count,
  });

  final String id;
  final String label;
  final int count;

  factory TopicGraphNode.fromJson(Object? json) {
    if (json case {
      'id': final String id,
      'label': final String label,
      'count': final int count,
    } when id.trim().isNotEmpty && count >= 0) {
      return TopicGraphNode(
        id: id.trim(),
        label: label.trim().isEmpty ? id.trim() : label.trim(),
        count: count,
      );
    }
    throw const FormatException('Invalid graph node');
  }
}

@immutable
class TopicGraphEdge {
  const TopicGraphEdge({
    required this.source,
    required this.target,
    required this.weight,
  });

  final String source;
  final String target;
  final int weight;

  factory TopicGraphEdge.fromJson(Object? json) {
    if (json case {
      'source': final String source,
      'target': final String target,
      'weight': final int weight,
    } when source.trim().isNotEmpty && target.trim().isNotEmpty && weight >= 0) {
      return TopicGraphEdge(
        source: source.trim(),
        target: target.trim(),
        weight: weight,
      );
    }
    throw const FormatException('Invalid graph edge');
  }
}

@immutable
class TopicGraph {
  const TopicGraph({
    required this.conference,
    required this.nodes,
    required this.edges,
    required this.isLocalFallback,
  });

  final String conference;
  final List<TopicGraphNode> nodes;
  final List<TopicGraphEdge> edges;
  final bool isLocalFallback;
}

enum PublicSearchMode { hybrid, keyword, localScheduleFallback }

@immutable
class PublicSearchResult {
  const PublicSearchResult({
    required this.query,
    required this.conference,
    required this.mode,
    required this.talks,
    required this.moments,
  });

  final String query;
  final String conference;
  final PublicSearchMode mode;

  /// Matching sessions with speaker names stripped.
  final List<ScheduleTalk> talks;

  /// Matching attendee moments with unshared text stripped (`shared == true` only).
  final List<SearchMomentHit> moments;
}

@immutable
class SharedNoteMatch {
  SharedNoteMatch({
    required this.id,
    required String excerpt,
    Iterable<String> topics = const [],
  }) : excerpt = _collapseSingleLine(excerpt, maxRunes: 280),
       topics = List.unmodifiable(_normalizeSubmissionTopics(topics));

  final String id;

  /// Excerpt from a note its author explicitly chose to share, capped at 280
  /// characters. Score, similarity, and author handle are never exposed.
  final String excerpt;
  final List<String> topics;
}

@immutable
class MatchesLookupResult {
  const MatchesLookupResult({
    this.matches = const <SharedNoteMatch>[],
    this.needsInput = false,
  });

  final List<SharedNoteMatch> matches;
  final bool needsInput;
}

@immutable
class WavelengthRefreshResult {
  const WavelengthRefreshResult({
    required this.liveSuccess,
    this.liveTopicCounts = const {},
    this.livePeopleByTopic = const {},
    this.liveEdges = const [],
    this.recommendedTopicOrder = const [],
    this.basedOnSummary,
    this.fallbackMessage,
  });

  final bool liveSuccess;
  final Map<String, int> liveTopicCounts;
  final Map<String, int> livePeopleByTopic;
  final List<({String source, String target, int weight})> liveEdges;
  final List<String> recommendedTopicOrder;
  final String? basedOnSummary;
  final String? fallbackMessage;
}

/// Slim backend seam through which the ConFellow Flutter app communicates
/// with the Attendee API (or its labeled local schedule fallback).
abstract interface class WavelengthBackend {
  /// True when operating purely against the labeled fake / local schedule.
  bool get isFake;

  /// True when the latest backend call fell back to the bundled KubeCon schedule.
  bool get isUsingLocalFallback;

  /// Honest status copy describing whether live attendee endpoints or local
  /// schedule fallback are active.
  String get statusLabel;

  /// Reserved behind a flag until `/rooms` exists on the backend.
  bool get roomsAvailable;

  Future<ProfileSyncResult> syncProfile(
    PhoneProfile profile, {
    String? interestsOverride,
  });

  Future<NoteReceipt> submitNote(NoteSubmission submission);

  Future<PublicSearchResult> searchContent(String query, {int limit = 20});

  Future<TopicGraph> fetchGraph({int limit = 50});

  Future<WavelengthRefreshResult> refreshRecommendations({
    String? typedInterests,
  });

  Future<MatchesLookupResult> findSharedNoteMatches({
    String? queryText,
    int limit = 10,
  });

  void close();
}

/// Production Attendee API backend reusing [TranscriptSync] + [AttendeeApi] for
/// secure token storage (`FlutterSecureStorage`), durable transcript segment
/// uploads (`PUT /transcripts/{stream}/segments/{seq}`), profile updates
/// (`PUT /me`), opt-in shared moments (`POST /moments`), graph (`GET /graph`),
/// and hybrid search (`GET /search`), with clean fallback to [ScheduleCatalog].
class AttendeeWavelengthBackend implements WavelengthBackend {
  AttendeeWavelengthBackend({
    required this.profileStore,
    required this.sync,
    this.catalog,
    this.ownsSync = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const String unreachableFallbackMessage =
      'Could not reach ConFellow. Showing the schedule on this phone.';

  final PhoneProfileStore profileStore;
  final TranscriptSync sync;
  final ScheduleCatalog? catalog;
  final bool ownsSync;
  final DateTime Function() _clock;

  bool _usingLocalFallback = false;

  @override
  bool get isFake => false;

  @override
  bool get isUsingLocalFallback => _usingLocalFallback;

  @override
  bool get roomsAvailable => true;

  @override
  String get statusLabel => _usingLocalFallback
      ? 'Local KubeCon schedule active · live attendee sync will resume automatically'
      : 'Connected to ConFellow conference wavelength';

  Future<(PhoneProfile profile, bool created)> _ensureConnected(
    PhoneProfile profile,
  ) async {
    var current = profile;
    var created = false;
    if (!sync.loaded) {
      await sync.initialize();
    }
    if (!sync.connected) {
      final initialInterests = current.buildProfileInterests();
      final initialTopics = current.combinedProfileTopics;
      final initialStarred = current.goingTalkIds.take(100).toList(
        growable: false,
      );
      final initialName = current.displayName.isEmpty
          ? null
          : current.displayName;
      try {
        await sync.connect(
          current.handle,
          current.conference,
          displayName: initialName,
          interests: initialInterests,
          topics: initialTopics,
          starredTalks: initialStarred,
        );
        created = sync.connected;
      } on AttendeeApiException catch (e) {
        if (e.status == 409) {
          current = await profileStore.rotateHandle(
            conference: current.conference,
          );
          try {
            await sync.connect(
              current.handle,
              current.conference,
              displayName: current.displayName.isEmpty
                  ? null
                  : current.displayName,
              interests: current.buildProfileInterests(),
              topics: current.combinedProfileTopics,
              starredTalks: current.goingTalkIds.take(100).toList(
                growable: false,
              ),
            );
            created = sync.connected;
          } on AttendeeApiException {
            // Offline, 503, or repeated collision: degrade cleanly without throwing.
          }
        }
      }
    }
    return (current, created);
  }

  @override
  Future<ProfileSyncResult> syncProfile(
    PhoneProfile profile, {
    String? interestsOverride,
  }) async {
    final (current, createdOnConnect) = await _ensureConnected(profile);
    if (!sync.connected ||
        sync.token == null ||
        sync.handle == null ||
        sync.conference == null) {
      _usingLocalFallback = true;
      return ProfileSyncResult(
        profile: current,
        syncedRemotely: false,
        created: false,
      );
    }

    final resolvedInterests = interestsOverride != null
        ? _collapseSingleLine(interestsOverride, maxRunes: 1000)
        : current.buildProfileInterests();
    final topics = current.combinedProfileTopics;
    final starredTalks = current.goingTalkIds.take(100).toList(growable: false);
    final candidateDisplayName = current.displayName.isEmpty
        ? null
        : current.displayName;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        Map<String, dynamic> response;
        try {
          response = await sync.api.updateProfile(
            sync.handle!,
            sync.conference!,
            token: sync.token,
            displayName: candidateDisplayName,
            interests: resolvedInterests,
            topics: topics,
            starredTalks: starredTalks,
          );
        } on AttendeeApiException catch (e) {
          // 016: If backend branch or Elastic mapping for `display_name` is not
          // live yet (422 or 503), retry once without `display_name` while
          // keeping the name saved on the phone for future syncs.
          if (candidateDisplayName != null &&
              (e.status == 422 || e.status == 503)) {
            response = await sync.api.updateProfile(
              sync.handle!,
              sync.conference!,
              token: sync.token,
              interests: resolvedInterests,
              topics: topics,
              starredTalks: starredTalks,
            );
          } else {
            rethrow;
          }
        }
        sync.rememberProfileFields(
          interests: resolvedInterests,
          topics: topics,
          starredTalks: starredTalks,
        );
        _usingLocalFallback = false;
        return ProfileSyncResult(
          profile: current,
          syncedRemotely: true,
          created: createdOnConnect || response['created'] == true,
        );
      } on AttendeeApiException catch (e) {
        if (attempt == 0 && e.status == 409) {
          continue;
        }
        _usingLocalFallback = true;
        return ProfileSyncResult(
          profile: current,
          syncedRemotely: false,
          created: false,
        );
      }
    }

    _usingLocalFallback = true;
    return ProfileSyncResult(
      profile: current,
      syncedRemotely: false,
      created: false,
    );
  }

  @override
  Future<NoteReceipt> submitNote(NoteSubmission submission) async {
    final nowUtc = _clock().toUtc();
    submission.validate(now: nowUtc);

    final matchedTopics = _resolveMatchedTopics(
      transcript: submission.transcript,
      explicitTopics: submission.topics,
      catalog: catalog,
    );
    final whySummary = matchedTopics.isNotEmpty
        ? 'Tuned: ${matchedTopics.join(', ')}'
        : 'Note saved';

    final localSummary = LocalNoteSummary(
      conversationId: submission.conversationId,
      topics: matchedTopics,
      why: whySummary,
      shared: submission.shared,
      sharedText: submission.shared ? submission.transcript : null,
      source: submission.source,
      createdAt: nowUtc,
    );

    // S1: Never store or transmit note transcript/sharedText inside `interests`.
    var updatedProfile = await profileStore.recordNote(localSummary);
    final (connectedProfile, _) = await _ensureConnected(updatedProfile);
    updatedProfile = connectedProfile;

    var transcriptSaved = false;
    int? savedSequence;
    if (sync.connected) {
      if (!sync.enabled) await sync.setEnabled(true);
      if (sync.canBegin) {
        try {
          await sync.begin();
          savedSequence = sync.lastSequence;
          await sync.finish(submission.transcript);
          await sync.flush();
          transcriptSaved = !sync.hasPending && sync.error == null;
        } on AttendeeApiException {
          transcriptSaved = false;
        }
      }
    }

    final profileSync = await syncProfile(updatedProfile);
    updatedProfile = profileSync.profile;

    String? sharedSegmentRef;
    if (submission.shared &&
        transcriptSaved &&
        sync.connected &&
        sync.token != null &&
        sync.stream != null &&
        savedSequence != null) {
      try {
        final shareResp = await sync.api.setSegmentSharing(
          sync.token!,
          sync.stream!,
          savedSequence,
          shared: true,
          participantsConsented: true,
        );
        if (shareResp['shared'] == true) {
          sharedSegmentRef = '${sync.stream}:$savedSequence';
        }
      } on AttendeeApiException {
        // Best-effort sharing toggle; private finalized segment stays intact.
      }
    }

    _usingLocalFallback = !transcriptSaved;
    return NoteReceipt(
      documentId: submission.computeStoreDocumentId(),
      conversationId: submission.conversationId,
      revision: submission.revision,
      matchedTopics: matchedTopics,
      isLocalFallback: !transcriptSaved,
      transcriptSavedRemotely: transcriptSaved,
      statusLabel: transcriptSaved
          ? NoteReceipt.savedRemotelyLabel
          : NoteReceipt.savedLocallyLabel,
      momentId: sharedSegmentRef,
    );
  }

  @override
  Future<PublicSearchResult> searchContent(
    String query, {
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 200) {
      throw const SearchException('Enter between 1 and 200 characters.');
    }
    final safeLimit = limit.clamp(1, 50);
    var profile = await profileStore.load();
    final (connectedProfile, _) = await _ensureConnected(profile);
    profile = connectedProfile;
    final conference = sync.conference ?? profile.conference;

    if (sync.connected && sync.token != null) {
      try {
        final body = await sync.api.search(
          sync.token!,
          conference,
          trimmed,
          limit: safeLimit,
        );
        if (body case {
          'mode': final String rawMode,
          'results': final List<Object?> results,
        }) {
          final talks = <ScheduleTalk>[];
          final moments = <SearchMomentHit>[];
          for (final hit in results) {
            if (hit is! Map) continue;
            final type = hit['type'];
            final id = hit['id'];
            if (id is! String || id.trim().isEmpty) continue;
            if (type == 'talk') {
              talks.add(_parseSearchTalkHit(hit, catalog: catalog));
            } else if (type == 'moment') {
              moments.add(_parseSearchMomentHit(hit, catalog: catalog));
            }
          }
          _usingLocalFallback = false;
          return PublicSearchResult(
            query: trimmed,
            conference: conference,
            mode: rawMode == 'keyword'
                ? PublicSearchMode.keyword
                : PublicSearchMode.hybrid,
            talks: List.unmodifiable(talks),
            moments: List.unmodifiable(moments),
          );
        }
      } on AttendeeApiException catch (e) {
        if (e.status != null && !_isFallbackStatus(e.status!)) {
          throw SearchException(switch (e.status!) {
            401 || 403 =>
              'Search access is unavailable. Please try again later.',
            422 => 'Enter between 1 and 200 characters.',
            429 => 'Too many searches. Please wait a moment and try again.',
            _ => 'Search is unavailable right now. Please try again.',
          });
        }
      } on FormatException {
        // Fall through to bundled schedule fallback.
      }
    }

    _usingLocalFallback = true;
    return _localSearchFallback(
      query: trimmed,
      conference: conference,
      limit: safeLimit,
      profile: profile,
    );
  }

  @override
  Future<TopicGraph> fetchGraph({int limit = 50}) async {
    final safeLimit = limit.clamp(1, 100);
    var profile = await profileStore.load();
    final (connectedProfile, _) = await _ensureConnected(profile);
    profile = connectedProfile;
    final conference = sync.conference ?? profile.conference;

    if (sync.connected && sync.token != null) {
      try {
        final body = await sync.api.graph(
          sync.token!,
          conference,
          limit: safeLimit,
        );
        if (body case {
          'nodes': final List<Object?> rawNodes,
          'edges': final List<Object?> rawEdges,
        }) {
          final nodes = [
            for (final item in rawNodes)
              if (item is Map) TopicGraphNode.fromJson(item),
          ].where((n) => !ScheduleCatalog.isMetaTag(n.label)).toList();

          final allowedIds = {for (final n in nodes) n.id};
          final edges = [
            for (final item in rawEdges)
              if (item is Map) TopicGraphEdge.fromJson(item),
          ].where(
            (e) =>
                allowedIds.contains(e.source) && allowedIds.contains(e.target),
          ).toList();

          // HTTP 200 is live success (`isLocalFallback: false`) even when `nodes` is empty.
          _usingLocalFallback = false;
          return TopicGraph(
            conference: conference,
            nodes: List.unmodifiable(nodes),
            edges: List.unmodifiable(edges),
            isLocalFallback: false,
          );
        }
      } on AttendeeApiException {
        // Fall through to bundled schedule graph.
      } on FormatException {
        // Fall through to bundled schedule graph.
      }
    }

    _usingLocalFallback = true;
    return _buildLocalTopicGraph(
      catalog: catalog,
      conference: conference,
      limit: safeLimit,
    );
  }

  @override
  Future<WavelengthRefreshResult> refreshRecommendations({
    String? typedInterests,
  }) async {
    var profile = typedInterests != null
        ? await profileStore.setInterests(typedInterests)
        : await profileStore.load();

    final syncResult = await syncProfile(profile);
    profile = syncResult.profile;
    if (!syncResult.syncedRemotely ||
        !sync.connected ||
        sync.token == null ||
        sync.conference == null) {
      _usingLocalFallback = true;
      return const WavelengthRefreshResult(
        liveSuccess: false,
        fallbackMessage: unreachableFallbackMessage,
      );
    }

    // 1. Try optional `GET /recommendations` first; fall back cleanly to
    //    `GET /graph` + `GET /search` on 404.
    try {
      final recBody = await sync.api.recommendations(
        sync.token!,
        sync.conference!,
      );
      final liveTopicCounts = <String, int>{};
      final livePeopleByTopic = <String, int>{};
      final recommendedTopicOrder = <String>[];

      if (recBody['topics'] case final List<Object?> rawTopics) {
        for (final item in rawTopics) {
          if (item is! Map) continue;
          final rawLabel = item['label'] ?? item['id'];
          if (rawLabel is! String || rawLabel.trim().isEmpty) continue;
          final label = rawLabel.trim();
          if (ScheduleCatalog.isMetaTag(label)) continue;
          final talksCount = item['talks'] is int ? item['talks'] as int : 0;
          final momentsCount = item['moments'] is int
              ? item['moments'] as int
              : 0;
          final peopleCount = item['people'] is int ? item['people'] as int : 0;
          liveTopicCounts[label] =
              (talksCount < 0 ? 0 : talksCount) +
              (momentsCount < 0 ? 0 : momentsCount);
          if (peopleCount > 0) {
            livePeopleByTopic[label] = peopleCount;
          }
          if (!recommendedTopicOrder.contains(label)) {
            recommendedTopicOrder.add(label);
          }
        }
      }

      final basedOnSummary = _formatBasedOnSummary(recBody['based_on']);

      var liveEdges = const <({String source, String target, int weight})>[];
      final graph = await fetchGraph(limit: 50);
      if (!graph.isLocalFallback) {
        for (final n in graph.nodes) {
          liveTopicCounts.putIfAbsent(n.label, () => n.count);
        }
        liveEdges = List.unmodifiable([
          for (final e in graph.edges)
            (source: e.source, target: e.target, weight: e.weight),
        ]);
      }

      _usingLocalFallback = false;
      return WavelengthRefreshResult(
        liveSuccess: true,
        liveTopicCounts: Map.unmodifiable(liveTopicCounts),
        livePeopleByTopic: Map.unmodifiable(livePeopleByTopic),
        liveEdges: liveEdges,
        recommendedTopicOrder: List.unmodifiable(recommendedTopicOrder),
        basedOnSummary: basedOnSummary,
      );
    } on AttendeeApiException catch (e) {
      if (e.status != 404) {
        _usingLocalFallback = true;
        return const WavelengthRefreshResult(
          liveSuccess: false,
          fallbackMessage: unreachableFallbackMessage,
        );
      }
      // 404 -> `/recommendations` not deployed yet; fall through to `/graph` + `/search`.
    }

    final graph = await fetchGraph(limit: 50);
    if (graph.isLocalFallback) {
      _usingLocalFallback = true;
      return const WavelengthRefreshResult(
        liveSuccess: false,
        fallbackMessage: unreachableFallbackMessage,
      );
    }

    final rawQuery = [
      if (profile.interests.isNotEmpty) profile.interests,
      ...profile.combinedProfileTopics.take(5),
    ].join(' ').trim();
    final query = _collapseSingleLine(rawQuery, maxRunes: 200);

    final livePeopleByTopic = <String, int>{};
    if (query.isNotEmpty) {
      try {
        final searchResult = await searchContent(query, limit: 30);
        if (searchResult.mode != PublicSearchMode.localScheduleFallback) {
          for (final moment in searchResult.moments) {
            final canonicalTopics = catalog != null
                ? catalog!.canonicalizeTopics(moment.topics)
                : moment.topics;
            for (final topic in canonicalTopics) {
              livePeopleByTopic[topic] = (livePeopleByTopic[topic] ?? 0) + 1;
            }
          }
        }
      } on SearchException {
        // Keep graph recommendations intact if optional moment search rejects input.
      }
    }

    _usingLocalFallback = false;
    return WavelengthRefreshResult(
      liveSuccess: true,
      liveTopicCounts: Map.unmodifiable({
        for (final n in graph.nodes) n.label: n.count,
      }),
      livePeopleByTopic: Map.unmodifiable(livePeopleByTopic),
      liveEdges: List.unmodifiable([
        for (final e in graph.edges)
          (source: e.source, target: e.target, weight: e.weight),
      ]),
    );
  }

  @override
  Future<MatchesLookupResult> findSharedNoteMatches({
    String? queryText,
    int limit = 10,
  }) async {
    var profile = await profileStore.load();
    final (connectedProfile, _) = await _ensureConnected(profile);
    profile = connectedProfile;
    if (!sync.connected || sync.token == null || sync.conference == null) {
      return const MatchesLookupResult();
    }

    final cappedQuery = queryText != null && queryText.trim().isNotEmpty
        ? _collapseSingleLine(queryText, maxRunes: 500)
        : null;

    try {
      final body = await sync.api.matches(
        sync.token!,
        conference: sync.conference!,
        interests: cappedQuery,
        limit: limit.clamp(1, 20),
      );
      if (body['matches'] case final List<Object?> rawMatches) {
        final parsed = <SharedNoteMatch>[];
        for (final item in rawMatches) {
          if (item is! Map) continue;
          final rawId = item['id'];
          final rawExcerpt = item['excerpt'];
          if (rawId is! String ||
              rawId.trim().isEmpty ||
              rawExcerpt is! String ||
              rawExcerpt.trim().isEmpty) {
            continue;
          }
          final rawTopics = item['topics'];
          final topics = <String>[
            if (rawTopics is List)
              for (final t in rawTopics)
                if (t is String && t.trim().isNotEmpty) t.trim(),
          ];
          parsed.add(
            SharedNoteMatch(
              id: rawId.trim(),
              excerpt: rawExcerpt,
              topics: catalog != null
                  ? catalog!.canonicalizeTopics(topics)
                  : topics,
            ),
          );
        }
        return MatchesLookupResult(matches: List.unmodifiable(parsed));
      }
      return const MatchesLookupResult();
    } on AttendeeApiException catch (e) {
      if (e.status == 422) {
        return const MatchesLookupResult(needsInput: true);
      }
      return const MatchesLookupResult();
    } on FormatException {
      return const MatchesLookupResult();
    }
  }

  PublicSearchResult _localSearchFallback({
    required String query,
    required String conference,
    required int limit,
    required PhoneProfile profile,
  }) {
    final schedule = catalog;
    final matchedTalks = <ScheduleTalk>[];
    final matchedMoments = <SearchMomentHit>[];

    if (schedule != null) {
      final queryTopics = schedule.extractMatchedTopics(query).toSet();
      final lowerQuery = query.toLowerCase();
      for (final talk in schedule.talks) {
        if (talk.isLogistics) continue;
        final talkTopics = schedule.effectiveTopicsForTalk(talk.id);
        final topicHit = talkTopics.any(queryTopics.contains);
        final textHit =
            talk.title.toLowerCase().contains(lowerQuery) ||
            talk.abstractText.toLowerCase().contains(lowerQuery);
        if (topicHit || textHit) {
          matchedTalks.add(talk);
          if (matchedTalks.length >= limit) break;
        }
      }

      for (final saved in profile.savedNotes) {
        final overlaps = [
          for (final t in saved.topics)
            if (queryTopics.contains(t) ||
                t.toLowerCase().contains(lowerQuery))
              t,
        ];
        final sharedHit =
            saved.shared &&
            (saved.sharedText?.toLowerCase().contains(lowerQuery) ?? false);
        if (overlaps.isNotEmpty || sharedHit) {
          matchedMoments.add(
            SearchMomentHit(
              id: saved.conversationId,
              topics: saved.topics,
              why: overlaps.isNotEmpty
                  ? 'Matches your interest in ${overlaps.join(', ')}'
                  : (saved.why ?? 'Saved on this phone'),
              shared: saved.shared,
              sharedText: saved.shared ? saved.sharedText : null,
            ),
          );
        }
      }
    }

    return PublicSearchResult(
      query: query,
      conference: conference,
      mode: PublicSearchMode.localScheduleFallback,
      talks: List.unmodifiable(matchedTalks),
      moments: List.unmodifiable(matchedMoments),
    );
  }

  @override
  void close() {
    if (ownsSync) sync.dispose();
  }
}

/// Clearly labeled in-memory fake implementation of [WavelengthBackend] for
/// local schedule-backed matching, unit testing, and `store.mjs` payload
/// verification without network dependencies.
class LabeledFakeWavelengthBackend implements WavelengthBackend {
  LabeledFakeWavelengthBackend({
    this.catalog,
    this.profileStore,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const String fakeBanner =
      'Local demo mode (labeled fake backend seam · bundled KubeCon schedule)';

  final ScheduleCatalog? catalog;
  final PhoneProfileStore? profileStore;
  final DateTime Function() _clock;

  final List<Map<String, Object?>> _submittedPayloads = [];
  final List<_StoredFakeNote> _storedNotes = [];
  PhoneProfile? _lastSyncedProfile;

  @override
  bool get isFake => true;

  @override
  bool get isUsingLocalFallback => true;

  @override
  bool get roomsAvailable => false;

  @override
  String get statusLabel => fakeBanner;

  PhoneProfile? get lastSyncedProfile => _lastSyncedProfile;

  /// Unmodifiable snapshot of outgoing `store.mjs`-shaped payloads recorded by
  /// [submitNote].
  List<Map<String, Object?>> get submittedPayloads => List.unmodifiable(
    _submittedPayloads.map((entry) => Map<String, Object?>.unmodifiable(entry)),
  );

  @override
  Future<ProfileSyncResult> syncProfile(
    PhoneProfile profile, {
    String? interestsOverride,
  }) async {
    _lastSyncedProfile =
        interestsOverride != null && interestsOverride.isNotEmpty
        ? profile.copyWith(interests: interestsOverride)
        : profile;
    return ProfileSyncResult(
      profile: _lastSyncedProfile!,
      syncedRemotely: false,
      created: false,
    );
  }

  @override
  Future<NoteReceipt> submitNote(NoteSubmission submission) async {
    final nowUtc = _clock().toUtc();
    final matchedTopics = _resolveMatchedTopics(
      transcript: submission.transcript,
      explicitTopics: submission.topics,
      catalog: catalog,
    );
    final normalizedSubmission = NoteSubmission(
      conference: submission.conference,
      ownerId: submission.ownerId,
      conversationId: submission.conversationId,
      revision: submission.revision,
      transcript: submission.transcript,
      consent: submission.consent,
      visibility: submission.visibility,
      isFinal: submission.isFinal,
      topics: matchedTopics,
      expiresAt: submission.expiresAt,
      shared: submission.shared,
      source: submission.source,
    );

    final payload = normalizedSubmission.toStorePayload(now: nowUtc);
    final docId = normalizedSubmission.computeStoreDocumentId();

    _submittedPayloads.add({
      ...payload,
      'topics': List<String>.unmodifiable(matchedTopics),
    });
    _storedNotes.removeWhere(
      (n) => n.submission.conversationId == normalizedSubmission.conversationId,
    );
    _storedNotes.insert(
      0,
      _StoredFakeNote(
        documentId: docId,
        submission: normalizedSubmission,
        matchedTopics: matchedTopics,
      ),
    );

    if (profileStore != null) {
      await profileStore!.recordNote(
        LocalNoteSummary(
          conversationId: normalizedSubmission.conversationId,
          topics: matchedTopics,
          why: matchedTopics.isNotEmpty
              ? 'Tuned: ${matchedTopics.join(', ')}'
              : 'Note saved',
          shared: normalizedSubmission.shared,
          sharedText: normalizedSubmission.shared
              ? normalizedSubmission.transcript
              : null,
          source: normalizedSubmission.source,
          createdAt: nowUtc,
        ),
      );
    }

    return NoteReceipt(
      documentId: docId,
      conversationId: normalizedSubmission.conversationId,
      revision: normalizedSubmission.revision,
      matchedTopics: matchedTopics,
      isLocalFallback: true,
      transcriptSavedRemotely: false,
      statusLabel: NoteReceipt.savedLocallyLabel,
    );
  }

  @override
  Future<PublicSearchResult> searchContent(
    String query, {
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 200) {
      throw const SearchException('Enter between 1 and 200 characters.');
    }
    final safeLimit = limit.clamp(1, 50);
    final nowUtc = _clock().toUtc();
    final queryTopics =
        catalog?.extractMatchedTopics(trimmed).toSet() ?? const <String>{};
    final lowerQuery = trimmed.toLowerCase();

    final moments = <SearchMomentHit>[];
    for (final entry in _storedNotes) {
      if (!entry.submission.expiresAt.isAfter(nowUtc)) continue;
      final overlappingTopics = [
        for (final t in entry.matchedTopics)
          if (queryTopics.contains(t) || t.toLowerCase().contains(lowerQuery))
            t,
      ];
      final textMatches = entry.submission.transcript
          .toLowerCase()
          .contains(lowerQuery);
      if (overlappingTopics.isEmpty && !textMatches) continue;

      final why = overlappingTopics.isNotEmpty
          ? 'Matches your interest in ${overlappingTopics.join(', ')}'
          : (entry.matchedTopics.isNotEmpty
                ? 'Tuned to ${entry.matchedTopics.join(', ')}'
                : 'On your wavelength');

      // Privacy invariant: unshared notes NEVER expose `transcript` in search.
      moments.add(
        SearchMomentHit(
          id: entry.documentId,
          topics: entry.matchedTopics,
          why: why,
          shared: entry.submission.shared,
          sharedText: entry.submission.shared
              ? entry.submission.transcript
              : null,
        ),
      );
      if (moments.length >= safeLimit) break;
    }

    final talks = <ScheduleTalk>[];
    if (catalog != null) {
      for (final talk in catalog!.talks) {
        if (talk.isLogistics) continue;
        final talkTopics = catalog!.effectiveTopicsForTalk(talk.id);
        final matches =
            talkTopics.any(queryTopics.contains) ||
            talk.title.toLowerCase().contains(lowerQuery) ||
            talk.abstractText.toLowerCase().contains(lowerQuery);
        if (matches) {
          talks.add(talk);
          if (talks.length >= safeLimit) break;
        }
      }
    }

    return PublicSearchResult(
      query: trimmed,
      conference: PhoneProfile.defaultConference,
      mode: PublicSearchMode.localScheduleFallback,
      talks: List.unmodifiable(talks),
      moments: List.unmodifiable(moments),
    );
  }

  @override
  Future<TopicGraph> fetchGraph({int limit = 50}) async =>
      _buildLocalTopicGraph(
        catalog: catalog,
        conference: PhoneProfile.defaultConference,
        limit: limit.clamp(1, 100),
      );

  @override
  Future<WavelengthRefreshResult> refreshRecommendations({
    String? typedInterests,
  }) async {
    if (typedInterests != null && profileStore != null) {
      await profileStore!.setInterests(typedInterests);
    }
    return const WavelengthRefreshResult(liveSuccess: false);
  }

  @override
  Future<MatchesLookupResult> findSharedNoteMatches({
    String? queryText,
    int limit = 10,
  }) async {
    final clean = queryText?.trim() ?? '';
    if (clean.isEmpty) {
      return const MatchesLookupResult(needsInput: true);
    }
    return const MatchesLookupResult();
  }

  @override
  void close() {}
}

class _StoredFakeNote {
  const _StoredFakeNote({
    required this.documentId,
    required this.submission,
    required this.matchedTopics,
  });

  final String documentId;
  final NoteSubmission submission;
  final List<String> matchedTopics;
}

bool _isValidHttpsBaseUrl(Uri url) =>
    url.scheme == 'https' &&
    url.host.isNotEmpty &&
    url.userInfo.isEmpty &&
    !url.hasQuery &&
    !url.hasFragment &&
    (url.path.isEmpty || url.path == '/');

bool _isFallbackStatus(int statusCode) =>
    statusCode == 404 ||
    statusCode == 502 ||
    statusCode == 503 ||
    statusCode == 504;

final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f]+');

String _collapseSingleLine(String input, {required int maxRunes}) {
  final collapsed = input
      .replaceAll(_controlChars, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (collapsed.isEmpty) return '';
  final runes = collapsed.runes;
  if (runes.length <= maxRunes) return collapsed;
  return String.fromCharCodes(runes.take(maxRunes)).trimRight();
}

String? _nullIfEmpty(String value) => value.isEmpty ? null : value;

List<String> _normalizeSubmissionTopics(
  Iterable<String> rawTopics, {
  int maxCount = 20,
}) {
  final byLower = <String, String>{};
  for (final item in rawTopics) {
    final clean = _collapseSingleLine(item, maxRunes: 64);
    if (clean.isNotEmpty) {
      byLower.putIfAbsent(clean.toLowerCase(), () => clean);
      if (byLower.length >= maxCount) break;
    }
  }
  return byLower.values.toList(growable: false);
}

List<String> _resolveMatchedTopics({
  required String transcript,
  required Iterable<String> explicitTopics,
  required ScheduleCatalog? catalog,
}) {
  if (catalog == null) {
    return List.unmodifiable(_normalizeSubmissionTopics(explicitTopics));
  }
  final combined = <String>{
    ...catalog.canonicalizeTopics(explicitTopics),
    ...catalog.extractMatchedTopics(transcript),
  };
  return List.unmodifiable(combined.take(20));
}

ScheduleTalk _parseSearchTalkHit(
  Map<Object?, Object?> hit, {
  required ScheduleCatalog? catalog,
}) {
  final id = (hit['id'] as String).trim();
  final localTalk = catalog?.talkById(id);
  if (localTalk != null) return localTalk;

  final rawTitle = hit['title'];
  final rawAbstract = hit['abstract'];
  final rawRoom = hit['room'];
  final rawStart = hit['start'];
  final rawEnd = hit['end'];
  final rawTopics = hit['topics'];
  final tags = <String>[];
  if (rawTopics is List) {
    for (final item in rawTopics) {
      if (item is String && item.trim().isNotEmpty) {
        tags.add(item.trim());
      }
    }
  }
  final startStr = rawStart is String
      ? rawStart
      : (rawStart is int ? rawStart.toString() : '');
  final endStr = rawEnd is String
      ? rawEnd
      : (rawEnd is int ? rawEnd.toString() : '');
  final dayStr = startStr.length >= 10 ? startStr.substring(0, 10) : '';

  // Deliberately ignores `hit['speakers']` so speaker names never enter app state.
  return ScheduleTalk(
    id: id,
    title: rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : id,
    abstractText: rawAbstract is String ? rawAbstract.trim() : '',
    time: startStr,
    day: dayStr,
    start: startStr,
    end: endStr,
    room: rawRoom is String ? rawRoom.trim() : '',
    tags: List.unmodifiable(tags),
  );
}

SearchMomentHit _parseSearchMomentHit(
  Map<Object?, Object?> hit, {
  required ScheduleCatalog? catalog,
}) {
  final id = (hit['id'] as String).trim();
  final rawTopics = hit['topics'];
  final rawList = <String>[];
  if (rawTopics is List) {
    for (final item in rawTopics) {
      if (item is String && item.trim().isNotEmpty) {
        rawList.add(item.trim());
      }
    }
  }
  final topics = catalog != null
      ? catalog.canonicalizeTopics(rawList)
      : _normalizeSubmissionTopics(rawList, maxCount: 5);
  final displayTopics = topics.isNotEmpty
      ? topics
      : _normalizeSubmissionTopics(rawList, maxCount: 5);

  // S2: Populate sharedText ONLY when `hit['shared'] == true` (zero `__setup_smoke__` exemption).
  final isShared = hit['shared'] == true;
  final rawGist = hit['gist'];
  final rawWhy = hit['why'];
  final generatedWhy = rawWhy is String && rawWhy.trim().isNotEmpty
      ? _collapseSingleLine(rawWhy, maxRunes: 280)
      : (displayTopics.isNotEmpty
            ? 'Matches your interest in ${displayTopics.join(', ')}'
            : 'Matched attendee note');

  return SearchMomentHit(
    id: id,
    topics: displayTopics,
    why: generatedWhy,
    shared: isShared,
    sharedText: isShared && rawGist is String ? rawGist : null,
  );
}

TopicGraph _buildLocalTopicGraph({
  required ScheduleCatalog? catalog,
  required String conference,
  required int limit,
}) {
  if (catalog == null) {
    return TopicGraph(
      conference: conference,
      nodes: const [],
      edges: const [],
      isLocalFallback: true,
    );
  }
  final topTopics = catalog.popularTopics(limit: limit);
  final nodes = [
    for (final topic in topTopics)
      if (catalog.sessionCountForTopic(topic) > 0)
        TopicGraphNode(
          id: topic,
          label: topic,
          count: catalog.sessionCountForTopic(topic),
        ),
  ];

  final rawEdges = catalog.coOccurringEdgesForTopics(
    [for (final n in nodes) n.label],
    maxEdges: nodes.length * nodes.length,
  );
  final edges = [
    for (final e in rawEdges)
      TopicGraphEdge(source: e.source, target: e.target, weight: e.weight),
  ];

  return TopicGraph(
    conference: conference,
    nodes: List.unmodifiable(nodes),
    edges: List.unmodifiable(edges),
    isLocalFallback: true,
  );
}

String? _formatBasedOnSummary(Object? rawBasedOn) {
  if (rawBasedOn is! Map) return null;
  final parts = <String>[];
  final notes = rawBasedOn['notes'];
  if (notes is int && notes > 0) {
    parts.add('$notes ${notes == 1 ? 'note' : 'notes'}');
  }
  if (rawBasedOn['topics'] case final List<Object?> rawTopics) {
    final clean = <String>[];
    for (final item in rawTopics) {
      if (item is String && item.trim().isNotEmpty) {
        clean.add(_collapseSingleLine(item, maxRunes: 64));
      }
    }
    if (clean.isNotEmpty) {
      parts.add(clean.take(3).join(', '));
    }
  }
  if (rawBasedOn['interests'] == true) {
    parts.add('your interests');
  }
  if (parts.isEmpty) return null;
  if (parts.length == 1) return 'Based on ${parts.first}';
  if (parts.length == 2) return 'Based on ${parts[0]} and ${parts[1]}';
  return 'Based on ${parts.sublist(0, parts.length - 1).join(', ')}, and ${parts.last}';
}
