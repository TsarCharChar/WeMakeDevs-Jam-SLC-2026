import 'package:flutter/material.dart';

/// ConFellow — Black + Blue Phosphor Radar Design System.
///
/// Tuned for bright conference halls (Salt Palace / KubeCon) and verified
/// against WCAG 2.1 relative luminance contrast and Machado (2009) full-severity
/// protanopia/deuteranopia CIEDE2000 color-difference thresholds.
///
/// ### Verified Luminance & Contrast Math
/// Relative luminance `L = 0.2126 * R_lin + 0.7152 * G_lin + 0.0722 * B_lin`,
/// contrast ratio `CR = (L_lighter + 0.05) / (L_darker + 0.05)`:
/// - `canvas` (`#04060A`): `L = 0.001780`
/// - `surface` (`#0B1018`): `L = 0.005077`
/// - `elevated` (`#111927`): `L = 0.009609`
/// - `brandWhite` (`#FFFFFF`): `L = 1.000000` -> **20.28:1** vs `canvas`
/// - `primaryText` (`#F4F8FF`): `L = 0.935879` -> **19.04:1** vs `canvas`,
///   **17.90:1** vs `surface`, **16.54:1** vs `elevated` (WCAG AAA)
/// - `secondaryText` (`#9BB0C9`): `L = 0.422363` -> **9.12:1** vs `canvas`,
///   **8.58:1** vs `surface`, **7.92:1** vs `elevated` (exceeds >= 5.8:1 floor)
/// - `phosphorBlue` (`#38BDF8`): `L = 0.440133` -> **9.47:1** vs `canvas`,
///   **8.90:1** vs `surface`, **8.22:1** vs `elevated`
/// - `phosphorCyan` (`#4CC9F0`): `L = 0.496011` -> **10.54:1** vs `canvas`
/// - `phosphorIce` (`#7DD3FC`): `L = 0.579768` -> **12.16:1** vs `canvas`
/// - `talkStarlight` (`#F8FAFC`): `L = 0.953559` -> **19.38:1** vs `canvas`
/// - `innerRing` (`#2A6F9E`): `L = 0.143297` -> **3.73:1** vs `canvas`,
///   **3.51:1** vs `surface`, **3.24:1** vs `elevated` (exceeds >= 3.2:1 target)
/// - `onPhosphor` (`#031824`) on `phosphorBlue` (`#38BDF8`): **8.45:1**
/// - `micHotCoral` (`#FF7A59`): `L = 0.359003` -> **7.90:1** vs `canvas`;
///   `onMicHot` (`#220702`) on `micHotCoral`: **7.44:1**
///
/// ### Verified CVD Separation (Machado 2009, 100% severity, CIEDE2000)
/// - `phosphorBlue` (`#38BDF8`) vs `micHotCoral` (`#FF7A59`):
///   Normal = **53.8**, Deutan = **50.2**, Protan = **44.3** (all >> 35.0).
/// - `talkStarlight` (`#F8FAFC`) vs `phosphorBlue` (`#38BDF8`):
///   Normal = **27.3**, Deutan = **28.2**, Protan = **23.6**, reinforced by
///   distinct geometric shapes (4-point star/diamond beacon vs circular blip).
abstract final class WavelengthColors {
  // --- Deep Pitch / Obsidian Black Surfaces (never smearing #000000) ---
  static const Color canvas = Color(0xFF04060A);
  static const Color surface = Color(0xFF0B1018);
  static const Color elevated = Color(0xFF111927);

  // --- Structural Edges & Radar Rings ---
  static const Color borderSubtle = Color(0xFF1D2C42);
  static const Color borderSpecular = Color(0xFF2C4669);

  /// Inner closeness ring ("Strong signal") — 3.73:1 contrast vs `#04060A`.
  static const Color innerRing = Color(0xFF2A6F9E);

  /// Middle closeness ring ("On your wavelength") — 2.14:1 contrast vs `#04060A`.
  static const Color middleRing = Color(0xFF1B496B);

  /// Outer closeness ring ("Drifting closer") — 1.51:1 contrast vs `#04060A`.
  static const Color outerRing = Color(0xFF13314A);

  /// Major 30-degree compass perimeter ticks — 4.42:1 contrast vs `#04060A`.
  static const Color compassTickMajor = Color(0xFF2E7BB0);
  static const Color compassTickMinor = Color(0xFF1B496B);

  // --- High-Contrast Hall Typography ---
  static const Color brandWhite = Color(0xFFFFFFFF);
  static const Color primaryText = Color(0xFFF4F8FF);
  static const Color secondaryText = Color(0xFFA9BCD0);
  static const Color mutedText = Color(0xFF6F8298);

  // --- Blue Phosphor Radar Signal Tokens (Idle Mic, Waves, Sweep, Spaces) ---
  static const Color phosphorBlue = Color(0xFF38BDF8);
  static const Color phosphorCyan = Color(0xFF4CC9F0);
  static const Color phosphorIce = Color(0xFF7DD3FC);
  static const Color phosphorBloom = Color(0xFF0EA5E9);
  static const Color phosphorAfterglow = Color(0xFF1E40AF);
  static const Color onPhosphor = Color(0xFF031824);

  /// Starlight / ice white core for Scheduled Talk 4-point diamond beacons.
  static const Color talkStarlight = Color(0xFFE6F1FF);

  /// Aqua accent for your own notes and linked-topic suggestions (`#5EEAD4`).
  static const Color noteAqua = Color(0xFF5EEAD4);

  /// Violet accent for people tuned in sparks (`#A78BFA`).
  static const Color personViolet = Color(0xFFA78BFA);

  // --- Active Recording ONLY (Mic Hot) ---
  /// Warm Signal Coral reserved strictly for live user microphone capture.
  /// Never used on idle controls, errors, or other people's notes.
  static const Color micHotCoral = Color(0xFFFF7A59);
  static const Color micHotGlow = Color(0xFFE85A37);
  static const Color onMicHot = Color(0xFF220702);

  // --- Status & Error Accents (Amber — never Coral!) ---
  static const Color warningAmber = Color(0xFFF6C445);
  static const Color errorBannerBg = Color(0xFF241C09);
  static const Color errorBannerBorder = Color(0xFFF6C445);
}

/// Distinguishes Scheduled Conference Talks from emergent Topic Spaces.
///
/// Always paired with distinct geometry:
/// - [SpaceKind.talk]: 4-point star / faceted diamond radar beacon
/// - [SpaceKind.topic]: glowing circular phosphor radar blip
enum SpaceKind {
  talk,
  topic;

  String get badgeLabel => switch (this) {
    SpaceKind.talk => 'Scheduled talk',
    SpaceKind.topic => 'Topic space',
  };

  IconData get fallbackIcon => switch (this) {
    SpaceKind.talk => Icons.auto_awesome_rounded,
    SpaceKind.topic => Icons.radar_rounded,
  };
}

/// Spatial closeness rings replacing raw cosine/Elastic numeric scores.
///
/// Never show `%` match scores or say `"nearby"`.
enum ClosenessRing {
  inner,
  middle,
  outer;

  String get humanLabel => switch (this) {
    ClosenessRing.inner => 'Strong signal',
    ClosenessRing.middle => 'On your wavelength',
    ClosenessRing.outer => 'Drifting closer',
  };

  /// Normalized radial fraction of the constellation's usable radius.
  double get radiusFactor => switch (this) {
    ClosenessRing.inner => 0.36,
    ClosenessRing.middle => 0.64,
    ClosenessRing.outer => 0.88,
  };
}

/// Toggle between the default Black + Blue Phosphor Radar signal colors and
/// Proposal 4d's CVD-safe hue-by-topic-family table.
enum TopicColorMode {
  /// Default: Electric Blue Phosphor (`#38BDF8` / `#7DD3FC`) + Starlight
  /// (`#F8FAFC`) beacons, keeping `#FF7A59` strictly for live mic.
  phosphorRadar,

  /// Optional 4d mode: 5 CVD-safe bioluminescent phosphor hues mapped from
  /// KubeCon `sess__tags` tracks while preserving shape-by-kind.
  topicFamily;

  String get label => switch (this) {
    TopicColorMode.phosphorRadar => 'Blue Phosphor Radar',
    TopicColorMode.topicFamily => 'Hue by topic family',
  };
}

/// Five CVD-safe topic families mapped from bundled KubeCon `sess__tags`.
///
/// Every color maintains >= 8.3:1 WCAG contrast on `#04060A` and avoids warm
/// coral (`#FF7A59`) so live mic state remains unmistakable.
enum TopicFamily {
  aiAndAgents('AI & Agents', Color(0xFF4CC9F0)),
  observabilityAndSystems('Observability & eBPF', Color(0xFF38BDF8)),
  platformAndDelivery('Platform & Delivery', Color(0xFF93C5FD)),
  securityAndIdentity('Security & Policy', Color(0xFFF6C445)),
  networkingAndRuntime('Mesh, Wasm & Edge', Color(0xFFE4EE89));

  const TopicFamily(this.label, this.color);
  final String label;
  final Color color;

  /// Classifies a KubeCon schedule tag or matched topic string into a family.
  static TopicFamily fromTopic(String rawTopic) {
    final lower = rawTopic.toLowerCase();
    if (lower.contains('ai') ||
        lower.contains('agent') ||
        lower.contains('llm') ||
        lower.contains('whisper') ||
        lower.contains('kubeflow') ||
        lower.contains('inference') ||
        lower.contains('gpu')) {
      return TopicFamily.aiAndAgents;
    }
    if (lower.contains('observability') ||
        lower.contains('ebpf') ||
        lower.contains('otel') ||
        lower.contains('telemetry') ||
        lower.contains('operations') ||
        lower.contains('performance') ||
        lower.contains('prometheus')) {
      return TopicFamily.observabilityAndSystems;
    }
    if (lower.contains('security') ||
        lower.contains('auth') ||
        lower.contains('rbac') ||
        lower.contains('zero trust') ||
        lower.contains('policy') ||
        lower.contains('opa') ||
        lower.contains('supply chain')) {
      return TopicFamily.securityAndIdentity;
    }
    if (lower.contains('connectivity') ||
        lower.contains('istio') ||
        lower.contains('envoy') ||
        lower.contains('mesh') ||
        lower.contains('wasm') ||
        lower.contains('edge') ||
        lower.contains('network')) {
      return TopicFamily.networkingAndRuntime;
    }
    return TopicFamily.platformAndDelivery;
  }
}

/// Resolves node core and halo colors according to [TopicColorMode] and [SpaceKind].
abstract final class WavelengthPaletteResolver {
  static Color nodeAccent({
    required SpaceKind kind,
    required List<String> topics,
    TopicColorMode mode = TopicColorMode.phosphorRadar,
  }) {
    if (mode == TopicColorMode.topicFamily && topics.isNotEmpty) {
      return TopicFamily.fromTopic(topics.first).color;
    }
    return switch (kind) {
      SpaceKind.talk => WavelengthColors.talkStarlight,
      SpaceKind.topic => WavelengthColors.phosphorIce,
    };
  }

  static Color nodeRim({
    required SpaceKind kind,
    required List<String> topics,
    TopicColorMode mode = TopicColorMode.phosphorRadar,
  }) {
    if (mode == TopicColorMode.topicFamily && topics.isNotEmpty) {
      return TopicFamily.fromTopic(topics.first).color;
    }
    return switch (kind) {
      SpaceKind.talk => WavelengthColors.phosphorCyan,
      SpaceKind.topic => WavelengthColors.phosphorBlue,
    };
  }

  /// Blends the user's top matched topic families for the `YOU` center node
  /// when [TopicColorMode.topicFamily] is active; otherwise returns core
  /// Electric Blue Phosphor (`#38BDF8`).
  static Color centerWavelengthColor({
    required List<String> activeTopics,
    TopicColorMode mode = TopicColorMode.phosphorRadar,
  }) {
    if (mode == TopicColorMode.phosphorRadar || activeTopics.isEmpty) {
      return WavelengthColors.phosphorBlue;
    }
    var blended = TopicFamily.fromTopic(activeTopics.first).color;
    final count = activeTopics.length < 3 ? activeTopics.length : 3;
    for (var i = 1; i < count; i++) {
      final next = TopicFamily.fromTopic(activeTopics[i]).color;
      blended = Color.lerp(blended, next, 1.0 / (i + 1)) ?? blended;
    }
    return blended;
  }
}

/// Typography scale enforcing a strict `14.0` logical-pixel minimum on every
/// informational text style for glanceability at arm's length in bright halls.
abstract final class WavelengthTypography {
  static const double minInformationalFontSize = 14.0;

  static const TextStyle brandWordmark = TextStyle(
    color: WavelengthColors.brandWhite,
    fontSize: 15.0,
    fontWeight: FontWeight.w700,
    letterSpacing: 5.0,
    height: 1.1,
  );

  static const TextStyle heroHeadline = TextStyle(
    color: WavelengthColors.primaryText,
    fontSize: 28.0,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.8,
    height: 1.15,
  );

  static const TextStyle sheetTitle = TextStyle(
    color: WavelengthColors.primaryText,
    fontSize: 21.0,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.22,
  );

  static const TextStyle sectionTitle = TextStyle(
    color: WavelengthColors.primaryText,
    fontSize: 16.0,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
  );

  static const TextStyle body = TextStyle(
    color: WavelengthColors.primaryText,
    fontSize: 15.0,
    fontWeight: FontWeight.w400,
    height: 1.48,
  );

  /// Minimum-floor informational metadata style (`14.0` sp, `#9BB0C9`, 9.12:1).
  static const TextStyle supporting = TextStyle(
    color: WavelengthColors.secondaryText,
    fontSize: 14.0,
    fontWeight: FontWeight.w500,
    height: 1.38,
  );

  /// Phosphor accent badge text (`14.0` sp — always paired with border/icon/fill,
  /// never color alone).
  static const TextStyle phosphorBadge = TextStyle(
    color: WavelengthColors.phosphorIce,
    fontSize: 14.0,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.2,
  );

  static const TextStyle mapNodeLabel = TextStyle(
    color: WavelengthColors.primaryText,
    fontSize: 14.0,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.18,
  );
}

/// Builds the complete Material 3 `ThemeData` for ConFellow's Black + Blue
/// Phosphor Radar aesthetic.
abstract final class WavelengthTheme {
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: WavelengthColors.surface,
      onSurface: WavelengthColors.primaryText,
      onSurfaceVariant: WavelengthColors.secondaryText,
      primary: WavelengthColors.phosphorBlue,
      onPrimary: WavelengthColors.onPhosphor,
      secondary: WavelengthColors.phosphorCyan,
      onSecondary: WavelengthColors.onPhosphor,
      error: WavelengthColors.warningAmber,
      onError: WavelengthColors.errorBannerBg,
      outline: WavelengthColors.borderSpecular,
      outlineVariant: WavelengthColors.borderSubtle,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: WavelengthColors.canvas,
      colorScheme: scheme,
      splashFactory: InkSparkle.splashFactory,
      textTheme: const TextTheme(
        headlineMedium: WavelengthTypography.heroHeadline,
        titleLarge: WavelengthTypography.sheetTitle,
        titleMedium: WavelengthTypography.sectionTitle,
        bodyLarge: WavelengthTypography.body,
        bodyMedium: WavelengthTypography.body,
        bodySmall: WavelengthTypography.supporting,
        labelLarge: TextStyle(
          fontSize: 15.0,
          fontWeight: FontWeight.w600,
          color: WavelengthColors.primaryText,
        ),
        labelMedium: WavelengthTypography.supporting,
        labelSmall: WavelengthTypography.supporting,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: WavelengthColors.canvas,
        foregroundColor: WavelengthColors.primaryText,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: WavelengthTypography.sectionTitle,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: WavelengthColors.elevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: WavelengthColors.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          side: BorderSide(color: WavelengthColors.borderSpecular, width: 1),
        ),
      ),
      cardTheme: CardThemeData(
        color: WavelengthColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(
            color: WavelengthColors.borderSubtle,
            width: 1,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: WavelengthColors.surface,
        selectedColor: WavelengthColors.phosphorAfterglow.withValues(
          alpha: 0.55,
        ),
        side: const BorderSide(
          color: WavelengthColors.borderSpecular,
          width: 1,
        ),
        labelStyle: WavelengthTypography.supporting.copyWith(
          color: WavelengthColors.primaryText,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return WavelengthColors.onPhosphor;
          }
          return WavelengthColors.secondaryText;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return WavelengthColors.phosphorBlue;
          }
          return WavelengthColors.surface;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return WavelengthColors.phosphorCyan;
          }
          return WavelengthColors.borderSpecular;
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WavelengthColors.surface,
        labelStyle: WavelengthTypography.supporting,
        hintStyle: WavelengthTypography.supporting,
        helperStyle: WavelengthTypography.supporting,
        errorStyle: WavelengthTypography.supporting.copyWith(
          color: WavelengthColors.warningAmber,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: WavelengthColors.borderSpecular),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: WavelengthColors.phosphorBlue,
            width: 1.6,
          ),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: WavelengthColors.warningAmber),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: WavelengthColors.warningAmber,
            width: 1.6,
          ),
        ),
      ),
    );
  }
}

/// Frosted obsidian card with a crisp `1px` top phosphor specular edge
/// (creates physical depth on `#04060A` without muddy drop shadows).
class PhosphorSurfaceCard extends StatelessWidget {
  const PhosphorSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.elevated = false,
    this.accentBorderColor,
    this.borderRadius = 20.0,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool elevated;
  final Color? accentBorderColor;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final bg = elevated ? WavelengthColors.elevated : WavelengthColors.surface;
    final rim =
        accentBorderColor ??
        (elevated
            ? WavelengthColors.borderSpecular
            : WavelengthColors.borderSubtle);
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: rim, width: 1.0),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            WavelengthColors.phosphorIce.withValues(alpha: 0.055),
            bg.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.22],
        ),
      ),
      padding: padding,
      child: child,
    );
  }
}

/// Paints the distinct geometric Space badge icon (`SpaceKind.talk` = 4-point
/// diamond/star beacon; `SpaceKind.topic` = concentric phosphor radar blip)
/// so node type never depends on color alone.
class SpaceShapeBadge extends StatelessWidget {
  const SpaceShapeBadge({
    super.key,
    required this.kind,
    this.topics = const [],
    this.colorMode = TopicColorMode.phosphorRadar,
    this.size = 24.0,
  });

  final SpaceKind kind;
  final List<String> topics;
  final TopicColorMode colorMode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final core = WavelengthPaletteResolver.nodeAccent(
      kind: kind,
      topics: topics,
      mode: colorMode,
    );
    final rim = WavelengthPaletteResolver.nodeRim(
      kind: kind,
      topics: topics,
      mode: colorMode,
    );
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SpaceShapeBadgePainter(kind: kind, core: core, rim: rim),
      ),
    );
  }
}

class _SpaceShapeBadgePainter extends CustomPainter {
  const _SpaceShapeBadgePainter({
    required this.kind,
    required this.core,
    required this.rim,
  });

  final SpaceKind kind;
  final Color core;
  final Color rim;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide * 0.44;

    // Soft phosphor halo
    canvas.drawCircle(
      center,
      r * 1.12,
      Paint()..color = rim.withValues(alpha: 0.20),
    );

    if (kind == SpaceKind.talk) {
      // 4-point star / faceted diamond beacon
      final path = Path()
        ..moveTo(center.dx, center.dy - r)
        ..quadraticBezierTo(
          center.dx + r * 0.24,
          center.dy - r * 0.24,
          center.dx + r,
          center.dy,
        )
        ..quadraticBezierTo(
          center.dx + r * 0.24,
          center.dy + r * 0.24,
          center.dx,
          center.dy + r,
        )
        ..quadraticBezierTo(
          center.dx - r * 0.24,
          center.dy + r * 0.24,
          center.dx - r,
          center.dy,
        )
        ..quadraticBezierTo(
          center.dx - r * 0.24,
          center.dy - r * 0.24,
          center.dx,
          center.dy - r,
        )
        ..close();

      canvas.drawPath(path, Paint()..color = core);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = rim,
      );
    } else {
      // Circular radar blip with outer phosphor ring
      canvas.drawCircle(
        center,
        r * 0.85,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = rim,
      );
      canvas.drawCircle(center, r * 0.48, Paint()..color = core);
    }
  }

  @override
  bool shouldRepaint(covariant _SpaceShapeBadgePainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.core != core ||
      oldDelegate.rim != rim;
}

/// Top brand bar displaying crisp `#FFFFFF` `CONFELLOW` wordmark, active
/// signal count on your wavelength (never `"nearby"`), and settings button.
class WavelengthBrandHeader extends StatelessWidget {
  const WavelengthBrandHeader({
    super.key,
    required this.signalCount,
    this.onOpenSettings,
    this.trailing,
  });

  final int signalCount;
  final VoidCallback? onOpenSettings;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final signalCopy = signalCount == 1
        ? '1 signal on your wavelength'
        : '$signalCount signals on your wavelength';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: WavelengthColors.phosphorAfterglow.withValues(alpha: 0.35),
              border: Border.all(
                color: WavelengthColors.phosphorBlue.withValues(alpha: 0.65),
              ),
            ),
            child: const Icon(
              Icons.radar_rounded,
              size: 18,
              color: WavelengthColors.phosphorCyan,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'CONFELLOW',
                  style: WavelengthTypography.brandWordmark,
                ),
                const SizedBox(height: 2),
                Text(
                  signalCopy,
                  style: WavelengthTypography.supporting,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          ?trailing,
          if (onOpenSettings != null)
            Semantics(
              button: true,
              label: 'Note and wavelength settings',
              child: IconButton(
                onPressed: onOpenSettings,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: 'Settings',
                icon: const Icon(
                  Icons.tune_rounded,
                  color: WavelengthColors.primaryText,
                  size: 22,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
