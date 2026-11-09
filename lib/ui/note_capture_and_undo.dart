import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'pcm_level_helper.dart';
import 'wavelength_theme.dart';

export 'pcm_level_helper.dart';

/// How a note was captured by the user.
enum NoteSourceKind {
  spoken,
  typedOrPasted,
  markdownOrTextFile,
  httpsLink;

  String get label => switch (this) {
    NoteSourceKind.spoken => 'Spoken note',
    NoteSourceKind.typedOrPasted => 'Typed note',
    NoteSourceKind.markdownOrTextFile => 'Markdown / text note',
    NoteSourceKind.httpsLink => 'Linked note',
  };
}

/// Immutable payload representing one finished user note ready for the Undo
/// window or Review-before-sending decision, and then Branch 2's backend seam.
@immutable
class CapturedNoteDraft {
  const CapturedNoteDraft({
    required this.noteId,
    required this.text,
    required this.sourceKind,
    required this.matchedTopics,
    required this.createdAt,
    this.linkedUri,
    this.shareNoteText = false,
    this.privateTranscriptSaving = false,
  });

  /// Maps 1-to-1 to `conversationId` in the backend adapter (`one id per note`).
  final String noteId;
  final String text;
  final NoteSourceKind sourceKind;

  /// Strictly matched from bundled schedule tags — empty when nothing matches
  /// (never invented).
  final List<String> matchedTopics;
  final DateTime createdAt;
  final Uri? linkedUri;

  /// Off by default: other attendees see only matched topics unless shared.
  final bool shareNoteText;
  // Capture the recording's consent state; changing settings later cannot
  // retract text already uploaded to private history.
  final bool privateTranscriptSaving;

  /// Primary card headline per `PROTOCOL.md`:
  /// - `"Tuned: eBPF, Observability"` when schedule topics matched
  /// - `"Note saved"` when zero schedule topics matched
  String get cardHeadline {
    if (matchedTopics.isEmpty) return 'Note saved';
    final preview = matchedTopics.take(3).join(', ');
    return 'Tuned: $preview';
  }

  CapturedNoteDraft copyWith({
    bool? shareNoteText,
    List<String>? matchedTopics,
  }) {
    return CapturedNoteDraft(
      noteId: noteId,
      text: text,
      sourceKind: sourceKind,
      matchedTopics: matchedTopics ?? this.matchedTopics,
      createdAt: createdAt,
      linkedUri: linkedUri,
      shareNoteText: shareNoteText ?? this.shareNoteText,
      privateTranscriptSaving: privateTranscriptSaving,
    );
  }
}

/// Matches a finished note strictly against real topics from the bundled
/// KubeCon schedule asset. Never invents topics.
abstract final class ScheduleTopicMatcher {
  /// Keyword aliases that only activate if the corresponding canonical topic
  /// actually exists in [availableScheduleTopics].
  static const Map<String, List<String>> _keywordHints = <String, List<String>>{
    'observability': <String>[
      'observability',
      'ebpf',
      'opentelemetry',
      'otel',
      'prometheus',
      'tracing',
      'metrics',
      'telemetry',
    ],
    'ai inference + agentic': <String>[
      'agent',
      'agentic',
      'inference',
      'llm',
      'vllm',
      'whisper',
      'model',
      'gpu',
    ],
    'platform engineering': <String>[
      'platform',
      'idp',
      'backstage',
      'gitops',
      'argocd',
      'argo',
      'developer portal',
    ],
    'security': <String>[
      'security',
      'zero trust',
      'rbac',
      'opa',
      'kyverno',
      'sbom',
      'supply chain',
      'kernel security',
      'auth',
    ],
    'connectivity': <String>[
      'connectivity',
      'network',
      'networking',
      'cilium',
      'gateway api',
      'ingress',
      'mesh',
      'dns',
    ],
    'operations + performance': <String>[
      'autoscaling',
      'karpenter',
      'performance',
      'latency',
      'sre',
      'cluster',
      'scheduling',
    ],
    'application development + delivery': <String>[
      'wasm',
      'webassembly',
      'helm',
      'kustomize',
      'ci/cd',
      'rollout',
      'canary',
      'serverless',
    ],
    'data processing + storage': <String>[
      'postgres',
      'database',
      'storage',
      'stateful',
      'csi',
      'vector',
      'elastic',
    ],
  };

  /// Meta/logistics schedule tags excluded from topic matching.
  static const Set<String> _nonTopicMetaTags = <String>{
    'any level',
    'beginner',
    'advanced',
    'sponsored',
    'separate registration required',
    'sponsor-hosted co-located events',
    'cncf-hosted co-located events',
    'end user talk',
    'experiences',
  };

  static List<String> matchNote({
    required String noteText,
    required Iterable<String> availableScheduleTopics,
    int maxResults = 4,
  }) {
    final normalizedNote = noteText.toLowerCase();
    if (normalizedNote.trim().isEmpty) return const <String>[];

    final scored = <(String, int)>[];
    final seenLower = <String>{};

    for (final rawTopic in availableScheduleTopics) {
      final clean = rawTopic.trim();
      if (clean.isEmpty) continue;
      final lowerTopic = clean.toLowerCase();
      if (_nonTopicMetaTags.contains(lowerTopic)) continue;
      if (!seenLower.add(lowerTopic)) continue;

      var score = 0;

      // 1. Direct phrase match against the schedule tag name
      final alphaTopic = lowerTopic
          .replaceAll(RegExp(r'[^\w\s+-]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (alphaTopic.length >= 3 && normalizedNote.contains(alphaTopic)) {
        score += 5;
      }

      // 2. Significant word match (>= 4 chars) within the schedule tag
      final words = alphaTopic
          .split(RegExp(r'[\s+/]+'))
          .where(
            (w) =>
                w.length >= 4 && w != 'with' && w != 'cloud' && w != 'native',
          );
      for (final word in words) {
        if (RegExp('\\b${RegExp.escape(word)}').hasMatch(normalizedNote)) {
          score += 2;
        }
      }

      // 3. Domain keyword hint (only scores if this canonical tag is in the asset)
      final hints = _keywordHints[lowerTopic];
      if (hints != null) {
        for (final hint in hints) {
          if (RegExp('\\b${RegExp.escape(hint)}').hasMatch(normalizedNote)) {
            score += 3;
          }
        }
      }

      if (score > 0) {
        scored.add((clean, score));
      }
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored
        .take(maxResults)
        .map((entry) => entry.$1)
        .toList(growable: false);
  }
}

/// Persists `"Review before sending"` (default `false`) and [TopicColorMode]
/// on the device using `path_provider` (zero extra dependencies), falling back
/// cleanly to in-memory storage inside widget tests.
class WavelengthPreferencesStore {
  WavelengthPreferencesStore({
    this.fileName = 'confellow_wavelength_prefs.json',
  });

  final String fileName;
  static Map<String, Object?> _memoryFallback = <String, Object?>{};

  Future<(bool reviewBeforeSending, TopicColorMode colorMode)> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$fileName');
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final review = decoded['reviewBeforeSending'] == true;
          final modeStr = decoded['colorMode'];
          final mode = modeStr == TopicColorMode.topicFamily.name
              ? TopicColorMode.topicFamily
              : TopicColorMode.phosphorRadar;
          return (review, mode);
        }
      }
    } catch (_) {
      // Widget test environment without path_provider channel registered.
    }
    final review = _memoryFallback['reviewBeforeSending'] == true;
    final mode = _memoryFallback['colorMode'] == TopicColorMode.topicFamily.name
        ? TopicColorMode.topicFamily
        : TopicColorMode.phosphorRadar;
    return (review, mode);
  }

  Future<void> save({
    required bool reviewBeforeSending,
    required TopicColorMode colorMode,
  }) async {
    final payload = <String, Object?>{
      'reviewBeforeSending': reviewBeforeSending,
      'colorMode': colorMode.name,
    };
    _memoryFallback = payload;
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // Ignored in headless test environments; memory fallback remains active.
    }
  }
}

/// Coordinates note submission and optional sharing. Separately consented
/// realtime private transcript saving is not cancelled by Undo or Discard.
class PendingNoteSendCoordinator extends ChangeNotifier {
  PendingNoteSendCoordinator({
    this.undoWindow = const Duration(seconds: 5),
    required this.onCommitSend,
    this.onPreviewApplied,
    this.onUndoReverted,
  });

  final Duration undoWindow;
  final FutureOr<void> Function(CapturedNoteDraft note) onCommitSend;
  final ValueChanged<CapturedNoteDraft>? onPreviewApplied;
  final ValueChanged<CapturedNoteDraft>? onUndoReverted;

  CapturedNoteDraft? _pending;
  Timer? _commitTimer;
  DateTime? _windowStartedAt;
  bool _reviewBeforeSending = false;
  bool _disposed = false;

  CapturedNoteDraft? get pendingNote => _pending;
  bool get reviewBeforeSending => _reviewBeforeSending;
  DateTime? get windowStartedAt => _windowStartedAt;

  set reviewBeforeSending(bool value) {
    if (_reviewBeforeSending == value) return;
    _reviewBeforeSending = value;
    if (value) {
      // Switching to manual review cancels any ticking auto-send timer.
      _commitTimer?.cancel();
      _commitTimer = null;
      _windowStartedAt = null;
    }
    _notify();
  }

  /// Enqueues a newly finished note. If an earlier note was still waiting in
  /// its auto-send Undo window, commits that earlier note first.
  void stageFinishedNote(CapturedNoteDraft draft) {
    if (_pending != null && !_reviewBeforeSending) {
      final previous = _pending!;
      _commitTimer?.cancel();
      _commitTimer = null;
      unawaited(Future<void>.sync(() => onCommitSend(previous)));
    }

    _pending = draft;
    onPreviewApplied?.call(draft);

    if (_reviewBeforeSending) {
      _windowStartedAt = null;
    } else {
      _windowStartedAt = DateTime.now();
      _commitTimer?.cancel();
      _commitTimer = Timer(undoWindow, commitNow);
    }
    _notify();
  }

  void setShareNoteText(bool share) {
    if (_pending == null) return;
    _pending = _pending!.copyWith(shareNoteText: share);
    _notify();
  }

  /// Cancels this pending note submission and springs the map back.
  void undoOrDiscard() {
    final reverted = _pending;
    if (reverted == null) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    _pending = null;
    _windowStartedAt = null;
    onUndoReverted?.call(reverted);
    _notify();
  }

  /// Sends the staged note immediately (either when the Undo window expires or
  /// when the user taps `Send` under "Review before sending").
  void commitNow() {
    final ready = _pending;
    if (ready == null) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    _pending = null;
    _windowStartedAt = null;
    _notify();
    unawaited(Future<void>.sync(() => onCommitSend(ready)));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _commitTimer?.cancel();
    super.dispose();
  }
}

/// Post-capture Undo / Review card rendered cleanly above the capture dock.
///
/// - When [reviewBeforeSending] is `false` (default): shows `"Tuned: <topics>"`
///   (or `"Note saved"`), an optional **"Share this note"** toggle, a 5-second
///   phosphor countdown bar, and **`Undo`**.
/// - When [reviewBeforeSending] is `true`: shows **`Discard`** and **`Send`**,
///   withholding this note submission until **`Send`** is tapped. Private
///   transcript saving, if enabled, runs independently during recording.
class NoteUndoReviewCard extends StatefulWidget {
  const NoteUndoReviewCard({
    super.key,
    required this.draft,
    required this.reviewBeforeSending,
    required this.onUndoOrDiscard,
    required this.onSendNow,
    required this.onToggleShareText,
    this.undoDuration = const Duration(seconds: 5),
    this.windowStartedAt,
    this.privateTranscriptSaving = false,
  });

  final CapturedNoteDraft draft;
  final bool reviewBeforeSending;
  final VoidCallback onUndoOrDiscard;
  final VoidCallback onSendNow;
  final ValueChanged<bool> onToggleShareText;
  final Duration undoDuration;
  final DateTime? windowStartedAt;
  final bool privateTranscriptSaving;

  @override
  State<NoteUndoReviewCard> createState() => _NoteUndoReviewCardState();
}

class _NoteUndoReviewCardState extends State<NoteUndoReviewCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _barController;

  @override
  void initState() {
    super.initState();
    _barController = AnimationController(
      vsync: this,
      duration: widget.undoDuration,
    );
    _syncCountdownBar();
  }

  @override
  void didUpdateWidget(covariant NoteUndoReviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft.noteId != widget.draft.noteId ||
        oldWidget.reviewBeforeSending != widget.reviewBeforeSending ||
        oldWidget.undoDuration != widget.undoDuration) {
      _barController.duration = widget.undoDuration;
      _syncCountdownBar();
    }
  }

  void _syncCountdownBar() {
    if (widget.reviewBeforeSending) {
      _barController.stop();
      _barController.value = 0.0;
      return;
    }
    final start = widget.windowStartedAt;
    if (start != null) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      final frac = (elapsedMs / widget.undoDuration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      _barController.forward(from: frac);
    } else {
      _barController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _barController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Semantics(
      liveRegion: true,
      container: true,
      child: PhosphorSurfaceCard(
        elevated: true,
        accentBorderColor: WavelengthColors.phosphorBlue,
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    size: 20,
                    color: WavelengthColors.phosphorCyan,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        draft.cardHeadline,
                        style: WavelengthTypography.sectionTitle,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.privateTranscriptSaving
                            ? 'Private transcript saving is separate. Undo or Discard does not delete uploaded text.'
                            : widget.reviewBeforeSending
                            ? 'Review before sending is on · nothing sent yet'
                            : draft.matchedTopics.isEmpty
                            ? 'Kept on your wavelength · no schedule tags matched'
                            : 'Wavelength updated · others see topics only unless shared',
                        style: WavelengthTypography.supporting,
                      ),
                    ],
                  ),
                ),
                if (!widget.reviewBeforeSending) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onUndoOrDiscard();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: WavelengthColors.primaryText,
                        backgroundColor: WavelengthColors.canvas,
                        side: const BorderSide(
                          color: WavelengthColors.phosphorCyan,
                          width: 1.3,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.undo_rounded, size: 18),
                      label: const Text(
                        'Undo',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 12),

            // Optional "Share this note" toggle ( >= 48dp accessible target )
            Semantics(
              button: true,
              toggled: draft.shareNoteText,
              label: 'Share this note text with matched spaces',
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onToggleShareText(!draft.shareNoteText);
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: draft.shareNoteText
                          ? WavelengthColors.phosphorAfterglow.withValues(
                              alpha: 0.40,
                            )
                          : WavelengthColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: draft.shareNoteText
                            ? WavelengthColors.phosphorBlue
                            : WavelengthColors.borderSpecular,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          draft.shareNoteText
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 20,
                          color: draft.shareNoteText
                              ? WavelengthColors.phosphorCyan
                              : WavelengthColors.secondaryText,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            draft.shareNoteText
                                ? 'Share this note · text visible in matched spaces'
                                : 'Share this note (optional · private text by default)',
                            style: WavelengthTypography.supporting.copyWith(
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

            // Review-before-sending explicit Send / Discard buttons
            if (widget.reviewBeforeSending) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          widget.onUndoOrDiscard();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WavelengthColors.primaryText,
                          side: const BorderSide(
                            color: WavelengthColors.borderSpecular,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 19,
                        ),
                        label: const Text(
                          'Discard',
                          style: TextStyle(
                            fontSize: 15.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          widget.onSendNow();
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: WavelengthColors.phosphorBlue,
                          foregroundColor: WavelengthColors.onPhosphor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.send_rounded, size: 18),
                        label: const Text(
                          'Send note',
                          style: TextStyle(
                            fontSize: 15.0,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: 10),
              // 5-second phosphor countdown progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 4,
                  child: reduceMotion
                      ? const LinearProgressIndicator(
                          value: 0.5,
                          backgroundColor: WavelengthColors.surface,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            WavelengthColors.phosphorCyan,
                          ),
                        )
                      : AnimatedBuilder(
                          animation: _barController,
                          builder: (context, _) => LinearProgressIndicator(
                            value: (1.0 - _barController.value).clamp(0.0, 1.0),
                            backgroundColor: WavelengthColors.surface,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              WavelengthColors.phosphorCyan,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Thumb-zone capture dock with:
/// 1. Primary **Tap to speak a note** button (Electric Blue Phosphor `#38BDF8`
///    when idle; Warm Signal Coral `#FF7A59` with live 24-bar PCM waveform +
///    harmonic wave ribbons + timer when recording; tactile spring press +
///    dynamic outward wave impulse!).
/// 2. Secondary **Type, paste or link a note** button.
/// 3. **Find my wavelength** radar/compass sweep control with mini animated
///    degree-tick radar dial & press sweep shader highlight.
class WavelengthCaptureDock extends StatefulWidget {
  const WavelengthCaptureDock({
    super.key,
    required this.isRecording,
    required this.isBusy,
    this.canRecord = true,
    required this.onTapRecordOrStop,
    required this.onSubmitManualNote,
    this.onPressWaveImpulse,
    this.onFindWavelength,
    this.micLevel = 0.0,
    this.micBars,
    this.pcmMeter,
    this.recordingElapsed,
    this.liveTranscript = '',
    this.statusMessage,
    this.errorMessage,
    this.pendingCard,
    this.onPickTextFileContent,
  });

  final bool isRecording;
  final bool isBusy;
  final bool canRecord;
  final VoidCallback onTapRecordOrStop;
  final void Function({
    required String content,
    required NoteSourceKind kind,
    Uri? linkedUri,
  })
  onSubmitManualNote;

  /// Fired immediately on pointer-down / tap of the Record button so the
  /// Constellation Map emits an outward shockwave impulse in lockstep.
  final VoidCallback? onPressWaveImpulse;

  /// Fired when "Find my wavelength" is pressed (triggers radar sweep / search).
  final VoidCallback? onFindWavelength;

  final double micLevel;
  final List<double>? micBars;
  final PcmLevelMeter? pcmMeter;
  final Duration? recordingElapsed;
  final String liveTranscript;
  final String? statusMessage;
  final String? errorMessage;
  final Widget? pendingCard;

  /// Optional platform/test hook for importing a `.txt` or `.md` file.
  final Future<String?> Function()? onPickTextFileContent;

  @override
  State<WavelengthCaptureDock> createState() => _WavelengthCaptureDockState();
}

class _WavelengthCaptureDockState extends State<WavelengthCaptureDock>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _animController;
  final PcmLevelMeter _fallbackMeter = PcmLevelMeter();
  final Stopwatch _recStopwatch = Stopwatch();

  bool _appActive = true;
  bool _pressedPrimary = false;
  bool _expandLiveWords = false;
  double? _buttonWaveStartSec;
  double? _radarButtonSweepStartSec;

  double get _nowSec =>
      (_animController.lastElapsedDuration?.inMicroseconds ?? 0) / 1e6;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animController =
        AnimationController(vsync: this, duration: const Duration(hours: 1))
          ..addListener(() {
            if (mounted) setState(() {});
          });

    if (widget.isRecording) {
      _recStopwatch.start();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTicker();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant WavelengthCaptureDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !oldWidget.isRecording) {
      _recStopwatch
        ..reset()
        ..start();
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _recStopwatch.stop();
      _expandLiveWords = false;
    }
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncTicker();
  }

  void _syncTicker() {
    if (!mounted) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final hasActiveButtonEffect =
        (_buttonWaveStartSec != null &&
            (_nowSec - _buttonWaveStartSec!) < 0.70) ||
        (_radarButtonSweepStartSec != null &&
            (_nowSec - _radarButtonSweepStartSec!) < 1.35);

    final shouldRun =
        _appActive &&
        !reduceMotion &&
        (widget.isRecording || hasActiveButtonEffect);
    if (shouldRun && !_animController.isAnimating) {
      _animController.repeat();
    } else if (!shouldRun && _animController.isAnimating) {
      _animController.stop(canceled: false);
    }
  }

  void _triggerPrimaryPressWave() {
    if (widget.isBusy || !widget.canRecord) return;
    HapticFeedback.mediumImpact();
    widget.onPressWaveImpulse?.call();

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduceMotion && _appActive) {
      if (!_animController.isAnimating) {
        _animController.repeat();
      }
      _buttonWaveStartSec = _nowSec;
    }
  }

  void _triggerRadarButtonPress() {
    HapticFeedback.selectionClick();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduceMotion && _appActive) {
      if (!_animController.isAnimating) {
        _animController.repeat();
      }
      _radarButtonSweepStartSec = _nowSec;
    }
    widget.onFindWavelength?.call();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final totalSec = d.inSeconds.clamp(0, 180);
    final mm = (totalSec ~/ 60).toString().padLeft(2, '0');
    final ss = (totalSec % 60).toString().padLeft(2, '0');
    return '$mm:$ss / 03:00';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final tSec = _nowSec;
    final meter = widget.pcmMeter ?? _fallbackMeter;

    final effectiveLevel = meter.effectiveLevel(
      isRecording: widget.isRecording,
      phaseSeconds: tSec,
      overrideLevel: widget.micLevel > 0 ? widget.micLevel : null,
      reduceMotion: reduceMotion,
    );
    final effectiveBars = meter.effectiveBars(
      isRecording: widget.isRecording,
      phaseSeconds: tSec,
      overrideLevel: widget.micLevel > 0 ? widget.micLevel : null,
      overrideBars: widget.micBars,
      reduceMotion: reduceMotion,
    );

    final buttonWaveProgress = _progressOrNull(
      startSec: _buttonWaveStartSec,
      nowSec: tSec,
      durationSec: 0.65,
    );
    final radarSweepProgress = _progressOrNull(
      startSec: _radarButtonSweepStartSec,
      nowSec: tSec,
      durationSec: 1.25,
    );

    final elapsed = widget.recordingElapsed ?? _recStopwatch.elapsed;

    return Container(
      decoration: BoxDecoration(
        color: WavelengthColors.canvas.withValues(alpha: 0.95),
        border: const Border(
          top: BorderSide(color: WavelengthColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Error banner if microphone or speech model failed
          if (widget.errorMessage != null &&
              widget.errorMessage!.trim().isNotEmpty) ...[
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: WavelengthColors.errorBannerBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: WavelengthColors.errorBannerBorder),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: WavelengthColors.micHotCoral,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.errorMessage!,
                        style: WavelengthTypography.supporting.copyWith(
                          color: WavelengthColors.primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Pending Undo / Review Card
          if (widget.pendingCard != null) ...[
            widget.pendingCard!,
            const SizedBox(height: 10),
          ],

          // Subtle secondary Live Whisper bonus strip (waveform stays primary!)
          if (widget.isRecording &&
              widget.liveTranscript.trim().isNotEmpty) ...[
            GestureDetector(
              onTap: () => setState(() => _expandLiveWords = !_expandLiveWords),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: WavelengthColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: WavelengthColors.borderSubtle),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.subtitles_outlined,
                        size: 17,
                        color: WavelengthColors.secondaryText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.liveTranscript.trim(),
                        maxLines: _expandLiveWords ? 4 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: WavelengthTypography.supporting.copyWith(
                          color: WavelengthColors.primaryText,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expandLiveWords
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: WavelengthColors.secondaryText,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // 1. Primary Button: Tap to speak a note (Blue Phosphor idle -> Coral live waveform)
          Semantics(
            button: true,
            enabled: !widget.isBusy && widget.canRecord,
            label: widget.isBusy
                ? 'Preparing your note'
                : widget.isRecording
                ? 'Tap to finish speaking your note'
                : 'Tap to speak a note',
            child: GestureDetector(
              onTapDown: widget.isBusy || !widget.canRecord
                  ? null
                  : (_) {
                      setState(() => _pressedPrimary = true);
                      _triggerPrimaryPressWave();
                    },
              onTapCancel: () => setState(() => _pressedPrimary = false),
              onTapUp: widget.isBusy || !widget.canRecord
                  ? null
                  : (_) {
                      setState(() => _pressedPrimary = false);
                      widget.onTapRecordOrStop();
                    },
              child: AnimatedScale(
                scale: _pressedPrimary && !reduceMotion ? 0.968 : 1.0,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutBack,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 68),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: CustomPaint(
                      painter: _PrimaryRecordButtonPainter(
                        isRecording: widget.isRecording,
                        isBusy: widget.isBusy,
                        micLevel: effectiveLevel,
                        micBars: effectiveBars,
                        timeSec: tSec,
                        reduceMotion: reduceMotion,
                        pressWaveProgress: buttonWaveProgress,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 13,
                        ),
                        child: Row(
                          children: [
                            // Leading mic / stop / busy badge
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isRecording
                                    ? WavelengthColors.onMicHot.withValues(
                                        alpha: 0.18,
                                      )
                                    : WavelengthColors.onPhosphor.withValues(
                                        alpha: 0.14,
                                      ),
                              ),
                              child: Center(
                                child: widget.isBusy
                                    ? SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: widget.isRecording
                                              ? WavelengthColors.onMicHot
                                              : WavelengthColors.onPhosphor,
                                        ),
                                      )
                                    : Icon(
                                        widget.isRecording
                                            ? Icons.stop_rounded
                                            : Icons.mic_rounded,
                                        size: 26,
                                        color: widget.isRecording
                                            ? WavelengthColors.onMicHot
                                            : WavelengthColors.onPhosphor,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.isBusy
                                        ? 'One moment…'
                                        : widget.isRecording
                                        ? 'Tap to finish note'
                                        : 'Tap to speak a note',
                                    style: TextStyle(
                                      fontSize: 17.0,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.3,
                                      color: widget.isRecording
                                          ? WavelengthColors.onMicHot
                                          : WavelengthColors.onPhosphor,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.isBusy
                                        ? (widget.statusMessage ??
                                              'Preparing on-device speech…')
                                        : widget.isRecording
                                        ? 'Listening · ${_formatDuration(elapsed)}'
                                        : 'Speak your own thought · audio stays on phone',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14.0,
                                      fontWeight: FontWeight.w600,
                                      color: widget.isRecording
                                          ? WavelengthColors.onMicHot
                                                .withValues(alpha: 0.88)
                                          : WavelengthColors.onPhosphor
                                                .withValues(alpha: 0.86),
                                    ),
                                  ),
                                ],
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
          ),

          const SizedBox(height: 10),

          // 2. Secondary Thumb Row: "Type or paste note" + "Find my wavelength"
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Type or paste a note',
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: () => showComposeNoteSheet(
                        context: context,
                        onSubmit: widget.onSubmitManualNote,
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: WavelengthColors.elevated,
                        foregroundColor: WavelengthColors.primaryText,
                        side: const BorderSide(
                          color: WavelengthColors.borderSpecular,
                          width: 1.1,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: const Icon(
                        Icons.edit_note_rounded,
                        size: 21,
                        color: WavelengthColors.phosphorIce,
                      ),
                      label: const Text(
                        'Type or paste note',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.onFindWavelength != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FindWavelengthRadarButton(
                    onPressed: _triggerRadarButtonPress,
                    sweepProgress: radarSweepProgress,
                    reduceMotion: reduceMotion,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static double? _progressOrNull({
    required double? startSec,
    required double nowSec,
    required double durationSec,
  }) {
    if (startSec == null) return null;
    final elapsed = nowSec - startSec;
    if (elapsed < 0.0 || elapsed > durationSec) return null;
    return (elapsed / durationSec).clamp(0.0, 1.0);
  }
}

/// Custom painter rendering the primary Record button's Blue Phosphor idle fill,
/// tactile press wave impulse, and Warm Signal Coral (`#FF7A59`) live 24-bar +
/// harmonic ribbon waveform when recording!
class _PrimaryRecordButtonPainter extends CustomPainter {
  const _PrimaryRecordButtonPainter({
    required this.isRecording,
    required this.isBusy,
    required this.micLevel,
    required this.micBars,
    required this.timeSec,
    required this.reduceMotion,
    required this.pressWaveProgress,
  });

  final bool isRecording;
  final bool isBusy;
  final double micLevel;
  final List<double> micBars;
  final double timeSec;
  final bool reduceMotion;
  final double? pressWaveProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1. Base Gradient Fill: unmistakable Electric Blue Phosphor (idle) vs
    //    Warm Signal Coral (recording ONLY)
    final gradient = isRecording
        ? const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [WavelengthColors.micHotCoral, Color(0xFFFF9270)],
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              WavelengthColors.phosphorBlue,
              WavelengthColors.phosphorCyan,
            ],
          );
    canvas.drawRect(rect, Paint()..shader = gradient.createShader(rect));

    // 2. Live Harmonic Wave Ribbons + Right-hand 24-bar Waveform while recording
    if (isRecording) {
      _paintHarmonicRibbon(
        canvas: canvas,
        size: size,
        amplitude: (6.0 + micLevel * 18.0),
        frequency: 2.6,
        phase: reduceMotion ? 0.6 : timeSec * 5.8,
        color: WavelengthColors.onMicHot.withValues(alpha: 0.13),
      );
      _paintHarmonicRibbon(
        canvas: canvas,
        size: size,
        amplitude: (4.0 + micLevel * 13.0),
        frequency: 4.1,
        phase: reduceMotion ? 1.9 : -timeSec * 4.2,
        color: WavelengthColors.brandWhite.withValues(alpha: 0.22),
      );

      // Right-aligned live vertical waveform bars
      final barCount = math.min(16, micBars.length);
      const barSpacing = 4.6;
      final startX = size.width - (barCount * barSpacing) - 14.0;
      final midY = size.height * 0.5;
      final barPaint = Paint()
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = WavelengthColors.onMicHot.withValues(alpha: 0.72);

      for (var i = 0; i < barCount; i++) {
        final barVal = micBars[(i * micBars.length) ~/ barCount].clamp(
          0.10,
          1.0,
        );
        final halfH = 4.0 + barVal * (size.height * 0.34);
        final x = startX + i * barSpacing;
        canvas.drawLine(
          Offset(x, midY - halfH),
          Offset(x, midY + halfH),
          barPaint,
        );
      }
    }

    // 3. Tactile Expanding Wave Impulse on Tap / Press
    if (pressWaveProgress != null) {
      final eased = Curves.easeOutCubic.transform(pressWaveProgress!);
      final maxR = size.longestSide * 1.05;
      final waveOrigin = Offset(38.0, size.height * 0.5);
      final alpha = (1.0 - pressWaveProgress!).clamp(0.0, 1.0);
      canvas.drawCircle(
        waveOrigin,
        14.0 + eased * maxR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2 * (1.0 - 0.5 * pressWaveProgress!)
          ..color = WavelengthColors.brandWhite.withValues(alpha: alpha * 0.65),
      );
    }
  }

  void _paintHarmonicRibbon({
    required Canvas canvas,
    required Size size,
    required double amplitude,
    required double frequency,
    required double phase,
    required Color color,
  }) {
    final path = Path()..moveTo(0, size.height);
    const steps = 48;
    final baseline = size.height * 0.62;
    for (var i = 0; i <= steps; i++) {
      final u = i / steps;
      final x = u * size.width;
      final y =
          baseline +
          math.sin(u * math.pi * 2.0 * frequency + phase) * amplitude * 0.55;
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PrimaryRecordButtonPainter oldDelegate) =>
      oldDelegate.isRecording != isRecording ||
      oldDelegate.isBusy != isBusy ||
      oldDelegate.micLevel != micLevel ||
      oldDelegate.timeSec != timeSec ||
      oldDelegate.pressWaveProgress != pressWaveProgress;
}

/// Companion **"Find my wavelength"** control with a custom mini animated
/// degree-tick radar/compass dial and specular sweep shader accent on press.
class FindWavelengthRadarButton extends StatelessWidget {
  const FindWavelengthRadarButton({
    super.key,
    required this.onPressed,
    this.sweepProgress,
    this.reduceMotion = false,
  });

  final VoidCallback onPressed;
  final double? sweepProgress;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final activeSweep = (!reduceMotion && sweepProgress != null)
        ? sweepProgress!
        : 0.0;

    return Semantics(
      button: true,
      label: 'Find my wavelength',
      child: Material(
        color: WavelengthColors.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: sweepProgress != null
                ? WavelengthColors.phosphorCyan
                : WavelengthColors.phosphorBlue.withValues(alpha: 0.70),
            width: 1.2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            child: CustomPaint(
              painter: _ButtonSweepAccentPainter(progress: sweepProgress),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CustomPaint(
                        painter: _MiniRadarCompassDialPainter(
                          sweepAngle:
                              -math.pi * 0.35 + activeSweep * math.pi * 4.0,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        'Find wavelength',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: WavelengthColors.primaryText,
                          fontSize: 14.0,
                          fontWeight: FontWeight.w700,
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
    );
  }
}

class _MiniRadarCompassDialPainter extends CustomPainter {
  const _MiniRadarCompassDialPainter({required this.sweepAngle});

  final double sweepAngle;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide * 0.46;

    // Outer compass bezel
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = WavelengthColors.phosphorBlue,
    );

    // 8 compass ticks
    final tickPaint = Paint()
      ..strokeWidth = 1.1
      ..color = WavelengthColors.phosphorIce.withValues(alpha: 0.80);
    for (var i = 0; i < 8; i++) {
      final a = (i / 8) * math.pi * 2.0;
      canvas.drawLine(
        Offset(c.dx + (r - 2.6) * math.cos(a), c.dy + (r - 2.6) * math.sin(a)),
        Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)),
        tickPaint,
      );
    }

    // Conical phosphor sweep wedge
    final rect = Rect.fromCircle(center: c, radius: r - 1.0);
    final wedge = Path()
      ..moveTo(c.dx, c.dy)
      ..arcTo(rect, sweepAngle - 0.95, 0.95, false)
      ..close();
    canvas.drawPath(
      wedge,
      Paint()..color = WavelengthColors.phosphorCyan.withValues(alpha: 0.36),
    );

    // Sweep needle + center pip
    canvas.drawLine(
      c,
      Offset(
        c.dx + (r - 1.5) * math.cos(sweepAngle),
        c.dy + (r - 1.5) * math.sin(sweepAngle),
      ),
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = WavelengthColors.phosphorIce,
    );
    canvas.drawCircle(c, 1.8, Paint()..color = WavelengthColors.brandWhite);
  }

  @override
  bool shouldRepaint(covariant _MiniRadarCompassDialPainter oldDelegate) =>
      oldDelegate.sweepAngle != sweepAngle;
}

class _ButtonSweepAccentPainter extends CustomPainter {
  const _ButtonSweepAccentPainter({required this.progress});

  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == null) return;
    final p = progress!;
    final x = -size.width * 0.35 + p * (size.width * 1.7);
    final bandRect = Rect.fromLTWH(x, 0, size.width * 0.45, size.height);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: [
            WavelengthColors.phosphorCyan.withValues(alpha: 0.0),
            WavelengthColors.phosphorCyan.withValues(alpha: 0.22 * (1.0 - p)),
            WavelengthColors.phosphorCyan.withValues(alpha: 0.0),
          ],
        ).createShader(bandRect),
    );
  }

  @override
  bool shouldRepaint(covariant _ButtonSweepAccentPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// Opens the dark bottom sheet for typing, pasting, importing `.txt`/`.md`,
/// or linking an `https://` note.
Future<void> showComposeNoteSheet({
  required BuildContext context,
  required void Function({
    required String content,
    required NoteSourceKind kind,
    Uri? linkedUri,
  })
  onSubmit,
  Future<String?> Function()? onPickTextFileContent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: WavelengthColors.elevated,
    barrierColor: Colors.black.withValues(alpha: 0.74),
    builder: (sheetCtx) => ComposeNoteSheet(onSubmit: onSubmit),
  );
}

/// Sleek dark phosphor sheet supporting typed or pasted text notes (no file upload).
class ComposeNoteSheet extends StatefulWidget {
  const ComposeNoteSheet({super.key, required this.onSubmit});

  final void Function({
    required String content,
    required NoteSourceKind kind,
    Uri? linkedUri,
  })
  onSubmit;

  @override
  State<ComposeNoteSheet> createState() => _ComposeNoteSheetState();
}

class _ComposeNoteSheetState extends State<ComposeNoteSheet> {
  final TextEditingController _textController = TextEditingController();
  String? _validationError;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text?.trim();
    if (pasted == null || pasted.isEmpty || !mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _validationError = null;
      _textController.text = _textController.text.isEmpty
          ? pasted
          : '${_textController.text}\n$pasted';
    });
  }

  void _submit() {
    setState(() => _validationError = null);

    final body = _textController.text.trim();
    if (body.runes.length < 2) {
      setState(() {
        _validationError = 'Add at least 2 characters for your note.';
      });
      return;
    }

    HapticFeedback.mediumImpact();
    widget.onSubmit(content: body, kind: NoteSourceKind.typedOrPasted);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.edit_note_rounded,
                  color: WavelengthColors.phosphorCyan,
                  size: 24,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Add a text note to your wavelength',
                    style: WavelengthTypography.sheetTitle,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: WavelengthColors.secondaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            TextField(
              controller: _textController,
              minLines: 4,
              maxLines: 8,
              maxLength: 2400,
              style: WavelengthTypography.body,
              decoration: const InputDecoration(
                labelText: 'Your note',
                hintText: 'e.g. Exploring Cilium observability and GPU inference autoscaling…',
              ),
            ),

            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pasteFromClipboard,
                style: TextButton.styleFrom(
                  foregroundColor: WavelengthColors.phosphorIce,
                  minimumSize: const Size(48, 48),
                ),
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text(
                  'Paste clipboard',
                  style: TextStyle(fontSize: 14.0, fontWeight: FontWeight.w600),
                ),
              ),
            ),

            if (_validationError != null) ...[
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Text(
                  _validationError!,
                  style: WavelengthTypography.supporting.copyWith(
                    color: WavelengthColors.micHotCoral,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: WavelengthColors.phosphorBlue,
                  foregroundColor: WavelengthColors.onPhosphor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.radar_rounded, size: 20),
                label: const Text(
                  'Tune wavelength with note',
                  style: TextStyle(fontSize: 16.0, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the device settings sheet containing the persisted
/// **"Review before sending"** switch and optional node color-mode toggle.
Future<void> showWavelengthSettingsSheet({
  required BuildContext context,
  required bool reviewBeforeSending,
  required ValueChanged<bool> onChangedReviewBeforeSending,
  TopicColorMode colorMode = TopicColorMode.phosphorRadar,
  ValueChanged<TopicColorMode>? onChangedColorMode,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: WavelengthColors.elevated,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (ctx) => WavelengthSettingsSheet(
      reviewBeforeSending: reviewBeforeSending,
      onChangedReviewBeforeSending: onChangedReviewBeforeSending,
      colorMode: colorMode,
      onChangedColorMode: onChangedColorMode,
    ),
  );
}

/// Device settings sheet for ConFellow's `"Review before sending"` preference.
class WavelengthSettingsSheet extends StatefulWidget {
  const WavelengthSettingsSheet({
    super.key,
    required this.reviewBeforeSending,
    required this.onChangedReviewBeforeSending,
    this.colorMode = TopicColorMode.phosphorRadar,
    this.onChangedColorMode,
  });

  final bool reviewBeforeSending;
  final ValueChanged<bool> onChangedReviewBeforeSending;
  final TopicColorMode colorMode;
  final ValueChanged<TopicColorMode>? onChangedColorMode;

  @override
  State<WavelengthSettingsSheet> createState() =>
      _WavelengthSettingsSheetState();
}

class _WavelengthSettingsSheetState extends State<WavelengthSettingsSheet> {
  late bool _reviewBeforeSending;
  late TopicColorMode _colorMode;

  @override
  void initState() {
    super.initState();
    _reviewBeforeSending = widget.reviewBeforeSending;
    _colorMode = widget.colorMode;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                color: WavelengthColors.phosphorCyan,
                size: 22,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Note & Wavelength Settings',
                  style: WavelengthTypography.sheetTitle,
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const Icon(
                  Icons.close_rounded,
                  color: WavelengthColors.secondaryText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          PhosphorSurfaceCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _reviewBeforeSending,
                onChanged: (next) {
                  HapticFeedback.selectionClick();
                  setState(() => _reviewBeforeSending = next);
                  widget.onChangedReviewBeforeSending(next);
                },
                title: const Text(
                  'Review before sending',
                  style: WavelengthTypography.sectionTitle,
                ),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Off by default. When on, finished notes wait for you to tap Send or Discard instead of using the 5-second Undo card.',
                    style: WavelengthTypography.supporting,
                  ),
                ),
              ),
            ),
          ),

          if (widget.onChangedColorMode != null) ...[
            const SizedBox(height: 12),
            PhosphorSurfaceCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Constellation node colors',
                    style: WavelengthTypography.sectionTitle,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in TopicColorMode.values)
                        ChoiceChip(
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          selected: _colorMode == mode,
                          onSelected: (_) {
                            HapticFeedback.selectionClick();
                            setState(() => _colorMode = mode);
                            widget.onChangedColorMode!(mode);
                          },
                          label: Text(
                            mode.label,
                            style: WavelengthTypography.supporting.copyWith(
                              color: WavelengthColors.primaryText,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),
          const Text(
            'Speak your own notes · Audio stays on your phone. Realtime saving uploads private transcript text only after opt-in. Review and Undo control note submission; they do not delete private uploads. Other attendees see only matched topics unless you choose Share this note.',
            style: WavelengthTypography.supporting,
          ),
        ],
      ),
    );
  }
}
