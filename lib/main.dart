import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'conversation_api.dart';
import 'cloud_sync_panel.dart';
import 'transcript_sync.dart';
import 'phone_profile_store.dart';
import 'recording_controller.dart';
import 'schedule_data.dart' as sched;
import 'search_screen.dart';
import 'ui/constellation_map.dart';
import 'ui/note_capture_and_undo.dart';
import 'ui/space_discovery_sheet.dart';
import 'ui/wavelength_theme.dart';

export 'search_screen.dart';

const bool _enableLiveAttendeeApi = bool.fromEnvironment(
  'ENABLE_LIVE_ATTENDEE_API',
  defaultValue: false,
);

void main() => runApp(const ConversationApp());

class ConversationApp extends StatelessWidget {
  const ConversationApp({
    super.key,
    this.catalog,
    this.profileStore,
    this.backend,
    this.sync,
    this.undoWindow = const Duration(seconds: 5),
    this.disableAnimations = false,
  });

  final sched.ScheduleCatalog? catalog;
  final PhoneProfileStore? profileStore;
  final WavelengthBackend? backend;
  final TranscriptSync? sync;
  final Duration undoWindow;
  final bool disableAnimations;

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
      initialCatalog: catalog,
      profileStore: profileStore,
      backend: backend,
      sync: sync,
      undoWindow: undoWindow,
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.initialCatalog,
    this.profileStore,
    this.backend,
    this.sync,
    this.undoWindow = const Duration(seconds: 5),
  });

  final sched.ScheduleCatalog? initialCatalog;
  final PhoneProfileStore? profileStore;
  final WavelengthBackend? backend;
  final TranscriptSync? sync;
  final Duration undoWindow;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final RecordingController _recording;
  late final TranscriptSync _sync;
  late final PhoneProfileStore _profileStore;
  late final bool _ownsProfileStore;
  late final PendingNoteSendCoordinator _noteCoordinator;

  WavelengthBackend? _backend;
  bool _ownsBackend = false;
  sched.ScheduleCatalog? _catalog;
  PhoneProfile _profile = PhoneProfile(handle: 'cf_loading000000000000');

  /// Note texts provisionally staged during the Undo / Review window so the map
  /// moves immediately on capture and springs cleanly back if Undone.
  CapturedNoteDraft? _stagedPreviewDraft;
  Set<String> _movedCloserIds = const {};
  Timer? _movedCloserTimer;
  String? _selectedNodeId;
  TopicColorMode _colorMode = TopicColorMode.phosphorRadar;

  int _pressImpulseTrigger = 0;
  int _tuneRippleTrigger = 0;
  int _radarSweepTrigger = 0;
  int _noteSeq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _ownsProfileStore = widget.profileStore == null;
    _profileStore = widget.profileStore ?? PhoneProfileStore();
    _catalog = widget.initialCatalog;

    _sync = widget.sync ?? TranscriptSync();
    _recording = RecordingController(
      sync: _sync,
      onNoteCompleted: _handleSpokenNote,
    );
    unawaited(_sync.initialize());
    _noteCoordinator = PendingNoteSendCoordinator(
      undoWindow: widget.undoWindow,
      onPreviewApplied: _handleDraftStaged,
      onUndoReverted: _handleDraftReverted,
      onCommitSend: _commitNoteToSeam,
    );

    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
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
        (_enableLiveAttendeeApi
            ? AttendeeWavelengthBackend(
                profileStore: _profileStore,
                catalog: loadedCatalog,
              )
            : LabeledFakeWavelengthBackend(catalog: loadedCatalog));

    setState(() {
      _profile = loadedProfile;
      _catalog = loadedCatalog;
      _backend = resolvedBackend;
      _ownsBackend = widget.backend == null;
      _noteCoordinator.reviewBeforeSending = loadedProfile.reviewBeforeSending;
      _radarSweepTrigger++;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_recording.stop());
    }
    if (state == AppLifecycleState.resumed && _sync.hasPending) {
      unawaited(_sync.retry());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _movedCloserTimer?.cancel();
    _noteCoordinator.dispose();
    _recording.dispose();
    if (widget.sync == null) {
      unawaited(_recording.closed.whenComplete(_sync.dispose));
    }
    if (_ownsBackend) _backend?.close();
    if (_ownsProfileStore) _profileStore.dispose();
    super.dispose();
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

  List<String> _matchScheduleTopics(String text) {
    final cat = _catalog;
    if (cat == null) return const [];
    final direct = cat.extractMatchedTopics(text);
    if (direct.isNotEmpty) return direct;
    // Secondary hint pass constrained strictly to canonical schedule vocabulary.
    return ScheduleTopicMatcher.matchNote(
      noteText: text,
      availableScheduleTopics: cat.topicVocabulary,
    );
  }

  void _handleSpokenNote(String transcript) {
    _stageNote(content: transcript, kind: NoteSourceKind.spoken);
  }

  void _stageNote({
    required String content,
    required NoteSourceKind kind,
    Uri? linkedUri,
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
      linkedUri: linkedUri,
      privateTranscriptSaving: kind == NoteSourceKind.spoken && _sync.enabled,
    );
    _noteCoordinator.stageFinishedNote(draft);
  }

  void _handleDraftStaged(CapturedNoteDraft draft) {
    final previousIds = {
      for (final node in _buildRankedNodes(includeStaged: false))
        if (node.ring == ClosenessRing.inner) node.id,
    };
    setState(() {
      _stagedPreviewDraft = draft;
      _tuneRippleTrigger++;
    });
    final updatedInner = {
      for (final node in _buildRankedNodes(includeStaged: true))
        if (node.ring == ClosenessRing.inner && !previousIds.contains(node.id))
          node.id,
    };
    if (updatedInner.isNotEmpty) {
      setState(() => _movedCloserIds = updatedInner);
      _movedCloserTimer?.cancel();
      _movedCloserTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _movedCloserIds = const {});
      });
    }
  }

  void _handleDraftReverted(CapturedNoteDraft _) {
    HapticFeedback.selectionClick();
    setState(() {
      _stagedPreviewDraft = null;
      _movedCloserIds = const {};
      _tuneRippleTrigger++;
    });
  }

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

    if (backend != null) {
      try {
        await backend.submitNote(submission);
      } catch (_) {
        // Keep local profile state resilient if remote submission fails.
      }
    }

    // Persist note topics (and shared text ONLY if explicitly shared) locally.
    final nextProfile = await _profileStore.recordNote(
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

    if (!mounted) return;
    setState(() {
      _profile = nextProfile;
      if (_stagedPreviewDraft?.noteId == draft.noteId) {
        _stagedPreviewDraft = null;
      }
    });
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
      _tuneRippleTrigger++;
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
      _tuneRippleTrigger++;
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

  void _triggerFindWavelengthSweep() {
    HapticFeedback.mediumImpact();
    setState(() => _radarSweepTrigger++);
  }

  void _openSearchScreen() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SearchScreen()));
  }

  List<ConstellationNode> _buildRankedNodes({bool includeStaged = true}) {
    final cat = _catalog;
    if (cat == null || cat.talks.isEmpty) return const [];

    final activeTopics = <String>{..._profile.activeWavelengthTopics};
    final noteTexts = <String>[
      for (final saved in _profile.savedNotes)
        if (saved.topics.isNotEmpty) saved.topics.join(' '),
      if (includeStaged && _stagedPreviewDraft != null)
        _stagedPreviewDraft!.text,
    ];
    if (includeStaged && _stagedPreviewDraft != null) {
      activeTopics.addAll(_stagedPreviewDraft!.matchedTopics);
    }

    final ranked = cat.rankSpaces(
      activeTopics: activeTopics,
      noteTexts: noteTexts,
      goingTalkIds: _profile.goingTalkIds.toSet(),
      maxResults: 18,
    );

    final sharedNotesByTopic = <String, List<SharedNotePreview>>{};
    for (final note in _profile.savedNotes) {
      if (!note.shared || note.sharedText == null) continue;
      final preview = SharedNotePreview(
        id: note.conversationId,
        topics: note.topics,
        why: note.why,
        sharedText: note.sharedText,
        isShared: true,
      );
      for (final topic in note.topics) {
        (sharedNotesByTopic[topic] ??= <SharedNotePreview>[]).add(preview);
      }
    }

    return [
      for (final space in ranked)
        ConstellationNode(
          id: space.id,
          kind: space.kind == sched.SpaceKind.talk
              ? SpaceKind.talk
              : SpaceKind.topic,
          ring: switch (space.closeness) {
            sched.ClosenessRing.inner => ClosenessRing.inner,
            sched.ClosenessRing.middle => ClosenessRing.middle,
            sched.ClosenessRing.outer => ClosenessRing.outer,
          },
          title: space.title,
          shortLabel: space.kind == sched.SpaceKind.topic
              ? '#${space.title}'
              : space.title,
          whyOnWavelength: space.why,
          matchedTopics: space.recentTopics,
          attendeeCount: space.peopleCount,
          recentActivityLabel: space.recentTopics.isNotEmpty
              ? 'Active topics: ${space.recentTopics.take(2).join(', ')}'
              : null,
          room: space.talk?.room,
          timeSlot: space.talk?.time,
          abstractText: space.talk?.abstractText,
          isGoing: space.isGoing,
          movedCloser: _movedCloserIds.contains(space.id),
          sharedNotes: [
            for (final topic in space.recentTopics)
              ...?sharedNotesByTopic[topic],
          ],
        ),
    ];
  }

  List<String> _buildQuickTopicChips() {
    final cat = _catalog;
    if (cat == null) return _profile.selectedTopics;
    final ordered = <String>{
      ..._profile.selectedTopics,
      if (_stagedPreviewDraft != null) ..._stagedPreviewDraft!.matchedTopics,
      ...cat.popularTopics(limit: 14),
    };
    return ordered.take(16).toList(growable: false);
  }

  void _openNodeSheet(ConstellationNode node) {
    setState(() => _selectedNodeId = node.id);
    final talkId = node.id.startsWith('talk:')
        ? node.id.substring('talk:'.length)
        : null;
    showSpaceDiscoverySheet(
      context: context,
      node: node,
      colorMode: _colorMode,
      onToggleGoing: talkId == null
          ? null
          : (_) => unawaited(_toggleGoingOnTalk(talkId)),
      onSelectTopic: (topic) => unawaited(_toggleTopicChip(topic)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_recording, _noteCoordinator, _sync]),
      builder: (context, _) {
        final isRecording = _recording.phase == RecordingPhase.recording;
        final nodes = _buildRankedNodes();
        final quickTopics = _buildQuickTopicChips();
        final selectedLower = {
          for (final t in _profile.activeWavelengthTopics) t.toLowerCase(),
        };
        final pending = _noteCoordinator.pendingNote;

        return Scaffold(
          backgroundColor: WavelengthColors.canvas,
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WavelengthBrandHeader(
                  signalCount: nodes.length,
                  trailing: Semantics(
                    button: true,
                    label: 'Search notes by interest',
                    child: IconButton(
                      onPressed: _openSearchScreen,
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      tooltip: 'Search notes',
                      icon: const Icon(
                        Icons.search_rounded,
                        color: WavelengthColors.phosphorIce,
                        size: 22,
                      ),
                    ),
                  ),
                  onOpenSettings: () => showWavelengthSettingsSheet(
                    context: context,
                    reviewBeforeSending: _noteCoordinator.reviewBeforeSending,
                    onChangedReviewBeforeSending: (val) =>
                        unawaited(_setReviewBeforeSending(val)),
                    colorMode: _colorMode,
                    onChangedColorMode: (mode) =>
                        setState(() => _colorMode = mode),
                  ),
                ),

                // Quick-tune schedule topic pills (zero onboarding gate!)
                if (quickTopics.isNotEmpty)
                  SizedBox(
                    height: 46,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      scrollDirection: Axis.horizontal,
                      itemCount: quickTopics.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final topic = quickTopics[index];
                        final active = selectedLower.contains(
                          topic.toLowerCase(),
                        );
                        return FilterChip(
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          selected: active,
                          showCheckmark: false,
                          avatar: Icon(
                            active
                                ? Icons.auto_awesome_rounded
                                : Icons.add_rounded,
                            size: 16,
                            color: active
                                ? WavelengthColors.phosphorCyan
                                : WavelengthColors.secondaryText,
                          ),
                          label: Text(
                            topic,
                            style: WavelengthTypography.supporting.copyWith(
                              color: active
                                  ? WavelengthColors.brandWhite
                                  : WavelengthColors.primaryText,
                              fontWeight: active
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          onSelected: (_) => unawaited(_toggleTopicChip(topic)),
                        );
                      },
                    ),
                  ),

                // Scrollable body: >=52% Hero Constellation Radar + Overflow Space List
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: ConstellationMap(
                          nodes: nodes,
                          selectedNodeId: _selectedNodeId,
                          onSelectNode: _openNodeSheet,
                          onTapCenter: _triggerFindWavelengthSweep,
                          activeUserTopics: _profile.activeWavelengthTopics
                              .toList(growable: false),
                          colorMode: _colorMode,
                          isRecording: isRecording,
                          micLevel: _recording.micLevel,
                          micBars: _recording.waveformBars,
                          recordingElapsed: _recording.elapsed,
                          pressImpulseTrigger: _pressImpulseTrigger,
                          tuneRippleTrigger: _tuneRippleTrigger,
                          radarSweepTrigger: _radarSweepTrigger,
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: CloudSyncPanel(
                            sync: _sync,
                            recording: _recording.phase != RecordingPhase.idle,
                          ),
                        ),
                      ),
                      if (nodes.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          sliver: SliverList.separated(
                            itemCount: nodes.length + 1,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Spaces on your wavelength',
                                      style: WavelengthTypography.sectionTitle,
                                    ),
                                    if (_backend?.isFake ?? true)
                                      const Flexible(
                                        child: Text(
                                          'KubeCon schedule',
                                          overflow: TextOverflow.ellipsis,
                                          style:
                                              WavelengthTypography.supporting,
                                        ),
                                      ),
                                  ],
                                );
                              }
                              final node = nodes[index - 1];
                              return SpaceSignalListTile(
                                node: node,
                                colorMode: _colorMode,
                                onTap: () => _openNodeSheet(node),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),

                // Persistent Thumb-Zone Capture & Radar Tuning Dock
                WavelengthCaptureDock(
                  isRecording: isRecording,
                  isBusy: _recording.busy,
                  canRecord: isRecording || _sync.canBegin,
                  onPressWaveImpulse: () =>
                      setState(() => _pressImpulseTrigger++),
                  onTapRecordOrStop: () => isRecording
                      ? unawaited(_recording.stop())
                      : unawaited(_recording.start()),
                  onSubmitManualNote: _stageNote,
                  onFindWavelength: _triggerFindWavelengthSweep,
                  micLevel: _recording.micLevel,
                  micBars: _recording.waveformBars,
                  recordingElapsed: _recording.elapsed,
                  liveTranscript: _recording.transcript,
                  statusMessage: _recording.status,
                  errorMessage: _recording.error,
                  pendingCard: pending == null
                      ? null
                      : NoteUndoReviewCard(
                          draft: pending,
                          privateTranscriptSaving:
                              pending.privateTranscriptSaving,
                          reviewBeforeSending:
                              _noteCoordinator.reviewBeforeSending,
                          undoDuration: widget.undoWindow,
                          windowStartedAt: _noteCoordinator.windowStartedAt,
                          onUndoOrDiscard: _noteCoordinator.undoOrDiscard,
                          onSendNow: _noteCoordinator.commitNow,
                          onToggleShareText: _noteCoordinator.setShareNoteText,
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
