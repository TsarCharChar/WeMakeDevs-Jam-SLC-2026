import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conversation_garden/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async => call.method == 'hasPermission' ? false : null,
        );
  });
  testWidgets('Denied microphone permission returns to a usable home screen', (
    tester,
  ) async {
    await tester.pumpWidget(const ConversationApp());
    await tester.tap(find.text('Press to record\na note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enable microphone access'), findsOneWidget);
    expect(find.text('Press to record\na note'), findsOneWidget);
    expect(find.text('One moment…'), findsNothing);
  });
  testWidgets('Home presents both actions and opens search without sending', (
    tester,
  ) async {
    await tester.pumpWidget(const ConversationApp());
    expect(find.text('CONFELLOW'), findsOneWidget);
    expect(find.text('Press to record\na note'), findsOneWidget);
    expect(find.textContaining('everyone’s permission'), findsNothing);
    final search = find.text('Find my\nwavelength');
    await tester.ensureVisible(search);
    await tester.tap(search);
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, 'Search notes');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Flutter and local AI');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(
      find.textContaining('Search currently queries a synthetic demo note.'),
      findsOneWidget,
    );
  });
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
