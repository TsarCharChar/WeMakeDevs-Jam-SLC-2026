import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

typedef ProfileDirectoryProvider = Future<Directory> Function();
typedef ProfileFileProvider = Future<File> Function();

/// Local metadata for a user's saved note.
///
/// Stores matched schedule topics, human `why` text, and `shared` flag so the
/// user's wavelength persists across app restarts without logging or persisting
/// unshared raw transcripts.
@immutable
class LocalNoteSummary {
  LocalNoteSummary({
    required this.conversationId,
    required Iterable<String> topics,
    this.why,
    this.shared = false,
    String? sharedText,
    this.source = 'spoken',
    DateTime? createdAt,
  }) : topics = List.unmodifiable(_cleanTopics(topics)),
       sharedText = shared ? _sanitizeSingleLine(sharedText, maxRunes: 280) : null,
       createdAt = (createdAt ?? DateTime.now().toUtc()).toUtc();

  final String conversationId;
  final List<String> topics;
  final String? why;
  final bool shared;

  /// Only retained when [shared] is `true`. Always `null` for private notes.
  final String? sharedText;

  /// `'spoken'` or `'notes'`, matching `POST /moments`.
  final String source;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'conversationId': conversationId,
    'topics': topics,
    if (why != null && why!.isNotEmpty) 'why': why,
    'shared': shared,
    if (shared && sharedText != null && sharedText!.isNotEmpty)
      'sharedText': sharedText,
    'source': source == 'notes' ? 'notes' : 'spoken',
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory LocalNoteSummary.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Invalid saved note entry.');
    }
    final id = json['conversationId'];
    if (id is! String || !PhoneProfile.identifierPattern.hasMatch(id.trim())) {
      throw const FormatException('Invalid saved note conversationId.');
    }
    final rawTopics = json['topics'];
    final parsedTopics = <String>[];
    if (rawTopics is List) {
      for (final item in rawTopics) {
        if (item is String && item.trim().isNotEmpty) {
          parsedTopics.add(item.trim());
        }
      }
    }
    final rawWhy = json['why'];
    final shared = json['shared'] == true;
    final rawSharedText = json['sharedText'];
    final rawSource = json['source'];
    final rawCreatedAt = json['createdAt'];
    DateTime? createdAt;
    if (rawCreatedAt is String) {
      createdAt = DateTime.tryParse(rawCreatedAt)?.toUtc();
    }
    return LocalNoteSummary(
      conversationId: id.trim(),
      topics: parsedTopics,
      why: rawWhy is String && rawWhy.trim().isNotEmpty ? rawWhy.trim() : null,
      shared: shared,
      sharedText: shared && rawSharedText is String ? rawSharedText : null,
      source: rawSource == 'notes' ? 'notes' : 'spoken',
      createdAt: createdAt,
    );
  }

  /// Redacted string representation that never prints note text.
  @override
  String toString() =>
      'LocalNoteSummary(conversationId: $conversationId, topics: $topics, shared: $shared)';
}

/// Immutable snapshot of on-device attendee state and preferences.
@immutable
class PhoneProfile {
  PhoneProfile({
    required this.handle,
    this.conference = defaultConference,
    this.attendeeToken,
    String interests = '',
    this.reviewBeforeSending = false,
    Iterable<String> selectedTopics = const [],
    Iterable<String> goingTalkIds = const [],
    Iterable<LocalNoteSummary> savedNotes = const [],
  }) : assert(handlePattern.hasMatch(handle), 'Invalid attendee handle: $handle'),
       assert(
         identifierPattern.hasMatch(conference),
         'Invalid conference identifier: $conference',
       ),
       interests = _sanitizeInterests(interests),
       selectedTopics = List.unmodifiable(_cleanTopics(selectedTopics)),
       goingTalkIds = List.unmodifiable(_cleanTalkIds(goingTalkIds)),
       savedNotes = List.unmodifiable(savedNotes);

  static const String defaultConference = 'cnh';

  /// Matches `backend/attendee/models.py` `Handle` (`2..32` chars) as well as
  /// `backend/models.py` `Identifier` (`1..128` chars).
  static final RegExp handlePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{1,31}$',
  );

  /// Matches `backend/models.py` `Identifier` (`1..128` chars).
  static final RegExp identifierPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$',
  );

  /// Matches `backend/attendee/models.py` `TalkId` (`1..128` chars).
  static final RegExp talkIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
  );

  /// Opaque phone handle (`cf_<20 hex chars>`, 23 chars). Zero login required.
  final String handle;

  /// Alias used by `server/elastic/store.mjs` / `ConversationWrite` contracts.
  String get ownerId => handle;

  /// Conference identifier (`'cnh'` by default).
  final String conference;

  /// Bearer token issued once by `PUT /me` (`201`). Never logged or put in URLs.
  final String? attendeeToken;

  /// Evolved interest summary (`<= 1000` chars) sent on `PUT /me`.
  final String interests;

  /// Off by default per UX decision; when enabled, finished notes wait for
  /// explicit Send or Discard instead of Undo auto-send.
  final bool reviewBeforeSending;

  final List<String> selectedTopics;
  final List<String> goingTalkIds;
  final List<LocalNoteSummary> savedNotes;

  /// Combined distinct topics from [selectedTopics] and [savedNotes] (`<= 20`
  /// when sent to `PUT /me`).
  List<String> get combinedProfileTopics {
    final merged = _cleanTopics([
      ...selectedTopics,
      for (final note in savedNotes) ...note.topics,
    ]);
    if (merged.length <= 20) return List.unmodifiable(merged);
    return List.unmodifiable(merged.sublist(0, 20));
  }

  /// Active topic set for local constellation ranking across app restarts.
  Set<String> get activeWavelengthTopics => {
    ...selectedTopics,
    for (final note in savedNotes) ...note.topics,
  };

  /// Synthesizes the `<= 1000`-character `interests` field for `PUT /me`
  /// without leaking unshared private note text.
  String buildProfileInterests() {
    if (interests.isNotEmpty) {
      return _sanitizeInterests(interests);
    }
    final topics = combinedProfileTopics;
    final sharedSnippets = [
      for (final note in savedNotes)
        if (note.shared && note.sharedText != null && note.sharedText!.isNotEmpty)
          note.sharedText!,
    ];
    final parts = <String>[
      if (topics.isNotEmpty) 'Topics: ${topics.join(', ')}',
      ...sharedSnippets.take(2),
    ];
    return _sanitizeInterests(parts.join(' · '));
  }

  /// Exact JSON body for `PUT /me` (`ProfileWrite` with `extra="forbid"`).
  Map<String, Object?> toPutMeBody() => {
    'handle': handle,
    'conference': conference,
    'interests': buildProfileInterests(),
    'topics': combinedProfileTopics,
    'starred_talks': goingTalkIds.length <= 100
        ? goingTalkIds
        : goingTalkIds.sublist(0, 100),
  };

  PhoneProfile copyWith({
    String? handle,
    String? conference,
    String? attendeeToken,
    bool clearAttendeeToken = false,
    String? interests,
    bool? reviewBeforeSending,
    Iterable<String>? selectedTopics,
    Iterable<String>? goingTalkIds,
    Iterable<LocalNoteSummary>? savedNotes,
  }) => PhoneProfile(
    handle: handle ?? this.handle,
    conference: conference ?? this.conference,
    attendeeToken: clearAttendeeToken
        ? null
        : (attendeeToken ?? this.attendeeToken),
    interests: interests ?? this.interests,
    reviewBeforeSending: reviewBeforeSending ?? this.reviewBeforeSending,
    selectedTopics: selectedTopics ?? this.selectedTopics,
    goingTalkIds: goingTalkIds ?? this.goingTalkIds,
    savedNotes: savedNotes ?? this.savedNotes,
  );

  Map<String, Object?> toJson() => {
    'handle': handle,
    'ownerId': handle,
    'conference': conference,
    if (attendeeToken != null && attendeeToken!.isNotEmpty)
      'attendeeToken': attendeeToken,
    if (interests.isNotEmpty) 'interests': interests,
    'reviewBeforeSending': reviewBeforeSending,
    'selectedTopics': selectedTopics,
    'goingTalkIds': goingTalkIds,
    'savedNotes': [for (final note in savedNotes) note.toJson()],
  };

  factory PhoneProfile.fromJson(
    Object? json, {
    required String Function() generateHandle,
  }) {
    if (json is! Map) {
      return PhoneProfile(handle: generateHandle());
    }
    final rawHandle = json['handle'] ?? json['ownerId'];
    final validHandle =
        rawHandle is String && handlePattern.hasMatch(rawHandle.trim())
        ? rawHandle.trim()
        : generateHandle();

    final rawConference = json['conference'];
    final validConference =
        rawConference is String &&
            identifierPattern.hasMatch(rawConference.trim())
        ? rawConference.trim()
        : defaultConference;

    final rawToken = json['attendeeToken'];
    // If handle had to be regenerated, any previous token no longer matches it.
    final preservedToken =
        (rawHandle is String &&
            rawHandle.trim() == validHandle &&
            rawToken is String &&
            rawToken.trim().isNotEmpty)
        ? rawToken.trim()
        : null;

    final rawInterests = json['interests'];
    final reviewBeforeSending = json['reviewBeforeSending'] == true;

    final selectedTopics = <String>[];
    if (json['selectedTopics'] case final List<Object?> rawTopics) {
      for (final item in rawTopics) {
        if (item is String && item.trim().isNotEmpty) {
          selectedTopics.add(item.trim());
        }
      }
    }

    final goingTalkIds = <String>[];
    if (json['goingTalkIds'] case final List<Object?> rawTalks) {
      for (final item in rawTalks) {
        if (item is String && item.trim().isNotEmpty) {
          goingTalkIds.add(item.trim());
        }
      }
    }

    final savedNotes = <LocalNoteSummary>[];
    if (json['savedNotes'] case final List<Object?> rawNotes) {
      for (final item in rawNotes) {
        try {
          savedNotes.add(LocalNoteSummary.fromJson(item));
        } on FormatException {
          // Skip malformed entries rather than losing the attendee's profile.
        }
      }
    }

    return PhoneProfile(
      handle: validHandle,
      conference: validConference,
      attendeeToken: preservedToken,
      interests: rawInterests is String ? rawInterests : '',
      reviewBeforeSending: reviewBeforeSending,
      selectedTopics: selectedTopics,
      goingTalkIds: goingTalkIds,
      savedNotes: savedNotes,
    );
  }

  /// Redacted string representation: never exposes [attendeeToken].
  @override
  String toString() =>
      'PhoneProfile(handle: $handle, conference: $conference, '
      'hasToken: ${attendeeToken != null}, '
      'reviewBeforeSending: $reviewBeforeSending, '
      'selectedTopics: ${selectedTopics.length}, '
      'goingTalkIds: ${goingTalkIds.length}, '
      'savedNotes: ${savedNotes.length})';
}

/// Persistent local store for the phone's opaque handle, attendee token,
/// preferences, selected topics, starred talks, and saved note metadata.
class PhoneProfileStore extends ChangeNotifier {
  PhoneProfileStore({
    ProfileFileProvider? fileProvider,
    ProfileDirectoryProvider? directoryProvider,
    Random? random,
  }) : _random = random ?? Random.secure(),
       _fileProvider =
           fileProvider ??
           (() async {
             final dir =
                 await (directoryProvider ?? getApplicationSupportDirectory)();
             return File('${dir.path}/confellow_profile.json');
           });

  static const String handlePrefix = 'cf_';

  final Random _random;
  final ProfileFileProvider _fileProvider;

  PhoneProfile? _profile;
  Future<PhoneProfile>? _pendingLoad;
  Future<void> _writeChain = Future<void>.value();

  /// Latest loaded profile snapshot, or null before [load] completes.
  PhoneProfile? get profile => _profile;

  /// Waits for any queued disk writes to finish.
  Future<void> flush() => _writeChain;

  /// Generates a fresh 23-character handle (`cf_<20 hex chars>`) matching both
  /// `Handle` (`2..32` chars) and `Identifier` (`1..128` chars).
  String generateHandle() {
    final buffer = StringBuffer(handlePrefix);
    for (var i = 0; i < 10; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Loads the persisted profile from disk, auto-generating and saving an
  /// opaque phone handle on first launch.
  Future<PhoneProfile> load() {
    if (_profile != null) return Future<PhoneProfile>.value(_profile!);
    return _pendingLoad ??= _loadFromDisk();
  }

  Future<PhoneProfile> _loadFromDisk() async {
    try {
      final file = await _fileProvider();
      if (await file.exists()) {
        final raw = await file.readAsString();
        final Object? decoded = jsonDecode(raw);
        var needsSave = false;
        final loaded = PhoneProfile.fromJson(
          decoded,
          generateHandle: () {
            needsSave = true;
            return generateHandle();
          },
        );
        _profile = loaded;
        if (needsSave) {
          await _enqueueSave(loaded);
        }
        notifyListeners();
        return loaded;
      }
    } catch (_) {
      // Corrupt or unreadable state falls back cleanly to a fresh local profile.
    }

    final initial = PhoneProfile(handle: generateHandle());
    _profile = initial;
    await _enqueueSave(initial);
    notifyListeners();
    return initial;
  }

  Future<PhoneProfile> setReviewBeforeSending(bool enabled) async {
    final current = await load();
    if (current.reviewBeforeSending == enabled) return current;
    return _commit(current.copyWith(reviewBeforeSending: enabled));
  }

  Future<PhoneProfile> setSelectedTopics(Iterable<String> topics) async {
    final current = await load();
    return _commit(current.copyWith(selectedTopics: topics));
  }

  Future<PhoneProfile> toggleTopic(String topic) async {
    final trimmed = _sanitizeTopic(topic);
    if (trimmed == null) return load();
    final current = await load();
    final lower = trimmed.toLowerCase();
    final exists = current.selectedTopics.any((t) => t.toLowerCase() == lower);
    final updated = exists
        ? [
            for (final t in current.selectedTopics)
              if (t.toLowerCase() != lower) t,
          ]
        : [...current.selectedTopics, trimmed];
    return _commit(current.copyWith(selectedTopics: updated));
  }

  Future<PhoneProfile> toggleGoingTalk(String talkId) async {
    final trimmed = talkId.trim();
    if (!PhoneProfile.talkIdPattern.hasMatch(trimmed)) return load();
    final current = await load();
    final exists = current.goingTalkIds.contains(trimmed);
    final updated = exists
        ? [
            for (final id in current.goingTalkIds)
              if (id != trimmed) id,
          ]
        : [...current.goingTalkIds, trimmed];
    return _commit(current.copyWith(goingTalkIds: updated));
  }

  Future<PhoneProfile> recordNote(
    LocalNoteSummary note, {
    String? evolvedInterests,
  }) async {
    final current = await load();
    final remaining = [
      for (final existing in current.savedNotes)
        if (existing.conversationId != note.conversationId) existing,
    ];
    final mergedTopics = _cleanTopics([
      ...current.selectedTopics,
      ...note.topics,
    ]);
    return _commit(
      current.copyWith(
        selectedTopics: mergedTopics,
        savedNotes: [note, ...remaining],
        interests: evolvedInterests ?? current.interests,
      ),
    );
  }

  Future<PhoneProfile> removeNote(String conversationId) async {
    final current = await load();
    final updated = [
      for (final existing in current.savedNotes)
        if (existing.conversationId != conversationId) existing,
    ];
    return _commit(current.copyWith(savedNotes: updated));
  }

  /// Stores the bearer token returned by `PUT /me` (`201`).
  Future<PhoneProfile> saveAttendeeToken(
    String token, {
    String? handle,
    String? conference,
  }) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return load();
    final current = await load();
    return _commit(
      current.copyWith(
        handle: handle ?? current.handle,
        conference: conference ?? current.conference,
        attendeeToken: trimmed,
      ),
    );
  }

  /// Rotates to a newly generated handle and clears any stale bearer token
  /// (used on `409` handle collision during initial claim or `401` expiry).
  Future<PhoneProfile> rotateHandle({String? conference}) async {
    final current = await load();
    return _commit(
      current.copyWith(
        handle: generateHandle(),
        conference: conference ?? current.conference,
        clearAttendeeToken: true,
      ),
    );
  }

  Future<PhoneProfile> _commit(PhoneProfile next) async {
    _profile = next;
    await _enqueueSave(next);
    notifyListeners();
    return next;
  }

  Future<void> _enqueueSave(PhoneProfile snapshot) {
    final payload = jsonEncode(snapshot.toJson());
    return _writeChain = _writeChain.then((_) async {
      final file = await _fileProvider();
      await file.parent.create(recursive: true);
      final tempFile = File('${file.path}.tmp');
      await tempFile.writeAsString(payload, flush: true);
      await tempFile.rename(file.path);
    });
  }
}

final RegExp _controlCharsPattern = RegExp(r'[\x00-\x1f\x7f]+');

String? _sanitizeSingleLine(String? input, {required int maxRunes}) {
  if (input == null) return null;
  final collapsed = input
      .replaceAll(_controlCharsPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (collapsed.isEmpty) return null;
  final runes = collapsed.runes;
  if (runes.length <= maxRunes) return collapsed;
  return String.fromCharCodes(runes.take(maxRunes)).trimRight();
}

String _sanitizeInterests(String input) =>
    _sanitizeSingleLine(input, maxRunes: 1000) ?? '';

String? _sanitizeTopic(String raw) => _sanitizeSingleLine(raw, maxRunes: 64);

List<String> _cleanTopics(Iterable<String> rawTopics) {
  final byLower = <String, String>{};
  for (final raw in rawTopics) {
    final clean = _sanitizeTopic(raw);
    if (clean != null) {
      byLower.putIfAbsent(clean.toLowerCase(), () => clean);
    }
  }
  return byLower.values.toList(growable: false);
}

List<String> _cleanTalkIds(Iterable<String> rawTalkIds) {
  final seen = <String>{};
  final result = <String>[];
  for (final raw in rawTalkIds) {
    final trimmed = raw.trim();
    if (PhoneProfile.talkIdPattern.hasMatch(trimmed) && seen.add(trimmed)) {
      result.add(trimmed);
    }
  }
  return result;
}
