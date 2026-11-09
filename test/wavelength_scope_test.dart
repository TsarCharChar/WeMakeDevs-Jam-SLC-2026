// Smoke tests for the Wavelength Scope and the Note page painters: they must paint every state without throwing,
// report taps on nodes, and stand still when motion is reduced.
//
// Run with `--update-goldens` to also write a picture of each state under test/goldens/,
// for comparing with the mock-up by eye. The pictures are not checked in CI.
import 'dart:io';

import 'package:conversation_garden/ui/wavelength_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const List<ScopeTopic> topics = <ScopeTopic>[
  ScopeTopic(id: 'obs', label: 'Observability', count: 60, ring: 0, people: 4, angleDeg: 315),
  ScopeTopic(id: 'otel', label: 'OpenTelemetry', count: 44, ring: 0, people: 2, angleDeg: 40),
  ScopeTopic(id: 'ai', label: 'AI Inference', count: 126, ring: 0, people: 6, angleDeg: 160),
  ScopeTopic(id: 'plat', label: 'Platform Eng', count: 36, ring: 1, people: 3, angleDeg: 215),
  ScopeTopic(id: 'ops', label: 'Ops + Perf', count: 65, ring: 1, people: 2, angleDeg: 265),
  ScopeTopic(id: 'dev', label: 'Device Mgmt', count: 86, ring: 1, people: 3, angleDeg: 100),
  ScopeTopic(id: 'cil', label: 'Cilium', count: 23, ring: 2, people: 1, angleDeg: 80),
  ScopeTopic(id: 'sec', label: 'Security', count: 77, ring: 2, people: 2, angleDeg: 350),
  ScopeTopic(id: 'auto', label: 'Autoscaling', count: 46, ring: 2, people: 1, angleDeg: 190),
];
const List<ScopeEdge> edges = <ScopeEdge>[
  ScopeEdge('obs', 'otel', 24), ScopeEdge('obs', 'ai', 21), ScopeEdge('ai', 'dev', 44), ScopeEdge('ai', 'sec', 20),
  ScopeEdge('ai', 'ops', 19), ScopeEdge('ai', 'auto', 17), ScopeEdge('ops', 'sec', 16), ScopeEdge('ops', 'dev', 15),
  ScopeEdge('obs', 'ops', 11), ScopeEdge('auto', 'dev', 11), ScopeEdge('obs', 'cil', 10), ScopeEdge('ai', 'plat', 10),
  ScopeEdge('plat', 'sec', 10), ScopeEdge('otel', 'cil', 7), ScopeEdge('cil', 'sec', 5),
  ScopeEdge('obs', 'missing', 3), // an edge to a topic that is not on screen must be ignored
];
const List<ScopeTalk> talks = <ScopeTalk>[
  ScopeTalk(id: 't1', topicId: 'obs'), ScopeTalk(id: 't2', topicId: 'otel'), ScopeTalk(id: 't3', topicId: 'ai', going: true),
  ScopeTalk(id: 't4', topicId: 'plat'), ScopeTalk(id: 't5', topicId: 'cil'), ScopeTalk(id: 't6', topicId: 'sec'),
  ScopeTalk(id: 't7', topicId: 'auto'), ScopeTalk(id: 't8', topicId: 'missing'),
];
const List<ScopeNote> notes = <ScopeNote>[
  ScopeNote(id: 'n1', topicIds: <String>['obs', 'otel']),
  ScopeNote(id: 'n2', topicIds: <String>['ai']),
  ScopeNote(id: 'n3', topicIds: <String>['plat', 'ai', 'missing']),
];

const TextStyle roboto = TextStyle(fontFamily: 'Roboto', fontSize: 14, fontWeight: FontWeight.w600);
final GlobalKey shot = GlobalKey();

Widget host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: const Color(0xFF04060A),
    body: RepaintBoundary(key: shot, child: child),
  ),
);

Widget scope({
  List<ScopeTopic> withTopics = topics,
  List<ScopeNote> withNotes = notes,
  String? selectedId,
  bool micLive = false,
  double micLevel = 0,
  Duration? elapsed,
  int press = 0,
  int tune = 0,
  bool? reduceMotion,
  ValueChanged<String>? onSelect,
  VoidCallback? onTapEmpty,
}) => host(
  Column(
    children: <Widget>[
      SizedBox(
        width: 412,
        height: 412,
        child: WavelengthScope(
          topics: withTopics,
          talks: talks,
          edges: edges,
          notes: withNotes,
          selectedId: selectedId,
          micLive: micLive,
          micLevel: micLevel,
          recordingElapsed: elapsed,
          pressImpulse: press,
          tuneImpulse: tune,
          reduceMotion: reduceMotion,
          onSelect: onSelect,
          onTapEmpty: onTapEmpty,
          labelStyle: roboto,
        ),
      ),
      SizedBox(width: 412, height: 110, child: WaveStrip(micLive: micLive, micLevel: micLevel, pressImpulse: press, reduceMotion: reduceMotion)),
    ],
  ),
);

Future<void> picture(WidgetTester tester, String name) async {
  if (!autoUpdateGoldenFiles) return;
  await expectLater(find.byKey(shot), matchesGoldenFile('goldens/scope_$name.png'));
}

void main() {
  setUpAll(() async {
    // Real glyphs for the pictures. Without this the test font draws every letter as a box.
    final String root = Platform.environment['FLUTTER_ROOT'] ?? '';
    final File font = File('$root/bin/cache/artifacts/material_fonts/Roboto-Medium.ttf');
    if (font.existsSync()) {
      final FontLoader loader = FontLoader('Roboto')..addFont(font.readAsBytes().then((List<int> b) => ByteData.view(Uint8List.fromList(b).buffer)));
      await loader.load();
    }
  });

  setUp(() {
    final TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first
      ..physicalSize = const Size(824, 1060)
      ..devicePixelRatio = 2;
  });

  testWidgets('paints idle, recording, selected and tuned states without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(scope());
    await tester.pump(const Duration(milliseconds: 3200));
    expect(tester.takeException(), isNull);
    await picture(tester, 'idle');

    await tester.pumpWidget(scope(micLive: true, micLevel: 0.8, elapsed: const Duration(seconds: 7), press: 1));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await picture(tester, 'recording');

    await tester.pumpWidget(scope(selectedId: 'ai', press: 2));
    await tester.pump(const Duration(milliseconds: 2900));
    expect(tester.takeException(), isNull);
    await picture(tester, 'selected');

    // A note is tuned: two topics move one ring closer and a new note appears.
    final List<ScopeTopic> closer = <ScopeTopic>[
      for (final ScopeTopic t in topics)
        t.id == 'cil' || t.id == 'sec' ? ScopeTopic(id: t.id, label: t.label, count: t.count, ring: 1, people: t.people, angleDeg: t.angleDeg) : t,
    ];
    await tester.pumpWidget(scope(withTopics: closer, withNotes: <ScopeNote>[...notes, const ScopeNote(id: 'n4', topicIds: <String>['cil', 'sec'])], press: 2, tune: 1));
    for (int i = 0; i < 110; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await picture(tester, 'tuned');

    await tester.pumpWidget(scope(selectedId: 't3', press: 2, tune: 1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tap on a node reports its id, and a tap on empty space reports that', (WidgetTester tester) async {
    final List<String> selected = <String>[];
    int empty = 0;
    // Reduced motion keeps every node at its exact ring and angle, so the tap points are known.
    await tester.pumpWidget(scope(reduceMotion: true, onSelect: selected.add, onTapEmpty: () => empty++));
    final Offset centre = tester.getCenter(find.byType(WavelengthScope));
    // 'ai' sits on ring 0 (radius 64) at compass 160 degrees.
    await tester.tapAt(centre + const Offset(21.9, 60.1));
    // 'cil' sits on ring 2 (radius 162) at compass 80 degrees.
    await tester.tapAt(centre + const Offset(159.5, -28.1));
    await tester.tapAt(centre + const Offset(-190, -190));
    expect(selected, <String>['ai', 'cil']);
    expect(empty, 1);
  });

  testWidgets('with reduced motion the map comes to rest', (WidgetTester tester) async {
    await tester.pumpWidget(scope(reduceMotion: true, micLive: true, micLevel: 0.6, elapsed: const Duration(seconds: 30)));
    // pumpAndSettle only returns when no frame is scheduled, so a ticker left running fails here.
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
    await picture(tester, 'reduced');
  });

  testWidgets('the Note page mic halo and wave paint idle, live, retuning and at rest', (WidgetTester tester) async {
    Widget note({bool live = false, double level = 0, int press = 0, int find = 0, bool? reduceMotion}) => host(
      Column(
        children: <Widget>[
          SizedBox(
            width: 412,
            height: 240,
            child: MicHalo(micLive: live, micLevel: level, pressImpulse: press, recordingElapsed: live ? const Duration(seconds: 7) : null, reduceMotion: reduceMotion),
          ),
          SizedBox(width: 412, height: 180, child: NoteWave(micLive: live, micLevel: level, findImpulse: find, reduceMotion: reduceMotion)),
        ],
      ),
    );
    await tester.pumpWidget(note());
    await tester.pump(const Duration(milliseconds: 3200));
    expect(tester.takeException(), isNull);
    await picture(tester, 'note_idle');

    await tester.pumpWidget(note(live: true, level: 0.8, press: 1));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await picture(tester, 'note_recording');

    await tester.pumpWidget(note(press: 1, find: 1));
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
    await picture(tester, 'note_retuning');

    await tester.pumpWidget(note(reduceMotion: true, live: true, level: 0.5, press: 2, find: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty map paints', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const SizedBox(width: 320, height: 320, child: WavelengthScope(topics: <ScopeTopic>[]))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
