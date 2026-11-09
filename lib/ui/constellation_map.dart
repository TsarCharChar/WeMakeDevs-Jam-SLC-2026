import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pcm_level_helper.dart';
import 'wavelength_theme.dart';

/// Maximum nodes shown on the hero constellation map to guarantee legibility
/// and >= 48x48 dp non-overlapping tap targets (overflow belongs in the list below).
const int kMaxConstellationNodes = 8;

/// Maximum single-note recording duration enforced by `RecordingController`.
const Duration kMaxNoteRecordingDuration = Duration(minutes: 3);

/// Summary of an attendee note attached to a Space.
///
/// Enforces privacy at the model layer: [displayableText] returns `null` unless
/// [isShared] or [isDemo] is `true`.
@immutable
class SharedNotePreview {
  const SharedNotePreview({
    required this.id,
    this.topics = const [],
    this.why,
    String? sharedText,
    this.isShared = false,
    this.isDemo = false,
  }) : _sharedText = (isShared || isDemo) ? sharedText : null;

  final String id;
  final List<String> topics;
  final String? why;
  final String? _sharedText;
  final bool isShared;
  final bool isDemo;

  /// Never exposes note text unless explicitly shared or flagged as the
  /// synthetic `__setup_smoke__` demo document.
  String? get displayableText => (isShared || isDemo) ? _sharedText : null;
}

/// A Scheduled Talk or Topic Space positioned on the ConFellow Constellation Map.
///
/// Nodes never represent individual people or `@handles`.
@immutable
class ConstellationNode {
  const ConstellationNode({
    required this.id,
    required this.kind,
    required this.ring,
    required this.title,
    required this.whyOnWavelength,
    String? shortLabel,
    this.matchedTopics = const [],
    this.attendeeCount = 0,
    this.recentActivityLabel,
    this.room,
    this.timeSlot,
    this.abstractText,
    this.isGoing = false,
    this.movedCloser = false,
    this.sharedNotes = const [],
    this.angleSeedRadians,
  }) : shortLabel = shortLabel ?? title;

  final String id;
  final SpaceKind kind;
  final ClosenessRing ring;
  final String title;
  final String shortLabel;

  /// Human-language explanation of why this Space matches (never `%` or `"nearby"`).
  final String whyOnWavelength;
  final List<String> matchedTopics;

  /// Count of people tuned in (never `@handles` until room chat exists).
  final int attendeeCount;

  /// Optional recency copy such as `"3 notes in the last 10 minutes"`.
  final String? recentActivityLabel;

  // --- Scheduled Talk metadata (when kind == SpaceKind.talk) ---
  final String? room;
  final String? timeSlot;
  final String? abstractText;
  final bool isGoing;

  /// Highlighted briefly when a newly captured note pulls this Space inward.
  final bool movedCloser;

  final List<SharedNotePreview> sharedNotes;
  final double? angleSeedRadians;

  String get compactMapLabel {
    final trimmed = shortLabel.trim();
    if (trimmed.runes.length <= 20) return trimmed;
    return '${String.fromCharCodes(trimmed.runes.take(19))}…';
  }

  String get tunedPeopleCopy => switch (attendeeCount) {
    <= 0 => 'Open wavelength · tune in first',
    1 => '1 person tuned in',
    final n => '$n people tuned in',
  };

  ConstellationNode copyWith({
    ClosenessRing? ring,
    String? whyOnWavelength,
    List<String>? matchedTopics,
    int? attendeeCount,
    String? recentActivityLabel,
    bool? isGoing,
    bool? movedCloser,
    List<SharedNotePreview>? sharedNotes,
  }) {
    return ConstellationNode(
      id: id,
      kind: kind,
      ring: ring ?? this.ring,
      title: title,
      shortLabel: shortLabel,
      whyOnWavelength: whyOnWavelength ?? this.whyOnWavelength,
      matchedTopics: matchedTopics ?? this.matchedTopics,
      attendeeCount: attendeeCount ?? this.attendeeCount,
      recentActivityLabel: recentActivityLabel ?? this.recentActivityLabel,
      room: room,
      timeSlot: timeSlot,
      abstractText: abstractText,
      isGoing: isGoing ?? this.isGoing,
      movedCloser: movedCloser ?? this.movedCloser,
      sharedNotes: sharedNotes ?? this.sharedNotes,
      angleSeedRadians: angleSeedRadians,
    );
  }
}

/// Full-width Black + Blue Phosphor Radar Constellation Hero (`>= 50%` screen height).
///
/// Features:
/// - Outer compass degree ring + rotating conical Blue Phosphor radar sweep
///   that flares each node's halo as the beam passes over its bearing.
/// - Tactile press wave impulse & outward tuned resonance ripple.
/// - Live mic-reactive harmonic sine undulations across all concentric rings
///   plus a 24-bar radial Coral (`#FF7A59`) waveform & 3-minute countdown arc
///   around the `YOU` center node while recording.
/// - Caps displayed nodes at 8, renders text labels ONLY on inner-ring nodes
///   and the selected node, and provides real `>= 48x48 dp` `Positioned`
///   `Semantics` + `GestureDetector` targets over `CustomPaint`.
class ConstellationMap extends StatefulWidget {
  const ConstellationMap({
    super.key,
    required this.nodes,
    this.selectedNodeId,
    this.onSelectNode,
    this.onTapCenter,
    this.activeUserTopics = const [],
    this.colorMode = TopicColorMode.phosphorRadar,
    this.isRecording = false,
    this.micLevel = 0.0,
    this.micBars,
    this.pcmMeter,
    this.recordingElapsed,
    this.pressImpulseTrigger = 0,
    this.tuneRippleTrigger = 0,
    this.radarSweepTrigger = 0,
    this.enableAmbientSweep = true,
    this.minScreenHeightFraction = 0.52,
  });

  final List<ConstellationNode> nodes;
  final String? selectedNodeId;
  final ValueChanged<ConstellationNode>? onSelectNode;
  final VoidCallback? onTapCenter;
  final List<String> activeUserTopics;
  final TopicColorMode colorMode;

  // --- Live Recording State ---
  final bool isRecording;
  final double micLevel;
  final List<double>? micBars;
  final PcmLevelMeter? pcmMeter;
  final Duration? recordingElapsed;

  // --- Monotonic Trigger Counters for One-Shot Waves & Sweeps ---
  /// Increment when the user presses the Record button to fire a fast tactile
  /// shockwave impulse from the center outward.
  final int pressImpulseTrigger;

  /// Increment when a note is captured/tuned or a topic chip is tapped to emit
  /// a dual-ring phosphor resonance wave.
  final int tuneRippleTrigger;

  /// Increment when "Find my wavelength" or topic search triggers an active
  /// conical radar scan across the constellation.
  final int radarSweepTrigger;

  /// Enables a calm ambient compass rotation when idle (honoring reduce-motion).
  final bool enableAmbientSweep;

  /// Minimum fraction of viewport height (`>= 0.50` hero floor).
  final double minScreenHeightFraction;

  @override
  State<ConstellationMap> createState() => _ConstellationMapState();
}

class _ConstellationMapState extends State<ConstellationMap>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _loopController;
  final PcmLevelMeter _fallbackMeter = PcmLevelMeter();
  final Stopwatch _recordingStopwatch = Stopwatch();

  bool _appActive = true;

  // Smooth radial transitions when nodes re-rank or Undo springs them back.
  final Map<String, double> _animatedRadiusFactors = <String, double>{};
  final Map<String, double> _fromRadiusFactors = <String, double>{};
  final Map<String, double> _targetRadiusFactors = <String, double>{};
  double _ringTransitionStartSec = 0.0;

  double? _pressImpulseStartSec;
  double? _tuneRippleStartSec;
  double? _activeSweepStartSec;

  double get _nowSec =>
      (_loopController.lastElapsedDuration?.inMicroseconds ?? 0) / 1e6;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    )..addListener(_onTick);

    if (widget.isRecording) {
      _recordingStopwatch.start();
    }
    _syncNodeTargets(snapImmediately: true);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTickerState();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTickerState();
  }

  @override
  void didUpdateWidget(covariant ConstellationMap oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isRecording && !oldWidget.isRecording) {
      _recordingStopwatch
        ..reset()
        ..start();
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _recordingStopwatch.stop();
    }

    if (widget.pressImpulseTrigger != oldWidget.pressImpulseTrigger) {
      _ensureRunningForOneShot();
      _pressImpulseStartSec = _nowSec;
    }

    if (widget.tuneRippleTrigger != oldWidget.tuneRippleTrigger) {
      _ensureRunningForOneShot();
      _tuneRippleStartSec = _nowSec;
      HapticFeedback.mediumImpact();
    }

    if (widget.radarSweepTrigger != oldWidget.radarSweepTrigger) {
      _ensureRunningForOneShot();
      _activeSweepStartSec = _nowSec;
    }

    _syncNodeTargets(snapImmediately: false);
    _syncTickerState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncTickerState();
  }

  void _ensureRunningForOneShot() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_appActive && !reduceMotion && !_loopController.isAnimating) {
      _loopController.repeat();
    }
  }

  void _syncTickerState() {
    if (!mounted) return;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldAnimate = _appActive && !reduceMotion;
    if (shouldAnimate && !_loopController.isAnimating) {
      _loopController.repeat();
    } else if (!shouldAnimate && _loopController.isAnimating) {
      _loopController.stop(canceled: false);
    }
  }

  void _syncNodeTargets({required bool snapImmediately}) {
    final capped = _prioritizedNodes(widget.nodes);
    final reduceMotion =
        !snapImmediately &&
        mounted &&
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    var anyChanged = false;

    for (final node in capped) {
      final target = node.ring.radiusFactor;
      final current = _animatedRadiusFactors[node.id];
      if (snapImmediately || reduceMotion || current == null) {
        _animatedRadiusFactors[node.id] = target;
        _fromRadiusFactors[node.id] = target;
        _targetRadiusFactors[node.id] = target;
      } else if ((_targetRadiusFactors[node.id] ?? current) != target) {
        _fromRadiusFactors[node.id] = current;
        _targetRadiusFactors[node.id] = target;
        anyChanged = true;
      }
    }

    if (anyChanged) {
      _ringTransitionStartSec = _nowSec;
    }
  }

  void _onTick() {
    final tSec = _nowSec;
    const springDuration = 0.68;
    for (final entry in _targetRadiusFactors.entries) {
      final id = entry.key;
      final to = entry.value;
      final from = _fromRadiusFactors[id] ?? to;
      if ((from - to).abs() < 0.0005) {
        _animatedRadiusFactors[id] = to;
        continue;
      }
      final raw = ((tSec - _ringTransitionStartSec) / springDuration).clamp(
        0.0,
        1.0,
      );
      final eased = Curves.easeOutBack.transform(raw);
      _animatedRadiusFactors[id] = lerpDouble(from, to, eased) ?? to;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loopController.dispose();
    super.dispose();
  }

  List<ConstellationNode> _prioritizedNodes(List<ConstellationNode> all) {
    final sorted = List<ConstellationNode>.of(all)
      ..sort((a, b) => a.ring.index.compareTo(b.ring.index));
    if (sorted.length <= kMaxConstellationNodes) return sorted;
    return sorted.sublist(0, kMaxConstellationNodes);
  }

  /// Computes well-separated polar angles per closeness ring so 48x48 dp node
  /// tap targets never collide even with 8 visible nodes.
  List<_PlacedNode> _computeNodePlacements({
    required List<ConstellationNode> visibleNodes,
    required Size canvasSize,
    required double timeSec,
    required bool reduceMotion,
  }) {
    final center = Offset(canvasSize.width * 0.5, canvasSize.height * 0.5);
    final usableRadius =
        math.min(canvasSize.width, canvasSize.height) * 0.5 - 38.0;
    final clampedRadius = math.max(92.0, usableRadius);

    // Group indices by ring so nodes on the same ring maintain clean spacing.
    final byRing = <ClosenessRing, List<ConstellationNode>>{
      ClosenessRing.inner: <ConstellationNode>[],
      ClosenessRing.middle: <ConstellationNode>[],
      ClosenessRing.outer: <ConstellationNode>[],
    };
    for (final node in visibleNodes) {
      byRing[node.ring]!.add(node);
    }

    final placements = <_PlacedNode>[];
    for (final ring in ClosenessRing.values) {
      final group = byRing[ring]!;
      if (group.isEmpty) continue;

      // Offset starting angle per ring so spokes stagger cleanly across rings.
      final ringPhaseOffset = switch (ring) {
        ClosenessRing.inner => -math.pi * 0.36,
        ClosenessRing.middle => math.pi * 0.14,
        ClosenessRing.outer => -math.pi * 0.72,
      };
      final ringDriftSpeed = switch (ring) {
        ClosenessRing.inner => 0.032,
        ClosenessRing.middle => -0.022,
        ClosenessRing.outer => 0.015,
      };

      for (var i = 0; i < group.length; i++) {
        final node = group[i];
        final baseSlotAngle =
            ringPhaseOffset + (2.0 * math.pi * i) / group.length;
        // Subtle deterministic jitter within 18% of slot width for organic star feel
        final hashJitter =
            (((node.id.hashCode & 0xFFFF) / 0xFFFF) - 0.5) *
            (math.pi / math.max(3, group.length)) *
            0.34;
        final baseAngle = node.angleSeedRadians ?? (baseSlotAngle + hashJitter);
        final drift = reduceMotion
            ? 0.0
            : timeSec * ringDriftSpeed +
                  0.028 * math.sin(timeSec * 0.45 + i * 1.7);
        final angle = baseAngle + drift;

        final rFactor =
            _animatedRadiusFactors[node.id] ?? node.ring.radiusFactor;
        final r = clampedRadius * rFactor;
        final pos = Offset(
          center.dx + r * math.cos(angle),
          center.dy + r * math.sin(angle),
        );

        final isSelected = node.id == widget.selectedNodeId;
        final showLabel = node.ring == ClosenessRing.inner || isSelected;

        placements.add(
          _PlacedNode(
            node: node,
            position: pos,
            polarAngle: angle,
            radiusPx: r,
            isSelected: isSelected,
            showLabel: showLabel,
          ),
        );
      }
    }
    return placements;
  }

  double? _currentSweepAngle(double timeSec, bool reduceMotion) {
    // 1. Active multi-revolution tuning sweep (2 full rotations over 2.4s):
    if (_activeSweepStartSec != null) {
      final elapsed = timeSec - _activeSweepStartSec!;
      const activeDuration = 2.4;
      if (elapsed >= 0.0 && elapsed <= activeDuration) {
        final progress = Curves.easeInOutCubic.transform(
          (elapsed / activeDuration).clamp(0.0, 1.0),
        );
        return -math.pi * 0.5 + progress * math.pi * 4.0;
      }
    }
    // 2. Calm ambient radar compass rotation (1 revolution every 22s):
    if (widget.enableAmbientSweep && !reduceMotion) {
      return -math.pi * 0.5 + (timeSec * (2.0 * math.pi / 22.0));
    }
    return null;
  }

  bool _isActiveSweepBoost(double timeSec) {
    if (_activeSweepStartSec == null) return false;
    final elapsed = timeSec - _activeSweepStartSec!;
    return elapsed >= 0.0 && elapsed <= 2.4;
  }

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final minHeroHeight = math.max(
      350.0,
      viewportHeight * widget.minScreenHeightFraction,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final timeSec = _nowSec;

    final meter = widget.pcmMeter ?? _fallbackMeter;
    final effectiveMic = meter.effectiveLevel(
      isRecording: widget.isRecording,
      phaseSeconds: timeSec,
      overrideLevel: widget.micLevel > 0 ? widget.micLevel : null,
      reduceMotion: reduceMotion,
    );
    final effectiveBars = meter.effectiveBars(
      isRecording: widget.isRecording,
      phaseSeconds: timeSec,
      overrideLevel: widget.micLevel > 0 ? widget.micLevel : null,
      overrideBars: widget.micBars,
      reduceMotion: reduceMotion,
    );

    final elapsedRec = widget.recordingElapsed ?? _recordingStopwatch.elapsed;
    final recordingProgress = widget.isRecording
        ? (elapsedRec.inMilliseconds / kMaxNoteRecordingDuration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    final pressWaveProgress = _progressOrNull(
      startSec: _pressImpulseStartSec,
      nowSec: timeSec,
      durationSec: 0.72,
    );
    final tuneRippleProgress = _progressOrNull(
      startSec: _tuneRippleStartSec,
      nowSec: timeSec,
      durationSec: 1.15,
    );
    final sweepAngle = _currentSweepAngle(timeSec, reduceMotion);
    final sweepBoost = _isActiveSweepBoost(timeSec);

    final visibleNodes = _prioritizedNodes(widget.nodes);
    final centerColor = WavelengthPaletteResolver.centerWavelengthColor(
      activeTopics: widget.activeUserTopics,
      mode: widget.colorMode,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final height = constraints.maxHeight.isFinite
            ? math.max(280.0, constraints.maxHeight)
            : minHeroHeight;
        final canvasSize = Size(width, height);
        final center = Offset(width * 0.5, height * 0.5);

        final placements = _computeNodePlacements(
          visibleNodes: visibleNodes,
          canvasSize: canvasSize,
          timeSec: timeSec,
          reduceMotion: reduceMotion,
        );

        return Semantics(
          container: true,
          label:
              'Wavelength radar constellation map showing ${placements.length} spaces',
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // 1. Phosphor Radar Canvas (starry dust, compass ring,
                  //    harmonic rings, conical radar sweep, node blips & YOU core)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ConstellationRadarPainter(
                        placements: placements,
                        colorMode: widget.colorMode,
                        centerColor: centerColor,
                        isRecording: widget.isRecording,
                        micEnergy: effectiveMic,
                        micBars: effectiveBars,
                        recordingProgress: recordingProgress,
                        timeSec: timeSec,
                        reduceMotion: reduceMotion,
                        sweepAngle: sweepAngle,
                        sweepBoost: sweepBoost,
                        pressWaveProgress: pressWaveProgress,
                        tuneRippleProgress: tuneRippleProgress,
                      ),
                    ),
                  ),

                  // 2. Subtle top-left ring legend pill (14sp floor, high contrast)
                  Positioned(
                    top: 10,
                    left: 14,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: WavelengthColors.surface.withValues(
                            alpha: 0.84,
                          ),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: WavelengthColors.borderSpecular,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SpaceShapeBadge(
                              kind: SpaceKind.talk,
                              size: 16,
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              'Talk',
                              style: WavelengthTypography.supporting,
                            ),
                            const SizedBox(width: 10),
                            const SpaceShapeBadge(
                              kind: SpaceKind.topic,
                              size: 16,
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              'Topic',
                              style: WavelengthTypography.supporting,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 3. Non-colliding Floating Pill Labels (ONLY inner ring & selected)
                  for (final placed in placements)
                    if (placed.showLabel)
                      _buildNodePillLabel(
                        placed: placed,
                        canvasSize: canvasSize,
                        center: center,
                      ),

                  // 4. Center `YOU` >= 56x56 dp Accessible Tap Target
                  Positioned(
                    left: center.dx - 28,
                    top: center.dy - 28,
                    width: 56,
                    height: 56,
                    child: Semantics(
                      button: widget.onTapCenter != null,
                      label: widget.isRecording
                          ? 'You, recording a note right now'
                          : 'You, at the center of your wavelength',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onTapCenter,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),

                  // 5. Individual >= 48x48 dp Accessible Node Tap Targets
                  for (final placed in placements)
                    Positioned(
                      left: placed.position.dx - 24,
                      top: placed.position.dy - 24,
                      width: 48,
                      height: 48,
                      child: Semantics(
                        button: true,
                        selected: placed.isSelected,
                        label:
                            '${placed.node.kind.badgeLabel}: ${placed.node.title}. '
                            '${placed.node.ring.humanLabel}. '
                            '${placed.node.tunedPeopleCopy}.',
                        hint: 'Opens space details',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            widget.onSelectNode?.call(placed.node);
                          },
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNodePillLabel({
    required _PlacedNode placed,
    required Size canvasSize,
    required Offset center,
  }) {
    // Place label radially outward from `YOU` so it never crosses the center!
    final placeAbove = placed.position.dy <= center.dy;
    const maxPillWidth = 156.0;
    final clampedLeft = (placed.position.dx - maxPillWidth * 0.5)
        .clamp(8.0, math.max(8.0, canvasSize.width - maxPillWidth - 8.0))
        .toDouble();
    final rawTop = placeAbove
        ? placed.position.dy - 40.0
        : placed.position.dy + 16.0;
    final clampedTop = rawTop
        .clamp(8.0, math.max(8.0, canvasSize.height - 34.0))
        .toDouble();

    final rimColor = placed.isSelected
        ? WavelengthColors.phosphorCyan
        : placed.node.movedCloser
        ? WavelengthColors.phosphorBlue
        : WavelengthColors.borderSpecular;

    return Positioned(
      left: clampedLeft,
      top: clampedTop,
      width: maxPillWidth,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: WavelengthColors.canvas.withValues(alpha: 0.90),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: rimColor,
                width: placed.isSelected ? 1.4 : 1.0,
              ),
            ),
            child: Text(
              placed.node.compactMapLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: WavelengthTypography.mapNodeLabel.copyWith(
                color: placed.isSelected
                    ? WavelengthColors.brandWhite
                    : WavelengthColors.primaryText,
              ),
            ),
          ),
        ),
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

class _PlacedNode {
  const _PlacedNode({
    required this.node,
    required this.position,
    required this.polarAngle,
    required this.radiusPx,
    required this.isSelected,
    required this.showLabel,
  });

  final ConstellationNode node;
  final Offset position;
  final double polarAngle;
  final double radiusPx;
  final bool isSelected;
  final bool showLabel;
}

class _ConstellationRadarPainter extends CustomPainter {
  const _ConstellationRadarPainter({
    required this.placements,
    required this.colorMode,
    required this.centerColor,
    required this.isRecording,
    required this.micEnergy,
    required this.micBars,
    required this.recordingProgress,
    required this.timeSec,
    required this.reduceMotion,
    required this.sweepAngle,
    required this.sweepBoost,
    required this.pressWaveProgress,
    required this.tuneRippleProgress,
  });

  final List<_PlacedNode> placements;
  final TopicColorMode colorMode;
  final Color centerColor;
  final bool isRecording;
  final double micEnergy;
  final List<double> micBars;
  final double recordingProgress;
  final double timeSec;
  final bool reduceMotion;
  final double? sweepAngle;
  final bool sweepBoost;
  final double? pressWaveProgress;
  final double? tuneRippleProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final maxRadius = math.max(
      92.0,
      math.min(size.width, size.height) * 0.5 - 38.0,
    );

    // 1. Deep Obsidian/Pitch-Black CRT Phosphor Radial Field
    final bgGlowColor = isRecording
        ? WavelengthColors.micHotCoral
        : WavelengthColors.phosphorAfterglow;
    final bgRect = Offset.zero & size;
    canvas.drawRect(
      bgRect,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                bgGlowColor.withValues(alpha: isRecording ? 0.16 : 0.22),
                WavelengthColors.phosphorBloom.withValues(alpha: 0.05),
                WavelengthColors.canvas,
              ],
              stops: const [0.0, 0.48, 1.0],
            ).createShader(
              Rect.fromCircle(center: center, radius: maxRadius * 1.15),
            ),
    );

    // 2. Subtle Starry Dust Field (deterministic coordinates, zero allocations)
    _paintStarDust(canvas, size);

    // 3. Outer Compass Degree Ring & Precision Ticks
    _paintCompassPerimeter(canvas, center, maxRadius * 0.985);

    // 4. Conical Rotating Radar / Compass Sweep Sector
    if (sweepAngle != null) {
      _paintRadarSweep(canvas, center, maxRadius * 0.96, sweepAngle!);
    }

    // 5. Concentric Closeness Rings (deformed by smooth harmonic sine waves
    //    when mic is live!)
    _paintClosenessRings(canvas, center, maxRadius);

    // 6. Tactile Press Impulse & Tuned Outward Resonance Waves
    if (pressWaveProgress != null) {
      _paintExpandingWave(
        canvas: canvas,
        center: center,
        maxRadius: maxRadius,
        progress: pressWaveProgress!,
        color: isRecording
            ? WavelengthColors.micHotCoral
            : WavelengthColors.phosphorCyan,
        strokeWidth: 2.6,
      );
    }
    if (tuneRippleProgress != null) {
      _paintExpandingWave(
        canvas: canvas,
        center: center,
        maxRadius: maxRadius,
        progress: tuneRippleProgress!,
        color: WavelengthColors.phosphorCyan,
        strokeWidth: 2.8,
      );
      final trailing = (tuneRippleProgress! - 0.18).clamp(0.0, 1.0);
      if (tuneRippleProgress! > 0.18) {
        _paintExpandingWave(
          canvas: canvas,
          center: center,
          maxRadius: maxRadius,
          progress: trailing,
          color: WavelengthColors.phosphorBlue,
          strokeWidth: 1.6,
        );
      }
    }

    // 7. Space Nodes (4-point diamond/star for Talks, circular blip for Topics)
    //    with radar-sweep angular pass flare!
    for (final placed in placements) {
      _paintSpaceNode(canvas, placed);
    }

    // 8. Center `YOU` Node (glowing Blue Phosphor core when idle; live 24-bar
    //    Coral radial waveform + 3-minute progress arc when recording!)
    _paintCenterYouNode(canvas, center);
  }

  void _paintStarDust(Canvas canvas, Size size) {
    final starPaint = Paint()..style = PaintingStyle.fill;
    const starCount = 34;
    for (var i = 0; i < starCount; i++) {
      // Halton-like low-discrepancy sequence across the viewport
      final fx = ((i * 0.61803398875) % 1.0);
      final fy = ((i * 0.38196601125 + (i % 7) * 0.142857) % 1.0);
      final pt = Offset(fx * size.width, fy * size.height);
      final twinkle = reduceMotion
          ? 0.30
          : 0.18 + 0.20 * (0.5 + 0.5 * math.sin(timeSec * 0.9 + i * 2.1));
      final r = (i % 4 == 0) ? 1.35 : 0.95;
      starPaint.color =
          (i % 3 == 0
                  ? WavelengthColors.phosphorIce
                  : WavelengthColors.primaryText)
              .withValues(alpha: twinkle);
      canvas.drawCircle(pt, r, starPaint);
    }
  }

  void _paintCompassPerimeter(Canvas canvas, Offset center, double compassR) {
    // Subtle outer instrument bezel circle
    canvas.drawCircle(
      center,
      compassR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = WavelengthColors.outerRing,
    );

    final majorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = WavelengthColors.compassTickMajor;

    final minorPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round
      ..color = WavelengthColors.compassTickMinor;

    // 72 degree ticks (every 5 degrees)
    for (var deg = 0; deg < 360; deg += 5) {
      final rad = deg * math.pi / 180.0;
      final isCardinal = deg % 90 == 0;
      final isMajor = deg % 30 == 0;
      final tickLen = isCardinal
          ? 8.5
          : isMajor
          ? 5.5
          : 2.8;
      final pOuter = Offset(
        center.dx + compassR * math.cos(rad),
        center.dy + compassR * math.sin(rad),
      );
      final pInner = Offset(
        center.dx + (compassR - tickLen) * math.cos(rad),
        center.dy + (compassR - tickLen) * math.sin(rad),
      );
      canvas.drawLine(pInner, pOuter, isMajor ? majorPaint : minorPaint);
    }
  }

  void _paintRadarSweep(
    Canvas canvas,
    Offset center,
    double radius,
    double beamAngle,
  ) {
    const sectorSpan = math.pi * 0.34; // ~61 degree phosphor afterglow trail
    final peakAlpha = sweepBoost ? 0.34 : 0.14;
    final midAlpha = sweepBoost ? 0.14 : 0.05;

    final rect = Rect.fromCircle(center: center, radius: radius);
    final sweepShader = SweepGradient(
      startAngle: 0.0,
      endAngle: math.pi * 2.0,
      colors: [
        WavelengthColors.phosphorBlue.withValues(alpha: 0.0),
        WavelengthColors.phosphorBloom.withValues(alpha: midAlpha),
        WavelengthColors.phosphorCyan.withValues(alpha: peakAlpha),
      ],
      stops: const [0.0, 1.0 - (sectorSpan / (math.pi * 2.0)) * 0.55, 1.0],
      transform: GradientRotation(beamAngle),
    ).createShader(rect);

    final sectorPath = Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(rect, beamAngle - sectorSpan, sectorSpan, false)
      ..close();

    canvas.drawPath(sectorPath, Paint()..shader = sweepShader);

    // Crisp leading phosphor beam line
    final beamEnd = Offset(
      center.dx + radius * math.cos(beamAngle),
      center.dy + radius * math.sin(beamAngle),
    );
    canvas.drawLine(
      center,
      beamEnd,
      Paint()
        ..strokeWidth = sweepBoost ? 1.8 : 1.1
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            WavelengthColors.phosphorCyan.withValues(alpha: 0.05),
            WavelengthColors.phosphorIce.withValues(
              alpha: sweepBoost ? 0.85 : 0.38,
            ),
          ],
        ).createShader(Rect.fromPoints(center, beamEnd)),
    );
  }

  void _paintClosenessRings(Canvas canvas, Offset center, double maxRadius) {
    final ringConfigs = <(ClosenessRing, Color, double)>[
      // Inner ring sits at 3.73:1 WCAG contrast against `#04060A`!
      (ClosenessRing.inner, WavelengthColors.innerRing, 1.65),
      (ClosenessRing.middle, WavelengthColors.middleRing, 1.25),
      (ClosenessRing.outer, WavelengthColors.outerRing, 1.10),
    ];

    for (final (ring, baseColor, strokeW) in ringConfigs) {
      final baseR = maxRadius * ring.radiusFactor;

      // Soft inner phosphor bloom on the inner ring
      if (ring == ClosenessRing.inner) {
        canvas.drawCircle(
          center,
          baseR,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5.0
            ..color =
                (isRecording
                        ? WavelengthColors.micHotCoral
                        : WavelengthColors.phosphorBloom)
                    .withValues(
                      alpha: isRecording ? 0.14 + micEnergy * 0.18 : 0.10,
                    ),
        );
      }

      final activeColor = isRecording
          ? (Color.lerp(
                  baseColor,
                  ring == ClosenessRing.inner
                      ? WavelengthColors.micHotCoral
                      : WavelengthColors.phosphorCyan,
                  (0.25 + micEnergy * 0.65).clamp(0.0, 0.9),
                ) ??
                baseColor)
          : baseColor;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW + (isRecording ? micEnergy * 0.9 : 0.0)
        ..color = activeColor;

      if (!isRecording || reduceMotion || micEnergy <= 0.005) {
        canvas.drawCircle(center, baseR, paint);
      } else {
        // Harmonic acoustic sine-wave undulations driven by live mic energy!
        const segments = 108;
        final path = Path();
        final ringScale = switch (ring) {
          ClosenessRing.inner => 1.0,
          ClosenessRing.middle => 0.75,
          ClosenessRing.outer => 0.50,
        };
        final ampPx = (3.0 + micEnergy * 11.5) * ringScale;
        final ringPhaseShift = ring.index * 0.95;

        for (var s = 0; s <= segments; s++) {
          final theta = (s / segments) * math.pi * 2.0;
          final h1 = math.sin(theta * 3.0 + timeSec * 4.8 + ringPhaseShift);
          final h2 =
              0.55 *
              math.sin(theta * 5.0 - timeSec * 6.4 + ringPhaseShift * 1.4);
          final h3 = 0.30 * math.cos(theta * 8.0 + timeSec * 8.6);
          final r = baseR + (h1 + h2 + h3) * ampPx * 0.54;
          final pt = Offset(
            center.dx + r * math.cos(theta),
            center.dy + r * math.sin(theta),
          );
          if (s == 0) {
            path.moveTo(pt.dx, pt.dy);
          } else {
            path.lineTo(pt.dx, pt.dy);
          }
        }
        path.close();
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintExpandingWave({
    required Canvas canvas,
    required Offset center,
    required double maxRadius,
    required double progress,
    required Color color,
    required double strokeWidth,
  }) {
    final eased = Curves.easeOutCubic.transform(progress);
    final radius = 24.0 + eased * (maxRadius * 0.96);
    final alpha = (1.0 - progress).clamp(0.0, 1.0);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * (1.0 - 0.35 * progress)
        ..color = color.withValues(alpha: alpha * 0.78),
    );
  }

  void _paintSpaceNode(Canvas canvas, _PlacedNode placed) {
    final coreColor = WavelengthPaletteResolver.nodeAccent(
      kind: placed.node.kind,
      topics: placed.node.matchedTopics,
      mode: colorMode,
    );
    final rimColor = WavelengthPaletteResolver.nodeRim(
      kind: placed.node.kind,
      topics: placed.node.matchedTopics,
      mode: colorMode,
    );

    // Compute radar sweep angular flare when the beam passes over this node!
    var sweepFlare = 0.0;
    if (sweepAngle != null) {
      final delta = _positiveAngleDiff(sweepAngle!, placed.polarAngle);
      if (delta >= 0.0 && delta <= 0.95) {
        final rawFlare = math.exp(-delta * 3.8);
        sweepFlare = rawFlare * (sweepBoost ? 1.0 : 0.45);
      }
    }

    final pos = placed.position;
    final baseR = placed.isSelected
        ? 9.5
        : placed.node.ring == ClosenessRing.inner
        ? 8.2
        : 6.8;
    final r = baseR + sweepFlare * 2.4;

    // Outer phosphor bloom + radar ping reticle
    final haloAlpha =
        (0.18 +
                (placed.isSelected ? 0.24 : 0.0) +
                (placed.node.movedCloser ? 0.22 : 0.0) +
                sweepFlare * 0.46)
            .clamp(0.0, 0.88);
    canvas.drawCircle(
      pos,
      r * (2.1 + sweepFlare * 0.85),
      Paint()..color = rimColor.withValues(alpha: haloAlpha * 0.55),
    );

    if (placed.isSelected || placed.node.movedCloser || sweepFlare > 0.18) {
      canvas.drawCircle(
        pos,
        r * (1.68 + sweepFlare * 0.55),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = placed.isSelected ? 1.6 : 1.15
          ..color = rimColor.withValues(
            alpha: (0.45 + sweepFlare * 0.50).clamp(0.0, 1.0),
          ),
      );
    }

    // Distinct shape per SpaceKind (CVD-safe!)
    if (placed.node.kind == SpaceKind.talk) {
      // 4-point star / diamond beacon for Scheduled Talks
      final diamondR = r * 1.24;
      final path = Path()
        ..moveTo(pos.dx, pos.dy - diamondR)
        ..quadraticBezierTo(
          pos.dx + diamondR * 0.26,
          pos.dy - diamondR * 0.26,
          pos.dx + diamondR,
          pos.dy,
        )
        ..quadraticBezierTo(
          pos.dx + diamondR * 0.26,
          pos.dy + diamondR * 0.26,
          pos.dx,
          pos.dy + diamondR,
        )
        ..quadraticBezierTo(
          pos.dx - diamondR * 0.26,
          pos.dy + diamondR * 0.26,
          pos.dx - diamondR,
          pos.dy,
        )
        ..quadraticBezierTo(
          pos.dx - diamondR * 0.26,
          pos.dy - diamondR * 0.26,
          pos.dx,
          pos.dy - diamondR,
        )
        ..close();

      canvas.drawPath(path, Paint()..color = coreColor);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = rimColor,
      );
    } else {
      // Glowing circular radar blip for Topic Spaces
      canvas.drawCircle(
        pos,
        r * 1.05,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = rimColor,
      );
      canvas.drawCircle(pos, r * 0.62, Paint()..color = coreColor);
    }

    // Small "I'm going" starlight check indicator on saved talks
    if (placed.node.isGoing) {
      final badgeCenter = Offset(pos.dx + r * 0.95, pos.dy - r * 0.95);
      canvas.drawCircle(
        badgeCenter,
        4.2,
        Paint()..color = WavelengthColors.phosphorBlue,
      );
      canvas.drawCircle(
        badgeCenter,
        2.0,
        Paint()..color = WavelengthColors.brandWhite,
      );
    }
  }

  void _paintCenterYouNode(Canvas canvas, Offset center) {
    if (!isRecording) {
      // Idle `YOU` Core: multi-layer Blue Phosphor bloom + crisp white label
      final breath = reduceMotion ? 0.0 : 0.5 + 0.5 * math.sin(timeSec * 2.1);
      canvas.drawCircle(
        center,
        34.0 + breath * 3.5,
        Paint()..color = centerColor.withValues(alpha: 0.12 + breath * 0.05),
      );
      canvas.drawCircle(
        center,
        24.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = centerColor.withValues(alpha: 0.72),
      );
      canvas.drawCircle(center, 18.5, Paint()..color = centerColor);

      final tp = TextPainter(
        text: const TextSpan(
          text: 'YOU',
          style: TextStyle(
            color: WavelengthColors.onPhosphor,
            fontSize: 14.0,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(center.dx - tp.width * 0.5, center.dy - tp.height * 0.5),
      );
      return;
    }

    // --- ACTIVE RECORDING STATE (`isRecording == true`) ---
    // 1. Warm Signal Coral radial bloom
    canvas.drawCircle(
      center,
      36.0 + micEnergy * 16.0,
      Paint()
        ..color = WavelengthColors.micHotCoral.withValues(
          alpha: (0.16 + micEnergy * 0.22).clamp(0.0, 0.45),
        ),
    );

    // 2. 3-minute Countdown Progress Arc around the center
    const countdownRadius = 35.0;
    canvas.drawCircle(
      center,
      countdownRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = WavelengthColors.borderSpecular.withValues(alpha: 0.65),
    );
    final remainingSweep =
        (1.0 - recordingProgress).clamp(0.0, 1.0) * math.pi * 2.0;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: countdownRadius),
      -math.pi * 0.5,
      remainingSweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..color = WavelengthColors.micHotCoral,
    );

    // 3. 24-Bar Radial Live Waveform Spokes around `YOU`
    final count = micBars.length;
    final barPaint = Paint()
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round
      ..color = WavelengthColors.micHotCoral;

    const innerSpokeR = 14.5;
    for (var i = 0; i < count; i++) {
      final angle = -math.pi * 0.5 + (i / count) * math.pi * 2.0;
      final barAmp = micBars[i].clamp(0.06, 1.0);
      final outerSpokeR = innerSpokeR + 3.0 + barAmp * 14.5;
      final p1 = Offset(
        center.dx + innerSpokeR * math.cos(angle),
        center.dy + innerSpokeR * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + outerSpokeR * math.cos(angle),
        center.dy + outerSpokeR * math.sin(angle),
      );
      canvas.drawLine(p1, p2, barPaint);
    }

    // 4. Glowing Coral Core
    canvas.drawCircle(
      center,
      12.0 + micEnergy * 2.0,
      Paint()..color = WavelengthColors.micHotCoral,
    );
    canvas.drawCircle(
      center,
      4.5,
      Paint()..color = WavelengthColors.brandWhite,
    );
  }

  /// Positive angular lag `beamAngle - nodeAngle` wrapped into `[0, 2*pi)`.
  static double _positiveAngleDiff(double beamAngle, double nodeAngle) {
    const twoPi = math.pi * 2.0;
    var diff = (beamAngle - nodeAngle) % twoPi;
    if (diff < 0) diff += twoPi;
    return diff;
  }

  @override
  bool shouldRepaint(covariant _ConstellationRadarPainter oldDelegate) {
    return oldDelegate.timeSec != timeSec ||
        oldDelegate.isRecording != isRecording ||
        oldDelegate.micEnergy != micEnergy ||
        oldDelegate.recordingProgress != recordingProgress ||
        oldDelegate.sweepAngle != sweepAngle ||
        oldDelegate.sweepBoost != sweepBoost ||
        oldDelegate.pressWaveProgress != pressWaveProgress ||
        oldDelegate.tuneRippleProgress != tuneRippleProgress ||
        oldDelegate.colorMode != colorMode ||
        oldDelegate.centerColor != centerColor ||
        oldDelegate.placements != placements;
  }
}
