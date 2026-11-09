import 'dart:convert';

import 'package:conversation_garden/attendee_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('profile and uploads use HTTPS JSON with attendee auth only', () async {
    final requests = <http.Request>[];
    final api = AttendeeApi(
      client: MockClient((request) async {
        requests.add(request);
        expect(request.followRedirects, false);
        if (request.url.path == '/me') {
          return http.Response('{"token":"synthetic"}', 201);
        }
        return http.Response(
          '{"stream_id":"device","sequence":0,"revision":1,"result":"created"}',
          200,
        );
      }),
    );
    await api.profile('phone', 'cnh');
    await api.writeSegment('synthetic', 'device', 0, {
      'revision': 1,
      'transcript': 'hello',
      'finalized': false,
      'consent': true,
    });
    expect(requests.first.headers.containsKey('Authorization'), false);
    expect(requests.last.headers['Authorization'], 'Bearer synthetic');
    expect(requests.last.url.scheme, 'https');
    expect(jsonDecode(requests.last.body)['transcript'], 'hello');
    api.close();
  });
  test('mismatched acknowledgement cannot mark a recording saved', () async {
    final api = AttendeeApi(
      client: MockClient(
        (_) async => http.Response(
          '{"stream_id":"wrong","sequence":0,"revision":1,"result":"created"}',
          200,
        ),
      ),
    );
    await expectLater(
      api.writeSegment('token', 'device', 0, {'revision': 1}),
      throwsA(isA<AttendeeApiException>()),
    );
    api.close();
  });
  test('unsafe origins are rejected before any credential is sent', () async {
    for (final origin in [
      'http://localhost:8000',
      'https://user:pass@example.com',
      'https://example.com/api',
      'https://example.com?q=secret',
    ]) {
      final api = AttendeeApi(
        baseUrl: Uri.parse(origin),
        client: MockClient((_) async {
          fail('Must not send');
        }),
      );
      await expectLater(
        api.profile('phone', 'cnh'),
        throwsA(isA<AttendeeApiException>()),
      );
      api.close();
    }
  });
  test('history uses authenticated pagination without token in URL', () async {
    final api = AttendeeApi(
      client: MockClient((request) async {
        expect(request.url.path, '/transcripts/device');
        expect(request.url.queryParameters, {'limit': '20', 'after': '4'});
        expect(request.headers['Authorization'], 'Bearer token');
        return http.Response('{"segments":[],"next_after":null}', 200);
      }),
    );
    await api.history('token', 'device', after: 4);
    api.close();
  });
}
