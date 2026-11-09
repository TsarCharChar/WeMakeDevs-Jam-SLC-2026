import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'constellation_map.dart';
import 'wavelength_theme.dart';

/// Feature flag reserving the room chat slot until `/rooms` exists on the backend.
///
/// Hidden by default per `PROTOCOL.md` ("Reserve a slot for room chat behind a
/// flag, hidden until `/rooms` exists").
const bool enableRoomChat = false;

/// Presents [SpaceDiscoverySheet] as a modal Black + Blue Phosphor bottom sheet.
Future<void> showSpaceDiscoverySheet({
  required BuildContext context,
  required ConstellationNode node,
  TopicColorMode colorMode = TopicColorMode.phosphorRadar,
  ValueChanged<bool>? onToggleGoing,
  ValueChanged<String>? onSelectTopic,
  bool showRoomChat = enableRoomChat,
  WidgetBuilder? roomChatSlotBuilder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: WavelengthColors.elevated,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (sheetContext) => SpaceDiscoverySheet(
      node: node,
      colorMode: colorMode,
      onToggleGoing: onToggleGoing,
      onSelectTopic: onSelectTopic,
      showRoomChat: showRoomChat,
      roomChatSlotBuilder: roomChatSlotBuilder,
    ),
  );
}

/// Bottom sheet opened when tapping any Scheduled Talk or Topic Space node/card.
///
/// Enforces ConFellow UX & privacy invariants:
/// - Explains why the Space is on your wavelength **in words** (zero `%`, zero `"nearby"`).
/// - Displays attendee count **in words** (e.g. `"4 people tuned in"`, never `@handles`).
/// - Shows room, time, abstract, and an **"I'm going"** toggle (`HapticFeedback.selectionClick()`)
///   for Scheduled Talks.
/// - Renders note text **only** for explicitly shared notes (or labeled demo notes).
/// - Keeps the room chat slot hidden behind [enableRoomChat] (`false` by default).
class SpaceDiscoverySheet extends StatefulWidget {
  const SpaceDiscoverySheet({
    super.key,
    required this.node,
    this.colorMode = TopicColorMode.phosphorRadar,
    this.onToggleGoing,
    this.onSelectTopic,
    this.showRoomChat = enableRoomChat,
    this.roomChatSlotBuilder,
  });

  final ConstellationNode node;
  final TopicColorMode colorMode;
  final ValueChanged<bool>? onToggleGoing;
  final ValueChanged<String>? onSelectTopic;
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
    HapticFeedback.selectionClick();
    final next = !_isGoing;
    setState(() => _isGoing = next);
    widget.onToggleGoing?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final visibleSharedNotes = node.sharedNotes
        .where(
          (n) =>
              n.displayableText != null && n.displayableText!.trim().isNotEmpty,
        )
        .toList(growable: false);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: node.kind == SpaceKind.talk ? 0.72 : 0.60,
      minChildSize: 0.42,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: WavelengthColors.elevated,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: WavelengthColors.borderSpecular, width: 1),
            ),
          ),
          child: Column(
            children: [
              // Drag handle + close bar
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 12, 4),
                child: Row(
                  children: [
                    SpaceShapeBadge(
                      kind: node.kind,
                      topics: node.matchedTopics,
                      colorMode: widget.colorMode,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      node.kind.badgeLabel,
                      style: WavelengthTypography.supporting.copyWith(
                        color: WavelengthColors.phosphorIce,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: WavelengthColors.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: WavelengthColors.borderSpecular,
                        ),
                      ),
                      child: Text(
                        node.ring.humanLabel,
                        style: WavelengthTypography.supporting,
                      ),
                    ),
                    const Spacer(),
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
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                  children: [
                    // Title
                    Text(node.title, style: WavelengthTypography.sheetTitle),
                    const SizedBox(height: 14),

                    // Why it's on your wavelength (in words — zero % or "nearby")
                    PhosphorSurfaceCard(
                      accentBorderColor: WavelengthColors.innerRing,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Icon(
                              Icons.waves_rounded,
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
                                  'Why this is on your wavelength',
                                  style: WavelengthTypography.supporting
                                      .copyWith(
                                        color: WavelengthColors.phosphorIce,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  node.whyOnWavelength,
                                  style: WavelengthTypography.body,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Tuned-in people count + note recency (counts only, never @handles)
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        _MetadataPill(
                          icon: Icons.people_outline_rounded,
                          label: node.tunedPeopleCopy,
                        ),
                        if (node.recentActivityLabel != null &&
                            node.recentActivityLabel!.trim().isNotEmpty)
                          _MetadataPill(
                            icon: Icons.schedule_rounded,
                            label: node.recentActivityLabel!,
                          ),
                      ],
                    ),

                    // Scheduled Talk section: Room, Time, "I'm going" toggle & Abstract
                    if (node.kind == SpaceKind.talk) ...[
                      const SizedBox(height: 16),
                      PhosphorSurfaceCard(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (node.timeSlot != null &&
                                node.timeSlot!.trim().isNotEmpty) ...[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.event_rounded,
                                    size: 19,
                                    color: WavelengthColors.phosphorCyan,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      node.timeSlot!,
                                      style: WavelengthTypography.body.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                            ],
                            if (node.room != null &&
                                node.room!.trim().isNotEmpty) ...[
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.meeting_room_outlined,
                                    size: 19,
                                    color: WavelengthColors.secondaryText,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      node.room!,
                                      style: WavelengthTypography.supporting
                                          .copyWith(
                                            color: WavelengthColors.primaryText,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                            ],
                            // >= 48dp CVD-safe "I'm going" toggle button
                            Semantics(
                              button: true,
                              toggled: _isGoing,
                              label: "I'm going to this talk",
                              child: SizedBox(
                                width: double.infinity,
                                height: 48,
                                child: _isGoing
                                    ? FilledButton.icon(
                                        onPressed: _handleToggleGoing,
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              WavelengthColors.phosphorBlue,
                                          foregroundColor:
                                              WavelengthColors.onPhosphor,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.check_circle_rounded,
                                          size: 20,
                                        ),
                                        label: const Text(
                                          "I'm going · Saved",
                                          style: TextStyle(
                                            fontSize: 15.0,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      )
                                    : OutlinedButton.icon(
                                        onPressed: _handleToggleGoing,
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor:
                                              WavelengthColors.primaryText,
                                          backgroundColor:
                                              WavelengthColors.canvas,
                                          side: const BorderSide(
                                            color:
                                                WavelengthColors.phosphorBlue,
                                            width: 1.4,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.bookmark_add_outlined,
                                          size: 20,
                                          color: WavelengthColors.phosphorCyan,
                                        ),
                                        label: const Text(
                                          "I'm going",
                                          style: TextStyle(
                                            fontSize: 15.0,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Recent Matched Topics Chips
                    if (node.matchedTopics.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Recent topics on this wavelength',
                        style: WavelengthTypography.sectionTitle,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final topic in node.matchedTopics)
                            ActionChip(
                              materialTapTargetSize:
                                  MaterialTapTargetSize.padded,
                              avatar: const Icon(
                                Icons.tag_rounded,
                                size: 16,
                                color: WavelengthColors.phosphorCyan,
                              ),
                              label: Text(
                                topic,
                                style: WavelengthTypography.supporting.copyWith(
                                  color: WavelengthColors.primaryText,
                                ),
                              ),
                              onPressed: widget.onSelectTopic == null
                                  ? null
                                  : () {
                                      HapticFeedback.selectionClick();
                                      widget.onSelectTopic!(topic);
                                    },
                            ),
                        ],
                      ),
                    ],

                    // Talk Abstract
                    if (node.kind == SpaceKind.talk &&
                        node.abstractText != null &&
                        node.abstractText!.trim().isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'Session abstract',
                        style: WavelengthTypography.sectionTitle,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        node.abstractText!.trim(),
                        style: WavelengthTypography.body.copyWith(
                          color: WavelengthColors.secondaryText,
                        ),
                      ),
                    ],

                    // Shared Notes (strictly only shared or explicitly labeled demo notes!)
                    if (visibleSharedNotes.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      const Text(
                        'Shared notes',
                        style: WavelengthTypography.sectionTitle,
                      ),
                      const SizedBox(height: 10),
                      for (final sharedNote in visibleSharedNotes) ...[
                        PhosphorSurfaceCard(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    sharedNote.isDemo
                                        ? Icons.science_outlined
                                        : Icons.speaker_notes_outlined,
                                    size: 17,
                                    color: WavelengthColors.phosphorCyan,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    sharedNote.isDemo
                                        ? 'Demo note'
                                        : 'Shared note',
                                    style: WavelengthTypography.supporting
                                        .copyWith(
                                          color: WavelengthColors.phosphorIce,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                sharedNote.displayableText!,
                                style: WavelengthTypography.body,
                              ),
                              if (sharedNote.topics.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final t in sharedNote.topics)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: WavelengthColors.elevated,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color:
                                                WavelengthColors.borderSubtle,
                                          ),
                                        ),
                                        child: Text(
                                          t,
                                          style:
                                              WavelengthTypography.supporting,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ] else ...[
                      const SizedBox(height: 18),
                      Text(
                        'Notes stay private by default. Only matched topics shape this space unless someone shares a note.',
                        style: WavelengthTypography.supporting,
                      ),
                    ],

                    // Reserved Room Chat Slot — gated behind `enableRoomChat` (false by default)
                    if (widget.showRoomChat) ...[
                      const SizedBox(height: 22),
                      if (widget.roomChatSlotBuilder != null)
                        widget.roomChatSlotBuilder!(context)
                      else
                        const PhosphorSurfaceCard(
                          child: Text(
                            'Room chat connected.',
                            style: WavelengthTypography.supporting,
                          ),
                        ),
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

class _MetadataPill extends StatelessWidget {
  const _MetadataPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: WavelengthColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: WavelengthColors.borderSpecular),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: WavelengthColors.phosphorCyan),
          const SizedBox(width: 7),
          Text(
            label,
            style: WavelengthTypography.supporting.copyWith(
              color: WavelengthColors.primaryText,
            ),
          ),
        ],
      ),
    );
  }
}

/// Companion row card for listing Spaces below the 8-node Constellation hero.
class SpaceSignalListTile extends StatelessWidget {
  const SpaceSignalListTile({
    super.key,
    required this.node,
    required this.onTap,
    this.colorMode = TopicColorMode.phosphorRadar,
  });

  final ConstellationNode node;
  final VoidCallback onTap;
  final TopicColorMode colorMode;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label:
          '${node.kind.badgeLabel}: ${node.title}. ${node.ring.humanLabel}. ${node.tunedPeopleCopy}',
      child: Material(
        color: WavelengthColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: node.movedCloser
                ? WavelengthColors.phosphorBlue
                : WavelengthColors.borderSubtle,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  SpaceShapeBadge(
                    kind: node.kind,
                    topics: node.matchedTopics,
                    colorMode: colorMode,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          node.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WavelengthTypography.sectionTitle,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${node.ring.humanLabel} · ${node.tunedPeopleCopy}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WavelengthTypography.supporting,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: WavelengthColors.secondaryText,
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
