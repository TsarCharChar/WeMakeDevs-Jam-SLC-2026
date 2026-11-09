import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../schedule_data.dart';
import 'wavelength_theme.dart';

/// Shown once on first launch when there is no saved profile yet.
///
/// Collects an optional `display_name` (1..60 characters, any language, one
/// line, shown next to what the person says in chats; generated `cf_<20-hex>`
/// handle stays untouched) plus initial topic bubbles and free-text interests.
class FirstLaunchOnboardingScreen extends StatefulWidget {
  const FirstLaunchOnboardingScreen({
    super.key,
    required this.catalog,
    required this.onComplete,
  });

  final ScheduleCatalog catalog;
  final FutureOr<void> Function({
    required String displayName,
    required Set<String> selectedTopics,
    required String typedInterests,
  })
  onComplete;

  @override
  State<FirstLaunchOnboardingScreen> createState() =>
      _FirstLaunchOnboardingScreenState();
}

class _FirstLaunchOnboardingScreenState
    extends State<FirstLaunchOnboardingScreen> {
  static const List<(double x, double y)> _bubbleSlots = <(double, double)>[
    (62, 54),
    (194, 54),
    (330, 58),
    (102, 152),
    (214, 150),
    (324, 156),
    (66, 250),
    (188, 246),
    (308, 252),
  ];

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _interestController = TextEditingController();

  final Set<String> _pickedTopics = <String>{};
  late List<String> _orderedTopics;
  int _maxTopicSessions = 1;
  int _pageIndex = 0;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final recommended = widget.catalog.recommendedBubbleTopics(
      selectedTopics: _pickedTopics,
    );
    _orderedTopics = recommended.isNotEmpty
        ? recommended
        : widget.catalog.popularTopics(limit: 36);
    for (final topic in _orderedTopics) {
      final count = widget.catalog.sessionCountForTopic(topic);
      if (count > _maxTopicSessions) _maxTopicSessions = count;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _interestController.dispose();
    super.dispose();
  }

  int get _totalPages =>
      _orderedTopics.isEmpty ? 1 : ((_orderedTopics.length + 8) ~/ 9);

  List<String> get _currentPageTopics {
    if (_orderedTopics.isEmpty) return const <String>[];
    final start = (_pageIndex % _totalPages) * 9;
    final end = math.min(start + 9, _orderedTopics.length);
    return _orderedTopics.sublist(start, end);
  }

  static String _shortLabel(String raw) {
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
    };
    return overrides[raw] ?? raw;
  }

  static String _formatBubbleLines(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length <= 1) return text.trim();
    if (words.length == 2) return '${words[0]}\n${words[1]}';
    final totalChars = text.length;
    var bestSplit = 1;
    var bestDiff = totalChars;
    for (var split = 1; split < words.length; split++) {
      final line1 = words.sublist(0, split).join(' ');
      final line2 = words.sublist(split).join(' ');
      final diff = (line1.length - line2.length).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestSplit = split;
      }
    }
    return '${words.sublist(0, bestSplit).join(' ')}\n${words.sublist(bestSplit).join(' ')}';
  }

  double _diameterForTopic(String topic) {
    final count = widget.catalog.sessionCountForTopic(topic);
    final ratio = _maxTopicSessions <= 0 ? 0.5 : count / _maxTopicSessions;
    if (ratio >= 0.52) return 96.0;
    if (ratio >= 0.24) return 84.0;
    return 74.0;
  }

  void _toggleTopic(String topic) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_pickedTopics.remove(topic)) {
        _pickedTopics.add(topic);
      }
    });
  }

  void _nextPage() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_totalPages > 1) {
        _pageIndex = (_pageIndex + 1) % _totalPages;
      } else if (_orderedTopics.length > 1) {
        _orderedTopics = <String>[
          ..._orderedTopics.skip(1),
          _orderedTopics.first,
        ];
      }
    });
  }

  Future<void> _finish({required bool skipped}) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    HapticFeedback.mediumImpact();

    final typedInterests = _interestController.text.trim();
    final matchedFromTyped = typedInterests.isEmpty
        ? const <String>[]
        : widget.catalog.extractMatchedTopics(typedInterests);
    final finalTopics = <String>{..._pickedTopics, ...matchedFromTyped};
    final name = skipped ? '' : _nameController.text.trim();

    await widget.onComplete(
      displayName: name,
      selectedTopics: finalTopics,
      typedInterests: typedInterests,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'CONFELLOW',
                  style: WavelengthTypography.brandWordmark,
                ),
                const SizedBox(height: 12),
                const Text(
                  'What should we call you?',
                  style: TextStyle(
                    fontSize: 22.0,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: WavelengthColors.primaryText,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nameController,
                  maxLength: 60,
                  maxLines: 1,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(
                    fontSize: 16.0,
                    fontWeight: FontWeight.w500,
                    color: WavelengthColors.primaryText,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'Ada Lovelace',
                    hintStyle: const TextStyle(
                      fontSize: 16.0,
                      color: WavelengthColors.mutedText,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0A111B),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF22405E)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: WavelengthColors.phosphorBlue,
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Shown next to what you say in chats.',
                  style: TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w500,
                    color: WavelengthColors.secondaryText,
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'PICK A FEW TOPICS',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.6,
                    color: WavelengthColors.phosphorBlue,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final sx = box.maxWidth / 368.0;
                      final sy = box.maxHeight / 308.0;
                      final sd = math.min(sx, sy).clamp(0.62, 1.12);
                      return Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          for (
                            var i = 0;
                            i < pageTopics.length && i < _bubbleSlots.length;
                            i++
                          )
                            Builder(
                              builder: (context) {
                                final topic = pageTopics[i];
                                final slot = _bubbleSlots[i];
                                final picked = _pickedTopics.contains(topic);
                                final linked =
                                    !picked && linkedTopics.contains(topic);
                                final d = (_diameterForTopic(topic) * sd).clamp(
                                  64.0,
                                  108.0,
                                );
                                final cx = (slot.$1 * sx).clamp(
                                  d / 2,
                                  math.max(d / 2, box.maxWidth - d / 2),
                                );
                                final cy = (slot.$2 * sy).clamp(
                                  d / 2,
                                  math.max(d / 2, box.maxHeight - d / 2),
                                );
                                return Positioned(
                                  left: cx - d / 2,
                                  top: cy - d / 2,
                                  width: d,
                                  height: d,
                                  child: _OnboardingTopicBubble(
                                    label: _shortLabel(topic),
                                    formattedLabel: _formatBubbleLines(
                                      _shortLabel(topic),
                                    ),
                                    picked: picked,
                                    linked: linked,
                                    onTap: () => _toggleTopic(topic),
                                  ),
                                );
                              },
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _interestController,
                  maxLength: 240,
                  maxLines: 1,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontSize: 15.0,
                    color: WavelengthColors.primaryText,
                  ),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'Type an interest (optional)',
                    hintStyle: const TextStyle(
                      fontSize: 15.0,
                      color: WavelengthColors.mutedText,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0A111B),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF1B2A3D)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(
                        color: WavelengthColors.phosphorBlue,
                        width: 1.4,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        onPressed: _submitting ? null : _nextPage,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: WavelengthColors.primaryText,
                          backgroundColor: const Color(0xFF0A111B),
                          side: const BorderSide(color: Color(0xFF23405E)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(99),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: const Text(
                          'More',
                          style: TextStyle(
                            fontSize: 15.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 50,
                      child: TextButton(
                        onPressed: _submitting
                            ? null
                            : () => unawaited(_finish(skipped: true)),
                        style: TextButton.styleFrom(
                          foregroundColor: WavelengthColors.secondaryText,
                          minimumSize: const Size(64, 50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                        child: const Text(
                          'Skip',
                          style: TextStyle(
                            fontSize: 15.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: FilledButton(
                          onPressed: _submitting
                              ? null
                              : () => unawaited(_finish(skipped: false)),
                          style: FilledButton.styleFrom(
                            backgroundColor: WavelengthColors.phosphorBlue,
                            foregroundColor: const Color(0xFF04121C),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          child: const Text(
                            'Start',
                            style: TextStyle(
                              fontSize: 16.0,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingTopicBubble extends StatelessWidget {
  const _OnboardingTopicBubble({
    required this.label,
    required this.formattedLabel,
    required this.picked,
    required this.linked,
    required this.onTap,
  });

  final String label;
  final String formattedLabel;
  final bool picked;
  final bool linked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: picked,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: picked
                ? const RadialGradient(
                    center: Alignment(0, -0.25),
                    colors: <Color>[Color(0xFF1A4B78), Color(0xFF0C243D)],
                  )
                : const RadialGradient(
                    center: Alignment(0, -0.25),
                    colors: <Color>[Color(0xFF0F1B2B), Color(0xFF070C14)],
                  ),
            border: Border.all(
              color: picked
                  ? const Color(0xFF7DD3FC)
                  : (linked
                        ? const Color(0x9938BDF8)
                        : const Color(0x4738BDF8)),
              width: picked ? 1.8 : 1.0,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formattedLabel,
                    textAlign: TextAlign.center,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: picked
                          ? Colors.white
                          : WavelengthColors.primaryText,
                    ),
                  ),
                ),
              ),
              if (linked)
                Positioned(
                  right: 7,
                  top: 7,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: Color(0xFF5EEAD4),
                      shape: BoxShape.circle,
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
