import 'dart:async';

import 'package:flutter/material.dart';

import 'recording_controller.dart';
import 'search_screen.dart';

export 'search_screen.dart';

void main() => runApp(const ConversationApp());

class ConversationApp extends StatelessWidget {
  const ConversationApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ConFellow',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF7F5EE),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF42644E)),
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final RecordingController recording;
  @override
  void initState() {
    super.initState();
    recording = RecordingController();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(recording.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    recording.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: recording,
    builder: (context, _) {
      final active = recording.phase == RecordingPhase.recording;
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.graphic_eq_rounded, size: 23),
                        SizedBox(width: 8),
                        Text(
                          'CONFELLOW',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Good ideas\nfind each other.',
                      style: TextStyle(
                        fontSize: 38,
                        height: 1.08,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -1.8,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Capture a note. Tune into your people.',
                      style: TextStyle(color: Color(0xFF69716A), fontSize: 16),
                    ),
                    const SizedBox(height: 26),
                    BlobButton(
                      color: active
                          ? const Color(0xFFEDB5A2)
                          : const Color(0xFFDDE7BF),
                      icon: active
                          ? Icons.stop_rounded
                          : Icons.mic_none_rounded,
                      title: recording.busy
                          ? 'One moment…'
                          : active
                          ? 'Press to stop\nrecording'
                          : 'Press to record\na note',
                      subtitle: recording.busy
                          ? 'Preparing your note'
                          : active
                          ? 'Listening · up to 3 minutes'
                          : 'Speak your own thought',
                      busy: recording.busy,
                      onTap: recording.busy
                          ? null
                          : () => active ? recording.stop() : recording.start(),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      recording.status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF69716A),
                      ),
                    ),
                    const SizedBox(height: 20),
                    BlobButton(
                      color: const Color(0xFFD8D5ED),
                      icon: Icons.travel_explore,
                      title: 'Find my\nwavelength',
                      subtitle: 'Follow what sparks your curiosity',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SearchScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (recording.error != null)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE6DF),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(recording.error!),
                      ),
                    if (recording.transcript.isNotEmpty || active) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              active ? 'LIVE TRANSCRIPT' : 'YOUR NOTE',
                              style: const TextStyle(
                                fontSize: 11,
                                letterSpacing: 1.6,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              recording.transcript.isEmpty
                                  ? 'Speak naturally. Words will appear as they are transcribed.'
                                  : recording.transcript,
                              style: const TextStyle(fontSize: 16, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      'Speak your own notes · Audio stays on your phone.\nSearching sends your typed interests to our server.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: Color(0xFF69716A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class BlobButton extends StatelessWidget {
  const BlobButton({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });
  final Color color;
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final bool busy;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    child: Material(
      color: color,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.only(
        topLeft: Radius.elliptical(110, 85),
        topRight: Radius.elliptical(165, 110),
        bottomLeft: Radius.elliptical(145, 105),
        bottomRight: Radius.elliptical(95, 80),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            children: [
              if (busy)
                const SizedBox(
                  width: 30,
                  height: 30,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 32),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 25,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.7,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
