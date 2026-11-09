import 'dart:convert';
import 'dart:math' as math;

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

@immutable
class ScopeTopicEntry {
  const ScopeTopicEntry({
    required this.id,
    required this.label,
    required this.count,
    required this.ring,
    required this.people,
    required this.why,
    required this.linkedTopics,
    this.featuredTalk,
  });

  final String id;
  final String label;
  final int count;
  final int ring; // 0, 1, or 2
  final int people; // 0 unless backed by real backend moment count
  final String why;
  final List<String> linkedTopics;
  final ScheduleTalk? featuredTalk;
}

@immutable
class ScopeTalkEntry {
  const ScopeTalkEntry({
    required this.id,
    required this.topicId,
    required this.talk,
    required this.going,
    required this.why,
    required this.linkedTopics,
  });

  final String id;
  final String topicId;
  final ScheduleTalk talk;
  final bool going;
  final String why;
  final List<String> linkedTopics;
}

@immutable
class ScopeGraphData {
  const ScopeGraphData({
    required this.topics,
    required this.talks,
    required this.edges,
  });

  final List<ScopeTopicEntry> topics;
  final List<ScopeTalkEntry> talks;
  final List<({String source, String target, int weight})> edges;
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
    required this._abstractTopicsById,
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
    // Words people say that the schedule has no tag for, pointed at the closest tag it does have.
    'machine learning': 'AI Inference + Agentic',
    'deep learning': 'AI Inference + Agentic',
    'ml': 'AI Inference + Agentic',
    'mlops': 'AI Inference + Agentic',
    'llm': 'AI Inference + Agentic',
    'llms': 'AI Inference + Agentic',
    'generative ai': 'AI Inference + Agentic',
    'genai': 'AI Inference + Agentic',
    'artificial intelligence': 'AI Inference + Agentic',
    'python': 'Application Development + Delivery',
    'rust': 'Application Development + Delivery',
    'golang': 'Application Development + Delivery',
    'java': 'Application Development + Delivery',
    'javascript': 'Application Development + Delivery',
    'typescript': 'Application Development + Delivery',
    'programming': 'Application Development + Delivery',
    'software development': 'Application Development + Delivery',
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
    'gpu': 'AI Inference + Agentic',
    'gpu scheduling': 'KAI Scheduler',
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
  final Map<String, List<String>> _abstractTopicsById;
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
    final abstractTopicsById = <String, List<String>>{};
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

      if (!talk.isLogistics && talk.abstractText.isNotEmpty) {
        final inAbstract = _matchText(talk.abstractText, matchPhrases);
        if (inAbstract.isNotEmpty) {
          abstractTopicsById[talk.id] = List<String>.unmodifiable(inAbstract);
        }
      }
    }

    return ScheduleCatalog._(
      talks: talkList,
      topicVocabulary: List<String>.unmodifiable(vocabulary),
      talksById: talksById,
      canonicalByLower: canonicalByLower,
      matchPhrases: matchPhrases,
      effectiveTalkTopics: effectiveTalkTopics,
      abstractTopicsById: abstractTopicsById,
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

  /// Strongest session co-occurrence edges among [topicLabels], capped at
  /// [maxEdges].
  List<({String source, String target, int weight})> coOccurringEdgesForTopics(
    Iterable<String> topicLabels, {
    int maxEdges = 15,
  }) {
    if (maxEdges <= 0) return const [];
    final allowed = canonicalizeTopics(topicLabels).toSet();
    if (allowed.length < 2) return const [];

    final edgeWeights = <(String, String), int>{};
    for (final talk in talks) {
      if (talk.isLogistics) continue;
      final present = [
        for (final t in (_effectiveTalkTopics[talk.id] ?? const <String>[]))
          if (allowed.contains(t)) t,
      ]..sort();
      for (var i = 0; i < present.length; i++) {
        for (var j = i + 1; j < present.length; j++) {
          final pair = (present[i], present[j]);
          edgeWeights[pair] = (edgeWeights[pair] ?? 0) + 1;
        }
      }
    }

    final sorted = edgeWeights.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) return byWeight;
        final bySource = a.key.$1.toLowerCase().compareTo(
          b.key.$1.toLowerCase(),
        );
        if (bySource != 0) return bySource;
        return a.key.$2.toLowerCase().compareTo(b.key.$2.toLowerCase());
      });

    return List.unmodifiable([
      for (final entry in sorted.take(maxEdges))
        (source: entry.key.$1, target: entry.key.$2, weight: entry.value),
    ]);
  }

  /// Canonical schedule topics (excluding [selectedTopics] themselves) that
  /// co-occur on at least one non-logistics session with [selectedTopics].
  Set<String> topicsLinkedTo(Iterable<String> selectedTopics) {
    final selected = canonicalizeTopics(selectedTopics).toSet();
    if (selected.isEmpty) return const <String>{};
    final linked = <String>{};
    for (final talk in talks) {
      if (talk.isLogistics) continue;
      final talkTopics = _effectiveTalkTopics[talk.id] ?? const <String>[];
      if (!talkTopics.any(selected.contains)) continue;
      for (final t in talkTopics) {
        if (!selected.contains(t)) {
          linked.add(t);
        }
      }
    }
    return Set.unmodifiable(linked);
  }

  /// Recommended schedule topics for bubble selection: selected topics first,
  /// then strongly co-occurring linked topics, then popular conference topics.
  List<String> recommendedBubbleTopics({
    required Iterable<String> selectedTopics,
  }) {
    if (topicVocabulary.isEmpty) return const [];
    final selected = canonicalizeTopics(selectedTopics);
    final selectedSet = selected.toSet();
    final cap = math.min(
      topicVocabulary.length,
      math.max(18, selected.length + 6),
    );

    if (selectedSet.isEmpty) {
      return popularTopics(limit: cap);
    }

    final coCounts = <String, int>{};
    for (final talk in talks) {
      if (talk.isLogistics) continue;
      final talkTopics = _effectiveTalkTopics[talk.id] ?? const <String>[];
      final overlapCount = talkTopics.where(selectedSet.contains).length;
      if (overlapCount == 0) continue;
      for (final t in talkTopics) {
        if (selectedSet.contains(t)) continue;
        coCounts[t] = (coCounts[t] ?? 0) + overlapCount;
      }
    }

    final sortedLinked = coCounts.keys.toList()
      ..sort((a, b) {
        final byCo = (coCounts[b] ?? 0).compareTo(coCounts[a] ?? 0);
        if (byCo != 0) return byCo;
        final bySessions = (_topicSessionCounts[b] ?? 0).compareTo(
          _topicSessionCounts[a] ?? 0,
        );
        if (bySessions != 0) return bySessions;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final ordered = <String>{
      ...selected,
      ...sortedLinked,
      ...popularTopics(limit: topicVocabulary.length),
    };
    return List.unmodifiable(ordered.take(cap));
  }

  /// Builds the home-screen [ScopeGraphData] for `WavelengthScope`:
  /// - Up to [maxTopics] (`9`) topics with `ring == 0` capped at `<= 4` direct
  ///   topics (`S3`).
  /// - Cold start (`directTopics` and `goingTopics` empty): `0` on `ring: 0`,
  ///   top `4` popular on `ring: 1`, and next `5` on `ring: 2`.
  /// - One best non-logistics [ScheduleTalk] per shown topic (preferring
  ///   [goingTalkIds], avoiding duplicate talk IDs across topics).
  /// - Up to `15` strongest edges among shown topics.
  /// - Words-only `why` strings (zero `%`, zero `"nearby"`, zero `"conversation"`).
  ScopeGraphData buildScopeGraph({
    required Set<String> selectedTopics,
    required List<List<String>> noteTopicLists,
    required Set<String> goingTalkIds,
    Map<String, int> liveTopicCounts = const {},
    Map<String, int> livePeopleByTopic = const {},
    List<({String source, String target, int weight})>? liveEdges,
    int maxTopics = 9,
  }) {
    if (maxTopics <= 0 || topicVocabulary.isEmpty) {
      return const ScopeGraphData(topics: [], talks: [], edges: []);
    }

    final selectedList = canonicalizeTopics(selectedTopics);
    final selectedSet = selectedList.toSet();
    final selectedOrder = <String, int>{
      for (var i = 0; i < selectedList.length; i++) selectedList[i]: i,
    };
    final noteTopicCounts = <String, int>{};
    final noteTopicOrder = <String, int>{};
    var orderCursor = 0;
    for (final list in noteTopicLists.reversed) {
      for (final topic in canonicalizeTopics(list)) {
        noteTopicCounts[topic] = (noteTopicCounts[topic] ?? 0) + 1;
        noteTopicOrder.putIfAbsent(topic, () => orderCursor++);
      }
    }

    final goingSet = <String>{
      for (final id in goingTalkIds)
        if (_talksById[id] != null && !_talksById[id]!.isLogistics) id,
    };
    final goingTopicCounts = <String, int>{};
    for (final id in goingSet) {
      for (final t in (_effectiveTalkTopics[id] ?? const <String>[])) {
        goingTopicCounts[t] = (goingTopicCounts[t] ?? 0) + 1;
      }
    }
    final goingTopics = goingTopicCounts.keys.toSet();

    final normalizedLiveCounts = <String, int>{};
    for (final entry in liveTopicCounts.entries) {
      final canonical = _canonicalByLower[_normalizeWhitespace(entry.key)];
      if (canonical != null && entry.value >= 0) {
        normalizedLiveCounts[canonical] = entry.value;
      }
    }

    final normalizedLivePeople = <String, int>{};
    for (final entry in livePeopleByTopic.entries) {
      final canonical = _canonicalByLower[_normalizeWhitespace(entry.key)];
      if (canonical != null && entry.value > 0) {
        normalizedLivePeople[canonical] = entry.value;
      }
    }

    int effectiveCount(String topic) =>
        normalizedLiveCounts[topic] ?? (_topicSessionCounts[topic] ?? 0);

    List<String> rankedPopularAll() {
      final list = [...topicVocabulary]..sort((a, b) {
        final byLiveOrLocal = effectiveCount(b).compareTo(effectiveCount(a));
        if (byLiveOrLocal != 0) return byLiveOrLocal;
        final byLocal = (_topicSessionCounts[b] ?? 0).compareTo(
          _topicSessionCounts[a] ?? 0,
        );
        if (byLocal != 0) return byLocal;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
      return list;
    }

    final targetCount = math.min(maxTopics, topicVocabulary.length);
    final directTopics = <String>{...noteTopicCounts.keys, ...selectedSet};

    final chosenTopicSpecs = <({String topic, int ring, String why})>[];

    if (directTopics.isEmpty && goingTopics.isEmpty) {
      // Cold start: 0 on ring 0, top 4 popular on ring 1, next 5 on ring 2.
      final popular = rankedPopularAll();
      for (var i = 0; i < targetCount && i < popular.length; i++) {
        final topic = popular[i];
        final sessions = math.max(1, effectiveCount(topic));
        final sessionWord = sessions == 1 ? 'session' : 'sessions';
        chosenTopicSpecs.add((
          topic: topic,
          ring: i < 4 ? 1 : 2,
          why: 'Active across $sessions KubeCon $sessionWord',
        ));
      }
    } else {
      final seedTopics = <String>{...directTopics, ...goingTopics};
      final coOccurringBridge = <String, Set<String>>{};
      final coOccurringCounts = <String, int>{};

      for (final talk in talks) {
        if (talk.isLogistics) continue;
        final talkTopics = _effectiveTalkTopics[talk.id] ?? const <String>[];
        final sharedSeeds = [
          for (final t in talkTopics)
            if (seedTopics.contains(t)) t,
        ];
        if (sharedSeeds.isEmpty) continue;
        for (final t in talkTopics) {
          if (seedTopics.contains(t)) continue;
          coOccurringCounts[t] = (coOccurringCounts[t] ?? 0) + 1;
          (coOccurringBridge[t] ??= <String>{}).addAll(sharedSeeds);
        }
      }

      if (liveEdges != null) {
        for (final e in liveEdges) {
          final a = _canonicalByLower[_normalizeWhitespace(e.source)];
          final b = _canonicalByLower[_normalizeWhitespace(e.target)];
          if (a == null || b == null || a == b || e.weight <= 0) continue;
          if (seedTopics.contains(a) && !seedTopics.contains(b)) {
            coOccurringCounts[b] = (coOccurringCounts[b] ?? 0) + e.weight;
            (coOccurringBridge[b] ??= <String>{}).add(a);
          } else if (seedTopics.contains(b) && !seedTopics.contains(a)) {
            coOccurringCounts[a] = (coOccurringCounts[a] ?? 0) + e.weight;
            (coOccurringBridge[a] ??= <String>{}).add(b);
          }
        }
      }

      final sortedDirect = directTopics.toList()
        ..sort((a, b) {
          int directScore(String t) {
            final notes = noteTopicCounts[t] ?? 0;
            final selected = selectedSet.contains(t);
            final going = goingTopicCounts[t] ?? 0;
            final people = normalizedLivePeople[t] ?? 0;
            return (notes > 0 ? 10 + (notes - 1) * 3 : 0) +
                (selected ? 8 : 0) +
                (going > 0 ? 3 : 0) +
                (people > 0 ? 2 : 0);
          }

          final byScore = directScore(b).compareTo(directScore(a));
          if (byScore != 0) return byScore;
          final rankA = noteTopicOrder[a] ?? 9999;
          final rankB = noteTopicOrder[b] ?? 9999;
          if (rankA != rankB) return rankA.compareTo(rankB);
          final selA = selectedOrder[a] ?? 9999;
          final selB = selectedOrder[b] ?? 9999;
          if (selA != selB) return selA.compareTo(selB);
          final byCount = effectiveCount(b).compareTo(effectiveCount(a));
          if (byCount != 0) return byCount;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });

      final sortedGoingOnly = [
        for (final t in goingTopics)
          if (!directTopics.contains(t)) t,
      ]..sort((a, b) {
        final byGoing = (goingTopicCounts[b] ?? 0).compareTo(
          goingTopicCounts[a] ?? 0,
        );
        if (byGoing != 0) return byGoing;
        final byCount = effectiveCount(b).compareTo(effectiveCount(a));
        if (byCount != 0) return byCount;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

      final sortedBridge = coOccurringCounts.keys.toList()
        ..sort((a, b) {
          final byCo = (coOccurringCounts[b] ?? 0).compareTo(
            coOccurringCounts[a] ?? 0,
          );
          if (byCo != 0) return byCo;
          final byPeople = (normalizedLivePeople[b] ?? 0).compareTo(
            normalizedLivePeople[a] ?? 0,
          );
          if (byPeople != 0) return byPeople;
          final byCount = effectiveCount(b).compareTo(effectiveCount(a));
          if (byCount != 0) return byCount;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });

      String topicWhy(String topic) {
        final noteHits = noteTopicCounts[topic] ?? 0;
        final isSelected = selectedSet.contains(topic);
        final isFromGoing = goingTopics.contains(topic);
        if (noteHits > 0 && isSelected) {
          return 'Matches your notes and your interest in $topic';
        }
        if (noteHits > 0) {
          return 'From your notes on $topic';
        }
        if (isSelected) {
          return 'Matches your interest in $topic';
        }
        if (isFromGoing) {
          return 'Featured in a session on your schedule';
        }
        final bridges = (coOccurringBridge[topic] ?? const <String>{})
            .take(2)
            .toList(growable: false);
        if (bridges.isNotEmpty) {
          return 'Connected to sessions on ${_joinHumanList(bridges)}';
        }
        final sessions = math.max(1, effectiveCount(topic));
        final sessionWord = sessions == 1 ? 'session' : 'sessions';
        return 'Active across $sessions KubeCon $sessionWord';
      }

      final seen = <String>{};
      var ring0Count = 0;
      var ring1Count = 0;

      // Direct topics: cap ring 0 at <= 4; overflow direct topics go to ring 1.
      for (final topic in sortedDirect) {
        if (chosenTopicSpecs.length >= targetCount) break;
        if (!seen.add(topic)) continue;
        final ring = ring0Count < 4 ? 0 : 1;
        if (ring == 0) {
          ring0Count++;
        } else {
          ring1Count++;
        }
        chosenTopicSpecs.add((topic: topic, ring: ring, why: topicWhy(topic)));
      }

      // Topics from "I'm going" talks sit on ring 1 (up to 4) then ring 2.
      for (final topic in sortedGoingOnly) {
        if (chosenTopicSpecs.length >= targetCount) break;
        if (!seen.add(topic)) continue;
        final ring = ring1Count < 4 ? 1 : 2;
        if (ring == 1) ring1Count++;
        chosenTopicSpecs.add((topic: topic, ring: ring, why: topicWhy(topic)));
      }

      // Co-occurring bridge topics fill ring 1 (up to 3 if needed) then ring 2.
      for (final topic in sortedBridge) {
        if (chosenTopicSpecs.length >= targetCount) break;
        if (!seen.add(topic)) continue;
        final ring = ring1Count < 3 ? 1 : 2;
        if (ring == 1) ring1Count++;
        chosenTopicSpecs.add((topic: topic, ring: ring, why: topicWhy(topic)));
      }

      // Popular backfill on ring 2 if fewer than targetCount topics matched.
      if (chosenTopicSpecs.length < targetCount) {
        for (final topic in rankedPopularAll()) {
          if (chosenTopicSpecs.length >= targetCount) break;
          if (!seen.add(topic)) continue;
          chosenTopicSpecs.add((
            topic: topic,
            ring: 2,
            why: topicWhy(topic),
          ));
        }
      }
    }

    final shownSet = <String>{for (final s in chosenTopicSpecs) s.topic};

    // Build up to 15 strongest edges among shown topics.
    final mergedEdgeWeights = <(String, String), int>{};
    for (final localEdge in coOccurringEdgesForTopics(
      shownSet,
      maxEdges: shownSet.length * shownSet.length,
    )) {
      mergedEdgeWeights[(localEdge.source, localEdge.target)] =
          localEdge.weight;
    }
    if (liveEdges != null) {
      for (final e in liveEdges) {
        final rawA = _canonicalByLower[_normalizeWhitespace(e.source)];
        final rawB = _canonicalByLower[_normalizeWhitespace(e.target)];
        if (rawA == null ||
            rawB == null ||
            rawA == rawB ||
            e.weight <= 0 ||
            !shownSet.contains(rawA) ||
            !shownSet.contains(rawB)) {
          continue;
        }
        final pair = rawA.compareTo(rawB) < 0 ? (rawA, rawB) : (rawB, rawA);
        final prev = mergedEdgeWeights[pair] ?? 0;
        if (e.weight > prev) {
          mergedEdgeWeights[pair] = e.weight;
        }
      }
    }

    final sortedEdges = mergedEdgeWeights.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) return byWeight;
        final bySource = a.key.$1.toLowerCase().compareTo(
          b.key.$1.toLowerCase(),
        );
        if (bySource != 0) return bySource;
        return a.key.$2.toLowerCase().compareTo(b.key.$2.toLowerCase());
      });

    final scopeEdges = List<({String source, String target, int weight})>.unmodifiable([
      for (final entry in sortedEdges.take(15))
        (source: entry.key.$1, target: entry.key.$2, weight: entry.value),
    ]);

    // Select at most one best non-logistics ScheduleTalk per shown topic,
    // preferring goingTalkIds and avoiding duplicate talk IDs across topics.
    final usedTalkIds = <String>{};
    final scopeTopics = <ScopeTopicEntry>[];
    final scopeTalks = <ScopeTalkEntry>[];

    for (final spec in chosenTopicSpecs) {
      final topic = spec.topic;
      final candidates = <ScheduleTalk>[];
      for (final talk in talks) {
        if (talk.isLogistics || usedTalkIds.contains(talk.id)) continue;
        final talkTopics = _effectiveTalkTopics[talk.id] ?? const <String>[];
        if (talkTopics.contains(topic)) {
          candidates.add(talk);
        }
      }
      if (candidates.isEmpty) {
        for (final talk in talks) {
          if (talk.isLogistics || usedTalkIds.contains(talk.id)) continue;
          final absTopics = _abstractTopicsById[talk.id] ?? const <String>[];
          if (absTopics.contains(topic)) {
            candidates.add(talk);
          }
        }
      }

      ScheduleTalk? bestTalk;
      if (candidates.isNotEmpty) {
        int talkScore(ScheduleTalk t) {
          final isGoing = goingSet.contains(t.id);
          final tTopics = _effectiveTalkTopics[t.id] ?? const <String>[];
          var noteOverlap = 0;
          var selectedOverlap = 0;
          var shownOverlap = 0;
          for (final tag in tTopics) {
            if ((noteTopicCounts[tag] ?? 0) > 0) noteOverlap++;
            if (selectedSet.contains(tag)) selectedOverlap++;
            if (shownSet.contains(tag)) shownOverlap++;
          }
          return (isGoing ? 100 : 0) +
              noteOverlap * 5 +
              selectedOverlap * 4 +
              shownOverlap;
        }

        candidates.sort((a, b) {
          final byScore = talkScore(b).compareTo(talkScore(a));
          if (byScore != 0) return byScore;
          final byStart = a.start.compareTo(b.start);
          if (byStart != 0) return byStart;
          return a.id.compareTo(b.id);
        });
        bestTalk = candidates.first;
        usedTalkIds.add(bestTalk.id);
      }

      final relatedAll = _relatedTopicsForTopic(topic);
      final linkedForTopic = <String>{
        for (final r in relatedAll)
          if (shownSet.contains(r)) r,
        ...relatedAll.take(4),
      }.take(5).toList(growable: false);

      scopeTopics.add(
        ScopeTopicEntry(
          id: topic,
          label: topic,
          count: math.max(1, effectiveCount(topic)),
          ring: spec.ring,
          people: normalizedLivePeople[topic] ?? 0,
          why: spec.why,
          linkedTopics: List.unmodifiable(linkedForTopic),
          featuredTalk: bestTalk,
        ),
      );

      if (bestTalk != null) {
        final isGoing = goingSet.contains(bestTalk.id);
        final talkTopics =
            _effectiveTalkTopics[bestTalk.id] ?? const <String>[];
        final matchedNote = [
          for (final t in talkTopics)
            if ((noteTopicCounts[t] ?? 0) > 0) t,
        ];
        final matchedSel = [
          for (final t in talkTopics)
            if (selectedSet.contains(t)) t,
        ];
        final matchedDirect = <String>{...matchedNote, ...matchedSel};

        final String talkWhy;
        if (isGoing && matchedDirect.isNotEmpty) {
          talkWhy =
              'On your schedule and matches your interest in ${_joinHumanList(matchedDirect.take(3).toList())}';
        } else if (isGoing) {
          talkWhy = 'Saved to your schedule';
        } else if (matchedNote.isNotEmpty &&
            matchedSel.any((t) => !matchedNote.contains(t))) {
          talkWhy =
              'Matches your notes and interests in ${_joinHumanList(matchedDirect.take(3).toList())}';
        } else if (matchedNote.isNotEmpty) {
          talkWhy =
              'Matches your notes on ${_joinHumanList(matchedNote.take(3).toList())}';
        } else if (matchedSel.isNotEmpty) {
          talkWhy =
              'Matches your interest in ${_joinHumanList(matchedSel.take(3).toList())}';
        } else {
          final exploreList = talkTopics.isNotEmpty ? talkTopics : [topic];
          talkWhy =
              'KubeCon session exploring ${_joinHumanList(exploreList.take(2).toList())}';
        }

        final talkLinked = <String>{topic, ...talkTopics};
        scopeTalks.add(
          ScopeTalkEntry(
            id: 'talk:${bestTalk.id}',
            topicId: topic,
            talk: bestTalk,
            going: isGoing,
            why: talkWhy,
            linkedTopics: List.unmodifiable(talkLinked.take(5)),
          ),
        );
      }
    }

    return ScopeGraphData(
      topics: List.unmodifiable(scopeTopics),
      talks: List.unmodifiable(scopeTalks),
      edges: scopeEdges,
    );
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
            peopleCount: 0,
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

      // Precomputed abstract topics avoid re-scanning 600 abstracts per call.
      var abstractMatches = const <String>[];
      if (matchedDirect.isEmpty && directTopics.isNotEmpty) {
        final inAbstract = _abstractTopicsById[talk.id] ?? const <String>[];
        if (inAbstract.isNotEmpty) {
          abstractMatches = [
            for (final t in inAbstract)
              if (directTopics.contains(t)) t,
          ];
        }
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
            peopleCount: 0,
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
          peopleCount: 0,
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
          peopleCount: 0,
          talk: talk,
        ),
      );
    }
    return List.unmodifiable(spaces);
  }

  List<String> _relatedTopicsForTopic(String topic) {
    final counts = <String, int>{};
    for (final talk in talks) {
      if (talk.isLogistics) continue;
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
