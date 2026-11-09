import 'package:flutter/material.dart';

import 'conversation_api.dart';
import 'ui/wavelength_theme.dart';

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
      final notes = await api.search(interests.text);
      if (!mounted) return;
      setState(() => results = notes);
    } on SearchException catch (failure) {
      if (!mounted) return;
      setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  static String _capText(String value, int maxRunes) {
    final trimmed = value.trim();
    final runes = trimmed.runes;
    if (runes.length <= maxRunes) return trimmed;
    return '${String.fromCharCodes(runes.take(maxRunes)).trimRight()}…';
  }

  @override
  void dispose() {
    interests.dispose();
    if (widget.api == null) api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: WavelengthTheme.dark(),
    child: Scaffold(
      backgroundColor: WavelengthColors.canvas,
      appBar: AppBar(
        title: const Text('Find my wavelength'),
        backgroundColor: WavelengthColors.canvas,
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
                  color: WavelengthColors.brandWhite,
                  fontSize: 34,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Tell us what you’d love to explore.',
                style: WavelengthTypography.body,
              ),
              const SizedBox(height: 12),
              const Text(
                'Search currently queries a synthetic demo note. Attendee topic matching is coming next.',
                style: WavelengthTypography.supporting,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: interests,
                enabled: !loading,
                minLines: 3,
                maxLines: 6,
                maxLength: 120,
                style: WavelengthTypography.body,
                onChanged: (_) => setState(() {
                  results = null;
                  error = null;
                }),
                decoration: const InputDecoration(
                  labelText: 'Your interests',
                  hintText: 'e.g. OpenTelemetry, Cilium, or AI inference',
                  helperText: 'Use 2–120 characters.',
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: valid && !loading ? search : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: WavelengthColors.phosphorBlue,
                    foregroundColor: WavelengthColors.onPhosphor,
                    disabledBackgroundColor: WavelengthColors.elevated,
                    disabledForegroundColor: WavelengthColors.secondaryText,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: WavelengthColors.onPhosphor,
                          ),
                        )
                      : const Icon(Icons.radar_rounded),
                  label: Text(
                    loading
                        ? 'Searching…'
                        : error != null
                        ? 'Retry search'
                        : 'Search notes',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Searching sends your typed interests to our server.',
                textAlign: TextAlign.center,
                style: WavelengthTypography.supporting,
              ),
              const SizedBox(height: 24),
              if (error != null)
                Semantics(
                  liveRegion: true,
                  child: PhosphorSurfaceCard(
                    accentBorderColor: WavelengthColors.micHotCoral,
                    child: Text(error!, style: WavelengthTypography.body),
                  ),
                ),
              if (results != null && results!.isEmpty)
                Semantics(
                  liveRegion: true,
                  child: const PhosphorSurfaceCard(
                    child: Text(
                      'No matching notes found. Try different interests.',
                      style: WavelengthTypography.body,
                    ),
                  ),
                ),
              if (results != null && results!.isNotEmpty) ...[
                Semantics(
                  liveRegion: true,
                  child: const Text(
                    'Search results',
                    style: WavelengthTypography.sectionTitle,
                  ),
                ),
                const SizedBox(height: 12),
                for (final note in results!) ...[
                  PhosphorSurfaceCard(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.isDemo
                              ? 'Demo note'
                              : note.shared
                              ? 'Shared note'
                              : 'Matched note',
                          style: WavelengthTypography.phosphorBadge,
                        ),
                        if (note.topics.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final topic in note.topics.take(5))
                                Chip(label: Text(_capText(topic, 64))),
                            ],
                          ),
                        ],
                        if (note.why != null &&
                            note.why!.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _capText(note.why!, 280),
                            style: WavelengthTypography.body,
                          ),
                        ],
                        if (note.sharedText != null &&
                            note.sharedText!.trim().isNotEmpty) ...[
                          const SizedBox(height: 10),
                          SelectableText(
                            _capText(note.sharedText!, 280),
                            style: WavelengthTypography.body,
                          ),
                        ] else if (note.topics.isEmpty &&
                            (note.why == null || note.why!.trim().isEmpty)) ...[
                          const SizedBox(height: 10),
                          const Text(
                            'On your wavelength · note text kept private',
                            style: WavelengthTypography.supporting,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
