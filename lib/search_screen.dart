import 'package:flutter/material.dart';

import 'conversation_api.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.api});

  /// An injected API is owned by its caller; otherwise this screen owns it.
  final ConversationApi? api;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final interests = TextEditingController();
  late final ConversationApi api = widget.api ?? ConversationApi();
  bool loading = false;
  String? error;
  List<Conversation>? results;

  bool get valid =>
      interests.text.trim().runes.length >= 2 &&
      interests.text.trim().runes.length <= 120;

  Future<void> search() async {
    if (loading || !valid) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = null;
      results = null;
    });
    try {
      final conversations = await api.search(interests.text);
      if (!mounted) return;
      setState(() => results = conversations);
    } on SearchException catch (failure) {
      if (!mounted) return;
      setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    interests.dispose();
    if (widget.api == null) api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Find my wavelength'),
      backgroundColor: Colors.transparent,
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'What’s on\nyour mind?',
              style: TextStyle(
                fontSize: 38,
                height: 1.1,
                fontWeight: FontWeight.w600,
                letterSpacing: -1.4,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Tell us what you’d love to explore.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            const Text(
              'Search currently queries a synthetic demo note. Attendee topic matching is coming next.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: interests,
              enabled: !loading,
              minLines: 3,
              maxLines: 6,
              maxLength: 120,
              onChanged: (_) => setState(() {
                results = null;
                error = null;
              }),
              decoration: InputDecoration(
                labelText: 'Your interests',
                hintText: 'e.g. on-device AI, eBPF, or platform engineering',
                helperText: 'Use 2–120 characters.',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: valid && !loading ? search : null,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.search),
              label: Text(
                loading
                    ? 'Searching…'
                    : error != null
                    ? 'Retry search'
                    : 'Search notes',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Searching sends your typed interests to our server.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 24),
            if (error != null) Semantics(liveRegion: true, child: Text(error!)),
            if (results != null && results!.isEmpty)
              Semantics(
                liveRegion: true,
                child: const Text(
                  'No matching notes found. Try different interests.',
                ),
              ),
            if (results != null && results!.isNotEmpty) ...[
              Semantics(
                liveRegion: true,
                child: const Text(
                  'Search results',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 12),
              for (final note in results!)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.isDemo
                              ? 'Demo note'
                              : note.shared
                              ? 'Shared note'
                              : 'Matched note',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        if (note.topics.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final topic in note.topics)
                                Chip(label: Text(topic)),
                            ],
                          ),
                        ],
                        if (note.why != null && note.why!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(note.why!),
                        ],
                        if (note.sharedText != null &&
                            note.sharedText!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          SelectableText(note.sharedText!),
                        ] else if (note.topics.isEmpty &&
                            (note.why == null || note.why!.isEmpty)) ...[
                          const SizedBox(height: 8),
                          const Text('On your wavelength · note text kept private'),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
