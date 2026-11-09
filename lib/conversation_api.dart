import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class Conversation {
  const Conversation({
    required this.id,
    required this.transcript,
    this.conference,
  });

  final String id;
  final String transcript;
  final String? conference;

  factory Conversation.fromJson(Object? json) {
    if (json case {'id': String id, 'transcript': String transcript}) {
      final conference = (json as Map)['conference'];
      if (conference == null || conference is String) {
        return Conversation(
          id: id,
          transcript: transcript,
          conference: conference as String?,
        );
      }
    }
    throw const FormatException('Invalid conversation response');
  }
}

class SearchException implements Exception {
  const SearchException(this.message);
  final String message;
}

class ConversationApi {
  ConversationApi({
    http.Client? client,
    Uri? baseUrl,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _baseUrl =
           baseUrl ??
           Uri.parse(
             const String.fromEnvironment(
               'API_BASE_URL',
               defaultValue: 'https://grindset.cnh.radarhq.io',
             ),
           );

  final http.Client _client;
  final Uri _baseUrl;
  final Duration timeout;

  Future<List<Conversation>> search(String interests) async {
    final topic = interests.trim();
    if (topic.runes.length < 2 || topic.runes.length > 120) {
      throw const SearchException('Enter between 2 and 120 characters.');
    }
    if (_baseUrl.scheme != 'https' ||
        _baseUrl.host.isEmpty ||
        _baseUrl.userInfo.isNotEmpty ||
        _baseUrl.hasQuery ||
        _baseUrl.hasFragment ||
        (_baseUrl.path.isNotEmpty && _baseUrl.path != '/')) {
      throw const SearchException(
        'The search server address is not configured correctly.',
      );
    }
    try {
      final response = await _client
          .get(
            _baseUrl
                .resolve('/querysession')
                .replace(queryParameters: {'topic': topic}),
            headers: {'Accept': 'application/json'},
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw SearchException(switch (response.statusCode) {
          401 || 403 => 'Search access is unavailable. Please try again later.',
          422 => 'Enter between 2 and 120 characters.',
          429 => 'Too many searches. Please wait a moment and try again.',
          _ => 'Conversation search is unavailable. Please try again.',
        });
      }
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      if (body case {'conversations': List conversations}) {
        return conversations.map(Conversation.fromJson).toList(growable: false);
      }
      throw const FormatException('Missing conversations');
    } on TimeoutException {
      throw const SearchException('Search took too long. Please try again.');
    } on http.ClientException {
      throw const SearchException(
        'Could not reach search. Check your connection and try again.',
      );
    } on FormatException {
      throw const SearchException(
        'The server returned an unexpected response. Please try again later.',
      );
    }
  }

  void close() => _client.close();
}
