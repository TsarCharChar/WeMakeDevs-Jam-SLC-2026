import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../cloud_sync_panel.dart';
import '../transcript_sync.dart';
import 'wavelength_theme.dart';

/// How a note was captured by the user.
enum NoteSourceKind {
  spoken,
  typedOrPasted;

  String get label => switch (this) {
    NoteSourceKind.spoken => 'Spoken note',
    NoteSourceKind.typedOrPasted => 'Typed note',
  };
}

/// Immutable payload representing one finished user note ready for the Undo
/// window or Review-before-sending decision, and then the backend seam.
@immutable
class CapturedNoteDraft {
  const CapturedNoteDraft({
    required this.noteId,
    required this.text,
    required this.sourceKind,
    required this.matchedTopics,
    required this.createdAt,
    this.shareNoteText = false,
    this.privateTranscriptSaving = false,
  });

  /// Maps 1-to-1 to `conversationId` (`one id per note`).
  final String noteId;
  final String text;
  final NoteSourceKind sourceKind;

  /// Strictly matched from bundled schedule tags — empty when nothing matches
  /// (never invented).
  final List<String> matchedTopics;
  final DateTime createdAt;

  /// Off by default: other attendees see only matched topics unless shared.
  final bool shareNoteText;

  /// True when separately opted-in realtime private transcript saving was active
  /// during recording; Undo or Discard does not retract already uploaded text.
  final bool privateTranscriptSaving;

  /// Primary status headline:
  /// - `"Tuned: Cilium · Security"` when schedule topics matched
  /// - `"Note saved"` when zero schedule topics matched
  String get cardHeadline {
    if (matchedTopics.isEmpty) return 'Note saved';
    final preview = matchedTopics.take(3).join(' · ');
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
      shareNoteText: shareNoteText ?? this.shareNoteText,
      privateTranscriptSaving: privateTranscriptSaving,
    );
  }
}

/// Coordinates the Undo / Review-before-sending window so nothing leaves the
/// phone prematurely and `Undo` genuinely cancels transmission.
class PendingNoteSendCoordinator extends ChangeNotifier {
  PendingNoteSendCoordinator({
    this.undoWindow = const Duration(seconds: 6),
    required this.onCommitSend,
    this.onPreviewApplied,
    this.onUndoReverted,
  });

  final Duration undoWindow;
  final FutureOr<void> Function(CapturedNoteDraft note) onCommitSend;
  final ValueChanged<CapturedNoteDraft>? onPreviewApplied;
  final ValueChanged<CapturedNoteDraft>? onUndoReverted;

  final List<CapturedNoteDraft> _deferredQueue = <CapturedNoteDraft>[];
  CapturedNoteDraft? _pending;
  Timer? _commitTimer;
  DateTime? _windowStartedAt;
  bool _reviewBeforeSending = false;
  bool _heldForReview = false;
  bool _disposed = false;

  CapturedNoteDraft? get pendingNote => _pending;
  bool get reviewBeforeSending => _reviewBeforeSending;
  bool get heldForReview => _heldForReview;
  bool get requiresManualAction => _reviewBeforeSending || _heldForReview;
  DateTime? get windowStartedAt => _windowStartedAt;

  set reviewBeforeSending(bool value) {
    if (_reviewBeforeSending == value) return;
    _reviewBeforeSending = value;
    if (value) {
      // Switching to manual review cancels any ticking auto-send timer.
      _commitTimer?.cancel();
      _commitTimer = null;
      _windowStartedAt = null;
    } else if (_pending != null && !_heldForReview) {
      // Switching manual review off starts the countdown for a fresh pending note.
      _startCountdownTimer();
    }
    _notify();
  }

  /// Holds the currently pending note for explicit `Send` / `Discard` review
  /// (called when the app lifecycle pauses/inactivates so a backgrounded note
  /// never auto-sends unseen).
  void holdForManualReview() {
    if (_pending == null) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    _windowStartedAt = null;
    _heldForReview = true;
    _notify();
  }

  /// Enqueues a newly finished note. If an earlier note was still pending,
  /// preserves it in [_deferredQueue] for manual review rather than sending it
  /// prematurely or overwriting it silently.
  void stageFinishedNote(CapturedNoteDraft draft) {
    if (_pending != null) {
      _commitTimer?.cancel();
      _commitTimer = null;
      _windowStartedAt = null;
      _deferredQueue.insert(0, _pending!);
    }

    _pending = draft;
    _heldForReview = false;
    onPreviewApplied?.call(draft);

    if (requiresManualAction) {
      _windowStartedAt = null;
    } else {
      _startCountdownTimer();
    }
    _notify();
  }

  void _startCountdownTimer() {
    _windowStartedAt = DateTime.now();
    _commitTimer?.cancel();
    _commitTimer = Timer(undoWindow, commitNow);
  }

  void setShareNoteText(bool share) {
    if (_pending == null) return;
    _pending = _pending!.copyWith(shareNoteText: share);
    _notify();
  }

  /// Cancels the pending note BEFORE any backend call and springs the map back.
  void undoOrDiscard() {
    final reverted = _pending;
    if (reverted == null) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    _windowStartedAt = null;
    _heldForReview = false;
    _pending = null;
    onUndoReverted?.call(reverted);
    _advanceDeferredQueue();
    _notify();
  }

  /// Sends the staged note immediately (either when the Undo window expires or
  /// when the user taps `Send`).
  void commitNow() {
    final ready = _pending;
    if (ready == null) return;
    _commitTimer?.cancel();
    _commitTimer = null;
    _windowStartedAt = null;
    _heldForReview = false;
    _pending = null;
    _advanceDeferredQueue();
    _notify();
    unawaited(Future<void>.sync(() => onCommitSend(ready)));
  }

  void _advanceDeferredQueue() {
    if (_deferredQueue.isEmpty) return;
    final next = _deferredQueue.removeAt(0);
    _pending = next;
    _heldForReview = true;
    _windowStartedAt = null;
    onPreviewApplied?.call(next);
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

/// Post-capture Tuned / Undo / Review card overlaid on the Note page wave.
///
/// - When [reviewBeforeSending] and [heldForReview] are `false` (default):
///   shows `"TUNED"` (or `"NOTE SAVED"`), matched topic chips, a compact
///   **"Share this note"** toggle, and an **`Undo`** pill with a circular
///   `#38BDF8` countdown ring.
/// - When [reviewBeforeSending] or [heldForReview] is `true`:
///   shows `"READY TO SEND"`, **`Discard`** and **`Send`** pills, sending
///   nothing until **`Send`** is tapped.
class NoteUndoReviewCard extends StatefulWidget {
  const NoteUndoReviewCard({
    super.key,
    required this.draft,
    required this.reviewBeforeSending,
    this.heldForReview = false,
    required this.onUndoOrDiscard,
    required this.onSendNow,
    required this.onToggleShareText,
    this.undoDuration = const Duration(seconds: 6),
    this.windowStartedAt,
    this.privateTranscriptSaving = false,
  });

  final CapturedNoteDraft draft;
  final bool reviewBeforeSending;
  final bool heldForReview;
  final VoidCallback onUndoOrDiscard;
  final VoidCallback onSendNow;
  final ValueChanged<bool> onToggleShareText;
  final Duration undoDuration;
  final DateTime? windowStartedAt;
  final bool privateTranscriptSaving;

  bool get manualReview => reviewBeforeSending || heldForReview;

  @override
  State<NoteUndoReviewCard> createState() => _NoteUndoReviewCardState();
}

class _NoteUndoReviewCardState extends State<NoteUndoReviewCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ringController;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: widget.undoDuration,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncCountdown();
  }

  @override
  void didUpdateWidget(covariant NoteUndoReviewCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draft.noteId != widget.draft.noteId ||
        oldWidget.manualReview != widget.manualReview ||
        oldWidget.undoDuration != widget.undoDuration ||
        oldWidget.windowStartedAt != widget.windowStartedAt) {
      _ringController.duration = widget.undoDuration;
      _syncCountdown();
    }
  }

  void _syncCountdown() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.manualReview || reduceMotion) {
      _ringController.stop();
      _ringController.value = 0.0;
      return;
    }
    final start = widget.windowStartedAt;
    if (start != null && widget.undoDuration.inMilliseconds > 0) {
      final elapsedMs = DateTime.now().difference(start).inMilliseconds;
      final frac = (elapsedMs / widget.undoDuration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      _ringController.forward(from: frac);
    } else {
      _ringController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final manual = widget.manualReview;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final headerLabel = manual
        ? 'READY TO SEND'
        : (draft.matchedTopics.isNotEmpty ? 'TUNED' : 'NOTE SAVED');

    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xF5101A28), Color(0xF5090E16)],
          ),
          border: Border.all(color: const Color(0xFF1F3A55)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x2E0EA5E9),
              blurRadius: 28,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          headerLabel,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14.0,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.5,
                            color: WavelengthColors.phosphorBlue,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (draft.matchedTopics.isNotEmpty)
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              for (final topic in draft.matchedTopics.take(3))
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: WavelengthColors.phosphorBlue
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(99),
                                    border: Border.all(
                                      color: WavelengthColors.phosphorBlue
                                          .withValues(alpha: 0.40),
                                    ),
                                  ),
                                  child: Text(
                                    topic,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14.0,
                                      fontWeight: FontWeight.w600,
                                      color: WavelengthColors.primaryText,
                                    ),
                                  ),
                                ),
                            ],
                          )
                        else
                          const Text(
                            'No schedule topics matched',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.0,
                              fontWeight: FontWeight.w500,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (!manual)
                    _UndoCountdownButton(
                      controller: _ringController,
                      reduceMotion: reduceMotion,
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onUndoOrDiscard();
                      },
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: <Widget>[
                        _ActionPillButton(
                          label: 'Discard',
                          primary: false,
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            widget.onUndoOrDiscard();
                          },
                        ),
                        _ActionPillButton(
                          label: 'Send',
                          primary: true,
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            widget.onSendNow();
                          },
                        ),
                      ],
                    ),
                ],
              ),
              if (widget.privateTranscriptSaving) ...<Widget>[
                const SizedBox(height: 6),
                const Text(
                  'Private transcript saving is separate. Undo or Discard does not delete uploaded text.',
                  style: TextStyle(
                    fontSize: 13.0,
                    fontWeight: FontWeight.w500,
                    color: WavelengthColors.secondaryText,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Semantics(
                button: true,
                toggled: draft.shareNoteText,
                label: 'Share this note',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onToggleShareText(!draft.shareNoteText);
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            draft.shareNoteText
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 18,
                            color: draft.shareNoteText
                                ? WavelengthColors.phosphorBlue
                                : WavelengthColors.mutedText,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              draft.shareNoteText
                                  ? 'Share this note · visible in matched spaces'
                                  : 'Share this note · off (private by default)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.0,
                                fontWeight: FontWeight.w500,
                                color: draft.shareNoteText
                                    ? WavelengthColors.primaryText
                                    : WavelengthColors.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UndoCountdownButton extends StatelessWidget {
  const _UndoCountdownButton({
    required this.controller,
    required this.reduceMotion,
    required this.onPressed,
  });

  final AnimationController controller;
  final bool reduceMotion;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Undo',
      child: Material(
        color: const Color(0xFF0A121C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
          side: const BorderSide(color: Color(0xFF2A4664)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 94),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 14, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: reduceMotion
                        ? const CustomPaint(
                            painter: _CountdownRingPainter(remaining: 0.65),
                          )
                        : AnimatedBuilder(
                            animation: controller,
                            builder: (context, _) => CustomPaint(
                              painter: _CountdownRingPainter(
                                remaining: (1.0 - controller.value).clamp(
                                  0.0,
                                  1.0,
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Undo',
                    style: TextStyle(
                      fontSize: 15.0,
                      fontWeight: FontWeight.w600,
                      color: WavelengthColors.primaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  const _CountdownRingPainter({required this.remaining});

  final double remaining;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const radius = 9.0;
    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..color = const Color(0xFF1F3A55);
    canvas.drawCircle(center, radius, trackPaint);

    if (remaining <= 0) return;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = WavelengthColors.phosphorBlue;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * remaining,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _CountdownRingPainter oldDelegate) =>
      oldDelegate.remaining != remaining;
}

class _ActionPillButton extends StatelessWidget {
  const _ActionPillButton({
    required this.label,
    required this.primary,
    required this.onPressed,
  });

  final String label;
  final bool primary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: primary
            ? WavelengthColors.phosphorBlue
            : const Color(0xFF0A121C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
          side: BorderSide(
            color: primary
                ? WavelengthColors.phosphorBlue
                : const Color(0xFF2A4664),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 68),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15.0,
                    fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
                    color: primary
                        ? const Color(0xFF04121C)
                        : WavelengthColors.primaryText,
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

/// Opens the dark bottom sheet for typing or pasting a text note.
Future<void> showComposeNoteSheet({
  required BuildContext context,
  required void Function({
    required String content,
    required NoteSourceKind kind,
  })
  onSubmit,
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

/// Sleek dark phosphor sheet supporting typed or pasted text notes.
class ComposeNoteSheet extends StatefulWidget {
  const ComposeNoteSheet({super.key, required this.onSubmit});

  final void Function({
    required String content,
    required NoteSourceKind kind,
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
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.keyboard_alt_outlined,
                  color: WavelengthColors.phosphorBlue,
                  size: 24,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Type a note',
                    style: WavelengthTypography.sheetTitle,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Close',
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
              autofocus: true,
              minLines: 4,
              maxLines: 8,
              maxLength: 2400,
              style: WavelengthTypography.body,
              decoration: const InputDecoration(
                labelText: 'Your note',
                hintText:
                    'e.g. Exploring Cilium observability and GPU inference autoscaling…',
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
                  style: TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (_validationError != null) ...<Widget>[
              const SizedBox(height: 6),
              Semantics(
                liveRegion: true,
                child: Text(
                  _validationError!,
                  style: WavelengthTypography.supporting.copyWith(
                    color: WavelengthColors.warningAmber,
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
/// **"Review before sending"** switch and **"Saved transcripts"** history link.
Future<void> showWavelengthSettingsSheet({
  required BuildContext context,
  required bool reviewBeforeSending,
  required ValueChanged<bool> onChangedReviewBeforeSending,
  TranscriptSync? sync,
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
      sync: sync,
    ),
  );
}

/// Device settings sheet for ConFellow's `"Review before sending"` preference
/// and access to private `"Saved transcripts"` history.
class WavelengthSettingsSheet extends StatefulWidget {
  const WavelengthSettingsSheet({
    super.key,
    required this.reviewBeforeSending,
    required this.onChangedReviewBeforeSending,
    this.sync,
  });

  final bool reviewBeforeSending;
  final ValueChanged<bool> onChangedReviewBeforeSending;
  final TranscriptSync? sync;

  @override
  State<WavelengthSettingsSheet> createState() =>
      _WavelengthSettingsSheetState();
}

class _WavelengthSettingsSheetState extends State<WavelengthSettingsSheet> {
  late bool _reviewBeforeSending;

  @override
  void initState() {
    super.initState();
    _reviewBeforeSending = widget.reviewBeforeSending;
  }

  @override
  Widget build(BuildContext context) {
    final sync = widget.sync;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.tune_rounded,
                color: WavelengthColors.phosphorBlue,
                size: 22,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Settings',
                  style: WavelengthTypography.sheetTitle,
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: 'Close',
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
                    'Off by default. When on, finished notes wait for you to tap Send or Discard instead of using the Undo countdown.',
                    style: WavelengthTypography.supporting,
                  ),
                ),
              ),
            ),
          ),
          if (sync != null) ...<Widget>[
            const SizedBox(height: 12),
            PhosphorSurfaceCard(
              padding: EdgeInsets.zero,
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  minVerticalPadding: 14,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(
                    Icons.history_rounded,
                    color: WavelengthColors.phosphorBlue,
                  ),
                  title: const Text(
                    'Saved transcripts',
                    style: WavelengthTypography.sectionTitle,
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      'Private transcript history for this phone',
                      style: WavelengthTypography.supporting,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: WavelengthColors.secondaryText,
                  ),
                  onTap: () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.push(
                      MaterialPageRoute<void>(
                        builder: (_) => TranscriptHistoryScreen(sync: sync),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Audio stays on your phone.\nYour note\'s text is saved to your profile.',
            style: WavelengthTypography.supporting,
          ),
          const SizedBox(height: 6),
          Text(
            'Other attendees see only matched topics unless you choose Share this note.',
            style: WavelengthTypography.supporting.copyWith(
              color: WavelengthColors.mutedText,
            ),
          ),
        ],
      ),
    );
  }
}
