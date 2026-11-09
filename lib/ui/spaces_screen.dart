import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../conversation_api.dart' show SharedNoteMatch;
import '../phone_profile_store.dart';
import '../schedule_data.dart' as sched;
import 'space_discovery_sheet.dart';
import 'wavelength_theme.dart';

/// Tuned Topic Spaces & Going Talks screen (`page4-spaces.png`), also serving
/// as the full screen-reader semantic list of spaces on the user's wavelength.
class SpacesScreen extends StatelessWidget {
  const SpacesScreen({
    super.key,
    required this.catalog,
    required this.profileStore,
    required this.initialProfile,
    required this.scopeGraph,
    this.livePeopleByTopic = const <String, int>{},
    this.liveTopicCounts = const <String, int>{},
    this.sharedMatches = const <SharedNoteMatch>[],
    this.onToggleGoing,
    this.onSelectTopic,
    this.onOpenRoomChat,
    this.showRoomChat = enableRoomChat,
  });

  final sched.ScheduleCatalog catalog;
  final PhoneProfileStore profileStore;
  final PhoneProfile initialProfile;
  final sched.ScopeGraphData scopeGraph;
  final Map<String, int> livePeopleByTopic;
  final Map<String, int> liveTopicCounts;
  final List<SharedNoteMatch> sharedMatches;
  final FutureOr<void> Function(String talkId)? onToggleGoing;
  final FutureOr<void> Function(String topic)? onSelectTopic;
  final void Function({required String room, required String title})?
  onOpenRoomChat;
  final bool showRoomChat;

  List<SharedSpaceNote> _sharedNotesForTopic(
    PhoneProfile profile,
    String topic,
  ) {
    final lower = topic.toLowerCase();
    return <SharedSpaceNote>[
      for (final note in profile.savedNotes)
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

  SpaceSheetNode _buildTopicSheetNode({
    required PhoneProfile profile,
    required String canonicalTopic,
    required Set<String> goingIds,
  }) {
    sched.ScopeTopicEntry? graphEntry;
    for (final entry in scopeGraph.topics) {
      if (entry.id.toLowerCase() == canonicalTopic.toLowerCase() ||
          entry.label.toLowerCase() == canonicalTopic.toLowerCase()) {
        graphEntry = entry;
        break;
      }
    }

    final talkCount =
        liveTopicCounts[canonicalTopic] ??
        graphEntry?.count ??
        catalog.sessionCountForTopic(canonicalTopic);
    final people =
        livePeopleByTopic[canonicalTopic] ?? graphEntry?.people ?? 0;

    final talksForTopic = catalog.talksForTopic(canonicalTopic);
    final featuredTalk =
        graphEntry?.featuredTalk ??
        (talksForTopic.isNotEmpty ? talksForTopic.first : null);
    final linked =
        graphEntry?.linkedTopics ??
        catalog
            .topicsLinkedTo(<String>[canonicalTopic])
            .take(5)
            .toList(growable: false);

    final noteCount = profile.savedNotes
        .where(
          (n) => n.topics.any(
            (t) => t.toLowerCase() == canonicalTopic.toLowerCase(),
          ),
        )
        .length;
    final why =
        graphEntry?.why ??
        (noteCount > 0
            ? '${noteCount == 1 ? 'One of your notes' : '$noteCount of your notes'} tuned this topic.'
            : (profile.selectedTopics.any(
                    (t) => t.toLowerCase() == canonicalTopic.toLowerCase(),
                  )
                  ? 'Selected in your interests.'
                  : 'Active across $talkCount ${talkCount == 1 ? 'talk' : 'talks'} on the schedule.'));

    return SpaceSheetNode(
      id: 'topic:$canonicalTopic',
      kind: SpaceKind.topic,
      title: graphEntry?.label ?? canonicalTopic,
      whyOnWavelength: why,
      talkCount: talkCount,
      peopleCount: people,
      talkId: featuredTalk?.id,
      talkTitle: featuredTalk?.title,
      timeSlot: featuredTalk?.time,
      room: featuredTalk?.room,
      isGoing: featuredTalk != null && goingIds.contains(featuredTalk.id),
      linkedTopics: linked,
      sharedNotes: _sharedNotesForTopic(profile, canonicalTopic),
    );
  }

  SpaceSheetNode _buildTalkSheetNode({
    required PhoneProfile profile,
    required sched.ScheduleTalk talk,
    required Set<String> goingIds,
  }) {
    final talkTopics = catalog.effectiveTopicsForTalk(talk.id);
    final primaryTopic = talkTopics.isNotEmpty ? talkTopics.first : null;
    final people = primaryTopic != null
        ? (livePeopleByTopic[primaryTopic] ?? 0)
        : 0;
    final talkCount = primaryTopic != null
        ? (liveTopicCounts[primaryTopic] ??
              catalog.sessionCountForTopic(primaryTopic))
        : null;

    return SpaceSheetNode(
      id: 'talk:${talk.id}',
      kind: SpaceKind.talk,
      title: talk.title,
      topicLabel: primaryTopic,
      whyOnWavelength: goingIds.contains(talk.id)
          ? (talkTopics.isNotEmpty
                ? 'On your schedule · covers ${talkTopics.take(2).join(' and ')}.'
                : 'Saved to the talks you plan to go to.')
          : (talkTopics.isNotEmpty
                ? 'Covers ${talkTopics.take(2).join(' and ')} on your wavelength.'
                : 'Scheduled conference session.'),
      talkCount: talkCount,
      peopleCount: people,
      talkId: talk.id,
      timeSlot: talk.time,
      room: talk.room,
      abstractText: talk.abstractText,
      isGoing: goingIds.contains(talk.id),
      linkedTopics: talkTopics,
      sharedNotes: <SharedSpaceNote>[
        for (final t in talkTopics) ..._sharedNotesForTopic(profile, t),
      ],
    );
  }

  void _openSheet(
    BuildContext context,
    SpaceSheetNode node, {
    String? chatRoom,
  }) {
    final resolvedRoom =
        chatRoom ??
        (node.kind == SpaceKind.topic
            ? 'topic:${node.title}'
            : (node.talkId != null ? 'talk:${node.talkId}' : node.id));
    showSpaceDiscoverySheet(
      context: context,
      node: node,
      showRoomChat: showRoomChat,
      onJoinChat: onOpenRoomChat == null
          ? null
          : () => onOpenRoomChat!(room: resolvedRoom, title: node.title),
      onToggleGoing: onToggleGoing == null
          ? null
          : (talkId, _) => unawaited(Future<void>.sync(() => onToggleGoing!(talkId))),
      onSelectTopic: onSelectTopic == null
          ? null
          : (topic) => unawaited(Future<void>.sync(() => onSelectTopic!(topic))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: profileStore,
      builder: (context, _) {
        final profile = profileStore.profile ?? initialProfile;
        final goingIds = profile.goingTalkIds.toSet();

        final tunedCanonical = catalog.canonicalizeTopics(
          profile.activeWavelengthTopics,
        );
        final displayedTopics = tunedCanonical;

        final goingTalks = <sched.ScheduleTalk>[
          for (final id in profile.goingTalkIds)
            if (catalog.talkById(id) case final sched.ScheduleTalk talk) talk,
        ];

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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
                children: <Widget>[
                  // Top Back + Spaces header
                  Transform.translate(
                    offset: const Offset(-12, 0),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
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
                            'Spaces',
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
                  const SizedBox(height: 4),
                  const Text(
                    'The topics you are tuned to, their chats, and the talks you plan to go to.',
                    style: TextStyle(
                      fontSize: 15.0,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                      color: WavelengthColors.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // YOUR TOPICS
                  const Text(
                    'YOUR TOPICS',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14.0,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.8,
                      color: WavelengthColors.phosphorBlue,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (displayedTopics.isEmpty)
                    const _DashedEmptyCard(
                      text:
                          'Pick an interest or record a note and your topics appear here.',
                    )
                  else
                    for (var i = 0; i < displayedTopics.length; i++) ...<Widget>[
                      Builder(
                        builder: (context) {
                          final topic = displayedTopics[i];
                          final sheetNode = _buildTopicSheetNode(
                            profile: profile,
                            canonicalTopic: topic,
                            goingIds: goingIds,
                          );
                          return _TopicSpaceCard(
                            title: sheetNode.title,
                            talkCount: sheetNode.talkCount ?? 0,
                            peopleCount: sheetNode.peopleCount,
                            showRoomChat: showRoomChat,
                            onTap: () => _openSheet(
                              context,
                              sheetNode,
                              chatRoom: 'topic:$topic',
                            ),
                            onTapChat: onOpenRoomChat == null
                                ? null
                                : () => onOpenRoomChat!(
                                    room: 'topic:$topic',
                                    title: sheetNode.title,
                                  ),
                          );
                        },
                      ),
                      if (i < displayedTopics.length - 1)
                        const SizedBox(height: 10),
                    ],

                  const SizedBox(height: 22),

                  // TALKS YOU'RE GOING TO
                  const Text(
                    "TALKS YOU'RE GOING TO",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14.0,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.8,
                      color: WavelengthColors.phosphorBlue,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (goingTalks.isEmpty)
                    const _DashedEmptyCard(
                      text:
                          'Tap "I\'m going" on a talk and it lands here, with its room and time.',
                    )
                  else
                    for (var i = 0; i < goingTalks.length; i++) ...<Widget>[
                      Builder(
                        builder: (context) {
                          final talk = goingTalks[i];
                          final sheetNode = _buildTalkSheetNode(
                            profile: profile,
                            talk: talk,
                            goingIds: goingIds,
                          );
                          return _GoingTalkCard(
                            talk: talk,
                            onTap: () => _openSheet(
                              context,
                              sheetNode,
                              chatRoom: 'talk:${talk.id}',
                            ),
                          );
                        },
                      ),
                      if (i < goingTalks.length - 1) const SizedBox(height: 10),
                    ],

                  if (sharedMatches.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 22),
                    const Text(
                      'SHARED NOTES ON YOUR WAVELENGTH',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14.0,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.8,
                        color: WavelengthColors.phosphorBlue,
                      ),
                    ),
                    const SizedBox(height: 10),
                    for (var i = 0; i < sharedMatches.length; i++) ...<Widget>[
                      _SharedMatchCard(match: sharedMatches[i]),
                      if (i < sharedMatches.length - 1)
                        const SizedBox(height: 10),
                    ],
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SharedMatchCard extends StatelessWidget {
  const _SharedMatchCard({required this.match});

  final SharedNoteMatch match;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A111B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF1B2A3D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            match.excerpt,
            style: const TextStyle(
              fontSize: 15.0,
              fontWeight: FontWeight.w400,
              height: 1.4,
              color: WavelengthColors.primaryText,
            ),
          ),
          if (match.topics.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final topic in match.topics.take(4))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: WavelengthColors.phosphorBlue.withValues(
                        alpha: 0.14,
                      ),
                      borderRadius: BorderRadius.circular(99),
                      border: Border.all(
                        color: WavelengthColors.phosphorBlue.withValues(
                          alpha: 0.40,
                        ),
                      ),
                    ),
                    child: Text(
                      topic,
                      style: const TextStyle(
                        fontSize: 13.0,
                        fontWeight: FontWeight.w600,
                        color: WavelengthColors.primaryText,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _TopicSpaceCard extends StatelessWidget {
  const _TopicSpaceCard({
    required this.title,
    required this.talkCount,
    required this.peopleCount,
    required this.showRoomChat,
    required this.onTap,
    this.onTapChat,
  });

  final String title;
  final int talkCount;
  final int peopleCount;
  final bool showRoomChat;
  final VoidCallback onTap;
  final VoidCallback? onTapChat;

  @override
  Widget build(BuildContext context) {
    final talksCopy = '$talkCount ${talkCount == 1 ? 'talk' : 'talks'}';
    final semanticSummary = peopleCount > 0
        ? 'Topic space: $title. $peopleCount tuned in, $talksCopy.'
        : 'Topic space: $title. $talksCopy.';

    return Semantics(
      button: true,
      label: semanticSummary,
      child: Material(
        color: const Color(0xFF0A111B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF1B2A3D)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: Center(
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: Alignment(-0.28, -0.40),
                            colors: <Color>[
                              Color(0xFFF0FAFF),
                              Color(0xFF38BDF8),
                              Color(0xFF0EA5E9),
                            ],
                            stops: <double>[0.0, 0.60, 1.0],
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Color(0xBF38BDF8),
                              blurRadius: 14,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16.0,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                            color: WavelengthColors.primaryText,
                          ),
                        ),
                        const SizedBox(height: 3),
                        if (peopleCount > 0)
                          Row(
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
                              Expanded(
                                child: Text(
                                  '$peopleCount tuned in · $talksCopy',
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
                          )
                        else
                          Text(
                            talksCopy,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.0,
                              fontWeight: FontWeight.w500,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (showRoomChat) ...<Widget>[
                    const SizedBox(width: 10),
                    Semantics(
                      button: true,
                      label: 'Chat about $title',
                      child: Material(
                        color: const Color(0xFF0B1420),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(99),
                          side: const BorderSide(color: Color(0xFF2A4664)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.selectionClick();
                            if (onTapChat != null) {
                              onTapChat!();
                            } else {
                              onTap();
                            }
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: 44,
                              minWidth: 56,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Center(
                                child: Text(
                                  'Chat',
                                  style: TextStyle(
                                    fontSize: 14.0,
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
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoingTalkCard extends StatelessWidget {
  const _GoingTalkCard({required this.talk, required this.onTap});

  final sched.ScheduleTalk talk;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final metaLines = <String>[
      if (talk.time.isNotEmpty) talk.time,
      if (talk.room.isNotEmpty) talk.room,
    ];

    return Semantics(
      button: true,
      label: 'Going to talk: ${talk.title}. ${metaLines.join(', ')}',
      child: Material(
        color: const Color(0xFF0A111B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF1B2A3D)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const SizedBox(
                    width: 34,
                    height: 34,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CustomPaint(painter: _FilledDiamondPainter()),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          talk.title,
                          style: const TextStyle(
                            fontSize: 16.0,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                            color: WavelengthColors.primaryText,
                          ),
                        ),
                        if (metaLines.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            metaLines.join('\n'),
                            style: const TextStyle(
                              fontSize: 14.0,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                              color: WavelengthColors.secondaryText,
                            ),
                          ),
                        ],
                      ],
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

class _FilledDiamondPainter extends CustomPainter {
  const _FilledDiamondPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const r = 9.0;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = WavelengthColors.talkStarlight);
  }

  @override
  bool shouldRepaint(covariant _FilledDiamondPainter oldDelegate) => false;
}

class _DashedEmptyCard extends StatelessWidget {
  const _DashedEmptyCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _DashedRoundedRectPainter(
        color: Color(0xFF22405E),
        radius: 18,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 15.0,
            fontWeight: FontWeight.w500,
            height: 1.4,
            color: WavelengthColors.secondaryText,
          ),
        ),
      ),
    );
  }
}

class _DashedRoundedRectPainter extends CustomPainter {
  const _DashedRoundedRectPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = color;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + 6.0).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += 11.0;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRoundedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
