// Room chat: the screen someone lands on after tapping a topic or talk they care about.
//
// It talks to two backend routes (draft PR #17):
//   GET  /rooms/{room}/messages?conference=...   the newest page, oldest first, and a people count
//   POST /rooms/{room}/messages                  one line, up to 280 characters
// A room is "topic:<name>" or "talk:<id>". The screen polls while it is open and stops when it closes.
// Everything the server sends is treated as untrusted: types are checked and lengths are capped.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const Color _bg = Color(0xFF04060A);
const Color _surface = Color(0xFF0A111B);
const Color _line = Color(0xFF1B2A3D);
const Color _text1 = Color(0xFFF4F8FF);
const Color _text2 = Color(0xFFA9BCD0);
const Color _text3 = Color(0xFF6F8298);
const Color _core = Color(0xFF38BDF8);
const Color _violet = Color(0xFFA78BFA);
const Color _amber = Color(0xFFF6C445);
const int _maxLength = 280;

@immutable
class RoomMessage {
  const RoomMessage({required this.id, required this.text, required this.author, required this.mine});

  final String id;
  final String text;
  final String author;
  final bool mine;

  /// Null when the item is not a message in the expected shape.
  static RoomMessage? fromJson(Object? json) {
    if (json case {'id': final String id, 'text': final String text} when id.isNotEmpty && text.trim().isNotEmpty) {
      final Object? author = json['author'];
      final String shown = text.trim();
      return RoomMessage(
        id: id,
        text: shown.length > _maxLength ? shown.substring(0, _maxLength) : shown,
        author: author is String && author.isNotEmpty && author.length <= 40 ? author : 'guest',
        mine: json['mine'] == true,
      );
    }
    return null;
  }
}

enum _RoomState { loading, ready, unavailable, signedOut, offline }

class RoomChatScreen extends StatefulWidget {
  const RoomChatScreen({
    super.key,
    required this.baseUrl,
    required this.token,
    required this.conference,
    required this.room,
    required this.title,
    this.client,
    this.pollInterval = const Duration(seconds: 2),
  });

  /// The backend's HTTPS origin, for example https://grindset.cnh.radarhq.io.
  final Uri baseUrl;

  /// The attendee token from PUT /me.
  final String token;
  final String conference;

  /// `topic:<name>` or `talk:<id>`.
  final String room;

  /// What to call the room at the top of the screen, for example the topic's name.
  final String title;

  /// For tests. The screen closes a client it created itself.
  final http.Client? client;
  final Duration pollInterval;

  @override
  State<RoomChatScreen> createState() => _RoomChatScreenState();
}

class _RoomChatScreenState extends State<RoomChatScreen> with WidgetsBindingObserver {
  late final http.Client _client = widget.client ?? http.Client();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _timer;
  List<RoomMessage> _messages = const <RoomMessage>[];
  int _people = 0;
  _RoomState _state = _RoomState.loading;
  bool _sending = false, _loading = false;
  String? _sendError;

  Uri get _uri => widget.baseUrl.replace(pathSegments: <String>['rooms', widget.room, 'messages']);
  Map<String, String> get _headers => <String, String>{'Authorization': 'Bearer ${widget.token}', 'Accept': 'application/json'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    _timer = Timer.periodic(widget.pollInterval, (_) => unawaited(_load()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No polling while the app is in the background.
    if (state == AppLifecycleState.resumed) {
      _timer ??= Timer.periodic(widget.pollInterval, (_) => unawaited(_load()));
      unawaited(_load());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _input.dispose();
    _scroll.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading || !mounted) return;
    _loading = true;
    _RoomState next = _state;
    List<RoomMessage>? messages;
    int people = _people;
    try {
      final http.Response response = await _client
          .get(_uri.replace(queryParameters: <String, String>{'conference': widget.conference}), headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final Object? body = jsonDecode(utf8.decode(response.bodyBytes));
        if (body case {'messages': final List<Object?> raw}) {
          messages = <RoomMessage>[
            for (final Object? item in raw.length > 100 ? raw.sublist(raw.length - 100) : raw) ?RoomMessage.fromJson(item),
          ];
          final Object? count = body['people'];
          people = count is int && count >= 0 ? count : 0;
          next = _RoomState.ready;
        } else {
          next = _RoomState.offline;
        }
      } else if (response.statusCode == 404) {
        next = _RoomState.unavailable; // the route is not deployed on this backend yet
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        next = _RoomState.signedOut;
      } else {
        next = _RoomState.offline;
      }
    } on Object {
      next = _RoomState.offline;
    }
    _loading = false;
    if (!mounted) return;
    final String lastBefore = _messages.isEmpty ? '' : _messages.last.id;
    final bool grew = messages != null && messages.isNotEmpty && messages.last.id != lastBefore;
    setState(() {
      _state = next;
      _people = people;
      if (messages != null) _messages = messages;
    });
    if (grew) _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final String text = _input.text.trim().replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ');
    if (text.isEmpty || _sending) return; // one press, one message
    setState(() {
      _sending = true;
      _sendError = null;
    });
    _input.clear(); // clear at once, so the press is visibly taken
    String? error;
    try {
      final http.Response response = await _client
          .post(
            _uri,
            headers: <String, String>{..._headers, 'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{'conference': widget.conference, 'text': text}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 201) {
        error = response.statusCode == 422 ? 'One line, up to $_maxLength characters.' : 'That did not send. Try again.';
      }
    } on Object {
      error = 'That did not send. Check your connection.';
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sendError = error;
      if (error != null && _input.text.isEmpty) _input.text = text; // give the words back
    });
    if (error == null) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final bool canType = _state == _RoomState.ready || _state == _RoomState.offline || _state == _RoomState.loading;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.chevron_left, color: _text2, size: 30),
                    tooltip: 'Back',
                  ),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _text1, fontSize: 22, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_state == _RoomState.ready) ...<Widget>[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(color: _violet, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _people == 1 ? '1 person here' : '$_people people here',
                      style: const TextStyle(color: _text2, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _line),
                  ),
                  child: _body(),
                ),
              ),
              if (_sendError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_sendError!, style: const TextStyle(color: _amber, fontSize: 14)),
                ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: canType,
                      maxLength: _maxLength,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_send()),
                      style: const TextStyle(color: _text1, fontSize: 16),
                      cursorColor: _core,
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: 'Say something to this room',
                        hintStyle: const TextStyle(color: _text3, fontSize: 16),
                        filled: true,
                        fillColor: _surface,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF22405E))),
                        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _line)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _core, width: 1.5)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: FilledButton(
                      onPressed: canType && !_sending ? () => unawaited(_send()) : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: _core,
                        foregroundColor: const Color(0xFF04121C),
                        disabledBackgroundColor: _line,
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      child: Semantics(label: 'Send', child: const Icon(Icons.arrow_upward_rounded, size: 24)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    String? notice;
    switch (_state) {
      case _RoomState.loading:
        notice = _messages.isEmpty ? 'Opening the room…' : null;
      case _RoomState.unavailable:
        notice = 'Chat is not switched on for this event yet.';
      case _RoomState.signedOut:
        notice = 'Set up your profile to join this room.';
      case _RoomState.offline:
        notice = _messages.isEmpty ? 'Could not reach the room. Trying again…' : null;
      case _RoomState.ready:
        notice = _messages.isEmpty ? 'Nobody has said anything here yet. Be the first.' : null;
    }
    if (notice != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(notice, textAlign: TextAlign.center, style: const TextStyle(color: _text2, fontSize: 15, height: 1.4)),
        ),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: _messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final RoomMessage message = _messages[index];
        return Align(
          alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: message.mine ? const Color(0x2938BDF8) : const Color(0xFF0F1826),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: message.mine ? const Color(0x8038BDF8) : _line),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      message.mine ? 'you' : message.author,
                      style: TextStyle(color: message.mine ? _core : _text3, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(message.text, style: const TextStyle(color: _text1, fontSize: 16, height: 1.35)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
