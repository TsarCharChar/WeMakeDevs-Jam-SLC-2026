import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

/// Real-time 16 kHz, 16-bit signed little-endian mono PCM level & 24-bar
/// harmonic/envelope analyzer for `RecordingController`.
///
/// Designed for zero disk I/O, zero allocations on the hot loop beyond compact
/// double buffers, and natural visual responsiveness across whispers and loud
/// conference halls.
///
/// ### Drop-in `RecordingController` wiring:
/// ```dart
/// final PcmLevelMeter pcmLevels = PcmLevelMeter();
/// // Inside start():
/// pcmLevels.reset();
/// // Inside _recorder.startStream(...).listen((bytes) { ... }):
/// _session?.feed(bytes);
/// if (pcmLevels.ingestPcm16Chunk(bytes)) update();
/// // Inside _cleanup() / stop():
/// pcmLevels.reset();
/// ```
class PcmLevelMeter {
  PcmLevelMeter({
    this.barCount = 24,
    this.noiseFloorDb = -46.0,
    this.peakDb = -3.5,
    this.minNotifyIntervalMs = 16,
  }) : assert(barCount >= 8, 'barCount must be at least 8'),
       _bars = List<double>.filled(barCount, 0.0),
       _history = ListQueue<double>(barCount);

  /// Number of reactive waveform bars (default: 24).
  final int barCount;

  /// Noise floor in dBFS mapped to `0.0` normalized amplitude.
  final double noiseFloorDb;

  /// Peak ceiling in dBFS mapped to `1.0` normalized amplitude.
  final double peakDb;

  /// Frame-rate throttle (~60 Hz) for `ChangeNotifier` listeners.
  final int minNotifyIntervalMs;

  double _smoothedLevel = 0.0;
  double _rawRmsLevel = 0.0;
  double _highFreqPresence = 0.0;
  int _lastNotifyEpochMs = 0;

  final List<double> _bars;
  final ListQueue<double> _history;

  /// Smoothed perceptual voice level in `[0.0, 1.0]`.
  double get level => _smoothedLevel;

  /// Unsmoothed normalized level of the most recent PCM chunk in `[0.0, 1.0]`.
  double get rawLevel => _rawRmsLevel;

  /// High-frequency / consonant sibilance ratio in `[0.0, 1.0]`.
  double get highFrequencyPresence => _highFreqPresence;

  /// Read-only view of the rolling 24-bar amplitude/band profile (`[0.0, 1.0]`).
  List<double> get bars => List<double>.unmodifiable(_bars);

  /// Clears all amplitude state when recording starts or stops.
  void reset() {
    _smoothedLevel = 0.0;
    _rawRmsLevel = 0.0;
    _highFreqPresence = 0.0;
    _lastNotifyEpochMs = 0;
    _history.clear();
    for (var i = 0; i < _bars.length; i++) {
      _bars[i] = 0.0;
    }
  }

  /// Processes a raw `pcm16bits` mono little-endian [bytes] chunk.
  ///
  /// Returns `true` when listeners should be notified (throttled to ~60 fps or
  /// immediate on sharp speech transients).
  bool ingestPcm16Chunk(Uint8List bytes, {int? nowEpochMs}) {
    final sampleCount = bytes.length ~/ 2;
    if (sampleCount <= 0) return false;

    final byteData = ByteData.sublistView(bytes);

    // Compute overall chunk RMS + first-difference HF energy + 4 sub-windows
    // so rapid syllables populate the 24-bar history smoothly.
    const subWindows = 4;
    final windowSize = math.max(1, sampleCount ~/ subWindows);

    var sumSqAll = 0.0;
    var diffSqAll = 0.0;
    var prevSample = 0.0;

    for (var w = 0; w < subWindows; w++) {
      final startSample = w * windowSize;
      final endSample = w == subWindows - 1
          ? sampleCount
          : math.min(sampleCount, (w + 1) * windowSize);
      if (endSample <= startSample) continue;

      var winSumSq = 0.0;
      for (var i = startSample; i < endSample; i++) {
        final rawInt16 = byteData.getInt16(i * 2, Endian.little);
        final norm = rawInt16 / 32768.0;
        final sq = norm * norm;
        winSumSq += sq;
        sumSqAll += sq;

        final diff = norm - prevSample;
        diffSqAll += diff * diff;
        prevSample = norm;
      }

      final winRms = math.sqrt(winSumSq / (endSample - startSample));
      final winNorm = _rmsToPerceptualUnit(winRms);
      _pushHistorySample(winNorm);
    }

    final rms = math.sqrt(sumSqAll / sampleCount);
    final diffRms = math.sqrt(diffSqAll / sampleCount);

    final targetLevel = _rmsToPerceptualUnit(rms);
    _rawRmsLevel = targetLevel;

    // Approximate zero-crossing / consonant presence for lively outer harmonic bars.
    final hfRatio = rms > 0.0005
        ? (diffRms / (rms * 1.8)).clamp(0.0, 1.0)
        : 0.0;
    _highFreqPresence = _highFreqPresence * 0.65 + hfRatio * 0.35;

    // Fast attack (0.58) so plosives snap immediately, smooth release (0.20).
    final alpha = targetLevel > _smoothedLevel ? 0.58 : 0.20;
    final previousSmoothed = _smoothedLevel;
    _smoothedLevel = (_smoothedLevel + (targetLevel - _smoothedLevel) * alpha)
        .clamp(0.0, 1.0);

    _rebuildBars();

    final now = nowEpochMs ?? DateTime.now().millisecondsSinceEpoch;
    final transientJump = (_smoothedLevel - previousSmoothed).abs() >= 0.055;
    if (transientJump || (now - _lastNotifyEpochMs) >= minNotifyIntervalMs) {
      _lastNotifyEpochMs = now;
      return true;
    }
    return false;
  }

  /// Returns the display level in `[0.0, 1.0]`, blending a gentle simulated
  /// breathing pulse when [isRecording] is true and hardware PCM input is near
  /// silence (e.g., emulators, widget tests, or pauses between thoughts), while
  /// scaling dramatically as soon as real speech arrives.
  double effectiveLevel({
    required bool isRecording,
    required double phaseSeconds,
    double? overrideLevel,
    bool reduceMotion = false,
  }) {
    if (!isRecording) return 0.0;
    final live = (overrideLevel ?? _smoothedLevel).clamp(0.0, 1.0);
    if (reduceMotion) {
      return math.max(live, 0.22);
    }
    // Gentle simulated open-mic breath between 0.08 and 0.19 when silent:
    final breath =
        0.13 +
        0.042 * math.sin(phaseSeconds * 2.7) +
        0.018 * math.sin(phaseSeconds * 5.9 + 0.8);
    // Blend seamlessly: once live >= 0.12, 100% real voice energy drives it.
    final silenceBlend = (1.0 - (live / 0.12)).clamp(0.0, 1.0);
    return (live + breath * silenceBlend * 0.85).clamp(0.0, 1.0);
  }

  /// Returns a 24-element bar profile in `[0.0, 1.0]` combining real rolling
  /// PCM history with a gentle standing-wave fallback when silent.
  List<double> effectiveBars({
    required bool isRecording,
    required double phaseSeconds,
    double? overrideLevel,
    List<double>? overrideBars,
    bool reduceMotion = false,
  }) {
    if (!isRecording) {
      return List<double>.filled(barCount, 0.0);
    }

    final sourceBars = (overrideBars != null && overrideBars.length == barCount)
        ? overrideBars
        : _bars;
    final live = (overrideLevel ?? _smoothedLevel).clamp(0.0, 1.0);

    if (reduceMotion) {
      final base = math.max(live, 0.22);
      return List<double>.generate(barCount, (i) {
        final centerDist = ((i / (barCount - 1)) - 0.5).abs() * 2.0;
        final arch = 1.0 - 0.45 * centerDist * centerDist;
        return (base * arch).clamp(0.08, 1.0);
      });
    }

    final silenceWeight = (1.0 - (live / 0.10)).clamp(0.0, 1.0);
    return List<double>.generate(barCount, (i) {
      final u = i / (barCount - 1);
      final centerEnvelope = math.sin(u * math.pi);
      final simBar =
          (0.10 +
                  0.09 *
                      centerEnvelope *
                      (0.55 +
                          0.45 *
                              math.sin(phaseSeconds * 3.6 + i * 0.52) *
                              math.cos(phaseSeconds * 1.9 - i * 0.27)))
              .clamp(0.05, 0.26);

      final realBar = overrideBars != null
          ? sourceBars[i].clamp(0.0, 1.0)
          : math.max(sourceBars[i], live * (0.45 + 0.55 * centerEnvelope));

      return (realBar * (1.0 - silenceWeight * 0.65) + simBar * silenceWeight)
          .clamp(0.05, 1.0);
    });
  }

  double _rmsToPerceptualUnit(double rms) {
    if (rms <= 1e-6) return 0.0;
    final db = 20.0 * (math.log(rms) / math.ln10);
    final linear = ((db - noiseFloorDb) / (peakDb - noiseFloorDb)).clamp(
      0.0,
      1.0,
    );
    // Slight gamma curve (0.82) boosts conversational speech clarity.
    return math.pow(linear, 0.82).toDouble().clamp(0.0, 1.0);
  }

  void _pushHistorySample(double v) {
    if (_history.length >= barCount) {
      _history.removeFirst();
    }
    _history.addLast(v);
  }

  void _rebuildBars() {
    final histList = _history.toList(growable: false);
    if (histList.isEmpty) return;

    for (var i = 0; i < barCount; i++) {
      // Mirror/sculpt rolling envelope with subtle spectral presence toward edges
      final histIdx = (i * histList.length ~/ barCount).clamp(
        0,
        histList.length - 1,
      );
      final u = i / (barCount - 1);
      final edgeFactor = (u - 0.5).abs() * 2.0;
      final spectralBoost = 1.0 + (_highFreqPresence * 0.28 * edgeFactor);
      final centerLift = 0.78 + 0.22 * math.sin(u * math.pi);
      final target = (histList[histIdx] * spectralBoost * centerLift).clamp(
        0.0,
        1.0,
      );
      _bars[i] = (_bars[i] * 0.32 + target * 0.68).clamp(0.0, 1.0);
    }
  }
}
