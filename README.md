# flutter_healthkit_hrv

Read **Apple Health** data in Flutter, including **beat-to-beat RR intervals** from Apple Watch, with a ~250-line Swift bridge and no third-party plugins.

Popular plugins such as [`health`](https://pub.dev/packages/health) give you heart rate and Apple's SDNN value, but not the raw RR intervals behind them. Without RR intervals you can't compute RMSSD or pNN50, and you can't run your own artifact filtering. This repo reads them through `HKHeartbeatSeriesQuery` and computes the metrics in Dart.

## What it reads

| Method | Data |
|---|---|
| `HealthKit.heartbeatSeries(start, end)` | RR intervals (ms) per Apple Watch recording |
| `HealthKit.quantity(type, start, end)` | `heartRate`, `restingHeartRate`, `walkingHeartRateAverage`, `hrvSdnn`, `respiratoryRate`, `oxygenSaturation`, `bodyMass`, `vo2Max` |
| `HealthKit.dailySum(type, start, end)` | `steps`, `activeEnergy`, `distance`, `exerciseMinutes`: per-day totals via `HKStatisticsCollectionQuery`, so iPhone + Watch samples are **not double-counted** |
| `HealthKit.sleep(start, end)` | Sleep stages: `inBed`, `awake`, `asleep`, `core`, `deep`, `rem` (iOS 16+ stages) with source name |
| `HealthKit.workouts(start, end)` | Type, duration, kcal, distance |

`HrvMetrics.fromRr(rr)` turns RR intervals into **SDNN, RMSSD, pNN50, mean RR and heart rate**, dropping intervals outside 300–2000 ms.

```dart
await HealthKit.requestAuthorization();
final now = DateTime.now();
final series = await HealthKit.heartbeatSeries(now.subtract(const Duration(days: 7)), now);
for (final s in series) {
  final m = HrvMetrics.fromRr(s.rr);
  print('${s.start}: RMSSD ${m?.rmssd.toStringAsFixed(1)} ms');
}
```

## Use it in your app

Copy three things:

1. `HealthKitBridge` from [`ios/Runner/AppDelegate.swift`](ios/Runner/AppDelegate.swift) plus the 4 lines that register the `healthkit_hrv` channel
2. [`lib/healthkit.dart`](lib/healthkit.dart) and [`lib/hrv.dart`](lib/hrv.dart)
3. iOS setup:
   - Xcode → Runner → *Signing & Capabilities* → **+ HealthKit** (or copy [`Runner.entitlements`](ios/Runner/Runner.entitlements))
   - `NSHealthShareUsageDescription` in `Info.plist`

## Gotchas learned in production

- **Beat-to-beat data only exists when the Watch records it.** That happens during the periodic background HRV readings and during Breathe / Mindfulness sessions. Expect a few recordings per day, each ~1 minute long.
- **The callback gives `timeSinceSeriesStart`, not RR.** RR is the difference between consecutive beats. Skip the first beat after `precededByGap == true`.
- **iOS never reveals whether read access was denied.** A denied type looks exactly like "no data". Design the empty state with that in mind.
- **Don't sum raw step samples.** iPhone and Watch both write them. Use statistics queries (as `dailySum` does).
- **Sleep comes from several sources** (Watch, iPhone, third-party apps), and they overlap. Pick one source per night (the example prefers Apple Watch).
- HealthKit is iPhone-only (not iPad) and needs a real device with data. The simulator has an empty store.

## Run the example

```bash
flutter run   # on a physical iPhone paired with an Apple Watch
```

Requires iOS 15+.

## Tests

```bash
flutter test
```

## License

MIT
