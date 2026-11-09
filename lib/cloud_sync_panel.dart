import 'package:flutter/material.dart';

import 'attendee_api.dart';
import 'transcript_sync.dart';

class CloudSyncPanel extends StatelessWidget {
  const CloudSyncPanel({
    super.key,
    required this.sync,
    required this.recording,
  });
  final TranscriptSync sync;
  final bool recording;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'PRIVATE TRANSCRIPT SAVING',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Semantics(liveRegion: true, child: Text(sync.status)),
          if (sync.connected) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Save text in realtime'),
              subtitle: const Text(
                'Text goes to your private server history. Audio stays on this device.',
              ),
              value: sync.enabled,
              onChanged: recording ? null : sync.setEnabled,
            ),
            Wrap(
              spacing: 8,
              children: [
                if (sync.error != null || sync.hasPending)
                  TextButton(
                    onPressed: sync.sending ? null : sync.retry,
                    child: const Text('Retry sync'),
                  ),
                TextButton(
                  onPressed: sync.connecting ? null : sync.renewSession,
                  child: const Text('Renew session'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => TranscriptHistoryScreen(sync: sync),
                    ),
                  ),
                  child: const Text('Saved transcripts'),
                ),
              ],
            ),
          ] else if (sync.loaded)
            TextButton.icon(
              onPressed: recording || sync.connecting
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => _SetupDialog(sync: sync),
                    ),
              icon: const Icon(Icons.cloud_upload_outlined),
              label: const Text('Enable realtime saving'),
            )
          else if (sync.error != null)
            TextButton(
              onPressed: sync.initialize,
              child: const Text('Retry session loading'),
            ),
        ],
      ),
    ),
  );
}

class _SetupDialog extends StatefulWidget {
  const _SetupDialog({required this.sync});
  final TranscriptSync sync;
  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  late final handle = TextEditingController(
    text: 'phone-${randomDeviceId().substring(0, 12)}',
  );
  final conference = TextEditingController(
    text: const String.fromEnvironment('CONFERENCE_ID', defaultValue: 'cnh'),
  );
  bool consent = false, busy = false;
  String? error;
  @override
  void dispose() {
    handle.dispose();
    conference.dispose();
    super.dispose();
  }

  Future<void> connect() async {
    if (!consent || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.sync.connect(handle.text.trim(), conference.text.trim());
      if (mounted) Navigator.of(context).pop();
    } on AttendeeApiException catch (e) {
      if (mounted) {
        setState(() {
          error = e.message;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Save transcripts privately'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Transcribed text uploads while you record, about every two seconds when new words are available. Audio stays on your phone. Only record with everyone’s permission. Saved text is accessible for seven days; this is not a guarantee of physical deletion.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: handle,
              enabled: !busy,
              maxLength: 32,
              decoration: const InputDecoration(labelText: 'Device handle'),
            ),
            TextField(
              controller: conference,
              enabled: !busy,
              maxLength: 128,
              decoration: const InputDecoration(labelText: 'Conference ID'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: consent,
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      consent = value ?? false;
                    }),
              title: const Text(
                'I agree to upload my transcripts in realtime.',
              ),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy || !consent ? null : connect,
          child: Text(busy ? 'Connecting…' : 'Connect and enable'),
        ),
      ],
    ),
  );
}

class TranscriptHistoryScreen extends StatefulWidget {
  const TranscriptHistoryScreen({super.key, required this.sync});
  final TranscriptSync sync;
  @override
  State<TranscriptHistoryScreen> createState() =>
      _TranscriptHistoryScreenState();
}

class _TranscriptHistoryScreenState extends State<TranscriptHistoryScreen> {
  final List<Map<String, dynamic>> segments = [];
  int? after;
  bool loading = false, more = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  Future<void> load({bool reset = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.sync.history(after: reset ? null : after);
      final entries = (page['segments'] as List).map((item) {
        final row = (item as Map).cast<String, dynamic>();
        if (row['sequence'] is! int ||
            row['transcript'] is! String ||
            row['finalized'] is! bool) {
          throw const FormatException();
        }
        return row;
      }).toList();
      final cursor = page['next_after'];
      if (cursor != null &&
          (cursor is! int || !reset && after != null && cursor <= after!)) {
        throw const FormatException();
      }
      if (!mounted) return;
      setState(() {
        if (reset) segments.clear();
        segments.addAll(entries);
        after = cursor as int?;
        more = after != null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is AttendeeApiException
              ? e.message
              : 'Could not read transcript history. Try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Saved transcripts'),
      actions: [
        IconButton(
          onPressed: loading ? null : () => load(reset: true),
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Private history for this device. Refresh to see recent changes. Saved transcripts expire from history after seven days.',
        ),
        const SizedBox(height: 16),
        if (!loading && error == null && segments.isEmpty)
          const Text('No saved transcripts yet.'),
        for (final segment in segments)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recording ${(segment['sequence'] as int) + 1} · ${segment['finalized'] == true ? "Complete" : "Partial"}',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(segment['transcript'] as String),
                ],
              ),
            ),
          ),
        if (loading) const Center(child: CircularProgressIndicator()),
        if (error != null) ...[
          Text(error!),
          TextButton(
            onPressed: loading ? null : () => load(reset: segments.isEmpty),
            child: const Text('Retry history'),
          ),
        ] else if (more)
          TextButton(
            onPressed: loading ? null : load,
            child: const Text('Load more'),
          ),
      ],
    ),
  );
}
