import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../schedule_data.dart';
import 'wavelength_theme.dart';

/// Drifting bubble picker and free-text interest tuner (`page3-interests.png`).
class InterestsScreen extends StatefulWidget {
  const InterestsScreen({
    super.key,
    required this.catalog,
    this.initialSelectedTopics = const <String>{},
    this.onRetune,
  });

  final ScheduleCatalog catalog;
  final Set<String> initialSelectedTopics;
  final FutureOr<void> Function(
    Set<String> selectedTopics,
    String typedInterests,
  )?
  onRetune;

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _InterestsScreenState extends State<InterestsScreen>
    with SingleTickerProviderStateMixin {
  /// Non-overlapping `(x, y)` centres in the `412 x 436` mock-up field.
  static const List<(double x, double y)> _bubbleSlots = <(double, double)>[
    (62, 62),
    (194, 62),
    (330, 66),
    (100, 176),
    (210, 172),
    (322, 180),
    (64, 290),
    (184, 284),
    (302, 294),
    (124, 384),
    (244, 386),
    (350, 384),
  ];

  final TextEditingController _textController = TextEditingController();
  final FocusNode _fieldFocus = FocusNode();
  late final AnimationController _driftController;

  late Set<String> _pickedTopics;
  late List<String> _orderedTopics;
  int _maxTopicSessions = 1;
  int _pageIndex = 0;
  bool _fieldFocused = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final canonicalInitial = widget.catalog.canonicalizeTopics(
      widget.initialSelectedTopics,
    );
    _pickedTopics = <String>{
      if (canonicalInitial.isNotEmpty)
        ...canonicalInitial
      else
        ...widget.initialSelectedTopics,
    };

    final recommended = widget.catalog.recommendedBubbleTopics(
      selectedTopics: _pickedTopics,
    );
    _orderedTopics = recommended.isNotEmpty
        ? recommended
        : widget.catalog.popularTopics(limit: 48);

    for (final topic in _orderedTopics) {
      final c = widget.catalog.sessionCountForTopic(topic);
      if (c > _maxTopicSessions) _maxTopicSessions = c;
    }

    _driftController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _fieldFocus.addListener(_onFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  void _syncMotion() {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      if (_driftController.isAnimating) {
        _driftController.stop();
      }
    } else if (!_driftController.isAnimating) {
      _driftController.repeat();
    }
  }

  void _onFocusChanged() {
    if (mounted && _fieldFocused != _fieldFocus.hasFocus) {
      setState(() => _fieldFocused = _fieldFocus.hasFocus);
    }
  }

  @override
  void dispose() {
    _fieldFocus
      ..removeListener(_onFocusChanged)
      ..dispose();
    _textController.dispose();
    _driftController.dispose();
    super.dispose();
  }

  int get _totalPages =>
      _orderedTopics.isEmpty ? 1 : ((_orderedTopics.length + 11) ~/ 12);

  List<String> get _currentPageTopics {
    if (_orderedTopics.isEmpty) return const <String>[];
    final start = (_pageIndex % _totalPages) * 12;
    final end = math.min(start + 12, _orderedTopics.length);
    return _orderedTopics.sublist(start, end);
  }

  double _designDiameterForTopic(String topic) {
    final count = widget.catalog.sessionCountForTopic(topic);
    final ratio = _maxTopicSessions <= 0 ? 0.5 : count / _maxTopicSessions;
    if (ratio >= 0.52) return 108.0;
    if (ratio >= 0.24) return 92.0;
    return 78.0;
  }

  static String _shortBubbleLabel(String raw) {
    const overrides = <String, String>{
      'AI Inference + Agentic': 'AI Inference',
      'Application Development + Delivery': 'App Delivery',
      'Operations + Performance': 'Ops + Perf',
      'Platform Engineering': 'Platform Eng',
      'Data Processing + Storage': 'Data + Storage',
      'Open Policy Agent (OPA)': 'OPA',
      'Open Cluster Management': 'Cluster Mgmt',
      'Inclusion + Accessibility': 'Accessibility',
      'Developer Experience': 'DevEx',
      'Contributor Experience': 'ContribEx',
      'Flatcar Container Linux': 'Flatcar Linux',
      'Podman Container Tools': 'Podman',
    };
    return overrides[raw] ?? raw;
  }

  void _toggleBubble(String topic) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_pickedTopics.remove(topic)) {
        _pickedTopics.add(topic);
      }
    });
  }

  void _nextBubblePage() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_totalPages > 1) {
        _pageIndex = (_pageIndex + 1) % _totalPages;
      } else if (_orderedTopics.length > 1) {
        // Rotate deterministically when small test catalogs have <= 12 topics.
        _orderedTopics = <String>[
          ..._orderedTopics.skip(1),
          _orderedTopics.first,
        ];
      }
    });
  }

  Future<void> _submitRetune() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    final typed = _textController.text.trim();
    final matchedFromTyped = typed.isEmpty
        ? const <String>[]
        : widget.catalog.extractMatchedTopics(typed);
    final finalTopics = <String>{..._pickedTopics, ...matchedFromTyped};

    await widget.onRetune?.call(finalTopics, typed);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  String _buildLinkedReasonCopy() {
    if (_pickedTopics.isEmpty) {
      return 'Pick a few and the suggestions follow you.';
    }
    final labels = _pickedTopics.map(_shortBubbleLabel).toList(growable: false);
    if (labels.length == 1) {
      return 'A dot marks topics linked to ${labels.first}.';
    }
    if (labels.length == 2) {
      return 'A dot marks topics linked to ${labels[0]} and ${labels[1]}.';
    }
    final extra = labels.length - 2;
    return 'A dot marks topics linked to ${labels[0]} and ${labels[1]} and $extra more.';
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final filter = _textController.text.trim().toLowerCase();
    final linkedTopics = widget.catalog.topicsLinkedTo(_pickedTopics);
    final pageTopics = _currentPageTopics;

    return Scaffold(
      backgroundColor: WavelengthColors.canvas,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          color: WavelengthColors.canvas,
          gradient: RadialGradient(
            center: Alignment(0, -0.08),
            radius: 0.72,
            colors: <Color>[Color(0x4D0C4A7A), Color(0x0004060A)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, viewport) {
              final compactViewport = viewport.maxHeight < 520;

              Widget buildBubbleField() {
                return LayoutBuilder(
                  builder: (context, box) {
                    final sx = box.maxWidth / 412.0;
                    final sy = box.maxHeight / 436.0;
                    final sd = math.min(sx, sy).clamp(0.62, 1.15);

                    return AnimatedBuilder(
                      animation: _driftController,
                      builder: (context, _) {
                        final phaseT = reduceMotion
                            ? 0.0
                            : _driftController.value * math.pi * 2.0;

                        return Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            for (
                              var i = 0;
                              i < pageTopics.length && i < _bubbleSlots.length;
                              i++
                            )
                              _buildPositionedBubble(
                                index: i,
                                topic: pageTopics[i],
                                boxSize: Size(box.maxWidth, box.maxHeight),
                                sx: sx,
                                sy: sy,
                                sd: sd,
                                phaseT: phaseT,
                                reduceMotion: reduceMotion,
                                filter: filter,
                                linkedTopics: linkedTopics,
                              ),
                          ],
                        );
                      },
                    );
                  },
                );
              }

              final topChildren = <Widget>[
                // Top Back + Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 22, 0),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(false),
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: 'Back',
                        icon: const Icon(
                          Icons.chevron_left_rounded,
                          size: 28,
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Expanded(
                        child: Text(
                          'Interests',
                          style: TextStyle(
                            fontSize: 24.0,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3,
                            color: WavelengthColors.primaryText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Subtitle
                const Padding(
                  padding: EdgeInsets.fromLTRB(22, 4, 22, 12),
                  child: Text(
                    'Type what you care about, or tap what pulls you. Your map retunes to it.',
                    style: TextStyle(
                      fontSize: 15.0,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      color: WavelengthColors.secondaryText,
                    ),
                  ),
                ),

                // 56px Search / Interest Field + 44x44 blue submit button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 56,
                    padding: const EdgeInsets.fromLTRB(16, 0, 6, 0),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A111B),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _fieldFocused
                            ? WavelengthColors.phosphorBlue
                            : const Color(0xFF22405E),
                        width: _fieldFocused ? 1.4 : 1.0,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: _fieldFocused
                              ? const Color(0x590EA5E9)
                              : const Color(0x1F0EA5E9),
                          blurRadius: _fieldFocused ? 28 : 20,
                        ),
                      ],
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _fieldFocus,
                            maxLength: 120,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => unawaited(_submitRetune()),
                            style: const TextStyle(
                              fontSize: 16.0,
                              fontWeight: FontWeight.w500,
                              color: WavelengthColors.primaryText,
                            ),
                            decoration: const InputDecoration(
                              filled: false,
                              counterText: '',
                              isCollapsed: true,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 14,
                              ),
                              hintText: 'e.g. eBPF tracing, GPU scheduling',
                              hintStyle: TextStyle(
                                fontSize: 16.0,
                                fontWeight: FontWeight.w500,
                                color: WavelengthColors.mutedText,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Semantics(
                          button: true,
                          label: 'Submit typed interests',
                          child: Material(
                            color: WavelengthColors.phosphorBlue,
                            borderRadius: BorderRadius.circular(14),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => unawaited(_submitRetune()),
                              child: const SizedBox(
                                width: 44,
                                height: 44,
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 22,
                                  color: Color(0xFF04121C),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // SUGGESTED FOR YOU label
                const Padding(
                  padding: EdgeInsets.fromLTRB(22, 14, 22, 4),
                  child: Text(
                    'SUGGESTED FOR YOU',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14.0,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.8,
                      color: WavelengthColors.phosphorBlue,
                    ),
                  ),
                ),
              ];

              final bottomChildren = <Widget>[
                // Linked-dot explanation row
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 4, 22, 10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 34),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        if (_pickedTopics.isNotEmpty) ...<Widget>[
                          Container(
                            width: 9,
                            height: 9,
                            decoration: const BoxDecoration(
                              color: WavelengthColors.noteAqua,
                              shape: BoxShape.circle,
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: WavelengthColors.noteAqua,
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Text(
                            _buildLinkedReasonCopy(),
                            style: const TextStyle(
                              fontSize: 14.0,
                              fontWeight: FontWeight.w500,
                              height: 1.35,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom More + Retune my wavelength buttons
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 12),
                  child: Row(
                    children: <Widget>[
                      Semantics(
                        button: true,
                        label: 'More topic suggestions',
                        child: Material(
                          color: const Color(0xFF0A111B),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: const BorderSide(color: Color(0xFF23405E)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _nextBubblePage,
                            child: const SizedBox(
                              height: 54,
                              child: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 18),
                                child: Center(
                                  child: Text(
                                    'More',
                                    style: TextStyle(
                                      fontSize: 15.0,
                                      fontWeight: FontWeight.w600,
                                      color: WavelengthColors.primaryText,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Semantics(
                          button: true,
                          label: 'Retune my wavelength',
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              gradient: const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Color(0xFF56C8FB),
                                  Color(0xFF2AA9EA),
                                ],
                              ),
                              boxShadow: const <BoxShadow>[
                                BoxShadow(
                                  color: Color(0x730EA5E9),
                                  blurRadius: 28,
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: _submitting
                                    ? null
                                    : () => unawaited(_submitRetune()),
                                child: const SizedBox(
                                  height: 54,
                                  child: Center(
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(
                                        'Retune my wavelength',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 16.0,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF04121C),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ];

              if (compactViewport) {
                return SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      ...topChildren,
                      SizedBox(
                        width: viewport.maxWidth,
                        height: 300,
                        child: buildBubbleField(),
                      ),
                      ...bottomChildren,
                    ],
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ...topChildren,
                  Expanded(child: buildBubbleField()),
                  ...bottomChildren,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPositionedBubble({
    required int index,
    required String topic,
    required Size boxSize,
    required double sx,
    required double sy,
    required double sd,
    required double phaseT,
    required bool reduceMotion,
    required String filter,
    required Set<String> linkedTopics,
  }) {
    final slot = _bubbleSlots[index];
    final diameter = math.max(58.0, _designDiameterForTopic(topic) * sd);
    final label = _shortBubbleLabel(topic);
    final selected = _pickedTopics.contains(topic);
    final isLinked = !selected && linkedTopics.contains(topic);
    final matchesFilter =
        filter.isEmpty ||
        label.toLowerCase().contains(filter) ||
        topic.toLowerCase().contains(filter);

    final speedFactor = 1.0 + (index % 4) * 0.25;
    final dx = reduceMotion
        ? 0.0
        : ((index % 3) - 1) * 3.0 * math.sin(phaseT * speedFactor + index);
    final dy = reduceMotion
        ? 0.0
        : (index.isOdd ? 4.0 : -4.0) *
              math.cos(phaseT * speedFactor + index * 0.7);

    final cx = (slot.$1 * sx + dx).clamp(
      diameter / 2 + 4.0,
      math.max(diameter / 2 + 4.0, boxSize.width - diameter / 2 - 4.0),
    );
    final cy = (slot.$2 * sy + dy).clamp(
      diameter / 2 + 2.0,
      math.max(diameter / 2 + 2.0, boxSize.height - diameter / 2 - 2.0),
    );

    return Positioned(
      left: cx - diameter / 2,
      top: cy - diameter / 2,
      width: diameter,
      height: diameter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: matchesFilter ? 1.0 : 0.16,
        child: _TopicBubbleButton(
          topic: topic,
          label: label,
          diameter: diameter,
          selected: selected,
          showLinkedDot: isLinked,
          onTap: () => _toggleBubble(topic),
        ),
      ),
    );
  }
}

class _TopicBubbleButton extends StatelessWidget {
  const _TopicBubbleButton({
    required this.topic,
    required this.label,
    required this.diameter,
    required this.selected,
    required this.showLinkedDot,
    required this.onTap,
  });

  final String topic;
  final String label;
  final double diameter;
  final bool selected;
  final bool showLinkedDot;
  final VoidCallback onTap;

  static String _formatBubbleLines(String label) {
    final words = label.trim().split(RegExp(r'\s+'));
    if (words.length <= 1) return label;
    if (words.length == 2) return '${words[0]}\n${words[1]}';
    final splitAt = (words.length / 2).ceil();
    return '${words.sublist(0, splitAt).join(' ')}\n${words.sublist(splitAt).join(' ')}';
  }

  @override
  Widget build(BuildContext context) {
    final displayText = _formatBubbleLines(label);
    return Semantics(
      button: true,
      selected: selected,
      label: showLinkedDot ? '$topic, linked to your picks' : topic,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: selected
                      ? const RadialGradient(
                          center: Alignment(-0.28, -0.40),
                          radius: 0.88,
                          colors: <Color>[
                            Color(0xFFF0FAFF),
                            Color(0xFFBAE6FD),
                            Color(0xFF38BDF8),
                          ],
                          stops: <double>[0.0, 0.45, 1.0],
                        )
                      : RadialGradient(
                          center: const Alignment(-0.28, -0.40),
                          radius: 0.88,
                          colors: <Color>[
                            WavelengthColors.phosphorBlue.withValues(
                              alpha: 0.34,
                            ),
                            WavelengthColors.phosphorBloom.withValues(
                              alpha: 0.13,
                            ),
                            WavelengthColors.phosphorBloom.withValues(
                              alpha: 0.05,
                            ),
                          ],
                          stops: const <double>[0.0, 0.55, 1.0],
                        ),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFFF0FAFF)
                        : WavelengthColors.phosphorBlue.withValues(alpha: 0.55),
                    width: 1.2,
                  ),
                  boxShadow: selected
                      ? <BoxShadow>[
                          BoxShadow(
                            color: WavelengthColors.phosphorBlue.withValues(
                              alpha: 0.22,
                            ),
                            spreadRadius: 4,
                            blurRadius: 0,
                          ),
                          BoxShadow(
                            color: WavelengthColors.phosphorBlue.withValues(
                              alpha: 0.60,
                            ),
                            blurRadius: 30,
                          ),
                        ]
                      : <BoxShadow>[
                          BoxShadow(
                            color: WavelengthColors.phosphorBloom.withValues(
                              alpha: 0.22,
                            ),
                            blurRadius: 20,
                          ),
                        ],
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                alignment: Alignment.center,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    displayText,
                    textAlign: TextAlign.center,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: selected
                          ? const Color(0xFF04121C)
                          : WavelengthColors.primaryText,
                    ),
                  ),
                ),
              ),
            ),
            if (showLinkedDot)
              Positioned(
                top: diameter * 0.09,
                right: diameter * 0.13,
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: WavelengthColors.noteAqua,
                    shape: BoxShape.circle,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: WavelengthColors.noteAqua,
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
