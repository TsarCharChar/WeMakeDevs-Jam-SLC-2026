import 'dart:async';
import 'dart:convert';

import 'package:conversation_garden/conversation_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('encodes a trimmed query and parses the backend contract', () async {
    final api = ConversationApi(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/querysession');
        expect(request.url.queryParameters, {'topic': 'AI & café?'});
        expect(request.headers['Accept'], 'application/json');
        return http.Response(
          jsonEncode({
            'conversations': [
              {
                'id': 'one',
                'conference': '__setup_smoke__',
                'transcript': 'café ☕',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(api.close);
    final results = await api.search('  AI & café?  ');
    expect(results.single.id, 'one');
    expect(results.single.transcript, 'café ☕');
  });

  test('empty results are valid', () async {
    final api = ConversationApi(
      client: MockClient(
        (_) async => http.Response('{"conversations":[]}', 200),
      ),
    );
    addTearDown(api.close);
    expect(await api.search('Flutter'), isEmpty);
  });

  test('invalid input makes no network request', () async {
    final api = ConversationApi(
      client: MockClient((_) async => fail('Unexpected request')),
    );
    addTearDown(api.close);
    for (final query in [' ', 'x', 'x' * 121, '😀' * 61]) {
      // The backend counts Unicode code points, not UTF-16 code units.
      if (query == '😀' * 61) continue;
      await expectLater(api.search(query), throwsA(isA<SearchException>()));
    }
  });

  test('HTTP failures do not expose raw server errors', () async {
    for (final status in [401, 403, 422, 429, 500, 503]) {
      final api = ConversationApi(
        client: MockClient(
          (_) async => http.Response('sensitive internal error', status),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.search('Flutter'),
        throwsA(
          isA<SearchException>().having(
            (e) => e.message,
            'message',
            isNot(contains('sensitive')),
          ),
        ),
      );
    }
  });

  test(
    'invalid JSON, old mock contract, and malformed hits are errors',
    () async {
      for (final body in [
        '<html>gateway</html>',
        '{"sessions":[]}',
        '{"conversations":[{"id":1}]}',
      ]) {
        final api = ConversationApi(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        addTearDown(api.close);
        await expectLater(
          api.search('Flutter'),
          throwsA(isA<SearchException>()),
        );
      }
    },
  );

  test('network failure and timeout have retryable messages', () async {
    final offline = ConversationApi(
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    final slow = ConversationApi(
      client: MockClient((_) => Completer<http.Response>().future),
      timeout: Duration.zero,
    );
    addTearDown(offline.close);
    addTearDown(slow.close);
    await expectLater(
      offline.search('Flutter'),
      throwsA(
        isA<SearchException>().having(
          (e) => e.message,
          'message',
          contains('connection'),
        ),
      ),
    );
    await expectLater(
      slow.search('Flutter'),
      throwsA(
        isA<SearchException>().having(
          (e) => e.message,
          'message',
          contains('too long'),
        ),
      ),
    );
  });
}
