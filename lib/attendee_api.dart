import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class AttendeeApiException implements Exception {
  const AttendeeApiException(
    this.message, {
    this.status,
    this.retryable = false,
  });
  final String message;
  final int? status;
  final bool retryable;
}

/// Only attendee credentials belong here. Database/service credentials stay on
/// the server. The same HTTPS origin is used by the existing demo search.
class AttendeeApi {
  AttendeeApi({
    http.Client? client,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       baseUrl =
           baseUrl ??
           Uri.parse(
             const String.fromEnvironment(
               'API_BASE_URL',
               defaultValue: 'https://grindset.cnh.radarhq.io',
             ),
           );

  final http.Client _client;
  final Uri baseUrl;
  final Duration timeout;

  void validateOrigin() {
    if (baseUrl.scheme != 'https' ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        (baseUrl.path.isNotEmpty && baseUrl.path != '/')) {
      throw const AttendeeApiException(
        'Configure a valid HTTPS server address.',
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    validateOrigin();
    final uri = baseUrl.resolve(path).replace(queryParameters: query);
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await (() async => http.Response.fromStream(
        await _client.send(request),
      ))().timeout(timeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        final code = response.statusCode;
        throw AttendeeApiException(
          switch (code) {
            401 => 'Your attendee session needs renewal. Tap Renew session.',
            403 => 'This session cannot access that conference.',
            404 => 'This saved recording is unavailable or expired.',
            409 =>
              path == '/me' ? 'That handle is taken. Choose another handle.' : 'The saved recording changed. Your pending text is retained.',
            410 => 'This recording expired. Your pending text is retained.',
            422 => 'The server rejected the details. Check your input.',
            429 => 'The server is busy. Your text is waiting to sync.',
            _ =>
              'Cannot reach transcript storage. Your text is waiting to sync.',
          },
          status: code,
          retryable: code == 408 || code == 429 || code >= 500,
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } on TimeoutException {
      throw const AttendeeApiException(
        'Connection timed out. Pending text is retained.',
        retryable: true,
      );
    } on http.ClientException {
      throw const AttendeeApiException(
        'Offline. Pending text is retained.',
        retryable: true,
      );
    } on FormatException {
      throw const AttendeeApiException(
        'Unexpected server response. Pending text is retained.',
        retryable: true,
      );
    } finally {
      // Cancel a timed-out transport as well as its Future, so retries do not
      // leave overlapping requests running in the background.
      abort.complete();
    }
  }

  Future<Map<String, dynamic>> profile(
    String handle,
    String conference, {
    String? token,
  }) => _request(
    'PUT',
    '/me',
    token: token,
    body: {
      'handle': handle,
      'conference': conference,
      'interests': '',
      'topics': <String>[],
      'starred_talks': <String>[],
    },
  );

  Future<void> writeSegment(
    String token,
    String stream,
    int sequence,
    Map<String, dynamic> payload,
  ) async {
    final result = await _request(
      'PUT',
      '/transcripts/$stream/segments/$sequence',
      token: token,
      body: payload,
    );
    if (result['stream_id'] != stream ||
        result['sequence'] != sequence ||
        result['revision'] != payload['revision'] ||
        !const ['created', 'updated', 'unchanged'].contains(result['result'])) {
      throw const AttendeeApiException(
        'Upload acknowledgement did not match. Pending text is retained.',
        retryable: true,
      );
    }
  }

  Future<Map<String, dynamic>> segment(
    String token,
    String stream,
    int sequence,
  ) => _request('GET', '/transcripts/$stream/segments/$sequence', token: token);

  Future<Map<String, dynamic>> history(
    String token,
    String stream, {
    int? after,
  }) => _request(
    'GET',
    '/transcripts/$stream',
    token: token,
    query: {'limit': '20', if (after != null) 'after': '$after'},
  );

  void close() => _client.close();
}
