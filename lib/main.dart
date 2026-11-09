import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'conversation_api.dart';
import 'phone_profile_store.dart';
import 'recording_controller.dart';
import 'schedule_data.dart' as sched;
import 'transcript_sync.dart';
import 'ui/interests_screen.dart';
import 'ui/note_capture_and_undo.dart';
import 'ui/onboarding_screen.dart';
import 'ui/room_chat_screen.dart';
import 'ui/space_discovery_sheet.dart';
import 'ui/spaces_screen.dart';
import 'ui/wavelength_scope.dart';
import 'ui/wavelength_theme.dart';

export 'search_screen.dart';

void main() => runApp(const ConversationApp());

class ConversationApp extends StatelessWidget {
  const ConversationApp({
    super.key,
    this.sync,
    this.catalog,
    this.profileStore,
    this.backend,
    this.undoWindow = const Duration(seconds: 6),
    this.disableAnimations = false,
    this.showOnboardingOnFirstLaunch = true,
  });

  final TranscriptSync? sync;
  final sched.ScheduleCatalog? catalog;
  final PhoneProfileStore? profileStore;
  final WavelengthBackend? backend;
  final Duration undoWindow;
  final bool disableAnimations;
  final bool showOnboardingOnFirstLaunch;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ConFellow',
    debugShowCheckedModeBanner: false,
    theme: WavelengthTheme.dark(),
    builder: disableAnimations
        ? (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          )
        : null,
    home: HomeScreen(
      sync: sync,
      initialCatalog: catalog,
      profileStore: profileStore,
      backend: backend,
      undoWindow: undoWindow,
      showOnboardingOnFirstLaunch: showOnboardingOnFirstLaunch,
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.sync,
    this.initialCatalog,
    this.profileStore,
    this.backend,
    this.undoWindow = const Duration(seconds: 6),
    this.showOnboardingOnFirstLaunch = true,
  });

  final TranscriptSync? sync;
  final sched.ScheduleCatalog? initialCatalog;
  final PhoneProfileStore? profileStore;
  final WavelengthBackend? backend;
  final Duration undoWindow;
  final bool showOnboardingOnFirstLaunch;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final TranscriptSync _sync;
  late final bool _ownsSync;
  late final RecordingController _recording;
  late final PhoneProfileStore _profileStore;
  late final bool _ownsProfileStore;
  late final PendingNoteSendCoordinator _noteCoordinator;
  late final PageController _pageController;

  WavelengthBackend? _backend;
  bool _ownsBackend = false;
  sched.ScheduleCatalog? _catalog;
  PhoneProfile _profile = PhoneProfile(handle: 'cf_loading000000000000');
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  // Cached Scope graph & widget models — ONLY recomputed when _catalog,
  // _profile, _stagedPreviewDraft, or _liveRefresh changes (Fix B1: zero
  // re-ranking on microphone PCM chunks!).
  sched.ScopeGraphData _scopeGraph = const sched.ScopeGraphData(
    topics: <sched.ScopeTopicEntry>[],
    talks: <sched.ScopeTalkEntry>[],
    edges: <({String source, String target, int weight})>[],
  );
  List<ScopeTopic> _scopeTopics = const <ScopeTopic>[];
  List<ScopeTalk> _scopeTalks = const <ScopeTalk>[];
  List<ScopeEdge> _scopeEdges = const <ScopeEdge>[];
  List<ScopeNote> _scopeNotes = const <ScopeNote>[];
  List<SharedNoteMatch> _sharedMatches = const <SharedNoteMatch>[];
  WavelengthRefreshResult? _liveRefresh;

  CapturedNoteDraft? _stagedPreviewDraft;
  String? _selectedNodeId;
  int _tabIndex = 0;
  bool _isRefreshing = false;
  bool _profileLoaded = false;

  String? _flashMessage;
  String? _persistentNoteSummary;
  String? _lastFullNoteText;
  Timer? _flashTimer;

  int _pressImpulse = 0;
  int _tuneImpulse = 0;
  int _findImpulse = 0;
  int _noteSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ownsSync = widget.sync == null;
    _sync = widget.sync ?? TranscriptSync();
    _ownsProfileStore = widget.profileStore == null;
    _profileStore = widget.profileStore ?? PhoneProfileStore();
    _catalog = widget.initialCatalog;
    _pageController = PageController();

    // Do NOT pass sync: to RecordingController so nothing streams during
    // recording and Undo genuinely prevents any upload.
    _recording = RecordingController(onNoteCompleted: _handleSpokenNote);
    _noteCoordinator = PendingNoteSendCoordinator(
      undoWindow: widget.undoWindow,
      onPreviewApplied: _handleDraftStaged,
      onUndoReverted: _handleDraftReverted,
      onCommitSend: _commitNoteToSeam,
    );

    if (_catalog != null) {
      _rebuildScopeCache();
    }

    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    unawaited(_sync.initialize());

    final loadedProfile = await _profileStore.load();
    sched.ScheduleCatalog? loadedCatalog = _catalog;
    if (loadedCatalog == null) {
      try {
        loadedCatalog = await sched.ScheduleCatalog.loadFromAssets();
      } catch (_) {
        loadedCatalog = sched.ScheduleCatalog.fromTalks(const []);
      }
    }

    if (!mounted) return;
    final resolvedBackend =
        widget.backend ??
        AttendeeWavelengthBackend(
          profileStore: _profileStore,
          sync: _sync,
          catalog: loadedCatalog,
        );

    setState(() {
      _profile = loadedProfile;
      _profileLoaded = true;
      _catalog = loadedCatalog;
      _backend = resolvedBackend;
      _ownsBackend = widget.backend == null;
      _noteCoordinator.reviewBeforeSending = loadedProfile.reviewBeforeSending;
      if (loadedProfile.savedNotes.isNotEmpty) {
        final latest = loadedProfile.savedNotes.first;
        _persistentNoteSummary = latest.topics.isNotEmpty
            ? 'Saved · Tuned: ${latest.topics.take(3).join(' · ')}'
            : 'Note saved to your profile.';
      }
      _rebuildScopeCache();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Fix S6: hold any pending note for manual Send/Discard so a backgrounded
      // note never auto-sends unseen.
      _noteCoordinator.holdForManualReview();
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        unawaited(_recording.stop());
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_sync.hasPending) {
        unawaited(_sync.retry());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flashTimer?.cancel();
    _pageController.dispose();
    _noteCoordinator.dispose();
    _recording.dispose();
    if (_ownsBackend) _backend?.close();
    if (_ownsSync) _sync.dispose();
    if (_ownsProfileStore) _profileStore.dispose();
    super.dispose();
  }

  void _rebuildScopeCache() {
    final cat = _catalog;
    if (cat == null) {
      _scopeGraph = const sched.ScopeGraphData(
        topics: <sched.ScopeTopicEntry>[],
        talks: <sched.ScopeTalkEntry>[],
        edges: <({String source, String target, int weight})>[],
      );
      _scopeTopics = const <ScopeTopic>[];
      _scopeTalks = const <ScopeTalk>[];
      _scopeEdges = const <ScopeEdge>[];
      _scopeNotes = const <ScopeNote>[];
      return;
    }

    final selectedTopics = <String>{
      ..._profile.selectedTopics,
      if (_stagedPreviewDraft != null) ..._stagedPreviewDraft!.matchedTopics,
    };

    final noteTopicLists = <List<String>>[
      for (final saved in _profile.savedNotes)
        if (saved.topics.isNotEmpty) saved.topics,
      if (_stagedPreviewDraft != null &&
          _stagedPreviewDraft!.matchedTopics.isNotEmpty)
        _stagedPreviewDraft!.matchedTopics,
    ];

    final graph = cat.buildScopeGraph(
      selectedTopics: selectedTopics,
      noteTopicLists: noteTopicLists,
      goingTalkIds: _profile.goingTalkIds.toSet(),
      liveTopicCounts: _liveRefresh?.liveTopicCounts ?? const <String, int>{},
      livePeopleByTopic:
          _liveRefresh?.livePeopleByTopic ?? const <String, int>{},
      liveEdges: _liveRefresh?.liveEdges,
      maxTopics: 9,
    );

    _scopeGraph = graph;
    _scopeTopics = List<ScopeTopic>.unmodifiable(<ScopeTopic>[
      for (final t in graph.topics)
        ScopeTopic(
          id: t.id,
          label: t.label,
          count: t.count,
          ring: t.ring,
          people: t.people,
        ),
    ]);
    _scopeTalks = List<ScopeTalk>.unmodifiable(<ScopeTalk>[
      for (final k in graph.talks)
        ScopeTalk(id: k.id, topicId: k.topicId, going: k.going),
    ]);
    _scopeEdges = List<ScopeEdge>.unmodifiable(<ScopeEdge>[
      for (final e in graph.edges)
        ScopeEdge(e.source, e.target, e.weight.toDouble()),
    ]);

    final topicIdByLower = <String, String>{
      for (final t in graph.topics) ...<String, String>{
        t.id.toLowerCase(): t.id,
        t.label.toLowerCase(): t.id,
      },
    };

    final builtNotes = <ScopeNote>[
      for (final saved in _profile.savedNotes)
        ScopeNote(
          id: saved.conversationId,
          topicIds: <String>[
            for (final raw in saved.topics)
              topicIdByLower[raw.toLowerCase()] ?? raw,
          ],
        ),
      if (_stagedPreviewDraft != null)
        ScopeNote(
          id: _stagedPreviewDraft!.noteId,
          topicIds: <String>[
            for (final raw in _stagedPreviewDraft!.matchedTopics)
              topicIdByLower[raw.toLowerCase()] ?? raw,
          ],
        ),
    ];
    _scopeNotes = List<ScopeNote>.unmodifiable(builtNotes);
  }

  void _showFlash(String message, {Duration duration = const Duration(seconds: 4)}) {
    _flashTimer?.cancel();
    if (!mounted) return;
    setState(() => _flashMessage = message);
    _flashTimer = Timer(duration, () {
      if (mounted) {
        setState(() => _flashMessage = null);
      }
    });
  }

  String _nextNoteId() {
    final ms = DateTime.now().toUtc().millisecondsSinceEpoch;
    final rand = math.Random()
        .nextInt(0xFFFFF)
        .toRadixString(16)
        .padLeft(5, '0');
    _noteSeq++;
    return 'note_${ms}_${_noteSeq}_$rand';
  }

  /// Fix B4: strictly match schedule topics via ScheduleCatalog; never invent!
  List<String> _matchScheduleTopics(String text) =>
      _catalog?.extractMatchedTopics(text) ?? const <String>[];

  void _handleSpokenNote(String transcript) {
    _stageNote(content: transcript, kind: NoteSourceKind.spoken);
  }

  void _stageNote({
    required String content,
    required NoteSourceKind kind,
  }) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return;
    final matched = _matchScheduleTopics(trimmed);
    final draft = CapturedNoteDraft(
      noteId: _nextNoteId(),
      text: trimmed,
      sourceKind: kind,
      matchedTopics: matched,
      createdAt: DateTime.now().toUtc(),
    );
    if (_tabIndex != 0) {
      _switchToTab(0);
    }
    _noteCoordinator.stageFinishedNote(draft);
    if (_lifecycleState != AppLifecycleState.resumed) {
      _noteCoordinator.holdForManualReview();
    }
  }

  void _handleDraftStaged(CapturedNoteDraft draft) {
    setState(() {
      _stagedPreviewDraft = draft;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
  }

  void _handleDraftReverted(CapturedNoteDraft _) {
    HapticFeedback.selectionClick();
    final wasManual = _noteCoordinator.requiresManualAction;
    setState(() {
      _stagedPreviewDraft = null;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
    _showFlash(
      wasManual ? 'Discarded. Nothing was sent.' : 'Undone. Nothing was sent.',
      duration: const Duration(seconds: 3),
    );
  }

  /// Fix N4: submit note once to backend seam, record locally only for fake
  /// backend (live AttendeeWavelengthBackend already persists to profileStore),
  /// and flash `receipt.statusLabel` for 4 seconds.
  Future<void> _commitNoteToSeam(CapturedNoteDraft draft) async {
    final backend = _backend;
    final source = draft.sourceKind == NoteSourceKind.spoken
        ? 'spoken'
        : 'notes';

    final submission = NoteSubmission(
      conference: _profile.conference,
      ownerId: _profile.handle,
      conversationId: draft.noteId,
      transcript: draft.text,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
      topics: draft.matchedTopics,
      shared: draft.shareNoteText,
      source: source,
    );

    NoteReceipt? receipt;
    if (backend != null) {
      try {
        receipt = await backend.submitNote(submission);
      } catch (_) {
        receipt = null;
      }
    }

    final PhoneProfile nextProfile;
    if (backend == null ||
        backend is LabeledFakeWavelengthBackend ||
        receipt == null) {
      nextProfile = await _profileStore.recordNote(
        LocalNoteSummary(
          conversationId: draft.noteId,
          topics: draft.matchedTopics,
          why: draft.cardHeadline,
          shared: draft.shareNoteText,
          sharedText: draft.shareNoteText ? draft.text : null,
          source: source,
          createdAt: draft.createdAt,
        ),
      );
    } else {
      nextProfile = await _profileStore.load();
    }

    MatchesLookupResult? matchLookup;
    if (backend != null) {
      try {
        matchLookup = await backend.findSharedNoteMatches(
          queryText: draft.text,
        );
      } catch (_) {
        matchLookup = null;
      }
    }

    if (!mounted) return;
    final summary = draft.matchedTopics.isNotEmpty
        ? 'Saved · Tuned: ${draft.matchedTopics.take(3).join(' · ')}'
        : 'Note saved to your profile.';
    setState(() {
      _profile = nextProfile;
      _lastFullNoteText = draft.text;
      _persistentNoteSummary = summary;
      if (matchLookup != null) {
        _sharedMatches = matchLookup.matches;
      }
      if (_stagedPreviewDraft?.noteId == draft.noteId) {
        _stagedPreviewDraft = null;
      }
      _rebuildScopeCache();
    });

    final sharedCount = _sharedMatches.length;
    if (sharedCount > 0) {
      _showFlash(
        '$sharedCount shared ${sharedCount == 1 ? 'note' : 'notes'} on your wavelength.',
      );
    } else {
      final label = receipt?.statusLabel ?? 'Saved on this phone. Not sent.';
      _showFlash(label);
    }
  }

  Future<void> _toggleTopicChip(String topic) async {
    HapticFeedback.selectionClick();
    final updated = await _profileStore.toggleTopic(topic);
    final backend = _backend;
    if (backend != null) {
      unawaited(backend.syncProfile(updated));
    }
    if (!mounted) return;
    setState(() {
      _profile = updated;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
  }

  Future<void> _toggleGoingOnTalk(String talkId) async {
    final updated = await _profileStore.toggleGoingTalk(talkId);
    final backend = _backend;
    if (backend != null) {
      unawaited(backend.syncProfile(updated));
    }
    if (!mounted) return;
    setState(() {
      _profile = updated;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
  }

  Future<void> _setReviewBeforeSending(bool enabled) async {
    _noteCoordinator.reviewBeforeSending = enabled;
    final updated = await _profileStore.setReviewBeforeSending(enabled);
    if (!mounted) return;
    setState(() {
      _profile = updated;
    });
  }

  Future<void> _handleFindMyWavelength() async {
    if (_recording.phase == RecordingPhase.recording || _isRefreshing) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _findImpulse++;
      _isRefreshing = true;
    });

    final backend = _backend;
    WavelengthRefreshResult? result;
    MatchesLookupResult? matchLookup;
    if (backend != null) {
      try {
        result = await backend.refreshRecommendations();
      } catch (_) {
        result = null;
      }
      final fallbackNoteQuery =
          _lastFullNoteText ??
          (_profile.savedNotes.isNotEmpty
              ? (_profile.savedNotes.first.sharedText ??
                    _profile.savedNotes.first.topics.join(' '))
              : '');
      final matchQuery = _profile.interests.trim().isNotEmpty
          ? _profile.interests.trim()
          : fallbackNoteQuery.trim();
      if (matchQuery.isNotEmpty) {
        try {
          matchLookup = await backend.findSharedNoteMatches(
            queryText: matchQuery,
          );
        } catch (_) {
          matchLookup = null;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _isRefreshing = false;
      if (result != null) {
        _liveRefresh = result;
      }
      if (matchLookup != null && !matchLookup.needsInput) {
        _sharedMatches = matchLookup.matches;
      }
      _rebuildScopeCache();
      _tuneImpulse++;
    });

    final isFake = backend?.isFake ?? true;
    if (result != null && !result.liveSuccess && !isFake) {
      final fallback = result.fallbackMessage;
      _showFlash(
        fallback != null && fallback.isNotEmpty
            ? fallback
            : 'Could not reach ConFellow. Showing the schedule on this phone.',
      );
    } else if (_sharedMatches.isNotEmpty) {
      final n = _sharedMatches.length;
      _showFlash(
        '$n shared ${n == 1 ? 'note' : 'notes'} on your wavelength · ${_scopeTopics.length} topics mapped.',
      );
    } else {
      _showFlash(
        'Updated: ${_scopeTopics.length} topics and ${_scopeTalks.length} talks. Swipe to see your map.',
      );
    }
  }

  void _switchToTab(int index) {
    if (index == _tabIndex && _pageController.hasClients) return;
    HapticFeedback.selectionClick();
    setState(() => _tabIndex = index);
    if (!_pageController.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _pageController.jumpToPage(index);
    } else {
      unawaited(
        _pageController.animateToPage(
          index,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  Future<void> _openInterestsScreen() async {
    final cat = _catalog;
    if (cat == null) return;
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => InterestsScreen(
          catalog: cat,
          initialSelectedTopics: _profile.activeWavelengthTopics,
          onRetune: _applyRetunedInterests,
        ),
      ),
    );
  }

  Future<void> _applyRetunedInterests(
    Set<String> pickedTopics,
    String typedInterests,
  ) async {
    var updated = await _profileStore.setSelectedTopics(pickedTopics);
    if (typedInterests.isNotEmpty) {
      updated = await _profileStore.setInterests(typedInterests);
    }
    if (!mounted) return;
    setState(() {
      _profile = updated;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
    _switchToTab(1);

    final backend = _backend;
    if (backend != null) {
      unawaited(_refreshAfterInterests(backend, updated, typedInterests, pickedTopics.length));
    } else {
      _showFlash(
        typedInterests.isNotEmpty
            ? 'Retuned to "$typedInterests" and ${pickedTopics.length} topics.'
            : 'Retuned to ${pickedTopics.length} topics.',
      );
    }
  }

  Future<void> _refreshAfterInterests(
    WavelengthBackend backend,
    PhoneProfile updatedProfile,
    String typedInterests,
    int pickedCount,
  ) async {
    try {
      await backend.syncProfile(
        updatedProfile,
        interestsOverride: typedInterests.isEmpty ? null : typedInterests,
      );
      final refreshed = await backend.refreshRecommendations(
        typedInterests: typedInterests.isEmpty ? null : typedInterests,
      );
      if (!mounted) return;
      setState(() {
        _liveRefresh = refreshed;
        _rebuildScopeCache();
        _tuneImpulse++;
      });
    } catch (_) {
      // Keep local schedule map active if refresh fails.
    }
    if (!mounted) return;
    _showFlash(
      typedInterests.isNotEmpty
          ? 'Retuned to "$typedInterests" and $pickedCount topics.'
          : 'Retuned to $pickedCount topics.',
    );
  }

  Future<void> _completeFirstLaunchOnboarding({
    required String displayName,
    required Set<String> selectedTopics,
    required String typedInterests,
  }) async {
    final updated = await _profileStore.completeOnboarding(
      displayName: displayName,
      selectedTopics: selectedTopics,
      interests: typedInterests,
    );
    if (!mounted) return;
    setState(() {
      _profile = updated;
      _rebuildScopeCache();
      _tuneImpulse++;
    });
    final backend = _backend;
    if (backend != null) {
      unawaited(backend.syncProfile(updated));
    }
  }

  Future<void> _openRoomChat({
    required String room,
    required String title,
  }) async {
    HapticFeedback.selectionClick();
    if (_sync.token == null && _backend != null) {
      try {
        await _backend!.syncProfile(_profile);
      } catch (_) {}
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoomChatScreen(
          baseUrl: _sync.api.baseUrl,
          token: _sync.token ?? '',
          conference: _profile.conference,
          room: room,
          title: title,
        ),
      ),
    );
  }

  Future<void> _openSpacesScreen() async {
    final cat = _catalog;
    if (cat == null) return;
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SpacesScreen(
          catalog: cat,
          profileStore: _profileStore,
          initialProfile: _profile,
          scopeGraph: _scopeGraph,
          livePeopleByTopic:
              _liveRefresh?.livePeopleByTopic ?? const <String, int>{},
          liveTopicCounts:
              _liveRefresh?.liveTopicCounts ?? const <String, int>{},
          sharedMatches: _sharedMatches,
          onToggleGoing: _toggleGoingOnTalk,
          onSelectTopic: _toggleTopicChip,
          onOpenRoomChat: ({required room, required title}) =>
              unawaited(_openRoomChat(room: room, title: title)),
        ),
      ),
    );
  }

  List<SharedSpaceNote> _sharedNotesForTopic(String topic) {
    final lower = topic.toLowerCase();
    return <SharedSpaceNote>[
      for (final note in _profile.savedNotes)
        if (note.shared &&
            note.sharedText != null &&
            note.sharedText!.trim().isNotEmpty &&
            note.topics.any((t) => t.toLowerCase() == lower))
          SharedSpaceNote(
            id: note.conversationId,
            text: note.sharedText!,
            topics: note.topics,
          ),
    ];
  }

  void _handleScopeSelect(String id) {
    HapticFeedback.selectionClick();
    SpaceSheetNode? sheetNode;
    final goingSet = _profile.goingTalkIds.toSet();

    for (final topicEntry in _scopeGraph.topics) {
      if (topicEntry.id == id) {
        final featured = topicEntry.featuredTalk;
        sheetNode = SpaceSheetNode(
          id: 'topic:${topicEntry.id}',
          kind: SpaceKind.topic,
          title: topicEntry.label,
          whyOnWavelength: topicEntry.why,
          talkCount: topicEntry.count,
          peopleCount: topicEntry.people,
          talkId: featured?.id,
          talkTitle: featured?.title,
          timeSlot: featured?.time,
          room: featured?.room,
          isGoing: featured != null && goingSet.contains(featured.id),
          linkedTopics: topicEntry.linkedTopics,
          sharedNotes: _sharedNotesForTopic(topicEntry.label),
        );
        break;
      }
    }

    if (sheetNode == null) {
      for (final talkEntry in _scopeGraph.talks) {
        if (talkEntry.id == id || talkEntry.talk.id == id) {
          final parentTopic = _scopeGraph.topics
              .where((t) => t.id == talkEntry.topicId)
              .firstOrNull;
          sheetNode = SpaceSheetNode(
            id: talkEntry.id,
            kind: SpaceKind.talk,
            title: talkEntry.talk.title,
            topicLabel: parentTopic?.label ?? talkEntry.topicId,
            whyOnWavelength: talkEntry.why,
            talkCount: parentTopic?.count,
            peopleCount: parentTopic?.people ?? 0,
            talkId: talkEntry.talk.id,
            timeSlot: talkEntry.talk.time,
            room: talkEntry.talk.room,
            abstractText: talkEntry.talk.abstractText,
            isGoing: goingSet.contains(talkEntry.talk.id),
            linkedTopics: talkEntry.linkedTopics,
            sharedNotes: <SharedSpaceNote>[
              for (final t in talkEntry.linkedTopics)
                ..._sharedNotesForTopic(t),
            ],
          );
          break;
        }
      }
    }

    if (sheetNode == null) return;
    final selectedNode = sheetNode;
    final chatRoom = selectedNode.kind == SpaceKind.topic
        ? 'topic:${selectedNode.title}'
        : (selectedNode.talkId != null
              ? 'talk:${selectedNode.talkId}'
              : selectedNode.id);
    setState(() => _selectedNodeId = id);
    showSpaceDiscoverySheet(
      context: context,
      node: selectedNode,
      onJoinChat: () =>
          unawaited(_openRoomChat(room: chatRoom, title: selectedNode.title)),
      onToggleGoing: (talkId, _) => unawaited(_toggleGoingOnTalk(talkId)),
      onSelectTopic: (topic) => unawaited(_toggleTopicChip(topic)),
    ).whenComplete(() {
      if (mounted && _selectedNodeId == id) {
        setState(() => _selectedNodeId = null);
      }
    });
  }

  void _handleTapMic() {
    final isRecording = _recording.phase == RecordingPhase.recording;
    if (_recording.busy && !isRecording) return;
    HapticFeedback.mediumImpact();
    setState(() => _pressImpulse++);
    if (isRecording) {
      unawaited(_recording.stop());
    } else {
      unawaited(_recording.start());
    }
  }

  static String _formatMmSs(Duration elapsed) {
    final totalSeconds = elapsed.inSeconds.clamp(0, 180);
    final mm = totalSeconds ~/ 60;
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.showOnboardingOnFirstLaunch &&
        _profileLoaded &&
        !_profile.onboardingDone &&
        _catalog != null) {
      return FirstLaunchOnboardingScreen(
        catalog: _catalog!,
        onComplete: _completeFirstLaunchOnboarding,
      );
    }

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[_recording, _noteCoordinator]),
      builder: (context, _) {
        final isRecording = _recording.phase == RecordingPhase.recording;
        final pending = _noteCoordinator.pendingNote;

        return Scaffold(
          backgroundColor: WavelengthColors.canvas,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Top Brand Row
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
                  child: Row(
                    children: <Widget>[
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CustomPaint(painter: _ConFellowMarkPainter()),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'CONFELLOW',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WavelengthTypography.brandWordmark,
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: 'Settings',
                        child: IconButton(
                          onPressed: () => showWavelengthSettingsSheet(
                            context: context,
                            reviewBeforeSending:
                                _noteCoordinator.reviewBeforeSending,
                            onChangedReviewBeforeSending: (val) =>
                                unawaited(_setReviewBeforeSending(val)),
                            sync: _sync,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          tooltip: 'Settings',
                          icon: const Icon(
                            Icons.tune_rounded,
                            color: WavelengthColors.secondaryText,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Two-Tab Switcher ("Note" / "Wavelength")
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                  child: Row(
                    children: <Widget>[
                      _TopTabButton(
                        label: 'Note',
                        active: _tabIndex == 0,
                        onTap: () => _switchToTab(0),
                      ),
                      const SizedBox(width: 24),
                      _TopTabButton(
                        label: 'Wavelength',
                        active: _tabIndex == 1,
                        onTap: () => _switchToTab(1),
                      ),
                    ],
                  ),
                ),

                // Two-Tab Swipeable Body
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      if (_tabIndex != index) {
                        setState(() => _tabIndex = index);
                      }
                    },
                    children: <Widget>[
                      _buildNoteTab(
                        isRecording: isRecording,
                        pending: pending,
                      ),
                      _buildWavelengthTab(isRecording: isRecording),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNoteTab({
    required bool isRecording,
    required CapturedNoteDraft? pending,
  }) {
    final String statusText;
    if (isRecording) {
      statusText = 'Listening · ${_formatMmSs(_recording.elapsed)} of 3:00';
    } else if (_isRefreshing) {
      statusText = 'Retuning to your notes and interests…';
    } else if (pending != null) {
      statusText = pending.matchedTopics.isNotEmpty
          ? 'Tuned: ${pending.matchedTopics.take(3).join(' · ')}'
          : 'Note saved';
    } else if (_flashMessage != null) {
      statusText = _flashMessage!;
    } else if (_persistentNoteSummary != null) {
      statusText = _persistentNoteSummary!;
    } else {
      statusText = 'Speak or type a note. Your map tunes to it.';
    }

    final micCaption = isRecording
        ? 'Tap to stop'
        : (_recording.busy ? 'Preparing…' : 'Tap to record a note');

    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Status line + optional amber error banner
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Semantics(
                    liveRegion: true,
                    child: isRecording
                        ? Row(
                            children: <Widget>[
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: WavelengthColors.micHotCoral,
                                  shape: BoxShape.circle,
                                  boxShadow: <BoxShadow>[
                                    BoxShadow(
                                      color: WavelengthColors.micHotCoral,
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  statusText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14.0,
                                    fontWeight: FontWeight.w500,
                                    color: WavelengthColors.micHotCoral,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Text(
                            statusText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.0,
                              fontWeight: FontWeight.w500,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                  ),
                ),
                if (_recording.error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                    child: Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: WavelengthColors.errorBannerBg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: WavelengthColors.warningAmber,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.warning_amber_rounded,
                                size: 20,
                                color: WavelengthColors.warningAmber,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _recording.error!,
                                style: const TextStyle(
                                  fontSize: 14.0,
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                  color: WavelengthColors.primaryText,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            // Hero Mic + Caption + "Type a note" Pill
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 228,
                  height: 228,
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      Positioned.fill(
                        child: MicHalo(
                          micLive: isRecording,
                          micLevel: _recording.micLevel,
                          micRadius: 64,
                          recordingElapsed: _recording.elapsed,
                          pressImpulse: _pressImpulse,
                          reduceMotion: MediaQuery.disableAnimationsOf(context),
                        ),
                      ),
                      Semantics(
                        button: true,
                        label: isRecording
                            ? 'Stop recording'
                            : 'Record a note',
                        child: GestureDetector(
                          onTap: _handleTapMic,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            width: 128,
                            height: 128,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: isRecording
                                  ? const RadialGradient(
                                      center: Alignment(0, -0.2),
                                      radius: 0.75,
                                      colors: <Color>[
                                        Color(0xFFFF936F),
                                        Color(0xFFE85A37),
                                      ],
                                    )
                                  : const RadialGradient(
                                      center: Alignment(0, -0.2),
                                      radius: 0.75,
                                      colors: <Color>[
                                        Color(0xFF0F1826),
                                        Color(0xFF070B12),
                                      ],
                                    ),
                            ),
                            alignment: Alignment.center,
                            child: isRecording
                                ? Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  )
                                : _recording.busy
                                ? const SizedBox(
                                    width: 32,
                                    height: 32,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.mic_none_rounded,
                                    size: 44,
                                    color: Colors.white,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleTapMic,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 2,
                    ),
                    child: Text(
                      micCaption,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 18.0,
                        fontWeight: FontWeight.w600,
                        color: WavelengthColors.primaryText,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Semantics(
                  button: true,
                  label: 'Type a note',
                  child: Material(
                    color: const Color(0xFF0A111B),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(99),
                      side: const BorderSide(color: Color(0xFF23405E)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => showComposeNoteSheet(
                        context: context,
                        onSubmit: _stageNote,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 240,
                          maxWidth: 340,
                          minHeight: 54,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                Icons.keyboard_alt_outlined,
                                size: 22,
                                color: WavelengthColors.primaryText,
                              ),
                              SizedBox(width: 10),
                              Flexible(
                                child: Text(
                                  'Type a note',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16.0,
                                    fontWeight: FontWeight.w600,
                                    color: WavelengthColors.primaryText,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            // Tall NoteWave + Tuned/Undo Card Stack + "Find my wavelength" Pill
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Stack(
                  alignment: Alignment.topCenter,
                  children: <Widget>[
                    SizedBox(
                      width: double.infinity,
                      height: 170,
                      child: NoteWave(
                        micLive: isRecording,
                        micLevel: _recording.micLevel,
                        findImpulse: _findImpulse,
                        reduceMotion: MediaQuery.disableAnimationsOf(context),
                      ),
                    ),
                    if (pending != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: NoteUndoReviewCard(
                          draft: pending,
                          reviewBeforeSending:
                              _noteCoordinator.reviewBeforeSending,
                          heldForReview: _noteCoordinator.heldForReview,
                          undoDuration: widget.undoWindow,
                          windowStartedAt: _noteCoordinator.windowStartedAt,
                          onUndoOrDiscard: _noteCoordinator.undoOrDiscard,
                          onSendNow: _noteCoordinator.commitNow,
                          onToggleShareText: _noteCoordinator.setShareNoteText,
                        ),
                      ),
                  ],
                ),
                _FindWavelengthPillButton(
                  busy: _isRefreshing,
                  disabled: isRecording,
                  onPressed: () => unawaited(_handleFindMyWavelength()),
                ),
              ],
            ),

            // Honest Two-Line Footer + Swipe Hint
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'Audio stays on your phone.\nYour note\'s text is saved to your profile.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      color: WavelengthColors.mutedText,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const _SwipeHintRow(
                    firstActive: true,
                    text: 'Swipe for your map ›',
                  ),
                ],
              ),
            ),
          ],
        );

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: content,
          ),
        );
      },
    );
  }

  Widget _buildWavelengthTab({required bool isRecording}) {
    final statusLine =
        _flashMessage ??
        '${_scopeTopics.length} topics and ${_scopeTalks.length} talks on your wavelength';

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final scopeHeight = math.min(
          availableWidth + 16.0,
          math.max(220.0, availableHeight - 185.0),
        );

        final content = Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(
                statusLine,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w500,
                  color: WavelengthColors.secondaryText,
                ),
              ),
            ),

            SizedBox(
              width: availableWidth,
              height: scopeHeight,
              child: WavelengthScope(
                topics: _scopeTopics,
                talks: _scopeTalks,
                edges: _scopeEdges,
                notes: _scopeNotes,
                selectedId: _selectedNodeId,
                micLive: isRecording,
                micLevel: _recording.micLevel,
                recordingElapsed: _recording.elapsed,
                pressImpulse: _pressImpulse,
                tuneImpulse: _tuneImpulse,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
                onSelect: _handleScopeSelect,
                onTapEmpty: () {
                  if (_selectedNodeId != null) {
                    setState(() => _selectedNodeId = null);
                  }
                },
              ),
            ),

            // 4-item Key Row
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: _ScopeLegendRow(),
            ),

            // Symmetric Round Buttons: Interests & Spaces
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _ScopeRoundNavButton(
                    label: 'Interests',
                    painter: const _InterestsGlyphPainter(),
                    onTap: () => unawaited(_openInterestsScreen()),
                  ),
                  SizedBox(width: math.min(44.0, availableWidth * 0.11)),
                  _ScopeRoundNavButton(
                    label: 'Spaces',
                    painter: const _SpacesGlyphPainter(),
                    onTap: () => unawaited(_openSpacesScreen()),
                  ),
                ],
              ),
            ),

            const Padding(
              padding: EdgeInsets.fromLTRB(24, 4, 24, 10),
              child: _SwipeHintRow(
                firstActive: false,
                text: '‹ Swipe back to record or type a note',
              ),
            ),
          ],
        );

        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: availableHeight),
            child: content,
          ),
        );
      },
    );
  }
}

class _ConFellowMarkPainter extends CustomPainter {
  const _ConFellowMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 22.0;
    final sy = size.height / 22.0;
    final center = Offset(11.0 * sx, 11.0 * sy);
    final r = 9.5 * math.min(sx, sy);

    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0)
        ..color = WavelengthColors.phosphorBlue.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = WavelengthColors.phosphorBlue,
    );

    final wave = Path()
      ..moveTo(3.5 * sx, 11.0 * sy)
      ..cubicTo(
        5.1 * sx,
        6.4 * sy,
        6.8 * sx,
        6.4 * sy,
        8.5 * sx,
        11.0 * sy,
      )
      ..cubicTo(
        10.2 * sx,
        15.6 * sy,
        11.9 * sx,
        15.6 * sy,
        13.5 * sx,
        11.0 * sy,
      )
      ..cubicTo(
        15.1 * sx,
        6.4 * sy,
        16.8 * sx,
        6.4 * sy,
        18.5 * sx,
        11.0 * sy,
      );

    canvas.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = WavelengthColors.primaryText,
    );
  }

  @override
  bool shouldRepaint(covariant _ConFellowMarkPainter oldDelegate) => false;
}

class _TopTabButton extends StatelessWidget {
  const _TopTabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: active
                        ? WavelengthColors.phosphorBlue
                        : Colors.transparent,
                    width: 2.0,
                  ),
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 17.0,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? WavelengthColors.primaryText
                      : WavelengthColors.mutedText,
                  shadows: active
                      ? const <Shadow>[
                          Shadow(
                            color: Color(0x990EA5E9),
                            blurRadius: 14,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FindWavelengthPillButton extends StatelessWidget {
  const _FindWavelengthPillButton({
    required this.busy,
    required this.disabled,
    required this.onPressed,
  });

  final bool busy;
  final bool disabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: !disabled,
      label: 'Find my wavelength',
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: disabled ? 0.55 : 1.0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF060B12),
            borderRadius: BorderRadius.circular(99),
            border: Border.all(
              color: WavelengthColors.phosphorBlue,
              width: 1.5,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: busy
                    ? const Color(0xCC38BDF8)
                    : const Color(0x730EA5E9),
                blurRadius: busy ? 38 : 26,
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(99),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: disabled ? null : onPressed,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 260,
                  maxWidth: 364,
                  minHeight: 56,
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CustomPaint(painter: _RadarDialGlyphPainter()),
                      ),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Find my wavelength',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17.0,
                            fontWeight: FontWeight.w600,
                            color: WavelengthColors.primaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarDialGlyphPainter extends CustomPainter {
  const _RadarDialGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.width / 24.0;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..color = WavelengthColors.phosphorBlue;

    canvas.drawCircle(c, 9.0 * s, stroke);
    canvas.drawCircle(
      c,
      4.5 * s,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = WavelengthColors.phosphorBlue.withValues(alpha: 0.6),
    );
    canvas.drawLine(c, Offset(c.dx + 6.0 * s, c.dy - 6.0 * s), stroke);
  }

  @override
  bool shouldRepaint(covariant _RadarDialGlyphPainter oldDelegate) => false;
}

class _ScopeLegendRow extends StatelessWidget {
  const _ScopeLegendRow();

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(
      fontSize: 14.0,
      fontWeight: FontWeight.w500,
      color: WavelengthColors.secondaryText,
    );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 18,
      runSpacing: 6,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: WavelengthColors.phosphorBlue,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            const Text('Topic', style: labelStyle),
          ],
        ),
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CustomPaint(painter: _LegendDiamondPainter()),
            ),
            SizedBox(width: 6),
            Text('Talk', style: labelStyle),
          ],
        ),
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 14,
              height: 14,
              child: CustomPaint(painter: _LegendNoteSquarePainter()),
            ),
            SizedBox(width: 6),
            Text('Your note', style: labelStyle),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: WavelengthColors.personViolet,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            const Text('Person', style: labelStyle),
          ],
        ),
      ],
    );
  }
}

class _LegendDiamondPainter extends CustomPainter {
  const _LegendDiamondPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const r = 5.5;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = WavelengthColors.talkStarlight,
    );
  }

  @override
  bool shouldRepaint(covariant _LegendDiamondPainter oldDelegate) => false;
}

class _LegendNoteSquarePainter extends CustomPainter {
  const _LegendNoteSquarePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(16.0 * math.pi / 180.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: 8.5, height: 8.5),
        const Radius.circular(2.0),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = WavelengthColors.noteAqua,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LegendNoteSquarePainter oldDelegate) => false;
}

class _ScopeRoundNavButton extends StatelessWidget {
  const _ScopeRoundNavButton({
    required this.label,
    required this.painter,
    required this.onTap,
  });

  final String label;
  final CustomPainter painter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 96,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0F17),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF1F3147)),
                ),
                alignment: Alignment.center,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CustomPaint(painter: painter),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w500,
                  color: WavelengthColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InterestsGlyphPainter extends CustomPainter {
  const _InterestsGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..color = WavelengthColors.primaryText;
    canvas.drawCircle(Offset(9.0 * s, 9.5 * s), 5.0 * s, p);
    canvas.drawCircle(Offset(17.5 * s, 15.0 * s), 3.2 * s, p);
    canvas.drawCircle(Offset(8.5 * s, 19.0 * s), 1.8 * s, p);
  }

  @override
  bool shouldRepaint(covariant _InterestsGlyphPainter oldDelegate) => false;
}

class _SpacesGlyphPainter extends CustomPainter {
  const _SpacesGlyphPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24.0;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = WavelengthColors.primaryText;

    final primary = Path()
      ..moveTo(6.5 * s, 4.0 * s)
      ..lineTo(14.5 * s, 4.0 * s)
      ..arcToPoint(
        Offset(17.0 * s, 6.5 * s),
        radius: Radius.circular(2.5 * s),
      )
      ..lineTo(17.0 * s, 10.5 * s)
      ..arcToPoint(
        Offset(14.5 * s, 13.0 * s),
        radius: Radius.circular(2.5 * s),
      )
      ..lineTo(9.0 * s, 13.0 * s)
      ..lineTo(5.5 * s, 16.0 * s)
      ..lineTo(5.5 * s, 12.8 * s)
      ..arcToPoint(
        Offset(4.0 * s, 10.5 * s),
        radius: Radius.circular(2.5 * s),
      )
      ..lineTo(4.0 * s, 6.5 * s)
      ..arcToPoint(
        Offset(6.5 * s, 4.0 * s),
        radius: Radius.circular(2.5 * s),
      );
    canvas.drawPath(primary, p);

    final secondary = Path()
      ..moveTo(11.0 * s, 16.5 * s)
      ..lineTo(15.5 * s, 16.5 * s)
      ..lineTo(18.5 * s, 19.0 * s)
      ..lineTo(18.5 * s, 16.3 * s)
      ..arcToPoint(
        Offset(20.0 * s, 14.2 * s),
        radius: Radius.circular(2.2 * s),
        clockwise: false,
      )
      ..lineTo(20.0 * s, 11.0 * s);
    canvas.drawPath(secondary, p);
  }

  @override
  bool shouldRepaint(covariant _SpacesGlyphPainter oldDelegate) => false;
}

class _SwipeHintRow extends StatelessWidget {
  const _SwipeHintRow({required this.firstActive, required this.text});

  final bool firstActive;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _PageDot(active: firstActive),
        const SizedBox(width: 6),
        _PageDot(active: !firstActive),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14.0,
              fontWeight: FontWeight.w500,
              color: WavelengthColors.secondaryText,
            ),
          ),
        ),
      ],
    );
  }
}

class _PageDot extends StatelessWidget {
  const _PageDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: active
            ? WavelengthColors.phosphorBlue
            : const Color(0xFF2A3F57),
        shape: BoxShape.circle,
        boxShadow: active
            ? const <BoxShadow>[
                BoxShadow(
                  color: WavelengthColors.phosphorBlue,
                  blurRadius: 8,
                ),
              ]
            : null,
      ),
    );
  }
}
