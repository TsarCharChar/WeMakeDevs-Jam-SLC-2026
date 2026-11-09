import 'dart:async';

import 'package:conversation_garden/recording_controller.dart';
import 'package:conversation_garden/transcript_sync.dart';
import 'package:conversation_garden/ui/note_capture_and_undo.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'transcript_sync_test.dart' show FakeApi, MemoryStorage;

// Record requests without calling widget assertions from the recorder's
// asynchronous completion callback. Assert the captured values after pumping.
class _RecordingApi extends FakeApi {
  String? lastToken;
  @override
  Future<void> writeSegment(
    String token,
    String stream,
    int sequence,
    Map<String, dynamic> payload,
  ) async {
    lastToken = token;
    writes.add({...payload, 'sequence': sequence});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'stopping once finalizes private text and stages one radar note',
    (tester) async {
      final stopped = Completer<void>();
      var stopCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.record/messages'),
            (call) async {
              if (call.method == 'stop') {
                stopCalls++;
                await stopped.future;
              }
              return null;
            },
          );
      final api = _RecordingApi();
      final sync = TranscriptSync(
        api: api,
        storage: MemoryStorage(),
        startTimer: false,
      );
      await sync.initialize();
      await sync.connect('radar-phone', 'cnh');
      await sync.begin();
      sync.updateText('Cilium private transcript');
      final completed = <String>[];
      final controller =
          RecordingController(sync: sync, onNoteCompleted: completed.add)
            ..phase = RecordingPhase.recording
            ..transcript = 'Cilium private transcript';
      final first = controller.stop();
      expect(identical(first, controller.stop()), true);
      await tester.pump();
      expect(stopCalls, 1);
      stopped.complete();
      await tester.pump();
      await first;
      await sync.flush();
      expect(sync.error, isNull);
      expect(sync.hasPending, false);
      expect(api.lastToken, 'synthetic-attendee-token');
      expect(api.writes.single['finalized'], true);
      expect(api.writes.single['transcript'], 'Cilium private transcript');
      expect(completed, ['Cilium private transcript']);
      expect(controller.phase, RecordingPhase.idle);
      controller.dispose();
      await tester.pump();
      await controller.closed;
      sync.dispose();
    },
  );

  testWidgets(
    'Undo notice remains truthful when private recording settings change',
    (tester) async {
      final draft = CapturedNoteDraft(
        noteId: 'spoken-note',
        text: 'private words',
        sourceKind: NoteSourceKind.spoken,
        matchedTopics: const ['Cilium'],
        createdAt: DateTime.utc(2026),
        privateTranscriptSaving: true,
      ).copyWith(shareNoteText: true);
      expect(draft.privateTranscriptSaving, true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteUndoReviewCard(
              draft: draft,
              privateTranscriptSaving: draft.privateTranscriptSaving,
              reviewBeforeSending: true,
              onUndoOrDiscard: () {},
              onSendNow: () {},
              onToggleShareText: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('does not delete uploaded text'),
        findsOneWidget,
      );
      expect(find.textContaining('nothing sent yet'), findsNothing);
    },
  );
}
