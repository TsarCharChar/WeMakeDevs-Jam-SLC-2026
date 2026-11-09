import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'wavelength_theme.dart';

/// Feature flag enabling room chat entry points (`GET/POST /rooms/{room}/messages`).
const bool enableRoomChat = true;

/// Shared note snippet displayed inside a Space sheet ONLY when explicitly shared.
@immutable
class SharedSpaceNote {
  const SharedSpaceNote({
    required this.id,
    required this.text,
    this.topics = const <String>[],
  });

  final String id;
  final String text;
  final List<String> topics;
}

/// View-model for presenting any Topic Space or Scheduled Talk inside
/// [SpaceDiscoverySheet].
@immutable
class SpaceSheetNode {
  const SpaceSheetNode({
    required this.id,
    required this.kind,
    required this.title,
    required this.whyOnWavelength,
    this.topicLabel,
    this.talkCount,
    this.peopleCount = 0,
    this.talkId,
    this.talkTitle,
    this.timeSlot,
    this.room,
    this.abstractText,
    this.isGoing = false,
    this.linkedTopics = const <String>[],
    this.sharedNotes = const <SharedSpaceNote>[],
  });

  final String id;
  final SpaceKind kind;
  final String title;
  final String whyOnWavelength;

  /// Parent topic label when [kind] is [SpaceKind.talk] (e.g. `"Observability"`).
  final String? topicLabel;

  /// Number of talks carrying this topic (shown when `> 0`).
  final int? talkCount;

  /// Real attendee count from backend (`0` when unavailable — never invented!).
  final int peopleCount;

  /// Talk id for `"I'm going"` toggling (either the talk itself, or the topic's
  /// featured talk).
  final String? talkId;

  /// Featured talk title when [kind] is [SpaceKind.topic].
  final String? talkTitle;
  final String? timeSlot;
  final String? room;
  final String? abstractText;
  final bool isGoing;
  final List<String> linkedTopics;
  final List<SharedSpaceNote> sharedNotes;
}

/// Presents [SpaceDiscoverySheet] as a modal Black + Blue Phosphor bottom sheet.
Future<void> showSpaceDiscoverySheet({
  required BuildContext context,
  required SpaceSheetNode node,
  void Function(String talkId, bool nextGoing)? onToggleGoing,
  ValueChanged<String>? onSelectTopic,
  VoidCallback? onJoinChat,
  bool showRoomChat = enableRoomChat,
  WidgetBuilder? roomChatSlotBuilder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x8C020408),
    builder: (sheetContext) => SpaceDiscoverySheet(
      node: node,
      onToggleGoing: onToggleGoing,
      onSelectTopic: onSelectTopic,
      onJoinChat: onJoinChat,
      showRoomChat: showRoomChat,
      roomChatSlotBuilder: roomChatSlotBuilder,
    ),
  );
}

/// Bottom sheet opened when tapping any Topic Space or Scheduled Talk on the
/// Wavelength Scope or Spaces screen.
///
/// Enforces ConFellow UX & privacy invariants:
/// - Explains why the Space is on your wavelength **in words** (zero `%`, zero `"nearby"`).
/// - Displays people count **ONLY** when `peopleCount > 0` (never invented).
/// - Embeds the featured talk (on Topic Space) or session details (on Talk Space)
///   with an **"I'm going"** / **"Going ✓"** toggle.
/// - Renders **"LINKED TOPICS"** chips with zero overflow at `412x892` and `320x640`.
class SpaceDiscoverySheet extends StatefulWidget {
  const SpaceDiscoverySheet({
    super.key,
    required this.node,
    this.onToggleGoing,
    this.onSelectTopic,
    this.onJoinChat,
    this.showRoomChat = enableRoomChat,
    this.roomChatSlotBuilder,
  });

  final SpaceSheetNode node;
  final void Function(String talkId, bool nextGoing)? onToggleGoing;
  final ValueChanged<String>? onSelectTopic;
  final VoidCallback? onJoinChat;
  final bool showRoomChat;
  final WidgetBuilder? roomChatSlotBuilder;

  @override
  State<SpaceDiscoverySheet> createState() => _SpaceDiscoverySheetState();
}

class _SpaceDiscoverySheetState extends State<SpaceDiscoverySheet> {
  late bool _isGoing;

  @override
  void initState() {
    super.initState();
    _isGoing = widget.node.isGoing;
  }

  @override
  void didUpdateWidget(covariant SpaceDiscoverySheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.isGoing != widget.node.isGoing ||
        oldWidget.node.id != widget.node.id) {
      _isGoing = widget.node.isGoing;
    }
  }

  void _handleToggleGoing() {
    final talkId = widget.node.talkId;
    if (talkId == null || talkId.isEmpty) return;
    HapticFeedback.selectionClick();
    final next = !_isGoing;
    setState(() => _isGoing = next);
    widget.onToggleGoing?.call(talkId, next);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final visibleSharedNotes = node.sharedNotes
        .where((n) => n.text.trim().isNotEmpty)
        .toList(growable: false);
    final hasTalkBlock =
        node.talkId != null &&
        ((node.talkTitle != null && node.talkTitle!.trim().isNotEmpty) ||
            (node.timeSlot != null && node.timeSlot!.trim().isNotEmpty) ||
            (node.room != null && node.room!.trim().isNotEmpty));

    final kindHeader = node.kind == SpaceKind.topic
        ? 'TOPIC SPACE'
        : (node.topicLabel != null && node.topicLabel!.trim().isNotEmpty
              ? 'TALK · ${node.topicLabel!.toUpperCase()}'
              : 'TALK');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: node.kind == SpaceKind.talk ? 0.68 : 0.64,
      minChildSize: 0.42,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Color(0xFF0E1724), Color(0xFF080C13)],
            ),
            border: Border(
              top: BorderSide(color: Color(0xFF22405E), width: 1),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Color(0x290EA5E9),
                blurRadius: 36,
                offset: Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2B3F57),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 10, 0),
                child: Row(
                  children: <Widget>[
                    _SheetKindGlyph(kind: node.kind),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        kindHeader,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.6,
                          color: WavelengthColors.phosphorBlue,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
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
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(22, 2, 22, 28),
                  children: <Widget>[
                    Text(
                      node.title,
                      style: const TextStyle(
                        fontSize: 23.0,
                        fontWeight: FontWeight.w600,
                        height: 1.18,
                        letterSpacing: -0.3,
                        color: WavelengthColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // WHY IT'S ON YOUR WAVELENGTH (in words — zero % or "nearby")
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: WavelengthColors.phosphorBlue.withValues(
                          alpha: 0.07,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: WavelengthColors.phosphorBlue.withValues(
                            alpha: 0.20,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            "WHY IT'S ON YOUR WAVELENGTH",
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14.0,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.3,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            node.whyOnWavelength,
                            style: const TextStyle(
                              fontSize: 15.0,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                              color: WavelengthColors.primaryText,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Stats row: talks count + ONLY real peopleCount > 0 (Fix B3 & B5)
                    if ((node.talkCount != null && node.talkCount! > 0) ||
                        node.peopleCount > 0) ...<Widget>[
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 18,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (node.talkCount != null && node.talkCount! > 0)
                            Text.rich(
                              TextSpan(
                                children: <InlineSpan>[
                                  TextSpan(
                                    text: '${node.talkCount}',
                                    style: const TextStyle(
                                      fontSize: 14.0,
                                      fontWeight: FontWeight.w700,
                                      color: WavelengthColors.primaryText,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        ' ${node.talkCount == 1 ? 'talk' : 'talks'}',
                                    style: const TextStyle(
                                      fontSize: 14.0,
                                      fontWeight: FontWeight.w500,
                                      color: WavelengthColors.secondaryText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (node.peopleCount > 0)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: const BoxDecoration(
                                    color: WavelengthColors.personViolet,
                                    shape: BoxShape.circle,
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: WavelengthColors.personViolet,
                                        blurRadius: 8,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text.rich(
                                    TextSpan(
                                      children: <InlineSpan>[
                                        TextSpan(
                                          text: '${node.peopleCount}',
                                          style: const TextStyle(
                                            fontSize: 14.0,
                                            fontWeight: FontWeight.w700,
                                            color: WavelengthColors.primaryText,
                                          ),
                                        ),
                                        TextSpan(
                                          text:
                                              ' ${node.peopleCount == 1 ? 'person' : 'people'} tuned in',
                                          style: const TextStyle(
                                            fontSize: 14.0,
                                            fontWeight: FontWeight.w500,
                                            color:
                                                WavelengthColors.secondaryText,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],

                    // Room Chat Entry ("Join the chat") — right above the fold
                    if (widget.showRoomChat) ...<Widget>[
                      const SizedBox(height: 14),
                      if (widget.roomChatSlotBuilder != null)
                        widget.roomChatSlotBuilder!(context)
                      else if (widget.onJoinChat != null)
                        SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: () {
                              HapticFeedback.mediumImpact();
                              Navigator.of(context).pop();
                              widget.onJoinChat!();
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: WavelengthColors.phosphorBlue,
                              foregroundColor: WavelengthColors.onPhosphor,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            icon: const Icon(Icons.forum_outlined, size: 20),
                            label: const Text(
                              'Join the chat',
                              style: TextStyle(
                                fontSize: 16.0,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],

                    // Featured talk (on Topic Space) or When & Where card (on Talk)
                    if (hasTalkBlock) ...<Widget>[
                      const SizedBox(height: 14),
                      _EmbeddedTalkCard(
                        headline: node.kind == SpaceKind.topic
                            ? (node.talkTitle ?? 'Featured talk')
                            : 'When and where',
                        timeSlot: node.timeSlot,
                        room: node.room,
                        isGoing: _isGoing,
                        onToggleGoing: widget.onToggleGoing == null
                            ? null
                            : _handleToggleGoing,
                      ),
                    ],

                    // Session Abstract (for Talk Space)
                    if (node.kind == SpaceKind.talk &&
                        node.abstractText != null &&
                        node.abstractText!.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      const Text(
                        'SESSION ABSTRACT',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.3,
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        node.abstractText!.trim(),
                        style: const TextStyle(
                          fontSize: 15.0,
                          fontWeight: FontWeight.w400,
                          height: 1.45,
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                    ],

                    // LINKED TOPICS (Fix N2 — honest schedule graph co-occurrence label)
                    if (node.linkedTopics.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 16),
                      const Text(
                        'LINKED TOPICS',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.3,
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final topic in node.linkedTopics)
                            _LinkedTopicPill(
                              label: topic,
                              onTap: widget.onSelectTopic == null
                                  ? null
                                  : () {
                                      HapticFeedback.selectionClick();
                                      widget.onSelectTopic!(topic);
                                    },
                            ),
                        ],
                      ),
                    ],

                    // Shared Notes (strictly only explicitly shared notes)
                    if (visibleSharedNotes.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 18),
                      const Text(
                        'SHARED NOTES',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14.0,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.3,
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final sharedNote in visibleSharedNotes) ...<Widget>[
                        PhosphorSurfaceCard(
                          padding: const EdgeInsets.all(14),
                          child: SelectableText(
                            sharedNote.text,
                            style: WavelengthTypography.body,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SheetKindGlyph extends StatelessWidget {
  const _SheetKindGlyph({required this.kind});

  final SpaceKind kind;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: CustomPaint(painter: _SheetKindGlyphPainter(kind: kind)),
    );
  }
}

class _SheetKindGlyphPainter extends CustomPainter {
  const _SheetKindGlyphPainter({required this.kind});

  final SpaceKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (kind == SpaceKind.topic) {
      canvas.drawCircle(
        c,
        5,
        Paint()..color = WavelengthColors.phosphorBlue,
      );
    } else {
      final path = Path()
        ..moveTo(c.dx, c.dy - 6)
        ..lineTo(c.dx + 6, c.dy)
        ..lineTo(c.dx, c.dy + 6)
        ..lineTo(c.dx - 6, c.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = WavelengthColors.talkStarlight,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SheetKindGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

class _EmbeddedTalkCard extends StatelessWidget {
  const _EmbeddedTalkCard({
    required this.headline,
    this.timeSlot,
    this.room,
    required this.isGoing,
    this.onToggleGoing,
  });

  final String headline;
  final String? timeSlot;
  final String? room;
  final bool isGoing;
  final VoidCallback? onToggleGoing;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(14.0) / 14.0;
    final metaParts = <String>[
      if (timeSlot != null && timeSlot!.trim().isNotEmpty) timeSlot!.trim(),
      if (room != null && room!.trim().isNotEmpty) room!.trim(),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A111B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1B2A3D)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stackVertically = constraints.maxWidth < 280 || textScale > 1.3;
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                headline,
                style: const TextStyle(
                  fontSize: 15.0,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  color: WavelengthColors.primaryText,
                ),
              ),
              if (metaParts.isNotEmpty) ...<Widget>[
                const SizedBox(height: 5),
                Text(
                  metaParts.join('\n'),
                  style: const TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                    color: WavelengthColors.secondaryText,
                  ),
                ),
              ],
            ],
          );

          final goingButton = onToggleGoing == null
              ? null
              : _GoingPillButton(isGoing: isGoing, onTap: onToggleGoing!);

          if (goingButton == null) return details;
          if (stackVertically) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                details,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerLeft, child: goingButton),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(child: details),
              const SizedBox(width: 12),
              goingButton,
            ],
          );
        },
      ),
    );
  }
}

class _GoingPillButton extends StatelessWidget {
  const _GoingPillButton({required this.isGoing, required this.onTap});

  final bool isGoing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: isGoing,
      label: isGoing ? 'Going to this talk' : "I'm going",
      child: Material(
        color: isGoing ? WavelengthColors.talkStarlight : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
          side: const BorderSide(color: WavelengthColors.talkStarlight),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 96),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Center(
                child: Text(
                  isGoing ? 'Going ✓' : "I'm going",
                  style: TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                    color: isGoing
                        ? const Color(0xFF06101A)
                        : WavelengthColors.talkStarlight,
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

class _LinkedTopicPill extends StatelessWidget {
  const _LinkedTopicPill({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: label,
      child: Material(
        color: WavelengthColors.phosphorBlue.withValues(alpha: 0.14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
          side: BorderSide(
            color: WavelengthColors.phosphorBlue.withValues(alpha: 0.40),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      label,
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
