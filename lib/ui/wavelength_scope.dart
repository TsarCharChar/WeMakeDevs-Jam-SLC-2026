// The Wavelength Scope: ConFellow's home-screen map.
//
// A port of the approved mock-up (.agent-review/design/wavelength-scope.html, function draw()).
// The numbers below are the mock-up's, in its 412-wide layout; the widget scales them to its size.
//
// What it draws, and from which data:
//   * rings      three standing waves (5, 8 and 13 lobes) that follow the mic level
//   * topics     circles sized by [ScopeTopic.count], on ring 0 (closest) to 2
//   * filaments  dotted links between topics, from [ScopeEdge] (GET /graph edges, or the bundled schedule)
//   * talks      diamonds tied to their topic
//   * notes      small squares orbiting the centre, tied to the topics they tuned
//   * people     one violet spark per person tuned in ([ScopeTopic.people]); pass 0 when the count is not real
//   * sweep      a rotating beam; a node flashes as it passes and sends a pulse along each filament
// Coral is used only while [WavelengthScope.micLive] is true.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

@immutable
class ScopeTopic {
  const ScopeTopic({
    required this.id,
    required this.label,
    required this.count,
    required this.ring,
    this.people = 0,
    this.angleDeg,
  }) : assert(ring >= 0 && ring <= 2);

  final String id;
  final String label;

  /// How many talks and notes carry the topic. Sets the circle's size.
  final int count;

  /// 0 is closest to the person, 2 is furthest. Changing it animates the node to the new ring.
  final int ring;

  /// People tuned in. Drawn as orbiting sparks, at most six.
  final int people;

  /// Compass angle, 0 is up and clockwise. Null spreads the ring's topics evenly.
  final double? angleDeg;
}

@immutable
class ScopeTalk {
  const ScopeTalk({required this.id, required this.topicId, this.going = false});

  final String id;
  final String topicId;
  final bool going;
}

@immutable
class ScopeEdge {
  const ScopeEdge(this.a, this.b, this.weight);

  final String a;
  final String b;

  /// Any positive scale. The scope normalises by the largest weight it is given.
  final double weight;
}

@immutable
class ScopeNote {
  const ScopeNote({required this.id, required this.topicIds});

  final String id;
  final List<String> topicIds;
}

class WavelengthScope extends StatefulWidget {
  const WavelengthScope({
    super.key,
    required this.topics,
    this.talks = const <ScopeTalk>[],
    this.edges = const <ScopeEdge>[],
    this.notes = const <ScopeNote>[],
    this.selectedId,
    this.micLive = false,
    this.micLevel = 0,
    this.recordingElapsed,
    this.recordingLimit = const Duration(minutes: 3),
    this.pressImpulse = 0,
    this.tuneImpulse = 0,
    this.onSelect,
    this.onTapEmpty,
    this.reduceMotion,
    this.backgroundColor = const Color(0xFF04060A),
    this.labelStyle = const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  });

  final List<ScopeTopic> topics;
  final List<ScopeTalk> talks;
  final List<ScopeEdge> edges;
  final List<ScopeNote> notes;

  /// Id of the selected topic or talk. Everything but it and its neighbours dims.
  final String? selectedId;
  final bool micLive;

  /// 0..1, the RMS level of the latest PCM chunk.
  final double micLevel;
  final Duration? recordingElapsed;
  final Duration recordingLimit;

  /// Bump to send a wave out from the centre when the mic button is pressed.
  final int pressImpulse;

  /// Bump when a note has been tuned.
  final int tuneImpulse;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onTapEmpty;

  /// Null follows the platform's reduce-motion setting.
  final bool? reduceMotion;
  final Color backgroundColor;
  final TextStyle labelStyle;

  @override
  State<WavelengthScope> createState() => _WavelengthScopeState();
}

// ── the mock-up's numbers ──
const double _design = 412;
const List<double> _ring = <double>[64, 114, 162];
const double _bezel = 196;
const List<int> _lobes = <int>[5, 8, 13];
const List<double> _ringHz = <double>[1.15, 0.9, 0.7];
const List<double> _ampIdle = <double>[0.9, 0.8, 0.7];
const List<double> _ampLive = <double>[6.5, 5.5, 4.5];
const double _sweepPeriod = 8;
const double _sweepTail = 78 * math.pi / 180;
const double _pingTau = 1.15;
const double _hop = 0.8;
const double _noteOrbit = 44;
const double _tau = math.pi * 2;

const Color _mid = Color(0xFF0EA5E9);
const Color _core = Color(0xFF38BDF8);
const Color _hot = Color(0xFFBAE6FD);
const Color _white = Color(0xFFF0FAFF);
const Color _aqua = Color(0xFF5EEAD4);
const Color _violet = Color(0xFFA78BFA);
const Color _ice = Color(0xFFE6F1FF);
const Color _coral = Color(0xFFFF7A59);
const Color _coralHot = Color(0xFFFFD0C2);

Color _a(Color c, double alpha) => c.withValues(alpha: alpha.clamp(0.0, 1.0));
Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t.clamp(0.0, 1.0))!;
double _rad(double compassDeg) => (compassDeg - 90) * math.pi / 180;
double _posMod(double a, double m) => ((a % m) + m) % m;
double _spring(double x) => x <= 0
    ? 0
    : x >= 1.7
    ? 1
    : 1 - math.exp(-5.5 * x) * math.cos(7.5 * x);
int _ringIndex(double r) => r < (_ring[0] + _ring[1]) / 2
    ? 0
    : r < (_ring[1] + _ring[2]) / 2
    ? 1
    : 2;

class _P {
  const _P(this.x, this.y, this.a, this.r, this.base);
  final double x, y, a, r, base;
  Offset get o => Offset(x, y);
}

class _RingAnim {
  const _RingAnim(this.from, this.to, this.t0);
  final double from, to, t0;
  double value(double now, bool reduce) =>
      from + (to - from) * (reduce ? (now >= t0 ? 1.0 : 0.0) : _spring((now - t0) / 0.9));
}

class _Impulse {
  const _Impulse(this.t0, this.strength, this.color);
  final double t0, strength;
  final Color color;
}

class _Marker {
  const _Marker(this.id, this.from, this.t0);
  final String id;
  final double from, t0;
}

class _WavelengthScopeState extends State<WavelengthScope> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  final Map<String, _RingAnim> _anim = <String, _RingAnim>{};
  final Map<String, double> _angles = <String, double>{};
  final Map<String, double> _noteBorn = <String, double>{};
  final Map<String, Map<String, double>> _adj = <String, Map<String, double>>{};
  final List<_Impulse> _impulses = <_Impulse>[];
  final List<_Marker> _markers = <_Marker>[];
  final Map<String, TextPainter> _textCache = <String, TextPainter>{};
  double _level = 0, _lastTick = 0, _tuneAt = -99, _maxCount = 1, _maxWeight = 1;
  bool _reduce = false;

  double get _now => _clock.value;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _sync(initial: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = widget.reduceMotion ?? MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _applyMotion();
  }

  @override
  void didUpdateWidget(WavelengthScope old) {
    super.didUpdateWidget(old);
    _reduce = widget.reduceMotion ?? MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _applyMotion();
    if (widget.pressImpulse != old.pressImpulse) {
      _impulses.add(_Impulse(_now, 0.8, widget.micLive ? _coral : _core));
    }
    if (widget.tuneImpulse != old.tuneImpulse) {
      _impulses.add(_Impulse(_now + 0.3, 1, _core));
      _tuneAt = _now;
    }
    if (widget.labelStyle != old.labelStyle) _textCache.clear();
    _sync(initial: false);
    if (_reduce) _level = widget.micLive ? widget.micLevel.clamp(0.0, 1.0) : 0;
  }

  void _applyMotion() {
    if (_reduce && _ticker.isActive) _ticker.stop();
    if (!_reduce && !_ticker.isActive) {
      _lastTick = 0;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final double now = elapsed.inMicroseconds / 1e6;
    final double dt = (now - _lastTick).clamp(0.0, 0.1);
    _lastTick = now;
    final double target = widget.micLive ? widget.micLevel.clamp(0.0, 1.0) : 0;
    final double tau = target > _level ? 0.03 : 0.11; // fast attack, slower release
    _level += (target - _level) * (1 - math.exp(-dt / tau));
    _impulses.removeWhere((_Impulse i) => now - i.t0 > 3);
    _markers.removeWhere((_Marker m) => now - m.t0 > 6);
    _clock.value = now;
  }

  /// Brings the per-node state in line with the widget's lists.
  void _sync({required bool initial}) {
    final double now = _now;
    _maxCount = 1;
    final List<List<ScopeTopic>> byRing = <List<ScopeTopic>>[<ScopeTopic>[], <ScopeTopic>[], <ScopeTopic>[]];
    for (final ScopeTopic t in widget.topics) {
      _maxCount = math.max(_maxCount, t.count.toDouble());
      byRing[t.ring].add(t);
    }
    const List<double> offsets = <double>[315, 265, 80];
    final Set<String> ids = <String>{};
    for (int r = 0; r < 3; r++) {
      for (int i = 0; i < byRing[r].length; i++) {
        final ScopeTopic t = byRing[r][i];
        ids.add(t.id);
        // A node keeps its angle when it changes ring, so it moves straight in or out.
        _angles[t.id] = t.angleDeg ?? _angles[t.id] ?? (offsets[r] + i * 360 / byRing[r].length) % 360;
        final double target = _ring[r];
        final _RingAnim? a = _anim[t.id];
        if (a == null) {
          _anim[t.id] = _RingAnim(target, target, -9);
        } else if (a.to != target) {
          final double current = a.value(now, _reduce);
          if (target < a.to) _markers.add(_Marker(t.id, current, now + 0.6));
          _anim[t.id] = _RingAnim(current, target, now + (_reduce ? 0 : 0.3));
        }
      }
    }
    _anim.removeWhere((String id, _RingAnim _) => !ids.contains(id));
    _angles.removeWhere((String id, double _) => !ids.contains(id));

    _adj.clear();
    _maxWeight = 1e-9;
    for (final ScopeEdge e in widget.edges) {
      if (ids.contains(e.a) && ids.contains(e.b) && e.a != e.b) _maxWeight = math.max(_maxWeight, e.weight);
    }
    for (final ScopeEdge e in widget.edges) {
      if (!ids.contains(e.a) || !ids.contains(e.b) || e.a == e.b) continue;
      final double w = (e.weight / _maxWeight).clamp(0.0, 1.0);
      (_adj[e.a] ??= <String, double>{})[e.b] = w;
      (_adj[e.b] ??= <String, double>{})[e.a] = w;
    }

    final Set<String> noteIds = <String>{for (final ScopeNote n in widget.notes) n.id};
    for (final String id in noteIds) {
      _noteBorn.putIfAbsent(id, () => initial ? -9 : now + 0.25);
    }
    _noteBorn.removeWhere((String id, double _) => !noteIds.contains(id));
  }

  // ── geometry, shared by painting and hit-testing (mock-up units, origin at the centre) ──

  double _disp(int i, double a, double ta, double now) {
    if (_reduce) return 0;
    final double amp = _ampIdle[i] + _ampLive[i] * _level;
    final double w = ta * _tau * _ringHz[i];
    double d = amp * (0.7 * math.sin(_lobes[i] * a + i * 1.7) * math.cos(w) + 0.3 * math.sin(2 * _lobes[i] * a - w * 1.3));
    for (final _Impulse im in _impulses) {
      final double dt = now - im.t0;
      if (dt < 0 || dt > 2.4) continue;
      final double x = (_ring[i] - dt * 240) / 24;
      d += im.strength * 11 * math.exp(-x * x) * math.exp(-dt * 0.9);
    }
    return d;
  }

  double _topicSize(ScopeTopic t) => 5 + 7 * math.sqrt(t.count / _maxCount);

  _P _topicPos(ScopeTopic t, double ta, double now) {
    final double base = _anim[t.id]!.value(now, _reduce);
    final double deg = _angles[t.id]!, seed = deg * 0.37;
    final double a = _rad(deg) + (_reduce ? 0 : 0.022 * math.sin(ta * 0.31 + seed));
    final double r = base + _disp(_ringIndex(base), a, ta, now) + (_reduce ? 0 : 2.2 * math.sin(ta * 0.23 + seed * 1.7));
    return _P(r * math.cos(a), r * math.sin(a), a, r, base);
  }

  _P _talkPos(int index, _P tp) {
    final double a = tp.a + (index.isEven ? 14 : -14) * math.pi / 180;
    final double r = tp.base > 150 ? tp.r : tp.r + 26;
    return _P(r * math.cos(a), r * math.sin(a), a, r, tp.base);
  }

  double _scale(Size size) => math.min(size.width, size.height) / _design;

  String? _hit(Offset local, Size size) {
    final double k = _scale(size), now = _now, ta = _reduce ? 2.0 : now;
    final Offset p = (local - size.center(Offset.zero)) / k;
    final Map<String, _P> pos = <String, _P>{for (final ScopeTopic t in widget.topics) t.id: _topicPos(t, ta, now)};
    String? best;
    double bestD = double.infinity;
    void consider(String id, Offset o, double r) {
      final double d = (o - p).distance;
      if (d < math.max(24 / k, r + 12) && d < bestD) {
        best = id;
        bestD = d;
      }
    }

    for (int i = 0; i < widget.talks.length; i++) {
      final _P? tp = pos[widget.talks[i].topicId];
      if (tp != null) consider(widget.talks[i].id, _talkPos(i, tp).o, 6.5);
    }
    for (final ScopeTopic t in widget.topics) {
      consider(t.id, pos[t.id]!.o, _topicSize(t));
    }
    return best;
  }

  TextPainter _text(String s, Color color, TextStyle style) {
    final int bucket = (color.a * 12).round(); // few distinct opacities, so fading names reuse layouts
    final String key = '$s|${color.toARGB32() & 0xFFFFFF}|$bucket|${style.fontSize}';
    final TextPainter? cached = _textCache[key];
    if (cached != null) return cached;
    if (_textCache.length > 240) _textCache.clear();
    final TextPainter tp = TextPainter(
      text: TextSpan(text: s, style: style.copyWith(color: _a(color, bucket / 12))),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return _textCache[key] = tp;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    for (final TextPainter tp in _textCache.values) {
      tp.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Wavelength map: ${widget.topics.length} topics and ${widget.talks.length} talks',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails d) {
          final Size? size = context.size;
          if (size == null) return;
          final String? id = _hit(d.localPosition, size);
          if (id != null) {
            widget.onSelect?.call(id);
          } else {
            widget.onTapEmpty?.call();
          }
        },
        child: RepaintBoundary(
          child: CustomPaint(painter: _ScopePainter(this), size: Size.infinite),
        ),
      ),
    );
  }
}

class _ScopePainter extends CustomPainter {
  _ScopePainter(this.s) : super(repaint: s._clock);
  final _WavelengthScopeState s;

  // Strokes the path as light: wide and dim first, then the hot core.
  void _glow(Canvas canvas, Path path, Color col, Color hot, double w, double k) {
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.plus;
    canvas.drawPath(path, p..color = _a(col, 0.05 * k)..strokeWidth = w + 9);
    canvas.drawPath(path, p..color = _a(col, 0.13 * k)..strokeWidth = w + 4);
    canvas.drawPath(path, p..color = _a(col, 0.55 * k)..strokeWidth = w + 1);
    canvas.drawPath(path, p..color = _a(hot, 0.9 * k)..strokeWidth = math.max(0.6, w * 0.55));
  }

  void _orb(Canvas canvas, Offset c, double r, Color col, double a0) {
    if (a0 <= 0.004 || r <= 0) return;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(c, r, <Color>[_a(col, a0), _a(col, a0 * 0.38), _a(col, 0)], const <double>[0, 0.4, 1]),
    );
  }

  // A filament between two nodes, bent towards the centre the further apart they are.
  Offset _arcPoint(_P p1, _P p2, double u) {
    final double da = _posMod(p2.a - p1.a + math.pi, _tau) - math.pi;
    final double a = p1.a + da * u;
    final double r = (p1.r + (p2.r - p1.r) * u) * (1 - 0.36 * math.sin(math.pi * u) * da.abs() / math.pi);
    return Offset(r * math.cos(a), r * math.sin(a));
  }

  Path _arcPath(_P p1, _P p2, [double u0 = 0, double u1 = 1]) {
    final Path path = Path();
    const int n = 26;
    for (int i = 0; i <= n; i++) {
      final Offset o = _arcPoint(p1, p2, u0 + (u1 - u0) * i / n);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    return path;
  }

  void _nameTag(Canvas canvas, String text, _P p, double r, double alpha, Color col, double halfWidth) {
    if (alpha <= 0.04) return;
    final TextPainter tp = s._text(text, _a(col, alpha), s.widget.labelStyle);
    final double w = tp.width, c = math.cos(p.a), sn = math.sin(p.a);
    late double x0, y;
    bool right() {
      x0 = p.x + r + 8;
      y = p.y;
      return x0 + w <= halfWidth - 10;
    }

    bool left() {
      x0 = p.x - r - 8 - w;
      y = p.y;
      return x0 >= -halfWidth + 10;
    }

    void vertical(bool down) {
      x0 = (p.x - w / 2).clamp(-halfWidth + 10, math.max(-halfWidth + 10, halfWidth - w - 10));
      y = p.y + (down ? r + 15 : -r - 14);
    }

    if (c > 0.3) {
      if (!right() && !left()) vertical(sn < 0);
    } else if (c < -0.3) {
      if (!left() && !right()) vertical(sn < 0);
    } else {
      vertical(p.base > 150 ? sn < 0 : sn > 0); // on the outer ring the tag goes towards the centre
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x0 - 6, y - 10.5, w + 12, 21), const Radius.circular(7)),
      Paint()..color = _a(s.widget.backgroundColor, 0.74 * alpha),
    );
    tp.paint(canvas, Offset(x0, y - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final WavelengthScope w = s.widget;
    final bool reduce = s._reduce, live = w.micLive;
    final double now = s._now, ta = reduce ? 2.0 : now, lv = s._level;
    final double k = s._scale(size), halfWidth = size.width / (2 * k);
    final Paint line = Paint()..style = PaintingStyle.stroke;

    canvas.drawRect(Offset.zero & size, Paint()..color = w.backgroundColor);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(k);

    // glass: the faint glow of the tube face
    _orb(canvas, Offset.zero, _bezel + 30, const Color(0xFF0C4A7A), 0.34);
    _orb(canvas, Offset.zero, 90, _mid, 0.07 + 0.10 * lv);

    // sweep beam and its afterglow
    final double sweepA = ta * _tau / _sweepPeriod - math.pi / 2;
    double age(double a) => reduce ? 99 : _posMod(sweepA - a, _tau) / (_tau / _sweepPeriod);
    if (!reduce) {
      final Rect disc = Rect.fromCircle(center: Offset.zero, radius: _bezel - 4);
      final Path sector = Path()
        ..moveTo(0, 0)
        ..arcTo(disc, sweepA - _sweepTail, _sweepTail, false)
        ..close();
      canvas.drawPath(
        sector,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = SweepGradient(
            startAngle: 0,
            endAngle: _sweepTail,
            colors: <Color>[_a(_mid, 0), _a(_mid, 0.045), _a(_core, 0.16), _a(_hot, 0.30)],
            stops: const <double>[0, 0.55, 0.9, 1],
            transform: GradientRotation(sweepA - _sweepTail),
          ).createShader(disc),
      );
      final Offset dir = Offset(math.cos(sweepA), math.sin(sweepA));
      _glow(canvas, Path()..moveTo(dir.dx * 22, dir.dy * 22)..lineTo(dir.dx * (_bezel - 4), dir.dy * (_bezel - 4)), _core, _white, 1, 0.8);
    }

    // spokes and bezel
    for (int d = 0; d < 360; d += 30) {
      final double a = _rad(d.toDouble());
      canvas.drawLine(
        Offset(_ring[0] * math.cos(a), _ring[0] * math.sin(a)),
        Offset((_bezel - 16) * math.cos(a), (_bezel - 16) * math.sin(a)),
        line..color = _a(_mid, 0.07)..strokeWidth = 1,
      );
    }
    canvas.drawCircle(Offset.zero, _bezel, line..color = _a(_core, 0.30)..strokeWidth = 1);
    final TextStyle numeral = TextStyle(fontSize: 9, fontWeight: FontWeight.w500, fontFamily: 'monospace', height: 1, letterSpacing: 0.4, color: _a(_core, 0.55));
    for (int d = 0; d < 360; d += 5) {
      final double a = _rad(d.toDouble());
      final bool major = d % 30 == 0, mid = d % 10 == 0;
      final double len = major ? 11 : (mid ? 7 : 4), e = math.exp(-age(a) / 0.55);
      canvas.drawLine(
        Offset(_bezel * math.cos(a), _bezel * math.sin(a)),
        Offset((_bezel - len) * math.cos(a), (_bezel - len) * math.sin(a)),
        line
          ..color = _a(_mix(_core, _white, e), (major ? 0.75 : (mid ? 0.42 : 0.26)) + 0.6 * e)
          ..strokeWidth = major ? 1.5 : 1,
      );
      if (major) {
        final TextPainter tp = s._text(d.toString().padLeft(3, '0'), _a(_core, 0.55), numeral);
        tp.paint(canvas, Offset((_bezel - 21) * math.cos(a) - tp.width / 2, (_bezel - 21) * math.sin(a) - tp.height / 2));
      }
    }
    canvas.drawPath(
      Path()
        ..moveTo(0, -_bezel - 3)
        ..lineTo(-5, -_bezel - 11)
        ..lineTo(5, -_bezel - 11)
        ..close(),
      Paint()..color = _a(_white, 0.9),
    );

    // rings: standing waves driven by the voice
    for (int i = 2; i >= 0; i--) {
      final Path ring = Path();
      for (int n = 0; n <= 144; n++) {
        final double a = n / 144 * _tau, r = _ring[i] + s._disp(i, a, ta, now);
        n == 0 ? ring.moveTo(r * math.cos(a), r * math.sin(a)) : ring.lineTo(r * math.cos(a), r * math.sin(a));
      }
      ring.close();
      _glow(canvas, ring, _mix(_core, _hot, lv * 0.5), _mix(_hot, _white, lv), 1, const <double>[1, 0.62, 0.42][i] * (0.8 + 0.9 * lv));
    }
    if (!reduce) {
      for (final _Impulse im in s._impulses) {
        final double dt = now - im.t0;
        if (dt < 0 || dt > 1.1) continue;
        _glow(canvas, Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: 18 + dt * 240)), im.color, _white, 1.2, (1 - dt / 1.1) * 0.9 * im.strength);
      }
    }

    // where everything is, and how much light each topic is holding
    final Map<String, _P> pos = <String, _P>{for (final ScopeTopic t in w.topics) t.id: s._topicPos(t, ta, now)};
    final Map<String, double> ping = <String, double>{for (final ScopeTopic t in w.topics) t.id: age(pos[t.id]!.a)};
    final Map<String, double> energy = <String, double>{for (final ScopeTopic t in w.topics) t.id: reduce ? 0.22 : math.exp(-ping[t.id]! / _pingTau)};
    if (!reduce) {
      s._adj.forEach((String id, Map<String, double> links) {
        links.forEach((String other, double weight) {
          final double late = ping[other]! - _hop; // light arriving along a filament from a neighbour
          if (late > 0) energy[id] = math.max(energy[id]!, 0.45 * math.sqrt(weight) * math.exp(-late / 0.7));
        });
      });
    }
    final String? sel = w.selectedId;
    String? selTopic = sel != null && pos.containsKey(sel) ? sel : null;
    if (sel != null && selTopic == null) {
      for (final ScopeTalk t in w.talks) {
        if (t.id == sel) selTopic = t.topicId;
      }
    }
    bool lit(String id) => sel == null || id == selTopic || (selTopic != null && (s._adj[selTopic]?.containsKey(id) ?? false));

    // filaments, and the pulses running along them
    for (final ScopeEdge e in w.edges) {
      final _P? pa = pos[e.a], pb = pos[e.b];
      final double? kw = s._adj[e.a]?[e.b];
      if (pa == null || pb == null || kw == null) continue;
      final bool on = sel != null && (e.a == selTopic || e.b == selTopic);
      final double dim = sel == null ? 1 : (on ? 1 : 0.12);
      if (on) {
        final Path path = _arcPath(pa, pb);
        canvas.drawPath(path, line..strokeCap = StrokeCap.round..blendMode = BlendMode.plus..color = _a(_core, 0.20 + 0.2 * kw)..strokeWidth = 3.5);
        canvas.drawPath(path, line..color = _a(_hot, 0.6 + 0.4 * kw)..strokeWidth = 1.2);
      } else {
        final double length = ((pa.o - pb.o).distance * 1.25).clamp(12.0, 520.0);
        final int dots = (length / 5.6).round();
        canvas.drawPoints(
          ui.PointMode.points,
          <Offset>[for (int i = 0; i <= dots; i++) _arcPoint(pa, pb, i / dots)],
          Paint()
            ..blendMode = BlendMode.plus
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 1.7
            ..color = _a(_core, (0.30 + 0.5 * kw) * dim),
        );
      }
      line
        ..blendMode = BlendMode.srcOver
        ..strokeCap = StrokeCap.butt;
      if (reduce) continue;
      for (final (String src, _P from, _P to) in <(String, _P, _P)>[(e.a, pa, pb), (e.b, pb, pa)]) {
        final double u = ping[src]! / _hop;
        if (u <= 0 || u >= 1) continue;
        canvas.drawPath(
          _arcPath(from, to, math.max(0, u - 0.16), u),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..blendMode = BlendMode.plus
            ..strokeWidth = 1.6
            ..color = _a(_hot, 0.55 * (1 - u * 0.5) * dim),
        );
        _orb(canvas, _arcPoint(from, to, u), 7, _white, 0.85 * (1 - u * 0.4) * dim);
      }
    }

    // the person's notes: small squares orbiting the centre, tied to the topics they tuned
    for (int i = 0; i < w.notes.length; i++) {
      final ScopeNote n = w.notes[i];
      final double a = (reduce ? 0 : ta * _tau / 48) + 0.4 + i * _tau / math.max(3, w.notes.length);
      final Offset o = Offset(_noteOrbit * math.cos(a), _noteOrbit * math.sin(a));
      final double born = reduce ? 1 : ((now - (s._noteBorn[n.id] ?? -9)) / 0.5).clamp(0.0, 1.0);
      if (born <= 0) continue;
      final double dim = sel == null ? 1 : (n.topicIds.contains(selTopic) ? 1 : 0.2);
      for (final String id in n.topicIds) {
        final _P? tp = pos[id];
        if (tp == null) continue;
        canvas.drawLine(o, tp.o, line..color = _a(_aqua, (sel != null && id == selTopic ? 0.6 : 0.2) * born * dim)..strokeWidth = 1);
      }
      final double half = 4.2 * (0.4 + 0.6 * _spring(born * 1.2));
      _orb(canvas, o, 11, _aqua, 0.22 * born * dim);
      canvas.save();
      canvas.translate(o.dx, o.dy);
      canvas.rotate(a + 0.5);
      final RRect card = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: half * 2, height: half * 2), const Radius.circular(1.6));
      canvas.drawRRect(card, Paint()..color = _a(_aqua, 0.28 * born * dim));
      canvas.drawRRect(card, line..color = _a(_aqua, 0.95 * born * dim)..strokeWidth = 1.3);
      canvas.restore();
    }

    // "came closer" markers after a note is tuned, and sparks flying into the centre
    for (final _Marker m in s._markers) {
      final double dt = now - m.t0;
      final _P? p = pos[m.id];
      if (p == null || dt < 0 || dt > 5.5) continue;
      ScopeTopic? topic;
      for (final ScopeTopic t in w.topics) {
        if (t.id == m.id) topic = t;
      }
      if (topic == null) continue;
      final double size0 = s._topicSize(topic), fade = (1 - (dt - 3.5) / 2).clamp(0.0, 1.0) * (dt / 0.5).clamp(0.0, 1.0);
      final Offset dir = Offset(math.cos(p.a), math.sin(p.a));
      final double from = m.from, to = p.r + size0 + 5;
      canvas.drawPoints(
        ui.PointMode.points,
        <Offset>[for (double r = to; r < from; r += 7) dir * r],
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.6
          ..color = _a(_hot, 0.6 * fade),
      );
      for (int j = 0; j < 2; j++) {
        final double tip = p.r + size0 + 9 + j * 7 + (reduce ? 0 : 3 * math.sin(now * 5 - j)), back = tip + 5, spread = 5 / tip;
        canvas.drawPath(
          Path()
            ..moveTo(back * math.cos(p.a - spread), back * math.sin(p.a - spread))
            ..lineTo(tip * dir.dx, tip * dir.dy)
            ..lineTo(back * math.cos(p.a + spread), back * math.sin(p.a + spread)),
          line..color = _a(_white, 0.9 * fade)..strokeWidth = 1.6,
        );
      }
      final double since = now - s._tuneAt;
      if (!reduce && since >= 0 && since < 0.75) {
        for (int j = 0; j < 4; j++) {
          final double u = (since / 0.7 - j * 0.07).clamp(0.0, 1.0);
          if (u <= 0 || u >= 1) continue;
          final double ease = u * u * (3 - 2 * u);
          _orb(canvas, Offset.lerp(dir * m.from, Offset.zero, ease)!, 6, _white, 0.9 * (1 - u * 0.5));
        }
      }
    }

    // talks: diamonds tied to their topic
    for (int i = 0; i < w.talks.length; i++) {
      final ScopeTalk t = w.talks[i];
      final _P? tp = pos[t.topicId];
      if (tp == null) continue;
      final _P p = s._talkPos(i, tp);
      final bool isSel = sel == t.id;
      final double dim = sel == null ? 1 : (isSel || t.topicId == selTopic ? 1 : 0.2);
      final double e = reduce ? 0.2 : math.exp(-age(p.a) / _pingTau), half = isSel ? 8 : 6.5;
      canvas.drawLine(tp.o, p.o, line..color = _a(_ice, 0.24 * dim)..strokeWidth = 1);
      _orb(canvas, p.o, 14 + 6 * e, _ice, (0.10 + 0.28 * e + (t.going ? 0.2 : 0)) * dim);
      final Path diamond = Path()
        ..moveTo(p.x, p.y - half)
        ..lineTo(p.x + half, p.y)
        ..lineTo(p.x, p.y + half)
        ..lineTo(p.x - half, p.y)
        ..close();
      canvas.drawPath(diamond, Paint()..color = t.going ? _a(_ice, 0.95 * dim) : _a(const Color(0xFF080D15), dim));
      canvas.drawPath(diamond, line..color = _a(_ice, (0.7 + 0.3 * e) * dim)..strokeWidth = 1.5);
    }

    // topics: orbs sized by count, with one spark per person tuned in
    for (final ScopeTopic t in w.topics) {
      final _P p = pos[t.id]!;
      final double e = energy[t.id]!, dim = lit(t.id) ? 1 : 0.2, r = s._topicSize(t);
      _orb(canvas, p.o, r * 2.7 + 12 * e, _mid, (0.30 + 0.55 * e) * dim);
      _orb(canvas, p.o, r * 1.5 + 4 * e, _core, (0.5 + 0.5 * e) * dim);
      canvas.drawCircle(
        p.o,
        r,
        Paint()
          ..shader = ui.Gradient.radial(
            p.o,
            r,
            <Color>[_a(_mix(_hot, _white, e), dim), _a(_mix(_core, _hot, e * 0.8), dim), _a(_mix(_mid, _core, e), dim)],
            const <double>[0, 0.55, 1],
            TileMode.clamp,
            null,
            Offset(p.x - r * 0.3, p.y - r * 0.35),
          ),
      );
      final int people = math.min(t.people, 6);
      final double seed = s._angles[t.id]! * 0.37;
      for (int j = 0; j < people; j++) {
        final double dir = j.isOdd ? -1 : 1, a = dir * ta * (0.7 + 0.13 * j) + j * _tau / people + seed, orbit = r + 7 + (j % 2) * 4;
        final Offset o = p.o + Offset(orbit * math.cos(a), orbit * math.sin(a));
        if (!reduce) {
          canvas.drawArc(Rect.fromCircle(center: p.o, radius: orbit), a, -dir * 0.7, false, line..color = _a(_violet, 0.3 * dim)..strokeWidth = 1.2);
        }
        _orb(canvas, o, 6.5, _violet, 0.8 * dim);
        canvas.drawCircle(o, 1.8, Paint()..color = _a(const Color(0xFFC4B5FD), 0.95 * dim));
      }
      if (sel == t.id) {
        for (int j = 0; j < 4; j++) {
          canvas.drawArc(Rect.fromCircle(center: p.o, radius: r + 15), (reduce ? 0 : ta * 0.8) + j * _tau / 4, 0.9, false, line..color = _a(_white, 0.95)..strokeWidth = 1.6);
        }
      }
    }

    // the person: a harmonic ring that turns coral and follows the voice while the mic is live
    {
      final Color col = live ? _coral : _core, hot = live ? _coralHot : _white;
      final double v = live ? lv : 0, r0 = live ? 14 + 4 * v : 12, amp = reduce ? 0 : (live ? 2 + 7 * v : 1.3), speed = live ? 1 : 0.28;
      _orb(canvas, Offset.zero, 34 + 18 * v, col, 0.30 + 0.35 * v);
      final Path you = Path();
      for (int n = 0; n <= 96; n++) {
        final double a = n / 96 * _tau;
        final double r = r0 + amp * (0.6 * math.sin(3 * a + ta * 4 * speed) + 0.4 * math.sin(7 * a - ta * 6 * speed) + 0.25 * math.sin(11 * a + ta * 9 * speed));
        n == 0 ? you.moveTo(r * math.cos(a), r * math.sin(a)) : you.lineTo(r * math.cos(a), r * math.sin(a));
      }
      you.close();
      _glow(canvas, you, col, hot, 1.3, 1);
      _orb(canvas, Offset.zero, 7, _white, 1);
      final Duration? elapsed = w.recordingElapsed;
      if (live && elapsed != null) {
        final double f = (elapsed.inMilliseconds / math.max(1, w.recordingLimit.inMilliseconds)).clamp(0.0, 1.0);
        final Rect arc = Rect.fromCircle(center: Offset.zero, radius: 33);
        canvas.drawCircle(Offset.zero, 33, line..color = _a(_coral, 0.16)..strokeWidth = 2);
        canvas.drawArc(arc, -math.pi / 2, math.max(0.03, f) * _tau, false, line..strokeCap = StrokeCap.round..color = _a(_coralHot, 0.95)..strokeWidth = 2);
        line.strokeCap = StrokeCap.butt;
      }
    }

    // names: the innermost occupied ring, the selection and its neighbours, and whatever the beam just crossed
    // With nothing on ring 0 yet (a new profile), the innermost ring that has topics keeps its names.
    final int innermost = w.topics.fold<int>(2, (int ring, ScopeTopic t) => math.min(ring, t.ring));
    final List<ScopeTopic> ordered = <ScopeTopic>[...w.topics]..sort((ScopeTopic a, ScopeTopic b) => b.ring.compareTo(a.ring));
    for (final ScopeTopic t in ordered) {
      final double alpha = sel != null
          ? (lit(t.id) ? 1 : 0)
          : t.ring == innermost
          ? 1
          : (reduce ? 0 : (math.exp(-ping[t.id]! / 0.9) * 1.25).clamp(0.0, 1.0));
      _nameTag(canvas, t.label, pos[t.id]!, s._topicSize(t) + (t.people > 0 ? 9 : 0), alpha, sel != null || t.ring == innermost ? _white : _hot, halfWidth);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ScopePainter old) => true;
}

/// The oscilloscope trace that runs behind the mic button on the home screen.
///
/// Put the round mic button on top of it, centred. Idle it is a slow blue wave. While the mic is
/// live it turns coral and follows [micLevel].
class WaveStrip extends StatefulWidget {
  const WaveStrip({super.key, this.micLive = false, this.micLevel = 0, this.micRadius = 40, this.pressImpulse = 0, this.reduceMotion});

  final bool micLive;
  final double micLevel;
  final double micRadius;
  final int pressImpulse;
  final bool? reduceMotion;

  @override
  State<WaveStrip> createState() => _WaveStripState();
}

class _WaveStripState extends State<WaveStrip> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _clock = ValueNotifier<double>(0);
  double _level = 0, _lastTick = 0, _rippleAt = -99;
  Color _rippleColor = _core;
  bool _reduce = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((Duration elapsed) {
      final double now = elapsed.inMicroseconds / 1e6, dt = (now - _lastTick).clamp(0.0, 0.1);
      _lastTick = now;
      final double target = widget.micLive ? widget.micLevel.clamp(0.0, 1.0) : 0;
      _level += (target - _level) * (1 - math.exp(-dt / (target > _level ? 0.03 : 0.11)));
      _clock.value = now;
    });
  }

  void _applyMotion() {
    _reduce = widget.reduceMotion ?? MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_reduce && _ticker.isActive) _ticker.stop();
    if (!_reduce && !_ticker.isActive) {
      _lastTick = 0;
      _ticker.start();
    }
    if (_reduce) _level = widget.micLive ? widget.micLevel.clamp(0.0, 1.0) : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applyMotion();
  }

  @override
  void didUpdateWidget(WaveStrip old) {
    super.didUpdateWidget(old);
    _applyMotion();
    if (widget.pressImpulse != old.pressImpulse) {
      _rippleAt = _clock.value;
      _rippleColor = widget.micLive ? _coral : _core;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _StripPainter(this), size: Size.infinite),
  );
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.s) : super(repaint: s._clock);
  final _WaveStripState s;

  @override
  void paint(Canvas canvas, Size size) {
    final bool live = s.widget.micLive, reduce = s._reduce;
    final double now = s._clock.value, ta = reduce ? 2.0 : now, lv = s._level, cx = size.width / 2, cy = size.height / 2, mic = s.widget.micRadius;
    final Color col = live ? _coral : _core, hot = live ? _coralHot : _hot;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final Paint dot = Paint();
    for (double x = 14; x < size.width - 10; x += 8) {
      canvas.drawRect(Rect.fromLTWH(x, cy - 0.5, 2, 1), dot..color = _a(_core, (x - 14) % 40 == 8 ? 0.22 : 0.10));
    }
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.plus;
    void glow(Path path, double w, double k) {
      canvas.drawPath(path, stroke..color = _a(col, 0.05 * k)..strokeWidth = w + 9);
      canvas.drawPath(path, stroke..color = _a(col, 0.13 * k)..strokeWidth = w + 4);
      canvas.drawPath(path, stroke..color = _a(col, 0.55 * k)..strokeWidth = w + 1);
      canvas.drawPath(path, stroke..color = _a(hot, 0.9 * k)..strokeWidth = math.max(0.6, w * 0.55));
    }

    for (int echo = 2; echo >= 0; echo--) {
      final double tt = ta - echo * 0.11;
      final Path trace = Path();
      for (double x = 0; x <= size.width; x += 3) {
        final double env = math.exp(-math.pow((x - cx) / 165, 2).toDouble());
        final double y = live
            ? (5 + 27 * lv * (1 - echo * 0.25)) * env * (0.55 * math.sin(x * 0.045 - tt * 5.2) + 0.3 * math.sin(x * 0.091 + tt * 7.9) + 0.15 * math.sin(x * 0.153 - tt * 12.3))
            : (reduce ? 0 : 3.4) * env * (0.7 * math.sin(x * 0.03 - tt * 1.2) + 0.3 * math.sin(x * 0.061 + tt * 0.8));
        x == 0 ? trace.moveTo(x, cy + y) : trace.lineTo(x, cy + y);
      }
      glow(trace, 1.1, const <double>[1, 0.34, 0.15][echo] * (live ? 1 : 0.7));
    }
    final double since = now - s._rippleAt;
    if (!reduce && since >= 0 && since < 0.9) {
      final Color keep = stroke.color;
      canvas.drawCircle(Offset(cx, cy), mic + since * 170, stroke..color = _a(s._rippleColor, 0.7 * (1 - since / 0.9))..strokeWidth = 2);
      stroke.color = keep;
    }
    final double halo = mic + 26 + 22 * (live ? lv : 0);
    canvas.drawCircle(
      Offset(cx, cy),
      halo,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(Offset(cx, cy), halo, <Color>[_a(col, live ? 0.34 + 0.3 * lv : 0.20), _a(col, 0.08), _a(col, 0)], const <double>[0, 0.4, 1]),
    );
    glow(Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: mic + 1)), 1.6, 1);
    if (live) glow(Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: mic + 8 + 14 * lv)), 1, 0.25 + 0.5 * lv);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) => true;
}

// ── the Note page: the mic's ring of light, and the tall wave under it ──

void _glowPath(Canvas canvas, Path path, Color col, Color hot, double w, double k) {
  final Paint p = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..blendMode = BlendMode.plus;
  canvas.drawPath(path, p..color = _a(col, 0.05 * k)..strokeWidth = w + 9);
  canvas.drawPath(path, p..color = _a(col, 0.13 * k)..strokeWidth = w + 4);
  canvas.drawPath(path, p..color = _a(col, 0.55 * k)..strokeWidth = w + 1);
  canvas.drawPath(path, p..color = _a(hot, 0.9 * k)..strokeWidth = math.max(0.6, w * 0.55));
}

void _orbAt(Canvas canvas, Offset c, double r, Color col, double a0) {
  if (a0 <= 0.004 || r <= 0) return;
  canvas.drawCircle(
    c,
    r,
    Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(c, r, <Color>[_a(col, a0), _a(col, a0 * 0.38), _a(col, 0)], const <double>[0, 0.4, 1]),
  );
}

/// Shared clock and smoothed mic level for the two Note-page painters.
class _Pulse {
  _Pulse(TickerProvider vsync) {
    _ticker = vsync.createTicker((Duration elapsed) {
      final double now = elapsed.inMicroseconds / 1e6, dt = (now - _last).clamp(0.0, 0.1);
      _last = now;
      level += (target - level) * (1 - math.exp(-dt / (target > level ? 0.03 : 0.11)));
      clock.value = now;
    });
  }

  late final Ticker _ticker;
  final ValueNotifier<double> clock = ValueNotifier<double>(0);
  double level = 0, target = 0, _last = 0;
  bool reduce = false;

  void update({required bool reduceMotion, required bool live, required double micLevel}) {
    reduce = reduceMotion;
    target = live ? micLevel.clamp(0.0, 1.0) : 0;
    if (reduce) {
      level = target;
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _last = 0;
      _ticker.start();
    }
  }

  void dispose() {
    _ticker.dispose();
    clock.dispose();
  }
}

/// The light around the big mic button on the Note page.
///
/// Put it behind the button, centred, in a box about (micRadius + 50) * 2 square. It draws the
/// glow ring, a harmonic ring that follows [micLevel], the three-minute arc, and a ripple each
/// time [pressImpulse] changes. Blue when idle, coral only while [micLive] is true.
class MicHalo extends StatefulWidget {
  const MicHalo({
    super.key,
    this.micLive = false,
    this.micLevel = 0,
    this.micRadius = 64,
    this.recordingElapsed,
    this.recordingLimit = const Duration(minutes: 3),
    this.pressImpulse = 0,
    this.reduceMotion,
  });

  final bool micLive;
  final double micLevel;
  final double micRadius;
  final Duration? recordingElapsed;
  final Duration recordingLimit;
  final int pressImpulse;
  final bool? reduceMotion;

  @override
  State<MicHalo> createState() => _MicHaloState();
}

class _MicHaloState extends State<MicHalo> with SingleTickerProviderStateMixin {
  late final _Pulse _pulse = _Pulse(this);
  double _rippleAt = -99;
  Color _rippleColor = _core;

  void _sync() => _pulse.update(
    reduceMotion: widget.reduceMotion ?? MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    live: widget.micLive,
    micLevel: widget.micLevel,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(MicHalo old) {
    super.didUpdateWidget(old);
    _sync();
    if (widget.pressImpulse != old.pressImpulse) {
      _rippleAt = _pulse.clock.value;
      _rippleColor = widget.micLive ? _coral : _core;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _MicHaloPainter(this), size: Size.infinite),
  );
}

class _MicHaloPainter extends CustomPainter {
  _MicHaloPainter(this.s) : super(repaint: s._pulse.clock);
  final _MicHaloState s;

  @override
  void paint(Canvas canvas, Size size) {
    final MicHalo w = s.widget;
    final bool live = w.micLive, reduce = s._pulse.reduce;
    final double now = s._pulse.clock.value, ta = reduce ? 2.0 : now, lv = live ? s._pulse.level : 0, mic = w.micRadius;
    final Offset c = size.center(Offset.zero);
    final Color col = live ? _coral : _core, hot = live ? _coralHot : _hot;

    final double since = now - s._rippleAt;
    if (!reduce && since >= 0 && since < 1.1) {
      _glowPath(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: mic + since * 200)), s._rippleColor, _white, 1.2, 1 - since / 1.1);
    }
    _orbAt(canvas, c, mic + 40 + 26 * lv, col, live ? 0.36 + 0.3 * lv : 0.22);
    _glowPath(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: mic + 1)), col, hot, 1.8, 1);

    final double amp = reduce ? 0 : (live ? 2.5 + 11 * lv : 1.6), speed = live ? 1 : 0.3;
    final Path ring = Path();
    for (int n = 0; n <= 120; n++) {
      final double a = n / 120 * _tau;
      final double r = mic + 18 + 5 * lv + amp * (0.6 * math.sin(5 * a + ta * 4 * speed) + 0.4 * math.sin(8 * a - ta * 6 * speed) + 0.25 * math.sin(13 * a + ta * 9 * speed));
      final Offset o = c + Offset(r * math.cos(a), r * math.sin(a));
      n == 0 ? ring.moveTo(o.dx, o.dy) : ring.lineTo(o.dx, o.dy);
    }
    ring.close();
    _glowPath(canvas, ring, col, hot, 1.2, live ? 0.9 : 0.55);

    final Duration? elapsed = w.recordingElapsed;
    if (live && elapsed != null) {
      final double f = (elapsed.inMilliseconds / math.max(1, w.recordingLimit.inMilliseconds)).clamp(0.0, 1.0);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: mic + 8),
        -math.pi / 2,
        math.max(0.03, f) * _tau,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5
          ..color = _a(_coralHot, 0.95),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MicHaloPainter old) => true;
}

/// The tall wave on the Note page, above the "Find my wavelength" button.
///
/// Always blue phosphor. Idle it drifts slowly. While [micLive] it follows [micLevel]. Each time
/// [findImpulse] changes it bursts for [findDuration] with a scan line crossing it, which is the
/// feedback for "Find my wavelength". Give it the full width and about 180 of height.
class NoteWave extends StatefulWidget {
  const NoteWave({
    super.key,
    this.micLive = false,
    this.micLevel = 0,
    this.findImpulse = 0,
    this.findDuration = const Duration(milliseconds: 1800),
    this.reduceMotion,
  });

  final bool micLive;
  final double micLevel;
  final int findImpulse;
  final Duration findDuration;
  final bool? reduceMotion;

  @override
  State<NoteWave> createState() => _NoteWaveState();
}

class _NoteWaveState extends State<NoteWave> with SingleTickerProviderStateMixin {
  late final _Pulse _pulse = _Pulse(this);
  double _findAt = -99;

  void _sync() => _pulse.update(
    reduceMotion: widget.reduceMotion ?? MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    live: widget.micLive,
    micLevel: widget.micLevel,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(NoteWave old) {
    super.didUpdateWidget(old);
    _sync();
    if (widget.findImpulse != old.findImpulse) _findAt = _pulse.clock.value;
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _NoteWavePainter(this), size: Size.infinite),
  );
}

class _NoteWavePainter extends CustomPainter {
  _NoteWavePainter(this.s) : super(repaint: s._pulse.clock);
  final _NoteWaveState s;

  @override
  void paint(Canvas canvas, Size size) {
    final bool live = s.widget.micLive, reduce = s._pulse.reduce;
    final double now = s._pulse.clock.value, ta = reduce ? 2.0 : now, lv = live ? s._pulse.level : 0;
    final double seconds = s.widget.findDuration.inMilliseconds / 1000, find = now - s._findAt;
    final bool finding = !reduce && find >= 0 && find < seconds;
    final double burst = finding ? math.pow(math.sin(math.pi * find / seconds), 0.7).toDouble() : 0;
    final double energy = math.max(lv, burst), cy = size.height / 2, unit = _design / size.width; // x in mock-up units
    final double room = math.min(1.0, (size.height / 2) / 84); // the mock-up gives the wave 84 either side
    final bool busy = live || finding;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _orbAt(canvas, Offset(size.width / 2, cy), size.width * 0.6, const Color(0xFF0C4A7A), 0.26 + 0.2 * energy);
    final Paint dot = Paint();
    for (double x = 14; x < size.width - 10; x += 8) {
      canvas.drawRect(Rect.fromLTWH(x, cy - 0.5, 2, 1), dot..color = _a(_core, (x - 14) % 40 == 8 ? 0.26 : 0.11));
    }
    for (double x = 46; x < size.width; x += 80) {
      canvas.drawRect(Rect.fromLTWH(x, cy - 44 * room, 1, 5), dot..color = _a(_core, 0.10));
      canvas.drawRect(Rect.fromLTWH(x, cy + 44 * room, 1, 5), dot);
    }
    for (int echo = 2; echo >= 0; echo--) {
      final double tt = ta - echo * 0.12, speed = (busy ? 1 : 0.42) * (1 + 1.6 * burst);
      final double amp = ((reduce ? 0 : 7) + 62 * lv * (1 - echo * 0.25) + 44 * burst * (1 - echo * 0.2)) * room;
      final Path trace = Path();
      for (double x = 0; x <= size.width; x += 3) {
        final double u = x * unit, e = (u - _design / 2) / 150, env = 0.34 + 0.66 * math.exp(-e * e);
        final double y = amp * env * (0.5 * math.sin(u * 0.032 - tt * 2.4 * speed) + 0.28 * math.sin(u * 0.071 + tt * 3.7 * speed) + 0.14 * math.sin(u * 0.127 - tt * 6.1 * speed) + (busy ? 0.1 * math.sin(u * 0.21 + tt * 13) : 0));
        x == 0 ? trace.moveTo(x, cy + y) : trace.lineTo(x, cy + y);
      }
      _glowPath(canvas, trace, _mix(_core, _hot, energy * 0.6), _mix(_hot, _white, energy), 1.4, const <double>[1, 0.36, 0.16][echo] * (0.75 + 0.6 * energy));
    }
    if (finding) {
      final double x = size.width * find / seconds;
      _glowPath(canvas, Path()..moveTo(x, cy - 84 * room)..lineTo(x, cy + 84 * room), _core, _white, 1, 0.9 * burst);
      _orbAt(canvas, Offset(x, cy), 60, _core, 0.35 * burst);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NoteWavePainter old) => true;
}
