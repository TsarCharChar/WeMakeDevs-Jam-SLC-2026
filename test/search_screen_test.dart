import 'dart:async';

import 'package:conversation_garden/conversation_api.dart';
import 'package:conversation_garden/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> submit(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'Kubernetes');
  await tester.pump();
  final button = find.widgetWithText(FilledButton, 'Search conversations');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void main() {
  testWidgets('submits once, shows loading, then renders returned transcript', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final api = ConversationApi(
      client: MockClient((_) {
        calls++;
        return pending.future;
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    expect(calls, 0);
    await submit(tester);
    expect(calls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    pending.complete(
      http.Response(
        '{"conversations":[{"id":"one","conference":"__setup_smoke__","transcript":"Container scaling"}]}',
        200,
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Container scaling'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Demo conversation'), findsOneWidget);
    expect(find.text('Container scaling'), findsOneWidget);
  });

  testWidgets('error allows retry and empty response has a distinct state', (
    tester,
  ) async {
    var calls = 0;
    final api = ConversationApi(
      client: MockClient(
        (_) async => ++calls == 1
            ? http.Response('internal failure', 503)
            : http.Response('{"conversations":[]}', 200),
      ),
    );
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    await submit(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('search is unavailable'), findsOneWidget);
    expect(find.text('internal failure'), findsNothing);
    final retry = find.widgetWithText(FilledButton, 'Retry search');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('No conversations found'), findsOneWidget);
  });

  testWidgets('late response after leaving the screen is ignored', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final api = ConversationApi(client: MockClient((_) => pending.future));
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(home: SearchScreen(api: api)));
    await submit(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(http.Response('{"conversations":[]}', 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
