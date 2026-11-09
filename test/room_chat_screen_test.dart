// The room chat screen: shows a room, sends one message per press, and says so plainly when the
// backend has no chat route yet.
import 'dart:convert';

import 'package:conversation_garden/ui/room_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget chat(http.Client client) => MaterialApp(
  home: RoomChatScreen(
    baseUrl: Uri.parse('https://example.test'),
    token: 'token-123',
    conference: 'cnh',
    room: 'topic:AI Inference + Agentic',
    title: 'AI Inference + Agentic',
    client: client,
    pollInterval: const Duration(seconds: 2),
  ),
);

http.Response page(List<Map<String, Object>> messages, {int people = 0}) =>
    http.Response(jsonEncode(<String, Object>{'room': 'topic:ai inference + agentic', 'people': people, 'messages': messages}), 200);

void main() {
  testWidgets('shows the room, sends one message per press and reads it back', (WidgetTester tester) async {
    final List<Map<String, Object>> stored = <Map<String, Object>>[
      <String, Object>{'id': 'm1', 'text': 'Anyone going to the llm-d talk?', 'author': 'grace', 'mine': false},
    ];
    final List<http.Request> posts = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      expect(request.headers['Authorization'], 'Bearer token-123');
      expect(request.url.pathSegments, <String>['rooms', 'topic:AI Inference + Agentic', 'messages']);
      if (request.method == 'POST') {
        posts.add(request);
        stored.add(<String, Object>{'id': 'm${stored.length + 1}', 'text': (jsonDecode(request.body) as Map<String, dynamic>)['text'] as String, 'author': 'ada', 'mine': true});
        return http.Response('{"id":"x","room":"r","at":"t"}', 201);
      }
      expect(request.url.queryParameters, <String, String>{'conference': 'cnh'});
      return page(stored, people: stored.length);
    });
    await tester.pumpWidget(chat(client));
    await tester.pump();
    expect(find.text('AI Inference + Agentic'), findsOneWidget);
    expect(find.text('Anyone going to the llm-d talk?'), findsOneWidget);
    expect(find.text('grace'), findsOneWidget);
    expect(find.text('1 person here'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  Yes, see you there  ');
    await tester.tap(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton), warnIfMissed: false); // a second press while sending is ignored
    await tester.pump();
    await tester.pump();
    expect(posts, hasLength(1));
    expect(jsonDecode(posts.single.body), <String, String>{'conference': 'cnh', 'text': 'Yes, see you there'});
    expect(find.text('Yes, see you there'), findsOneWidget);
    expect(find.text('you'), findsOneWidget);
    expect(find.text('2 people here'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

    await tester.pumpWidget(const SizedBox()); // closing the screen stops the polling
    expect(tester.takeException(), isNull);
  });

  testWidgets('says chat is not switched on when the backend has no room route', (WidgetTester tester) async {
    await tester.pumpWidget(chat(MockClient((_) async => http.Response('{"detail":"Not Found"}', 404))));
    await tester.pump();
    expect(find.text('Chat is not switched on for this event yet.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ignores malformed items and keeps a failed message in the box', (WidgetTester tester) async {
    final MockClient client = MockClient((http.Request request) async {
      if (request.method == 'POST') return http.Response('{"detail":"no"}', 503);
      return http.Response(
        jsonEncode(<String, Object>{
          'people': 'many',
          'messages': <Object>[
            <String, Object>{'id': 'ok', 'text': 'x' * 400, 'author': 7, 'mine': 'yes'},
            <String, Object>{'id': '', 'text': 'no id'},
            'not a message',
          ],
        }),
        200,
      );
    });
    await tester.pumpWidget(chat(client));
    await tester.pump();
    expect(find.text('x' * 280), findsOneWidget);
    expect(find.text('guest'), findsOneWidget);
    expect(find.text('0 people here'), findsOneWidget);
    expect(find.text('no id'), findsNothing);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();
    expect(find.text('That did not send. Try again.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'hello');
    await tester.pumpWidget(const SizedBox());
  });
}
