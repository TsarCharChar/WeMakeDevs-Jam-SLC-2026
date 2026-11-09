import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:http/http.dart' as http;

import 'phone_profile_store.dart';
import 'schedule_data.dart';

/// Matched note returned by search.
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

/// One-shot finished note submission DTO supporting both the `store.mjs`
/// adapter contract and the Attendee API (`PUT /me` + opt-in `POST /moments`).
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
  Map<String, Object?>? toMomentPayload({
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
    return {
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
    required this.statusLabel,
    this.momentId,
  });

  final String documentId;
  final String conversationId;
  final int revision;
  final List<String> matchedTopics;
  final bool isLocalFallback;
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

  /// Matching attendee moments/notes with unshared text stripped.
  final List<Conversation> moments;
}

@immutable
class FeedAlert {
  const FeedAlert({
    required this.id,
    this.kind,
    this.room,
    this.why,
    this.seen = false,
    this.at,
  });

  final String id;
  final String? kind;
  final String? room;
  final String? why;
  final bool seen;
  final String? at;

  factory FeedAlert.fromJson(Object? json) {
    if (json case {'id': final String id} when id.trim().isNotEmpty) {
      final rawKind = json['kind'];
      final rawRoom = json['room'];
      final rawWhy = json['why'];
      final rawSeen = json['seen'];
      final rawAt = json['at'];
      return FeedAlert(
        id: id.trim(),
        kind: rawKind is String ? rawKind : null,
        room: rawRoom is String ? rawRoom : null,
        why: rawWhy is String ? rawWhy : null,
        seen: rawSeen == true,
        at: rawAt is String
            ? rawAt
            : (rawAt is int ? rawAt.toString() : null),
      );
    }
    throw const FormatException('Invalid feed alert');
  }
}

/// Single backend seam through which the ConFellow Flutter app communicates
/// with the backend (or its labeled local fallback).
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

  Future<List<Conversation>> searchNotes(String interests);

  Future<PublicSearchResult> searchContent(String query, {int limit = 20});

  Future<TopicGraph> fetchGraph({int limit = 50});

  Future<List<FeedAlert>> fetchFeed({int limit = 20});

  Future<List<WavelengthSpace>> findWavelength({
    required Set<String> activeTopics,
    List<String> noteTexts = const [],
    Set<String> goingTalkIds = const {},
  });

  void close();
}

/// Production Attendee API client (`PUT /me`, `POST /moments`, `GET /search`,
/// `GET /graph`, `GET /feed`) with automatic, error-free fallback to the
/// bundled 600-session KubeCon [ScheduleCatalog] whenever endpoints return
/// `404`/`503` or the device is offline.
class AttendeeWavelengthBackend implements WavelengthBackend {
  AttendeeWavelengthBackend({
    required this.profileStore,
    this.catalog,
    http.Client? client,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 15),
    this.queryLegacySmokeEndpointOnFallback = false,
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _baseUrl =
           baseUrl ??
           Uri.parse(
             const String.fromEnvironment(
               'API_BASE_URL',
               defaultValue: 'https://grindset.cnh.radarhq.io',
             ),
           ),
       _clock = clock ?? DateTime.now;

  final PhoneProfileStore profileStore;
  final ScheduleCatalog? catalog;
  final http.Client _client;
  final Uri _baseUrl;
  final Duration timeout;
  final bool queryLegacySmokeEndpointOnFallback;
  final DateTime Function() _clock;

  bool _usingLocalFallback = false;

  @override
  bool get isFake => false;

  @override
  bool get isUsingLocalFallback => _usingLocalFallback;

  @override
  bool get roomsAvailable => false;

  @override
  String get statusLabel => _usingLocalFallback
      ? 'Local KubeCon schedule active · live attendee sync will resume automatically'
      : 'Connected to ConFellow conference wavelength';

  @override
  Future<ProfileSyncResult> syncProfile(
    PhoneProfile profile, {
    String? interestsOverride,
  }) async {
    if (!_isValidHttpsBaseUrl(_baseUrl) ||
        !PhoneProfile.handlePattern.hasMatch(profile.handle)) {
      _usingLocalFallback = true;
      return ProfileSyncResult(
        profile: profile,
        syncedRemotely: false,
        created: false,
      );
    }

    var current = profile;
    for (var attempt = 0; attempt < 2; attempt++) {
      final hasToken =
          current.attendeeToken != null && current.attendeeToken!.isNotEmpty;
      final headers = <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        if (hasToken) 'Authorization': 'Bearer ${current.attendeeToken}',
      };
      final bodyMap = current.toPutMeBody();
      if (interestsOverride != null && interestsOverride.isNotEmpty) {
        bodyMap['interests'] = _collapseSingleLine(
          interestsOverride,
          maxRunes: 1000,
        );
      }
      try {
        final response = await _client
            .put(
              _baseUrl.resolve('/me'),
              headers: headers,
              body: jsonEncode(bodyMap),
            )
            .timeout(timeout);

        if (response.statusCode == 200 || response.statusCode == 201) {
          final Object? decoded = jsonDecode(
            utf8.decode(response.bodyBytes, allowMalformed: true),
          );
          if (decoded is! Map) {
            throw const FormatException('Invalid PUT /me response');
          }
          final created =
              decoded['created'] == true || response.statusCode == 201;
          final rawToken = decoded['token'];
          if (rawToken is String && rawToken.trim().isNotEmpty) {
            current = await profileStore.saveAttendeeToken(
              rawToken.trim(),
              handle: current.handle,
              conference: current.conference,
            );
          }
          _usingLocalFallback = false;
          return ProfileSyncResult(
            profile: current,
            syncedRemotely: true,
            created: created,
          );
        }

        // Handle collision when claiming without a token, or expired/mismatched
        // profile token: rotate handle once and re-claim cleanly.
        if (attempt == 0 &&
            ((response.statusCode == 409 && !hasToken) ||
                response.statusCode == 401 ||
                response.statusCode == 403)) {
          current = await profileStore.rotateHandle(
            conference: current.conference,
          );
          continue;
        }

        // Concurrent seq_no conflict when updating with a valid token: retry once.
        if (attempt == 0 && response.statusCode == 409 && hasToken) {
          continue;
        }

        if (_isFallbackStatus(response.statusCode)) {
          _usingLocalFallback = true;
          return ProfileSyncResult(
            profile: current,
            syncedRemotely: false,
            created: false,
          );
        }

        throw const NoteSubmissionException(
          'Could not update your conference profile right now.',
        );
      } on TimeoutException {
        _usingLocalFallback = true;
        return ProfileSyncResult(
          profile: current,
          syncedRemotely: false,
          created: false,
        );
      } on http.ClientException {
        _usingLocalFallback = true;
        return ProfileSyncResult(
          profile: current,
          syncedRemotely: false,
          created: false,
        );
      } on FormatException {
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
        : 'Saved note';

    final localSummary = LocalNoteSummary(
      conversationId: submission.conversationId,
      topics: matchedTopics,
      why: whySummary,
      shared: submission.shared,
      sharedText: submission.shared ? submission.transcript : null,
      source: submission.source,
      createdAt: nowUtc,
    );

    final currentProfile = await profileStore.load();
    final wireInterests = _evolveInterests(
      existingInterests: currentProfile.buildProfileInterests(),
      matchedTopics: matchedTopics,
      transcript: submission.transcript,
    );
    final diskInterests = submission.shared
        ? wireInterests
        : _evolveInterests(
            existingInterests: currentProfile.interests,
            matchedTopics: matchedTopics,
            transcript: '',
          );
    final updatedProfile = await profileStore.recordNote(
      localSummary,
      evolvedInterests: diskInterests,
    );

    final syncResult = await syncProfile(
      updatedProfile,
      interestsOverride: wireInterests,
    );
    final activeProfile = syncResult.profile;

    String? createdMomentId;
    final token = activeProfile.attendeeToken;

    // CRITICAL PRIVACY RULE: Only publish to `POST /moments` when the user
    // explicitly opted into `shared: true` ("Share this note").
    if (submission.shared &&
        syncResult.syncedRemotely &&
        token != null &&
        token.isNotEmpty) {
      final candidateMomentTopics = matchedTopics.isNotEmpty
          ? matchedTopics
          : activeProfile.selectedTopics;
      final momentPayload = NoteSubmission(
        conference: activeProfile.conference,
        ownerId: activeProfile.handle,
        conversationId: submission.conversationId,
        transcript: submission.transcript,
        expiresAt: submission.expiresAt,
        topics: candidateMomentTopics,
        shared: true,
        source: submission.source,
      ).toMomentPayload(effectiveTopics: candidateMomentTopics);

      if (momentPayload != null) {
        try {
          final response = await _client
              .post(
                _baseUrl.resolve('/moments'),
                headers: {
                  'Authorization': 'Bearer $token',
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
                body: jsonEncode(momentPayload),
              )
              .timeout(timeout);
          if (response.statusCode == 201) {
            final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
            if (body case {'id': final String id} when id.isNotEmpty) {
              createdMomentId = id;
            }
          } else if (_isFallbackStatus(response.statusCode)) {
            _usingLocalFallback = true;
          }
        } on Exception {
          _usingLocalFallback = true;
        }
      }
    }

    final isFallback = !syncResult.syncedRemotely || _usingLocalFallback;
    return NoteReceipt(
      documentId: submission.computeStoreDocumentId(),
      conversationId: submission.conversationId,
      revision: submission.revision,
      matchedTopics: matchedTopics,
      isLocalFallback: isFallback,
      statusLabel: whySummary,
      momentId: createdMomentId,
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
    final conference = profile.conference;

    if (_isValidHttpsBaseUrl(_baseUrl)) {
      try {
        if (profile.attendeeToken == null || profile.attendeeToken!.isEmpty) {
          profile = (await syncProfile(profile)).profile;
        }
        final token = profile.attendeeToken;
        if (token != null && token.isNotEmpty) {
          final response = await _client
              .get(
                _baseUrl.resolve('/search').replace(
                  queryParameters: {
                    'q': trimmed,
                    'conference': conference,
                    'limit': '$safeLimit',
                  },
                ),
                headers: {
                  'Authorization': 'Bearer $token',
                  'Accept': 'application/json',
                },
              )
              .timeout(timeout);

          if (response.statusCode == 200) {
            final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
            if (body case {
              'mode': final String rawMode,
              'results': final List<Object?> results,
            }) {
              final talks = <ScheduleTalk>[];
              final moments = <Conversation>[];
              for (final hit in results) {
                if (hit is! Map) continue;
                final type = hit['type'];
                final id = hit['id'];
                if (id is! String || id.trim().isEmpty) continue;
                if (type == 'talk') {
                  talks.add(_parseSearchTalkHit(hit, catalog: catalog));
                } else if (type == 'moment') {
                  moments.add(
                    _parseSearchMomentHit(
                      hit,
                      conference: conference,
                      catalog: catalog,
                    ),
                  );
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
          } else if (!_isFallbackStatus(response.statusCode)) {
            throw SearchException(switch (response.statusCode) {
              401 || 403 =>
                'Search access is unavailable. Please try again later.',
              422 => 'Enter between 1 and 200 characters.',
              429 => 'Too many searches. Please wait a moment and try again.',
              _ => 'Search is unavailable right now. Please try again.',
            });
          }
        }
      } on SearchException {
        rethrow;
      } on Exception {
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
  Future<List<Conversation>> searchNotes(String interests) async {
    final trimmed = interests.trim();
    if (trimmed.runes.length < 2 || trimmed.runes.length > 120) {
      throw const SearchException('Enter between 2 and 120 characters.');
    }
    final result = await searchContent(trimmed, limit: 20);
    if (result.moments.isNotEmpty ||
        result.mode != PublicSearchMode.localScheduleFallback) {
      return result.moments;
    }

    final merged = <Conversation>[];
    if (queryLegacySmokeEndpointOnFallback && _isValidHttpsBaseUrl(_baseUrl)) {
      final smokeApi = ConversationApi(
        client: _NonClosingClient(_client),
        baseUrl: _baseUrl,
        timeout: timeout,
      );
      try {
        merged.addAll(await smokeApi.search(trimmed));
      } on SearchException {
        // Ignore legacy endpoint unavailability during local fallback.
      }
    }
    merged.addAll(result.moments);
    return List.unmodifiable(merged);
  }

  @override
  Future<TopicGraph> fetchGraph({int limit = 50}) async {
    final safeLimit = limit.clamp(1, 100);
    var profile = await profileStore.load();
    final conference = profile.conference;

    if (_isValidHttpsBaseUrl(_baseUrl)) {
      try {
        if (profile.attendeeToken == null || profile.attendeeToken!.isEmpty) {
          profile = (await syncProfile(profile)).profile;
        }
        final token = profile.attendeeToken;
        if (token != null && token.isNotEmpty) {
          final response = await _client
              .get(
                _baseUrl.resolve('/graph').replace(
                  queryParameters: {
                    'conference': conference,
                    'limit': '$safeLimit',
                  },
                ),
                headers: {
                  'Authorization': 'Bearer $token',
                  'Accept': 'application/json',
                },
              )
              .timeout(timeout);

          if (response.statusCode == 200) {
            final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
            if (body case {
              'nodes': final List<Object?> rawNodes,
              'edges': final List<Object?> rawEdges,
            }) {
              final nodes = [
                for (final item in rawNodes)
                  if (item is Map)
                    TopicGraphNode.fromJson(item),
              ].where((n) => !ScheduleCatalog.isMetaTag(n.label)).toList();

              if (nodes.isNotEmpty) {
                final allowedIds = {for (final n in nodes) n.id};
                final edges = [
                  for (final item in rawEdges)
                    if (item is Map) TopicGraphEdge.fromJson(item),
                ].where(
                  (e) =>
                      allowedIds.contains(e.source) &&
                      allowedIds.contains(e.target),
                ).toList();

                _usingLocalFallback = false;
                return TopicGraph(
                  conference: conference,
                  nodes: List.unmodifiable(nodes),
                  edges: List.unmodifiable(edges),
                  isLocalFallback: false,
                );
              }
            }
          }
        }
      } on Exception {
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
  Future<List<FeedAlert>> fetchFeed({int limit = 20}) async {
    final profile = await profileStore.load();
    final token = profile.attendeeToken;
    if (token == null || token.isEmpty || !_isValidHttpsBaseUrl(_baseUrl)) {
      return const [];
    }
    final safeLimit = limit.clamp(1, 100);
    try {
      final response = await _client
          .get(
            _baseUrl.resolve('/feed').replace(
              queryParameters: {
                'limit': '$safeLimit',
                'conference': profile.conference,
              },
            ),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(timeout);
      if (response.statusCode == 200) {
        final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body case {'alerts': final List<Object?> rawAlerts}) {
          return List.unmodifiable([
            for (final item in rawAlerts)
              if (item is Map) FeedAlert.fromJson(item),
          ]);
        }
      }
    } on Exception {
      // Feed alerts are non-critical; degrade silently when offline or 503.
    }
    return const [];
  }

  @override
  Future<List<WavelengthSpace>> findWavelength({
    required Set<String> activeTopics,
    List<String> noteTexts = const [],
    Set<String> goingTalkIds = const {},
  }) async {
    final schedule = catalog;
    if (schedule == null) return const [];
    final profile = await profileStore.load();
    final mergedTopics = <String>{
      ...profile.activeWavelengthTopics,
      ...activeTopics,
    };
    final mergedGoing = <String>{...profile.goingTalkIds, ...goingTalkIds};
    return schedule.rankSpaces(
      activeTopics: mergedTopics,
      noteTexts: noteTexts,
      goingTalkIds: mergedGoing,
    );
  }

  PublicSearchResult _localSearchFallback({
    required String query,
    required String conference,
    required int limit,
    required PhoneProfile profile,
  }) {
    final schedule = catalog;
    final matchedTalks = <ScheduleTalk>[];
    final matchedMoments = <Conversation>[];

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
            Conversation(
              id: saved.conversationId,
              conference: conference,
              shared: saved.shared,
              sharedText: saved.shared ? saved.sharedText : null,
              topics: saved.topics,
              why: overlaps.isNotEmpty
                  ? 'Matches your interest in ${overlaps.join(', ')}'
                  : (saved.why ?? 'Saved on this phone'),
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
  void close() => _client.close();
}

/// Clearly labeled in-memory fake implementation of [WavelengthBackend] for
/// local schedule-backed matching, unit testing, and `store.mjs` payload
/// verification without network dependencies.
class LabeledFakeWavelengthBackend implements WavelengthBackend {
  LabeledFakeWavelengthBackend({
    this.catalog,
    this.smokeSearchApi,
    this.ignoreSmokeSearchErrors = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const String fakeBanner =
      'Local demo mode (labeled fake backend seam · bundled KubeCon schedule)';

  final ScheduleCatalog? catalog;

  /// Optional `/querysession` client to include the backend's labeled
  /// `__setup_smoke__` demo document alongside local fake results.
  final ConversationApi? smokeSearchApi;
  final bool ignoreSmokeSearchErrors;
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
    _lastSyncedProfile = interestsOverride != null && interestsOverride.isNotEmpty
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

    return NoteReceipt(
      documentId: docId,
      conversationId: normalizedSubmission.conversationId,
      revision: normalizedSubmission.revision,
      matchedTopics: matchedTopics,
      isLocalFallback: true,
      statusLabel: fakeBanner,
    );
  }

  @override
  Future<List<Conversation>> searchNotes(String interests) async {
    final trimmed = interests.trim();
    if (trimmed.runes.length < 2 || trimmed.runes.length > 120) {
      throw const SearchException('Enter between 2 and 120 characters.');
    }

    final results = <Conversation>[];
    if (smokeSearchApi != null) {
      try {
        results.addAll(await smokeSearchApi!.search(trimmed));
      } on SearchException {
        if (!ignoreSmokeSearchErrors) rethrow;
      }
    }

    final content = await searchContent(trimmed, limit: 20);
    results.addAll(content.moments);
    return List.unmodifiable(results);
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

    final moments = <Conversation>[];
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
        Conversation(
          id: entry.documentId,
          conference: entry.submission.conference,
          shared: entry.submission.shared,
          sharedText: entry.submission.shared
              ? entry.submission.transcript
              : null,
          topics: entry.matchedTopics,
          why: why,
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
  Future<List<FeedAlert>> fetchFeed({int limit = 20}) async => const [];

  @override
  Future<List<WavelengthSpace>> findWavelength({
    required Set<String> activeTopics,
    List<String> noteTexts = const [],
    Set<String> goingTalkIds = const {},
  }) async {
    final schedule = catalog;
    if (schedule == null) return const [];
    final allNoteTexts = <String>[
      ...noteTexts,
      for (final entry in _storedNotes) entry.submission.transcript,
    ];
    return schedule.rankSpaces(
      activeTopics: activeTopics,
      noteTexts: allNoteTexts,
      goingTalkIds: goingTalkIds,
    );
  }

  @override
  void close() => smokeSearchApi?.close();
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

class _NonClosingClient extends http.BaseClient {
  _NonClosingClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);
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

String _evolveInterests({
  required String existingInterests,
  required List<String> matchedTopics,
  required String transcript,
}) {
  final snippet = _collapseSingleLine(transcript, maxRunes: 240);
  final topicClause = matchedTopics.isNotEmpty
      ? 'Topics: ${matchedTopics.join(', ')}'
      : '';
  final parts = <String>[
    if (topicClause.isNotEmpty) topicClause,
    if (snippet.isNotEmpty) snippet,
    if (existingInterests.isNotEmpty) existingInterests,
  ];
  return _collapseSingleLine(parts.join('; '), maxRunes: 1000);
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

Conversation _parseSearchMomentHit(
  Map<Object?, Object?> hit, {
  required String conference,
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

  final hitConference = hit['conference'] is String
      ? hit['conference'] as String
      : conference;
  final isDemo = hitConference == Conversation.demoConference;
  final isShared = hit['shared'] == true;
  final rawGist = hit['gist'];
  final rawWhy = hit['why'];
  final generatedWhy = rawWhy is String && rawWhy.trim().isNotEmpty
      ? rawWhy.trim()
      : (displayTopics.isNotEmpty
            ? 'Matches your interest in ${displayTopics.join(', ')}'
            : 'Matched attendee note');

  return Conversation(
    id: id,
    conference: hitConference,
    shared: isShared,
    sharedText: (isShared || isDemo) && rawGist is String ? rawGist : null,
    topics: List.unmodifiable(displayTopics),
    why: generatedWhy,
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
  final allowed = topTopics.toSet();
  final nodes = [
    for (final topic in topTopics)
      if (catalog.sessionCountForTopic(topic) > 0)
        TopicGraphNode(
          id: topic,
          label: topic,
          count: catalog.sessionCountForTopic(topic),
        ),
  ];

  final edgeWeights = <(String, String), int>{};
  for (final talk in catalog.talks) {
    if (talk.isLogistics) continue;
    final topics = [
      for (final t in catalog.effectiveTopicsForTalk(talk.id))
        if (allowed.contains(t)) t,
    ]..sort();
    for (var i = 0; i < topics.length; i++) {
      for (var j = i + 1; j < topics.length; j++) {
        final pair = (topics[i], topics[j]);
        edgeWeights[pair] = (edgeWeights[pair] ?? 0) + 1;
      }
    }
  }

  final sortedPairs = edgeWeights.entries.toList()
    ..sort((a, b) {
      final byWeight = b.value.compareTo(a.value);
      if (byWeight != 0) return byWeight;
      final bySource = a.key.$1.compareTo(b.key.$1);
      if (bySource != 0) return bySource;
      return a.key.$2.compareTo(b.key.$2);
    });

  final edges = [
    for (final entry in sortedPairs)
      TopicGraphEdge(
        source: entry.key.$1,
        target: entry.key.$2,
        weight: entry.value,
      ),
  ];

  return TopicGraph(
    conference: conference,
    nodes: List.unmodifiable(nodes),
    edges: List.unmodifiable(edges),
    isLocalFallback: true,
  );
}
