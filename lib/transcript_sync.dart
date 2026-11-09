import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'attendee_api.dart';

abstract interface class TranscriptStorage {
  Future<String?> read();
  Future<void> write(String value);
}

class SecureTranscriptStorage implements TranscriptStorage {
  SecureTranscriptStorage({this.key = 'attendee_transcript_outbox_v1'});
  final String key;
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String value) => _storage.write(key: key, value: value);
}

String randomDeviceId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class _Segment {
  _Segment(this.sequence);
  final int sequence;
  String text = '', acknowledgedText = '';
  int revision = 0;
  bool ended = false;
  Map<String, dynamic>? pending;
  Map<String, dynamic> toJson() => {
    'sequence': sequence,
    'text': text,
    'acknowledgedText': acknowledgedText,
    'revision': revision,
    'ended': ended,
    'pending': pending,
  };
  factory _Segment.fromJson(Map<String, dynamic> json) =>
      _Segment(json['sequence'] as int)
        ..text = json['text'] as String
        ..acknowledgedText = json['acknowledgedText'] as String
        ..revision = json['revision'] as int
        ..ended = json['ended'] as bool
        ..pending = (json['pending'] as Map?)?.cast<String, dynamic>();
}

/// A single device owns this stream. Persist the exact request before sending;
/// retries never change its revision or payload, even when Whisper revises text.
class TranscriptSync extends ChangeNotifier {
  TranscriptSync({
    AttendeeApi? api,
    TranscriptStorage? storage,
    this.interval = const Duration(seconds: 2),
    this.startTimer = true,
    DateTime Function()? now,
  }) : api = api ?? AttendeeApi(),
       storage = storage ?? SecureTranscriptStorage(),
       _now = now ?? DateTime.now;
  final AttendeeApi api;
  final TranscriptStorage storage;
  final Duration interval;
  final bool startTimer;
  final DateTime Function() _now;
  static const maxSegments = 8;
  static const maxCharacters = 20000;
  final List<_Segment> _segments = [];
  Map<String, dynamic>? _account;
  _Segment? _active;
  int _nextSequence = 0, _failures = 0;
  bool loaded = false, enabled = false, sending = false, connecting = false;
  bool _disposed = false,
      _dirty = false,
      _storageFailed = false,
      _blocked = false;
  bool _originMismatch = false, _loading = false;
  DateTime? _retryAt;
  Timer? _timer;
  Future<void> _writes = Future.value();
  Future<void>? _pump;
  Future<void>? _checkpoint;
  String? error;
  bool get connected => loaded && _account != null && !_originMismatch;
  String? get handle => _account?['handle'] as String?;
  String? get token => connected ? (_account?['token'] as String?) : null;
  String? get conference =>
      connected ? (_account?['conference'] as String?) : null;
  String? get stream => connected ? (_account?['stream'] as String?) : null;
  int? get lastSequence => _nextSequence > 0 ? _nextSequence - 1 : null;
  bool get hasPending => _segments.any(
    (s) =>
        s.pending != null ||
        s.text.isNotEmpty && (s.ended || s.text != s.acknowledgedText),
  );
  bool get canBegin =>
      loaded &&
      !_originMismatch &&
      !_storageFailed &&
      (!enabled || connected && !_blocked && _segments.length < maxSegments);
  String get status {
    if (error != null) return error!;
    if (!loaded) return 'Checking saved session…';
    if (_storageFailed) {
      return 'Secure storage unavailable · cloud saving stopped';
    }
    if (!enabled) return 'Cloud saving off · record locally for this session';
    if (sending) return 'Saving transcript…';
    if (hasPending) return 'Pending · text is waiting to sync';
    return 'Connected as $handle · ${_active == null
        ? "all queued text saved"
        : _active!.text.isEmpty
        ? "waiting for speech"
        : "latest text saved"}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Map<String, dynamic> _snapshot() => {
    'version': 1,
    'origin': api.baseUrl.origin,
    'account': _account,
    'enabled': enabled,
    'nextSequence': _nextSequence,
    'segments': _segments.map((s) => s.toJson()).toList(),
  };

  Future<void> _persist() {
    final encoded = jsonEncode(_snapshot());
    final write = _writes.then((_) => storage.write(encoded));
    _writes = write.then((_) {}, onError: (Object _) {});
    return write.then(
      (_) {
        _storageFailed = false;
      },
      onError: (Object _) {
        _storageFailed = true;
        error = 'Could not save securely on this phone. Keep the app open and retry.';
        _notify();
        throw const AttendeeApiException(
          'Secure storage is unavailable. Keep the app open and retry.',
        );
      },
    );
  }

  Future<void> initialize() async {
    if (_loading || loaded || _disposed) return;
    _loading = true;
    try {
      api.validateOrigin();
      final raw = await storage.read();
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        if (json['version'] != 1 || json['origin'] != api.baseUrl.origin) {
          _originMismatch = true;
          throw const AttendeeApiException(
            'Saved session belongs to another server or app version. Restore the original configuration.',
          );
        }
        _account = (json['account'] as Map?)?.cast<String, dynamic>();
        enabled = json['enabled'] as bool;
        _nextSequence = json['nextSequence'] as int;
        _segments.clear();
        _segments.addAll(
          (json['segments'] as List).map(
            (s) => _Segment.fromJson((s as Map).cast<String, dynamic>()),
          ),
        );
        if (_segments.length > maxSegments ||
            _segments.any((s) => s.text.runes.length > maxCharacters)) {
          throw const FormatException('Invalid outbox');
        }
        // A terminated recording cannot continue using its previous segment.
        for (final segment in _segments) {
          segment.ended = true;
        }
        _segments.removeWhere((s) => s.text.isEmpty && s.pending == null);
        await _persist();
      }
      _storageFailed = false;
      error = null;
      loaded = true;
      if (startTimer && !_disposed) {
        _timer = Timer.periodic(interval, (_) => unawaited(flush()));
      }
      _notify();
      await flush();
    } catch (e) {
      error = e is AttendeeApiException ? e.message : 'Could not read the saved session. Existing data has not been overwritten.';
      _storageFailed = true;
      _notify();
    } finally {
      _loading = false;
    }
  }

  Future<void> connect(
    String handle,
    String conference, {
    String? displayName,
    String? interests,
    List<String>? topics,
    List<String>? starredTalks,
  }) async {
    if (!loaded || _originMismatch || connecting || _account != null) return;
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{1,31}$').hasMatch(handle) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(conference)) {
      throw const AttendeeApiException(
        'Use a 2–32 character handle and a valid conference ID (letters, numbers, _ or -).',
      );
    }
    connecting = true;
    error = null;
    _notify();
    try {
      final cleanName = displayName != null && displayName.trim().isNotEmpty
          ? displayName.trim()
          : null;
      final hasProfileFields =
          cleanName != null ||
          interests != null ||
          topics != null ||
          starredTalks != null;
      Map<String, dynamic> profile;
      if (hasProfileFields) {
        try {
          profile = await api.updateProfile(
            handle,
            conference,
            displayName: cleanName,
            interests: interests ?? '',
            topics: topics ?? const <String>[],
            starredTalks: starredTalks ?? const <String>[],
          );
        } on AttendeeApiException catch (e) {
          if (cleanName != null && (e.status == 422 || e.status == 503)) {
            profile = await api.updateProfile(
              handle,
              conference,
              interests: interests ?? '',
              topics: topics ?? const <String>[],
              starredTalks: starredTalks ?? const <String>[],
            );
          } else {
            rethrow;
          }
        }
      } else {
        profile = await api.profile(handle, conference);
      }
      final token = profile['token'];
      if (token is! String ||
          token.isEmpty ||
          profile['handle'] != handle ||
          profile['conference'] != conference) {
        throw const AttendeeApiException(
          'Profile creation was not confirmed. Try a new handle.',
        );
      }
      _account = {
        'handle': handle,
        'conference': conference,
        'token': token,
        'stream': randomDeviceId(),
        if (hasProfileFields) ...{
          'interests': interests ?? '',
          'topics': topics ?? const <String>[],
          'starred_talks': starredTalks ?? const <String>[],
        },
      };
      enabled = true;
      await _persist();
    } on AttendeeApiException catch (e) {
      error = e.message;
      rethrow;
    } finally {
      connecting = false;
      _notify();
    }
  }

  void rememberProfileFields({
    required String interests,
    required List<String> topics,
    required List<String> starredTalks,
  }) {
    final acc = _account;
    if (acc == null) return;
    acc['interests'] = interests;
    acc['topics'] = List<String>.from(topics);
    acc['starred_talks'] = List<String>.from(starredTalks);
  }

  Future<void> setEnabled(bool value) async {
    if (_active != null || !loaded || !connected) return;
    enabled = value;
    try {
      await _persist();
    } on AttendeeApiException {
      return;
    }
    _notify();
    if (value) await retry();
  }

  Future<void> renewSession() async {
    if (!connected || connecting) return;
    connecting = true;
    _notify();
    try {
      final storedTopics = _account!['topics'];
      if (storedTopics is List) {
        await api.updateProfile(
          handle!,
          _account!['conference'] as String,
          token: _account!['token'] as String,
          interests: (_account!['interests'] as String?) ?? '',
          topics: storedTopics.whereType<String>().toList(growable: false),
          starredTalks:
              (_account!['starred_talks'] as List?)
                  ?.whereType<String>()
                  .toList(growable: false) ??
              const <String>[],
        );
      } else {
        await api.profile(
          handle!,
          _account!['conference'] as String,
          token: _account!['token'] as String,
        );
      }
      await retry();
    } on AttendeeApiException catch (e) {
      error = e.message;
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> begin() async {
    if (!enabled) return;
    if (!canBegin || _active != null || _nextSequence > 2147483647) {
      throw const AttendeeApiException(
        'Sync pending recordings before starting another cloud recording.',
      );
    }
    final segment = _Segment(_nextSequence++);
    _segments.add(segment);
    _active = segment;
    try {
      await _persist();
    } catch (_) {
      _active = null;
      segment.ended = true;
      rethrow;
    }
    _notify();
  }

  void updateText(String value) {
    if (_active == null) return;
    final text = value.trim();
    if (text.runes.length > maxCharacters) {
      error = 'Recording is too long to save. The last accepted partial is retained; copy the full text from this screen.';
      _blocked = true;
      _notify();
      return;
    }
    // Empty recognizer events must not erase already captured speech.
    if (text.isEmpty || text == _active!.text) return;
    _active!.text = text;
    _dirty = true;
    _notify();
  }

  Future<void> finish(String text) async {
    if (_active == null) return;
    updateText(text);
    _active!.ended = true;
    _active = null;
    _dirty = true;
    try {
      await _persist();
    } on AttendeeApiException {
      return;
    }
    _notify();
    unawaited(flush());
  }

  Future<void> retry() async {
    if (!loaded || _originMismatch) return;
    _failures = 0;
    _retryAt = null;
    _blocked = false;
    error = null;
    try {
      await _persist();
    } on AttendeeApiException {
      return;
    }
    await flush();
    _notify();
  }

  Future<void> flush() {
    if (_disposed || !loaded) return Future.value();
    // A slow network request must not delay durable capture of newer partials.
    if (_pump != null && _dirty && _checkpoint == null) {
      _dirty = false;
      _checkpoint = _persist().catchError((Object _) {}).whenComplete(() {
        _checkpoint = null;
      });
    }
    return _pump ??= _flush().whenComplete(() {
      _pump = null;
    });
  }

  Future<void> _flush() async {
    try {
      if (_dirty) {
        _dirty = false;
        await _persist();
      }
      if (!enabled ||
          !connected ||
          _storageFailed ||
          _blocked ||
          _failures >= 5 ||
          _retryAt != null && _now().isBefore(_retryAt!)) {
        return;
      }
      // At most one request per tick. A final snapshot can immediately follow
      // an acknowledged partial, without waiting for the next timer tick.
      _segments.removeWhere(
        (s) => s.ended && s.text.isEmpty && s.pending == null,
      );
      final candidates = _segments.where(
        (s) =>
            s.pending != null ||
            s.text.isNotEmpty && (s.ended || s.text != s.acknowledgedText),
      );
      if (candidates.isEmpty) return;
      final segment = candidates.first;
      final payload = segment.pending ??= <String, dynamic>{
        'revision': segment.revision + 1,
        'transcript': segment.text,
        'finalized': segment.ended,
        'consent': true,
      };
      await _persist();
      if (_disposed || !enabled) return;
      sending = true;
      _notify();
      try {
        await api.writeSegment(
          _account!['token'] as String,
          _account!['stream'] as String,
          segment.sequence,
          payload,
        );
      } on AttendeeApiException catch (e) {
        if (e.status != 409) rethrow;
        final saved = await api.segment(
          _account!['token'] as String,
          _account!['stream'] as String,
          segment.sequence,
        );
        if (saved['sequence'] != segment.sequence ||
            saved['revision'] != payload['revision'] ||
            saved['transcript'] != payload['transcript'] ||
            saved['finalized'] != payload['finalized']) {
          rethrow;
        }
      }
      segment.revision = payload['revision'] as int;
      segment.acknowledgedText = payload['transcript'] as String;
      segment.pending = null;
      if (payload['finalized'] == true) _segments.remove(segment);
      _failures = 0;
      _retryAt = null;
      error = null;
      await _persist();
      if (segment.ended && _segments.contains(segment) && !_disposed) {
        await _flush();
      }
    } on AttendeeApiException catch (e) {
      error = e.message;
      if (e.retryable) {
        _failures++;
        _retryAt = _now().add(Duration(seconds: 1 << _failures));
        if (_failures >= 5) error = 'Uploads paused after five attempts. Pending text is retained. Tap Retry sync.';
      } else {
        _blocked = true;
      }
    } catch (_) {
      error = 'Could not sync. Pending text is retained. Tap Retry sync.';
      _blocked = true;
    } finally {
      sending = false;
      _notify();
    }
  }

  Future<Map<String, dynamic>> history({int? after}) async {
    if (!connected) {
      throw const AttendeeApiException('Enable cloud saving first.');
    }
    return api.history(
      _account!['token'] as String,
      _account!['stream'] as String,
      after: after,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    api.close();
    super.dispose();
  }
}
