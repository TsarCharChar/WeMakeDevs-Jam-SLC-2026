import 'package:conversation_garden/attendee_api.dart';
import 'package:conversation_garden/conversation_api.dart';
import 'package:conversation_garden/main.dart';
import 'package:conversation_garden/phone_profile_store.dart';
import 'package:conversation_garden/schedule_data.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:conversation_garden/ui/room_chat_screen.dart';
import 'package:conversation_garden/ui/wavelength_scope.dart';
import 'package:conversation_garden/ui/wavelength_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:record_platform_interface/record_platform_interface.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:record_platform_interface/src/record_platform.dart';

class _MemoryTranscriptStorage implements TranscriptStorage {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async => _value = value;
}

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
    "tags": ["AI Inference + Agentic", "Autoscaling", "Kubernetes"]
  },
  {
    "id": "platform-security-opa-2026-11-12-1000",
    "title": "Platform Policy Guardrails Across Clusters",
    "abstract": "Declarative admission control for platform teams.",
    "time": "Thu, Nov 12, 2026 · 10:00 AM – 10:30 AM",
    "day": "2026-11-12",
    "start": "2026-11-12T10:00:00",
    "end": "2026-11-12T10:30:00",
    "room": "Salt Palace | Room 155B",
    "tags": [
      "Platform Engineering",
      "Security",
      "Open Policy Agent (OPA)",
      "Open Cluster Management",
      "Developer Experience",
      "Contributor Experience",
      "Envoy",
      "Network",
      "Operations + Performance"
    ]
  }
]
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScheduleCatalog testCatalog;
  late PhoneProfileStore profileStore;
  late LabeledFakeWavelengthBackend fakeBackend;
  late TranscriptSync testSync;

  setUp(() async {
    RecordPlatform.instance = RecordPlatformImpl();
    TestWidgetsFlutterBinding.instance.platformDispatcher
            .accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    testCatalog = ScheduleCatalog.fromJsonString(_testScheduleJson);
    profileStore = PhoneProfileStore.inMemory();
    fakeBackend = LabeledFakeWavelengthBackend(catalog: testCatalog);
    testSync = TranscriptSync(
      startTimer: false,
      storage: _MemoryTranscriptStorage(),
      api: AttendeeApi(
        client: MockClient((_) async => http.Response('{}', 404)),
      ),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => call.method == 'hasPermission' ? false : null,
        );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAccessibilityFeaturesTestValue();
    testSync.dispose();
    fakeBackend.close();
    profileStore.dispose();
  });

  Widget buildTestableApp({
    Duration undoWindow = const Duration(seconds: 4),
    bool showOnboardingOnFirstLaunch = false,
  }) {
    return ConversationApp(
      sync: testSync,
      catalog: testCatalog,
      profileStore: profileStore,
      backend: fakeBackend,
      undoWindow: undoWindow,
      disableAnimations: true,
      showOnboardingOnFirstLaunch: showOnboardingOnFirstLaunch,
    );
  }

  Future<void> settleFrames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> drainFakeAsyncIo(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> composeTypedNote(WidgetTester tester, String text) async {
    final typeBtn = find.text('Type a note');
    await tester.ensureVisible(typeBtn);
    await tester.tap(typeBtn);
    await settleFrames(tester);

    await tester.enterText(find.byType(TextField).first, text);
    await tester.pump();
    final submitBtn = find.text('Tune wavelength with note');
    await tester.ensureVisible(submitBtn);
    await tester.tap(submitBtn);
    await tester.pump();
    await settleFrames(tester);
  }

  testWidgets(
    'Denied microphone permission shows amber error banner and returns to usable Tap to record a note',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await profileStore.load();
      await tester.pumpWidget(buildTestableApp());
      await settleFrames(tester);

      expect(find.text('CONFELLOW'), findsOneWidget);
      expect(find.text('Tap to record a note'), findsOneWidget);
      expect(
        find.text(
          'Audio stays on your phone.\nYour note\'s text is saved to your profile.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Tap to record a note'));
      await settleFrames(tester);

      expect(find.textContaining('Enable microphone access'), findsOneWidget);
      expect(find.text('Tap to record a note'), findsOneWidget);

      // Fix S4: error icon uses warningAmber (#F6C445), never micHotCoral (#FF7A59).
      final warningIcon = tester.widget<Icon>(
        find.byIcon(Icons.warning_amber_rounded),
      );
      expect(warningIcon.color, WavelengthColors.warningAmber);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Undo cancels before backend send past undo window, normal expiration sends once, and Review before sending waits for Send or Discard',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const undoWindow = Duration(seconds: 4);
      await profileStore.load();
      await tester.pumpWidget(buildTestableApp(undoWindow: undoWindow));
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Compose a note -> stages Undo card immediately; tap Undo and advance
      //    clock PAST undoWindow to prove 0 payloads are ever sent!
      await composeTypedNote(
        tester,
        'Exploring Cilium and OpenTelemetry tracing today',
      );
      expect(find.textContaining('Tuned:'), findsOneWidget);
      expect(fakeBackend.submittedPayloads, isEmpty);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Undo'), findsNothing);
      expect(fakeBackend.submittedPayloads, isEmpty);

      // 2. Normal Undo expiration sends exactly once after undoWindow elapses.
      await composeTypedNote(
        tester,
        'Observability metrics with OpenTelemetry',
      );
      expect(find.text('Undo'), findsOneWidget);
      expect(fakeBackend.submittedPayloads, isEmpty);

      await tester.pump(const Duration(seconds: 5));
      await drainFakeAsyncIo(tester);
      expect(fakeBackend.submittedPayloads, hasLength(1));

      // 3. Enable "Review before sending" in Settings (and verify Saved transcripts link).
      await tester.tap(find.byTooltip('Settings'));
      await settleFrames(tester);
      expect(find.text('Saved transcripts'), findsOneWidget);

      await tester.tap(find.text('Review before sending'));
      await drainFakeAsyncIo(tester);
      await settleFrames(tester);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await settleFrames(tester);

      // 4. Test Discard under "Review before sending": waits past undoWindow
      //    with 0 new backend calls, and Discard drops the note cleanly.
      await composeTypedNote(tester, ' Envoy mesh routing notes ');
      expect(find.text('READY TO SEND'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      expect(fakeBackend.submittedPayloads, hasLength(1));

      await tester.tap(find.text('Discard'));
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('READY TO SEND'), findsNothing);
      expect(fakeBackend.submittedPayloads, hasLength(1));

      // 5. Test Send under "Review before sending": waits past undoWindow with
      //    0 calls until Send is tapped.
      await composeTypedNote(tester, 'Autoscaling GPU inference workloads');
      await tester.pump(const Duration(seconds: 6));
      expect(
        fakeBackend.submittedPayloads,
        hasLength(1),
        reason: 'Review before sending must not auto-send after undo window',
      );

      await tester.tap(find.text('Send'));
      await drainFakeAsyncIo(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(fakeBackend.submittedPayloads, hasLength(2));
      expect(fakeBackend.submittedPayloads.last['visibility'], 'conference');
      expect(fakeBackend.submittedPayloads.last['consent'], isTrue);
    },
  );

  testWidgets(
    'Unmatched note shows Note saved and invents zero schedule topics (Fix B4)',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await profileStore.load();
      await tester.pumpWidget(buildTestableApp());
      await settleFrames(tester);

      await composeTypedNote(
        tester,
        'I am open to grabbing lunch and sharing my experience',
      );

      expect(find.text('Note saved'), findsOneWidget);
      expect(find.text('NOTE SAVED'), findsOneWidget);
      expect(find.textContaining('Tuned:'), findsNothing);
      expect(find.text('Contributor Experience'), findsNothing);
      expect(find.text('Developer Experience'), findsNothing);
      expect(find.text('Open Cluster Management'), findsNothing);

      // Let undo window expire and verify 0 topics were invented on submission.
      await tester.pump(const Duration(seconds: 5));
      await drainFakeAsyncIo(tester);
      await tester.pump(const Duration(seconds: 5));

      expect(fakeBackend.submittedPayloads, hasLength(1));
      expect(fakeBackend.submittedPayloads.single['topics'], isEmpty);
      expect(profileStore.profile!.selectedTopics, isEmpty);
    },
  );

  testWidgets(
    '412x892 4-screen flow: Note -> Wavelength Scope -> Interests -> Spaces -> Space sheet & I am going',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await profileStore.load();
      await tester.pumpWidget(buildTestableApp());
      await settleFrames(tester);

      // 1. Trigger "Find my wavelength" on Note tab.
      await tester.tap(find.text('Find my wavelength'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Updated:'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 2. Switch to "Wavelength" tab -> renders WavelengthScope cleanly.
      await tester.tap(find.text('Wavelength'));
      await settleFrames(tester);
      expect(find.byType(WavelengthScope), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 2b. Fresh profile on "Spaces" shows empty dashed topic card (Fix 3).
      await tester.tap(find.text('Spaces'));
      await settleFrames(tester);
      expect(
        find.text(
          'Pick an interest or record a note and your topics appear here.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Back'));
      await settleFrames(tester);

      // 3. Open "Interests" -> tap a bubble + "More" + "Retune my wavelength".
      await tester.tap(find.text('Interests'));
      await settleFrames(tester);
      expect(find.text('SUGGESTED FOR YOU'), findsOneWidget);

      await tester.tap(find.text('Observability'));
      await tester.pump();
      expect(
        find.textContaining('A dot marks topics linked to Observability'),
        findsOneWidget,
      );

      await tester.tap(find.text('More'));
      await tester.pump();

      await tester.tap(find.text('Retune my wavelength'));
      await drainFakeAsyncIo(tester);
      await tester.pump(const Duration(seconds: 5));
      await settleFrames(tester);

      expect(find.byType(WavelengthScope), findsOneWidget);
      expect(profileStore.profile!.selectedTopics, contains('Observability'));
      expect(tester.takeException(), isNull);

      // 4. Open "Spaces" -> shows topic talks count, NO invented "tuned in",
      //    and empty "Tap \"I'm going\" on a talk..." card.
      await tester.tap(find.text('Spaces'));
      await settleFrames(tester);

      expect(find.text('YOUR TOPICS'), findsOneWidget);
      expect(find.text("TALKS YOU'RE GOING TO"), findsOneWidget);
      expect(find.text('Observability'), findsOneWidget);
      expect(find.text('1 talk'), findsOneWidget);
      expect(find.textContaining('tuned in'), findsNothing);
      expect(
        find.text(
          'Tap "I\'m going" on a talk and it lands here, with its room and time.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // 5. Open Space discovery sheet from topic card -> zero overflow, zero
      //    invented people count, "Join the chat" button visible, toggle "I'm going" populates going talks!
      await tester.tap(find.text('Observability'));
      await settleFrames(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('TOPIC SPACE'), findsOneWidget);
      expect(find.text("WHY IT'S ON YOUR WAVELENGTH"), findsOneWidget);
      expect(find.text('Join the chat'), findsOneWidget);
      expect(
        find.text('Zero-Overhead Observability with Cilium'),
        findsOneWidget,
      );
      expect(find.textContaining('tuned in'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('nearby'), findsNothing);

      await tester.tap(find.text("I'm going"));
      await drainFakeAsyncIo(tester);
      await settleFrames(tester);
      expect(find.text('Going ✓'), findsOneWidget);
      expect(
        profileStore.profile!.goingTalkIds,
        contains('ebpf-observability-cilium-2026-11-10-1100'),
      );

      // Close sheet and confirm talk now appears under "TALKS YOU'RE GOING TO".
      await tester.tap(find.byTooltip('Close'));
      await settleFrames(tester);

      expect(
        find.text('Zero-Overhead Observability with Cilium'),
        findsOneWidget,
      );
      expect(find.textContaining('Salt Palace | Room 250A'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 6. Tap "Chat" pill on topic card -> opens RoomChatScreen cleanly.
      await tester.tap(find.text('Chat'));
      await drainFakeAsyncIo(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(RoomChatScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'First-launch onboarding collects display_name and topics without changing cf_ handle and opens Note page',
    (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final initial = await profileStore.load();
      final originalHandle = initial.handle;
      expect(initial.onboardingDone, isFalse);

      await tester.pumpWidget(
        buildTestableApp(showOnboardingOnFirstLaunch: true),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('What should we call you?'), findsOneWidget);
      expect(
        find.text('Shown next to what you say in chats.'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField).first, 'Ada Lovelace');
      await tester.tap(find.text('Observability'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await drainFakeAsyncIo(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Tap to record a note'), findsOneWidget);
      expect(profileStore.profile!.handle, originalHandle);
      expect(profileStore.profile!.displayName, 'Ada Lovelace');
      expect(profileStore.profile!.selectedTopics, contains('Observability'));
      expect(profileStore.profile!.onboardingDone, isTrue);
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
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
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
    await settleFrames(tester);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.testTextInput.hide();
    await tester.scrollUntilVisible(
      find.text('Search notes'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await settleFrames(tester);
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
