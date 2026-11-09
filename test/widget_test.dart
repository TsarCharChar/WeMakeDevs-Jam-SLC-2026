import 'dart:io';

import 'package:conversation_garden/conversation_api.dart';
import 'package:conversation_garden/main.dart';
import 'package:conversation_garden/phone_profile_store.dart';
import 'package:conversation_garden/schedule_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String _testScheduleJson = '''
[
  {
    "id": "ebpf-observability-cilium-2026-11-10-1100",
    "title": "Zero-Overhead Observability with Cilium",
    "abstract": "Tracing container workloads without sidecars using OpenTelemetry.",
    "time": "Tue, Nov 10, 2026 · 11:00 AM – 11:30 AM",
    "day": "2026-11-10",
    "start": "2026-11-10T11:00:00",
    "end": "2026-11-10T11:30:00",
    "room": "Salt Palace | Room 250A",
    "tags": ["Observability", "Cilium", "OpenTelemetry"]
  },
  {
    "id": "llm-inference-k8s-2026-11-11-1400",
    "title": "Scaling Agentic AI Inference on Kubernetes",
    "abstract": "Prefix caching and GPU autoscaling for multi-tenant clusters.",
    "time": "Wed, Nov 11, 2026 · 2:00 PM – 2:30 PM",
    "day": "2026-11-11",
    "start": "2026-11-11T14:00:00",
    "end": "2026-11-11T14:30:00",
    "room": "Hyatt Regency | Ballroom C",
    "tags": ["AI Inference + Agentic", "Autoscaling"]
  }
]
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ScheduleCatalog testCatalog;
  late PhoneProfileStore profileStore;
  late LabeledFakeWavelengthBackend fakeBackend;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('confellow_widget_test_');
    testCatalog = ScheduleCatalog.fromJsonString(_testScheduleJson);
    profileStore = PhoneProfileStore(directoryProvider: () async => tempDir);
    fakeBackend = LabeledFakeWavelengthBackend(catalog: testCatalog);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => call.method == 'hasPermission' ? false : null,
        );
  });

  tearDown(() async {
    fakeBackend.close();
    await profileStore.flush();
    profileStore.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildTestableApp({Duration undoWindow = const Duration(seconds: 5)}) {
    return ConversationApp(
      catalog: testCatalog,
      profileStore: profileStore,
      backend: fakeBackend,
      undoWindow: undoWindow,
      disableAnimations: true,
    );
  }

  testWidgets('Denied microphone permission returns to a usable home screen', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestableApp());
    await tester.pumpAndSettle();

    expect(find.text('CONFELLOW'), findsOneWidget);
    expect(find.text('Tap to speak a note'), findsOneWidget);
    expect(find.textContaining('everyone’s permission'), findsNothing);

    await tester.tap(find.text('Tap to speak a note'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Enable microphone access'), findsOneWidget);
    expect(find.text('Tap to speak a note'), findsOneWidget);
    expect(find.text('One moment…'), findsNothing);
  });

  testWidgets('Home triggers radar sweep and opens search without sending', (
    tester,
  ) async {
    await tester.pumpWidget(buildTestableApp());
    await tester.pumpAndSettle();

    expect(find.text('Find wavelength'), findsOneWidget);
    await tester.tap(find.text('Find wavelength'));
    await tester.pump();

    await tester.tap(find.byTooltip('Search notes'));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(FilledButton, 'Search notes');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Cilium and OpenTelemetry');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(
      find.textContaining('Search currently queries a synthetic demo note.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Undo cancels a typed note before backend send, and Review before sending waits for Send',
    (tester) async {
      await tester.runAsync(() => profileStore.load());
      await tester.pumpWidget(
        buildTestableApp(undoWindow: const Duration(seconds: 4)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Compose a note mentioning Cilium -> stages Undo card immediately.
      await tester.tap(find.text('Type or paste note'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextField).first,
        'Exploring Cilium and OpenTelemetry tracing today',
      );
      await tester.pump();
      final addBtn = find.text('Tune wavelength with note');
      await tester.ensureVisible(addBtn);
      await tester.tap(addBtn);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Tuned:'), findsOneWidget);
      expect(fakeBackend.submittedPayloads, isEmpty);

      // 2. Tap Undo before the window elapses -> nothing ever hits the backend!
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tuned:'), findsNothing);
      expect(fakeBackend.submittedPayloads, isEmpty);

      // 3. Enable "Review before sending" in settings.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Review before sending'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      // 4. Compose another note -> shows Send note & Discard, does not auto-send.
      await tester.tap(find.text('Type or paste note'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'Autoscaling GPU inference workloads',
      );
      await tester.pump();
      final addBtn2 = find.text('Tune wavelength with note');
      await tester.ensureVisible(addBtn2);
      await tester.tap(addBtn2);
      await tester.pumpAndSettle();

      expect(find.text('Send note'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);
      expect(fakeBackend.submittedPayloads, isEmpty);

      await tester.runAsync(() async {
        await tester.tap(find.text('Send note'));
        await profileStore.flush();
      });
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(fakeBackend.submittedPayloads, hasLength(1));
      expect(fakeBackend.submittedPayloads.single['visibility'], 'conference');
      expect(fakeBackend.submittedPayloads.single['consent'], isTrue);
    },
  );

  testWidgets(
    'Space discovery sheet shows words-only match reason, people count, and I am going toggle',
    (tester) async {
      await tester.runAsync(() => profileStore.load());
      await tester.pumpWidget(buildTestableApp());
      await tester.pumpAndSettle();

      final talkRow = find.text('Zero-Overhead Observability with Cilium');
      await tester.scrollUntilVisible(
        talkRow,
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(talkRow);
      await tester.pumpAndSettle();

      expect(find.textContaining('Salt Palace | Room 250A'), findsOneWidget);
      expect(find.text('12 people tuned in'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('nearby'), findsNothing);

      final goingBtn = find.text("I'm going");
      await tester.scrollUntilVisible(
        goingBtn,
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(goingBtn);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(
        profileStore.profile!.goingTalkIds,
        contains('ebpf-observability-cilium-2026-11-10-1100'),
      );
    },
  );

  testWidgets('Search remains usable on a narrow display with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const SearchScreen(),
      ),
    );
    await tester.scrollUntilVisible(
      find.byType(TextField),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.testTextInput.hide();
    await tester.scrollUntilVisible(
      find.text('Search notes'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Search notes'),
          )
          .onPressed,
      isNull,
    );
  });
}
