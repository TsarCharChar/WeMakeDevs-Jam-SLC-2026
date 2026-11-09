import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Kind of node rendered on the "Find my wavelength" constellation map.
enum SpaceKind { topic, talk }

/// Qualitative closeness ring on the constellation map.
///
/// Closeness is communicated by ring position and human words, never by match
/// percentages or physical proximity.
enum ClosenessRing { inner, middle, outer }

/// Immutable conference session parsed from the bundled KubeCon schedule asset.
///
/// Keeps title, abstract, times, room, and tags while deliberately omitting
/// speaker names.
@immutable
class ScheduleTalk {
  const ScheduleTalk({
    required this.id,
    required this.title,
    required this.abstractText,
    required this.time,
    required this.day,
    required this.start,
    required this.end,
    required this.room,
    required this.tags,
  });

  final String id;
  final String title;
  final String abstractText;
  final String time;
  final String day;
  final String start;
  final String end;
  final String room;
  final List<String> tags;

  /// Technical and domain tags on this session (excluding format/level meta-tags).
  List<String> get topicTags =>
      tags.where((tag) => !ScheduleCatalog.isMetaTag(tag)).toList(growable: false);

  /// Session format, experience level, or stage meta-tags on this session.
  List<String> get metaTags =>
      tags.where(ScheduleCatalog.isMetaTag).toList(growable: false);

  /// True for conference logistics blocks (registration, coat check, coffee
  /// breaks, lunch, receptions) or co-located wrapper listings that carry no
  /// technical topic tags.
  bool get isLogistics =>
      (tags.isEmpty && _logisticsTitlePattern.hasMatch(title)) ||
      (topicTags.isEmpty &&
          (abstractText.isEmpty ||
              tags.any(_coLocatedWrapperTags.contains) ||
              _logisticsTitlePattern.hasMatch(title)));

  static const Set<String> _coLocatedWrapperTags = {
    'Sponsor-hosted Co-located Events',
    'CNCF-hosted Co-located Events',
    'Separate Registration Required',
  };

  static final RegExp _logisticsTitlePattern = RegExp(
    r'(registration|badge pick-up|coat \+ bag check|coffee break|\blunch\b|reception|party|booth crawl)',
    caseSensitive: false,
  );

  factory ScheduleTalk.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Schedule entry must be a JSON object.');
    }
    final id = _requireString(json, 'id', allowEmpty: false);
    final title = _requireString(json, 'title', allowEmpty: false);
    final abstractText = _requireString(json, 'abstract', allowEmpty: true);
    final time = _requireString(json, 'time', allowEmpty: true);
    final day = _requireString(json, 'day', allowEmpty: true);
    final start = _requireString(json, 'start', allowEmpty: true);
    final end = _requireString(json, 'end', allowEmpty: true);
    final room = _requireString(json, 'room', allowEmpty: true);

    final rawTags = json['tags'];
    if (rawTags is! List) {
      throw const FormatException('Schedule entry tags must be a JSON list.');
    }
    final parsedTags = <String>[];
    final seen = <String>{};
    for (final item in rawTags) {
      if (item is! String) {
        throw const FormatException('Schedule tag must be a string.');
      }
      final trimmed = item.trim();
      if (trimmed.isNotEmpty && seen.add(trimmed)) {
        parsedTags.add(trimmed);
      }
    }

    // Speaker fields (if ever present in an upstream export) are intentionally
    // ignored so speaker names never enter app state.
    return ScheduleTalk(
      id: id,
      title: title,
      abstractText: abstractText,
      time: time,
      day: day,
      start: start,
      end: end,
      room: room,
      tags: List.unmodifiable(parsedTags),
    );
  }

  static String _requireString(
    Map<Object?, Object?> json,
    String key, {
    required bool allowEmpty,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Invalid or missing "$key" in schedule entry.');
    }
    final trimmed = value.trim();
    if (!allowEmpty && trimmed.isEmpty) {
      throw FormatException('Schedule entry "$key" must not be empty.');
    }
    return trimmed;
  }
}

/// Ranked Topic Space or Talk Space surfaced on the constellation map and
/// discovery sheet.
@immutable
class WavelengthSpace {
  const WavelengthSpace({
    required this.id,
    required this.kind,
    required this.title,
    required this.closeness,
    required this.why,
    required this.recentTopics,
    required this.peopleCount,
    this.talk,
    this.isGoing = false,
  });

  /// Stable identifier (`topic:<tag>` or `talk:<id>`).
  final String id;
  final SpaceKind kind;
  final String title;
  final ClosenessRing closeness;

  /// Plain-language explanation of why this Space matches the user's wavelength.
  /// Never contains percentages or physical proximity claims ("nearby").
  final String why;

  /// Matched or related schedule topics for the discovery sheet.
  final List<String> recentTopics;

  /// Count of people tuned into this Space (handles stay hidden before room join).
  final int peopleCount;

  /// Populated when [kind] is [SpaceKind.talk].
  final ScheduleTalk? talk;

  /// True when the user marked "I'm going" on this talk.
  final bool isGoing;
}

/// Bundled KubeCon schedule catalog, topic matcher, and qualitative Space ranker.
class ScheduleCatalog {
  ScheduleCatalog._({
    required this.talks,
    required this.topicVocabulary,
    required this._talksById,
    required this._canonicalByLower,
    required this._matchPhrases,
    required this._effectiveTalkTopics,
    required this._topicSessionCounts,
  });

  static const String defaultAssetPath = 'assets/data/kubecon_schedule.json';

  /// Curated format, level, venue, registration, and sub-event wrapper tags
  /// inspected across all 143 unique tags in `kubecon_schedule.json`.
  ///
  /// Excluding these leaves genuine CNCF projects, Kubernetes SIGs/WGs, and
  /// technical/community domain subjects in [topicVocabulary].
  static const Set<String> knownMetaTags = {
    // Experience levels & audience onboarding tracks
    'Any Level',
    'Beginner',
    'Intermediate',
    'Advanced',
    'Cloud Native Novice',
    'Cloud Native University',
    'Emerging + Advanced',
    // Session formats, stages, registration, & sponsor tracks
    'End User Talk',
    'Maintainer Track',
    'Sponsored',
    'Cloud Native Theater',
    'Project Lightning Talks',
    'Sponsor Demo Theater',
    'Keynote Sessions',
    'Solutions Showcase',
    'Experiences',
    'Cloud Native Experience',
    'Separate Registration Required',
    'Project Pavilion Stage',
    'Project Pavilion Tours',
    'Project Opportunities',
    'Sponsor-hosted Co-located Events',
    'CNCF-hosted Co-located Events',
    'Learning Lounge',
    'Network Nook',
    'BoF',
    '⚡ Lightning Talks',
    '📚 Tutorials',
    '🚨 Contribfest',
    '🪧 Poster Sessions',
    // Cloud Native Theater mini-summit wrappers whose canonical project tags
    // ('Envoy', 'Istio', 'Kubeflow', 'KubeVirt', 'Kyverno') exist in schedule
    'EnvoyCon',
    'Istio Day',
    'Kubeflow Summit',
    'KubeVirt Summit',
    'KyvernoCon',
  };

  static final Set<String> _knownMetaTagsLower = {
    for (final tag in knownMetaTags) _normalizeWhitespace(tag),
  };

  /// Safe phrase aliases mapping natural abbreviations, hyphen/punctuation
  /// variants, and sub-project names strictly to canonical schedule tags.
  ///
  /// An alias is only active when its target tag actually exists in the loaded
  /// catalog's [topicVocabulary], so topics outside the schedule are never
  /// invented.
  static const Map<String, String> _curatedAliasesToScheduleTag = {
    'ai inference': 'AI Inference + Agentic',
    'agentic': 'AI Inference + Agentic',
    'agentic ai': 'AI Inference + Agentic',
    'ai agent': 'AI Inference + Agentic',
    'ai agents': 'AI Inference + Agentic',
    'llm inference': 'AI Inference + Agentic',
    'application development': 'Application Development + Delivery',
    'application delivery': 'Application Development + Delivery',
    'app delivery': 'Application Development + Delivery',
    'app development': 'Application Development + Delivery',
    'continuous delivery': 'Application Development + Delivery',
    'api-machinery': 'API Machinery',
    'argocd': 'Argo',
    'argo cd': 'Argo',
    'argo rollouts': 'Argo',
    'argo workflows': 'Argo',
    'autoscaler': 'Autoscaling',
    'hpa': 'Autoscaling',
    'cadence': 'Cadence Workflow',
    'kubectl': 'CLI',
    'kustomize': 'CLI',
    'coredns': 'CoreDNS',
    'crio': 'cri-o',
    'data processing': 'Data Processing + Storage',
    'devex': 'Developer Experience',
    'emissary': 'Emissary-ingress',
    'emissary ingress': 'Emissary-ingress',
    'envoycon': 'Envoy',
    'envoy proxy': 'Envoy',
    'flatcar': 'Flatcar Container Linux',
    'flatcar linux': 'Flatcar Container Linux',
    'fluxcd': 'Flux',
    'flux cd': 'Flux',
    'intoto': 'in-toto',
    'accessibility': 'Inclusion + Accessibility',
    'istio day': 'Istio',
    'k3s': 'K3s',
    'kai': 'KAI Scheduler',
    'kubeburner': 'kube-burner',
    'kubeflow summit': 'Kubeflow',
    'k8s': 'Kubernetes',
    'kubevirt summit': 'KubeVirt',
    'kyvernocon': 'Kyverno',
    'litmuschaos': 'Litmus',
    'llmd': 'llm-d',
    'metal3': 'Metal3.io',
    'multi-cluster': 'Multicluster',
    'multi cluster': 'Multicluster',
    'networking': 'Network',
    'ocm': 'Open Cluster Management',
    'opa': 'Open Policy Agent (OPA)',
    'open policy agent': 'Open Policy Agent (OPA)',
    'otel': 'OpenTelemetry',
    'open telemetry': 'OpenTelemetry',
    'operations and performance': 'Operations + Performance',
    'ovn': 'OVN-Kubernetes',
    'ovn kubernetes': 'OVN-Kubernetes',
    'podman': 'Podman Container Tools',
    'spire': 'SPIFFE',
  };

  /// Returns true when [tag] is a format, level, venue, or wrapper meta-tag
  /// rather than a technical/domain topic.
  static bool isMetaTag(String tag) {
    final normalized = _normalizeWhitespace(tag);
    return normalized.isEmpty || _knownMetaTagsLower.contains(normalized);
  }

  final List<ScheduleTalk> talks;

  /// Sorted, deduplicated technical and domain tags present in [talks].
  final List<String> topicVocabulary;

  final Map<String, ScheduleTalk> _talksById;
  final Map<String, String> _canonicalByLower;
  final List<_MatchPhrase> _matchPhrases;
  final Map<String, List<String>> _effectiveTalkTopics;
  final Map<String, int> _topicSessionCounts;

  factory ScheduleCatalog.fromTalks(Iterable<ScheduleTalk> talks) {
    final talkList = List<ScheduleTalk>.unmodifiable(talks);
    final talksById = <String, ScheduleTalk>{
      for (final talk in talkList) talk.id: talk,
    };

    final canonicalByLower = <String, String>{};
    for (final talk in talkList) {
      for (final tag in talk.tags) {
        if (isMetaTag(tag)) continue;
        final lower = _normalizeWhitespace(tag);
        canonicalByLower.putIfAbsent(lower, () => tag);
      }
    }

    final vocabulary = canonicalByLower.values.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final phraseToTopic = <String, String>{};
    for (final topic in vocabulary) {
      final lower = _normalizeWhitespace(topic);
      phraseToTopic[lower] = topic;
      if (lower.contains(' + ')) {
        phraseToTopic.putIfAbsent(lower.replaceAll(' + ', ' and '), () => topic);
        phraseToTopic.putIfAbsent(lower.replaceAll(' + ', ' & '), () => topic);
      }
    }
    for (final entry in _curatedAliasesToScheduleTag.entries) {
      final targetLower = _normalizeWhitespace(entry.value);
      final canonicalTarget = canonicalByLower[targetLower];
      if (canonicalTarget != null) {
        phraseToTopic.putIfAbsent(
          _normalizeWhitespace(entry.key),
          () => canonicalTarget,
        );
      }
    }

    final matchPhrases = [
      for (final entry in phraseToTopic.entries)
        _MatchPhrase(phrase: entry.key, canonicalTopic: entry.value),
    ]..sort((a, b) => b.phrase.length.compareTo(a.phrase.length));

    final effectiveTalkTopics = <String, List<String>>{};
    final topicSessionCounts = <String, int>{
      for (final topic in vocabulary) topic: 0,
    };

    for (final talk in talkList) {
      final combined = <String>{};
      for (final tag in talk.tags) {
        if (!isMetaTag(tag)) {
          final canonical = canonicalByLower[_normalizeWhitespace(tag)];
          if (canonical != null) combined.add(canonical);
        } else {
          final mapped = phraseToTopic[_normalizeWhitespace(tag)];
          if (mapped != null) combined.add(mapped);
        }
      }
      for (final titleTopic in _matchText(talk.title, matchPhrases)) {
        combined.add(titleTopic);
      }
      final frozen = List<String>.unmodifiable(combined);
      effectiveTalkTopics[talk.id] = frozen;
      for (final topic in frozen) {
        topicSessionCounts[topic] = (topicSessionCounts[topic] ?? 0) + 1;
      }
    }

    return ScheduleCatalog._(
      talks: talkList,
      topicVocabulary: List<String>.unmodifiable(vocabulary),
      talksById: talksById,
      canonicalByLower: canonicalByLower,
      matchPhrases: matchPhrases,
      effectiveTalkTopics: effectiveTalkTopics,
      topicSessionCounts: topicSessionCounts,
    );
  }

  factory ScheduleCatalog.fromJsonString(String rawJson) {
    final Object? decoded = jsonDecode(rawJson);
    if (decoded is! List) {
      throw const FormatException('Schedule JSON root must be a list.');
    }
    return ScheduleCatalog.fromTalks(decoded.map(ScheduleTalk.fromJson));
  }

  static Future<ScheduleCatalog> loadFromAssets({
    AssetBundle? bundle,
    String assetPath = defaultAssetPath,
  }) async {
    final raw = await (bundle ?? rootBundle).loadString(assetPath);
    return ScheduleCatalog.fromJsonString(raw);
  }

  /// Looks up a talk by [id], or null if absent.
  ScheduleTalk? talkById(String id) => _talksById[id];

  /// Number of sessions associated with [topic] (0 if unknown).
  int sessionCountForTopic(String topic) {
    final canonical = _canonicalByLower[_normalizeWhitespace(topic)];
    if (canonical == null) return 0;
    return _topicSessionCounts[canonical] ?? 0;
  }

  /// Effective canonical schedule topics associated with [talkId].
  List<String> effectiveTopicsForTalk(String talkId) =>
      _effectiveTalkTopics[talkId] ?? const [];

  /// Non-logistics sessions associated with [topic].
  List<ScheduleTalk> talksForTopic(String topic) {
    final canonical = _canonicalByLower[_normalizeWhitespace(topic)];
    if (canonical == null) return const [];
    return List.unmodifiable([
      for (final talk in talks)
        if (!talk.isLogistics &&
            (_effectiveTalkTopics[talk.id]?.contains(canonical) ?? false))
          talk,
    ]);
  }

  /// Returns canonical schedule topics sorted by session frequency descending,
  /// useful for starter topic chips before any note is recorded.
  List<String> popularTopics({int limit = 16}) {
    final sorted = [...topicVocabulary]..sort((a, b) {
      final byCount = (_topicSessionCounts[b] ?? 0).compareTo(
        _topicSessionCounts[a] ?? 0,
      );
      if (byCount != 0) return byCount;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    if (limit >= sorted.length) return List.unmodifiable(sorted);
    return List.unmodifiable(sorted.sublist(0, limit));
  }

  /// Deterministically matches [text] against [topicVocabulary].
  ///
  /// Uses case-insensitive token-bounded phrase matching plus curated aliases
  /// whose targets exist in [topicVocabulary]. Never invents topics outside the
  /// bundled schedule.
  List<String> extractMatchedTopics(String text) {
    if (text.trim().isEmpty || _matchPhrases.isEmpty) {
      return const [];
    }
    return List.unmodifiable(_matchText(text, _matchPhrases));
  }

  /// Resolves user-selected topic strings to canonical entries in
  /// [topicVocabulary], discarding unknown or meta-tag strings.
  List<String> canonicalizeTopics(Iterable<String> rawTopics) {
    final result = <String>{};
    for (final item in rawTopics) {
      final canonical = _canonicalByLower[_normalizeWhitespace(item)];
      if (canonical != null) {
        result.add(canonical);
      }
    }
    return List.unmodifiable(result);
  }

  /// Ranks Topic Spaces (`topic:<tag>`) and Talk Spaces (`talk:<id>`) into
  /// qualitative closeness rings (`inner`, `middle`, `outer`) with plain-words
  /// `why` explanations.
  List<WavelengthSpace> rankSpaces({
    required Set<String> activeTopics,
    required List<String> noteTexts,
    required Set<String> goingTalkIds,
    int maxResults = 24,
  }) {
    if (maxResults <= 0 || talks.isEmpty) return const [];

    final selectedSet = <String>{...canonicalizeTopics(activeTopics)};
    final noteTopicCounts = <String, int>{};
    for (final note in noteTexts) {
      for (final topic in extractMatchedTopics(note)) {
        noteTopicCounts[topic] = (noteTopicCounts[topic] ?? 0) + 1;
      }
    }

    final goingSet = <String>{
      for (final id in goingTalkIds)
        if (_talksById.containsKey(id)) id,
    };
    final goingTopics = <String>{};
    for (final id in goingSet) {
      goingTopics.addAll(_effectiveTalkTopics[id] ?? const []);
    }

    final hasPersonalSignal =
        selectedSet.isNotEmpty ||
        noteTopicCounts.isNotEmpty ||
        goingSet.isNotEmpty;

    if (!hasPersonalSignal) {
      return _coldStartSpaces(maxResults: maxResults);
    }

    final directTopics = <String>{...selectedSet, ...noteTopicCounts.keys};

    // Discover co-occurring topics from sessions that match the user's direct
    // interests so the outer ring surfaces adjacent conference spaces.
    final coOccurringBridge = <String, Set<String>>{};
    final coOccurringCounts = <String, int>{};
    if (directTopics.isNotEmpty) {
      for (final talk in talks) {
        if (talk.isLogistics) continue;
        final talkTopics = _effectiveTalkTopics[talk.id] ?? const [];
        final sharedDirect = [
          for (final t in talkTopics)
            if (directTopics.contains(t)) t,
        ];
        if (sharedDirect.isEmpty) continue;
        for (final t in talkTopics) {
          if (directTopics.contains(t)) continue;
          coOccurringCounts[t] = (coOccurringCounts[t] ?? 0) + 1;
          (coOccurringBridge[t] ??= <String>{}).addAll(sharedDirect);
        }
      }
    }

    final candidateTopics = <String>{
      ...noteTopicCounts.keys,
      ...selectedSet,
      ...goingTopics,
    };

    final sortedCoOccurring = coOccurringCounts.keys.toList()
      ..sort((a, b) {
        final byCount = (coOccurringCounts[b] ?? 0).compareTo(
          coOccurringCounts[a] ?? 0,
        );
        if (byCount != 0) return byCount;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    for (final topic in sortedCoOccurring.take(6)) {
      candidateTopics.add(topic);
    }

    final scoredTopics = <_ScoredSpace>[];
    for (final topic in candidateTopics) {
      final noteHits = noteTopicCounts[topic] ?? 0;
      final isSelected = selectedSet.contains(topic);
      final isFromGoing = goingTopics.contains(topic);
      final coCount = coOccurringCounts[topic] ?? 0;

      final int score =
          (noteHits > 0 ? 6 + (noteHits - 1) * 2 : 0) +
          (isSelected ? 5 : 0) +
          (isFromGoing ? 3 : 0) +
          (coCount > 0 ? 1 + (coCount > 3 ? 1 : 0) : 0);

      final ClosenessRing ring;
      if (noteHits > 0 || isSelected) {
        ring = ClosenessRing.inner;
      } else if (isFromGoing) {
        ring = ClosenessRing.middle;
      } else {
        ring = ClosenessRing.outer;
      }

      final String why;
      if (noteHits > 0 && isSelected) {
        why = 'Matches your notes and your interest in $topic';
      } else if (noteHits > 0) {
        why = 'From your notes on $topic';
      } else if (isSelected) {
        why = 'Matches your interest in $topic';
      } else if (isFromGoing) {
        why = 'Featured in a session on your schedule';
      } else {
        final bridges = (coOccurringBridge[topic] ?? const <String>{})
            .take(2)
            .toList(growable: false);
        why = bridges.isNotEmpty
            ? 'Connected to sessions on ${_joinHumanList(bridges)}'
            : 'Explored in KubeCon sessions on $topic';
      }

      final related = _relatedTopicsForTopic(topic);
      scoredTopics.add(
        _ScoredSpace(
          score: score,
          space: WavelengthSpace(
            id: 'topic:$topic',
            kind: SpaceKind.topic,
            title: topic,
            closeness: ring,
            why: why,
            recentTopics: List.unmodifiable([topic, ...related.take(3)]),
            peopleCount: _estimateTopicPeopleCount(
              topic,
              personalSignal: noteHits + (isSelected ? 1 : 0),
            ),
          ),
        ),
      );
    }

    final scoredTalks = <_ScoredSpace>[];
    for (final talk in talks) {
      final isGoing = goingSet.contains(talk.id);
      if (talk.isLogistics && !isGoing) continue;

      final talkTopics = _effectiveTalkTopics[talk.id] ?? const [];
      final matchedNoteTopics = [
        for (final t in talkTopics)
          if ((noteTopicCounts[t] ?? 0) > 0) t,
      ];
      final matchedSelectedTopics = [
        for (final t in talkTopics)
          if (selectedSet.contains(t)) t,
      ];
      final matchedDirect = <String>{
        ...matchedNoteTopics,
        ...matchedSelectedTopics,
      };

      // Check abstract matches only when direct topics are active so talks whose
      // tags are format-only still surface in the outer/middle ring.
      var abstractMatches = const <String>[];
      if (matchedDirect.isEmpty && directTopics.isNotEmpty && talk.abstractText.isNotEmpty) {
        final inAbstract = extractMatchedTopics(talk.abstractText);
        abstractMatches = [
          for (final t in inAbstract)
            if (directTopics.contains(t)) t,
        ];
      }

      final matchedGoingTopics = [
        for (final t in talkTopics)
          if (!matchedDirect.contains(t) && goingTopics.contains(t)) t,
      ];

      if (!isGoing &&
          matchedDirect.isEmpty &&
          abstractMatches.isEmpty &&
          matchedGoingTopics.isEmpty) {
        continue;
      }

      final allMatched = <String>{
        ...matchedDirect,
        ...abstractMatches,
        ...matchedGoingTopics,
      };

      final int score =
          (isGoing ? 9 : 0) +
          matchedNoteTopics.length * 5 +
          matchedSelectedTopics.length * 4 +
          abstractMatches.length * 2 +
          matchedGoingTopics.length;

      final ClosenessRing ring;
      if (isGoing ||
          matchedDirect.length >= 2 ||
          (matchedNoteTopics.isNotEmpty && matchedSelectedTopics.isNotEmpty)) {
        ring = ClosenessRing.inner;
      } else if (matchedDirect.isNotEmpty) {
        ring = ClosenessRing.middle;
      } else {
        ring = ClosenessRing.outer;
      }

      final String why;
      if (isGoing && matchedDirect.isNotEmpty) {
        why =
            'On your schedule and matches your interest in ${_joinHumanList(matchedDirect.take(3).toList())}';
      } else if (isGoing) {
        why = 'Saved to your schedule';
      } else if (matchedNoteTopics.isNotEmpty &&
          matchedSelectedTopics.any((t) => !matchedNoteTopics.contains(t))) {
        why =
            'Matches your notes and interests in ${_joinHumanList(matchedDirect.take(3).toList())}';
      } else if (matchedNoteTopics.isNotEmpty) {
        why =
            'Matches your notes on ${_joinHumanList(matchedNoteTopics.take(3).toList())}';
      } else if (matchedSelectedTopics.isNotEmpty) {
        why =
            'Matches your interest in ${_joinHumanList(matchedSelectedTopics.take(3).toList())}';
      } else if (abstractMatches.isNotEmpty) {
        why =
            'Touches on ${_joinHumanList(abstractMatches.take(3).toList())} in session details';
      } else {
        why =
            'Shares ${_joinHumanList(matchedGoingTopics.take(2).toList())} with sessions on your schedule';
      }

      final recent = <String>{
        ...allMatched,
        ...talkTopics,
      };

      scoredTalks.add(
        _ScoredSpace(
          score: score,
          space: WavelengthSpace(
            id: 'talk:${talk.id}',
            kind: SpaceKind.talk,
            title: talk.title,
            closeness: ring,
            why: why,
            recentTopics: List.unmodifiable(recent.take(4)),
            peopleCount: _estimateTalkPeopleCount(
              talk,
              topicCount: talkTopics.length,
              isGoing: isGoing,
            ),
            talk: talk,
            isGoing: isGoing,
          ),
        ),
      );
    }

    scoredTopics.sort(_compareScoredSpaces);
    scoredTalks.sort(_compareScoredSpaces);

    final topicQuota = (maxResults ~/ 2).clamp(1, maxResults);
    final talkQuota = maxResults - topicQuota;

    final chosen = <_ScoredSpace>[
      ...scoredTopics.take(topicQuota),
      ...scoredTalks.take(talkQuota),
    ];

    if (chosen.length < maxResults) {
      final remaining = maxResults - chosen.length;
      if (scoredTopics.length > topicQuota) {
        chosen.addAll(scoredTopics.skip(topicQuota).take(remaining));
      } else if (scoredTalks.length > talkQuota) {
        chosen.addAll(scoredTalks.skip(talkQuota).take(remaining));
      }
    }

    chosen.sort(_compareScoredSpaces);
    return List.unmodifiable(chosen.map((entry) => entry.space));
  }

  List<WavelengthSpace> _coldStartSpaces({required int maxResults}) {
    final topicCount = (maxResults ~/ 2).clamp(1, maxResults);
    final talkCount = maxResults - topicCount;

    final spaces = <WavelengthSpace>[];
    final topTopics = popularTopics(limit: topicCount);
    for (var i = 0; i < topTopics.length; i++) {
      final topic = topTopics[i];
      final sessions = _topicSessionCounts[topic] ?? 1;
      final sessionWord = sessions == 1 ? 'session' : 'sessions';
      spaces.add(
        WavelengthSpace(
          id: 'topic:$topic',
          kind: SpaceKind.topic,
          title: topic,
          closeness: i < 4 ? ClosenessRing.middle : ClosenessRing.outer,
          why: 'Active across $sessions KubeCon $sessionWord',
          recentTopics: List.unmodifiable([
            topic,
            ..._relatedTopicsForTopic(topic).take(2),
          ]),
          peopleCount: _estimateTopicPeopleCount(topic, personalSignal: 0),
        ),
      );
    }

    final candidateTalks = [
      for (final talk in talks)
        if (!talk.isLogistics && (_effectiveTalkTopics[talk.id]?.isNotEmpty ?? false))
          talk,
    ];
    for (var i = 0; i < candidateTalks.length && spaces.length < maxResults && i < talkCount; i++) {
      final talk = candidateTalks[i];
      final topics = _effectiveTalkTopics[talk.id] ?? const [];
      spaces.add(
        WavelengthSpace(
          id: 'talk:${talk.id}',
          kind: SpaceKind.talk,
          title: talk.title,
          closeness: ClosenessRing.outer,
          why: 'KubeCon session exploring ${_joinHumanList(topics.take(2).toList())}',
          recentTopics: List.unmodifiable(topics.take(4)),
          peopleCount: _estimateTalkPeopleCount(
            talk,
            topicCount: topics.length,
            isGoing: false,
          ),
          talk: talk,
        ),
      );
    }
    return List.unmodifiable(spaces);
  }

  List<String> _relatedTopicsForTopic(String topic) {
    final counts = <String, int>{};
    for (final talk in talks) {
      final topics = _effectiveTalkTopics[talk.id] ?? const [];
      if (!topics.contains(topic)) continue;
      for (final other in topics) {
        if (other == topic) continue;
        counts[other] = (counts[other] ?? 0) + 1;
      }
    }
    final sorted = counts.keys.toList()
      ..sort((a, b) {
        final byCount = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
        if (byCount != 0) return byCount;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return sorted;
  }

  int _estimateTopicPeopleCount(String topic, {required int personalSignal}) {
    final sessions = _topicSessionCounts[topic] ?? 1;
    return (3 + sessions * 2 + personalSignal).clamp(2, 64);
  }

  int _estimateTalkPeopleCount(
    ScheduleTalk talk, {
    required int topicCount,
    required bool isGoing,
  }) {
    final hashSeed = talk.id.codeUnits.fold<int>(0, (sum, c) => (sum + c) % 11);
    return 4 + hashSeed + topicCount * 2 + (isGoing ? 1 : 0);
  }

  static int _compareScoredSpaces(_ScoredSpace a, _ScoredSpace b) {
    final byRing = a.space.closeness.index.compareTo(b.space.closeness.index);
    if (byRing != 0) return byRing;
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    if (a.space.kind != b.space.kind) {
      return a.space.kind.index.compareTo(b.space.kind.index);
    }
    return a.space.title.toLowerCase().compareTo(b.space.title.toLowerCase());
  }

  static List<String> _matchText(String text, List<_MatchPhrase> phrases) {
    final normalized = _normalizeWhitespace(text);
    if (normalized.isEmpty) return const [];

    final earliestHitByTopic = <String, int>{};
    for (final entry in phrases) {
      final needle = entry.phrase;
      var searchFrom = 0;
      while (searchFrom <= normalized.length - needle.length) {
        final idx = normalized.indexOf(needle, searchFrom);
        if (idx == -1) break;
        final end = idx + needle.length;
        final leftOk = idx == 0 || !_isWordCodeUnit(normalized.codeUnitAt(idx - 1));
        final rightOk =
            end == normalized.length || !_isWordCodeUnit(normalized.codeUnitAt(end));

        // Guard against matching Kubernetes SIG-Node on "node.js".
        final isNodeJsFalsePositive =
            needle == 'node' && normalized.startsWith('.js', end);

        if (leftOk && rightOk && !isNodeJsFalsePositive) {
          final existing = earliestHitByTopic[entry.canonicalTopic];
          if (existing == null || idx < existing) {
            earliestHitByTopic[entry.canonicalTopic] = idx;
          }
          break;
        }
        searchFrom = idx + 1;
      }
    }

    final matched = earliestHitByTopic.keys.toList()
      ..sort((a, b) {
        final byPos = earliestHitByTopic[a]!.compareTo(earliestHitByTopic[b]!);
        if (byPos != 0) return byPos;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return matched;
  }

  static String _normalizeWhitespace(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _isWordCodeUnit(int unit) =>
      (unit >= 0x30 && unit <= 0x39) || // 0-9
      (unit >= 0x41 && unit <= 0x5A) || // A-Z
      (unit >= 0x61 && unit <= 0x7A) || // a-z
      (unit >= 0xC0 && unit <= 0x024F); // Latin-1 / Latin Extended letters

  static String _joinHumanList(List<String> items) {
    if (items.isEmpty) return 'cloud native topics';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} and ${items[1]}';
    final head = items.sublist(0, items.length - 1).join(', ');
    return '$head, and ${items.last}';
  }
}

class _MatchPhrase {
  const _MatchPhrase({required this.phrase, required this.canonicalTopic});

  final String phrase;
  final String canonicalTopic;
}

class _ScoredSpace {
  const _ScoredSpace({required this.score, required this.space});

  final int score;
  final WavelengthSpace space;
}
