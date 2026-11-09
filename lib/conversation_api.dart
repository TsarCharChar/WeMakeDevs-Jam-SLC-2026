import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class Conversation {
  const Conversation({
    required this.id,
    this.sharedText,
    this.topics = const [],
    this.why,
    this.conference,
    this.shared = false,
  });

  final String id;

  /// Only populated when the note was explicitly shared or comes from the
  /// backend's synthetic `__setup_smoke__` demo document.
  final String? sharedText;
  final List<String> topics;
  final String? why;
  final String? conference;
  final bool shared;

  bool get isDemo => conference == '__setup_smoke__';

  factory Conversation.fromJson(Object? json) {
    if (json case {'id': String id} when id.isNotEmpty) {
      final conference = json['conference'];
      if (conference != null && conference is! String) {
        throw const FormatException('Invalid note conference');
      }
      final sharedFlag = json['shared'];
      if (sharedFlag != null && sharedFlag is! bool) {
        throw const FormatException('Invalid shared flag');
      }
      final rawText = json['transcript'] ?? json['shared_text'];
      if (rawText != null && rawText is! String) {
        throw const FormatException('Invalid note text');
      }
      final rawWhy = json['why'];
      if (rawWhy != null && rawWhy is! String) {
        throw const FormatException('Invalid match reason');
      }
      final rawTopics = json['topics'];
      final topics = <String>[];
      if (rawTopics != null) {
        if (rawTopics is! List) {
          throw const FormatException('Invalid note topics');
        }
        for (final item in rawTopics) {
          if (item is! String) {
            throw const FormatException('Invalid note topic');
          }
          final trimmed = item.trim();
          if (trimmed.isNotEmpty) topics.add(trimmed);
        }
      }
      if (rawText == null && rawTopics == null && rawWhy == null) {
        throw const FormatException('Missing note fields');
      }
      final isDemo = conference == '__setup_smoke__';
      final isShared = sharedFlag == true;
      return Conversation(
        id: id,
        conference: conference as String?,
        shared: isShared,
        sharedText: (isShared || isDemo) ? rawText as String? : null,
        topics: List.unmodifiable(topics),
        why: rawWhy as String?,
      );
    }
    throw const FormatException('Invalid note response');
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
          _ => 'Note search is unavailable. Please try again.',
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
