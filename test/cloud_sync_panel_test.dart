import 'dart:convert';

import 'package:conversation_garden/attendee_api.dart';
import 'package:conversation_garden/cloud_sync_panel.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'transcript_sync_test.dart' show MemoryStorage;

void main() {
  testWidgets('setup requires explicit consent before claiming an attendee', (
    tester,
  ) async {
    var requests = 0;
    final sync = TranscriptSync(
      storage: MemoryStorage(),
      startTimer: false,
      api: AttendeeApi(
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          return http.Response(
            jsonEncode({
              'handle': body['handle'],
              'conference': body['conference'],
              'token': 'synthetic',
            }),
            201,
          );
        }),
      ),
    );
    await sync.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: sync,
            builder: (_, _) => CloudSyncPanel(sync: sync, recording: false),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Enable realtime saving'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Connect and enable'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('Connect and enable'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(sync.connected, true);
    expect(find.text('Save text in realtime'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
  });

  testWidgets('history paginates and refreshes partial recordings', (
    tester,
  ) async {
    final requests = <Uri>[];
    final sync = TranscriptSync(
      storage: MemoryStorage(),
      startTimer: false,
      api: AttendeeApi(
        client: MockClient((request) async {
          if (request.url.path == '/me') {
            return http.Response(
              '{"handle":"phone","conference":"cnh","token":"synthetic"}',
              201,
            );
          }
          requests.add(request.url);
          final second = request.url.queryParameters['after'] == '0';
          return http.Response(
            jsonEncode({
              'segments': [
                {
                  'sequence': second ? 1 : 0,
                  'transcript': second ? 'second note' : 'first partial',
                  'finalized': second,
                },
              ],
              'next_after': second ? null : 0,
            }),
            200,
          );
        }),
      ),
    );
    await sync.initialize();
    await sync.connect('phone', 'cnh');
    await tester.pumpWidget(
      MaterialApp(home: TranscriptHistoryScreen(sync: sync)),
    );
    await tester.pumpAndSettle();
    expect(find.text('first partial'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('second note'), findsOneWidget);
    expect(requests.last.queryParameters['after'], '0');
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters.containsKey('after'), false);
    expect(find.text('second note'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
  });
}
