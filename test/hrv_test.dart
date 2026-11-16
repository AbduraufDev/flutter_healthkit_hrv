import 'package:flutter_healthkit_hrv/hrv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('computes SDNN, RMSSD, pNN50 and heart rate', () {
    final m = HrvMetrics.fromRr([800, 810, 790, 850, 800])!;
    expect(m.beats, 5);
    expect(m.meanRr, 810);
    expect(m.heartRate, closeTo(74.07, 0.01));
    expect(m.sdnn, closeTo(23.452, 0.001)); // sqrt(2200 / 4)
    expect(m.rmssd, closeTo(40.620, 0.001)); // sqrt(6600 / 4)
    expect(m.pnn50, 25); // only |60| > 50; |-50| is not
  });

  test('drops artifacts outside the physiological range', () {
    final m = HrvMetrics.fromRr([800, 150, 810, 2600, 790])!;
    expect(m.beats, 3);
    expect(m.meanRr, 800);
  });

  test('returns null with too few intervals', () {
    expect(HrvMetrics.fromRr([800, 810]), isNull);
    expect(HrvMetrics.fromRr([]), isNull);
  });
}
