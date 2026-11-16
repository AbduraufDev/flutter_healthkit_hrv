import 'dart:math';

/// Time-domain HRV metrics from RR intervals (ms).
class HrvMetrics {
  final int beats;
  final double meanRr, heartRate, sdnn, rmssd, pnn50;

  const HrvMetrics._(this.beats, this.meanRr, this.heartRate, this.sdnn, this.rmssd, this.pnn50);

  /// Drops intervals outside [minRr]..[maxRr] (artifacts / missed beats), then computes
  /// SDNN (sample SD), RMSSD and pNN50. Returns null when fewer than 3 intervals remain.
  static HrvMetrics? fromRr(List<double> rr, {double minRr = 300, double maxRr = 2000}) {
    final x = rr.where((v) => v >= minRr && v <= maxRr).toList();
    if (x.length < 3) return null;

    final mean = x.reduce((a, b) => a + b) / x.length;
    final sdnn = sqrt(x.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / (x.length - 1));
    final diffs = [for (var i = 1; i < x.length; i++) x[i] - x[i - 1]];
    final rmssd = sqrt(diffs.map((d) => d * d).reduce((a, b) => a + b) / diffs.length);
    final pnn50 = diffs.where((d) => d.abs() > 50).length / diffs.length * 100;

    return HrvMetrics._(x.length, mean, 60000 / mean, sdnn, rmssd, pnn50);
  }
}
