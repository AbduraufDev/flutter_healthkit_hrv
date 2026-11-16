import 'package:flutter/services.dart';

/// Dart side of the HealthKit bridge in `ios/Runner/AppDelegate.swift`.
/// Every call throws a [PlatformException] when HealthKit is unavailable or a query fails.
class HealthKit {
  static const _channel = MethodChannel('healthkit_hrv');

  /// Shows the Apple Health permission sheet. `true` only means the sheet was shown:
  /// iOS never tells an app whether read access was granted (denied reads just return no data).
  static Future<bool> requestAuthorization() async =>
      await _channel.invokeMethod<bool>('requestAuthorization') ?? false;

  /// Beat-to-beat RR intervals recorded by Apple Watch, one entry per recording.
  static Future<List<HeartbeatSeries>> heartbeatSeries(DateTime start, DateTime end) async =>
      (await _list('getHeartbeatSeries', start, end)).map(HeartbeatSeries.fromMap).toList();

  /// Point samples. [type]: heartRate, restingHeartRate, walkingHeartRateAverage, hrvSdnn,
  /// respiratoryRate, oxygenSaturation, bodyMass, vo2Max.
  static Future<List<HealthSample>> quantity(String type, DateTime start, DateTime end) async =>
      (await _list('getQuantity', start, end, type)).map(HealthSample.fromMap).toList();

  /// Per-day totals. [type]: steps, activeEnergy, distance, exerciseMinutes.
  static Future<List<HealthSample>> dailySum(String type, DateTime start, DateTime end) async =>
      (await _list('getDailySum', start, end, type)).map(HealthSample.fromMap).toList();

  static Future<List<SleepSample>> sleep(DateTime start, DateTime end) async =>
      (await _list('getSleep', start, end)).map(SleepSample.fromMap).toList();

  static Future<List<Workout>> workouts(DateTime start, DateTime end) async =>
      (await _list('getWorkouts', start, end)).map(Workout.fromMap).toList();

  static Future<List<Map>> _list(String method, DateTime start, DateTime end, [String? type]) async {
    final rows = await _channel.invokeListMethod<Map>(method, {
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'type': ?type,
    });
    return rows ?? const [];
  }
}

DateTime _date(Object? ms) => DateTime.fromMillisecondsSinceEpoch((ms as num).round());

class HealthSample {
  final DateTime start, end;
  final double value;
  HealthSample(this.start, this.end, this.value);
  factory HealthSample.fromMap(Map m) =>
      HealthSample(_date(m['start']), _date(m['end']), (m['value'] as num).toDouble());
}

class HeartbeatSeries {
  final DateTime start, end;

  /// RR intervals in milliseconds.
  final List<double> rr;
  HeartbeatSeries(this.start, this.end, this.rr);
  factory HeartbeatSeries.fromMap(Map m) => HeartbeatSeries(
      _date(m['start']), _date(m['end']), [for (final v in m['rr'] as List) (v as num).toDouble()]);
}

class SleepSample {
  final DateTime start, end;

  /// inBed, awake, asleep, core, deep, rem, unknown.
  final String stage;
  final String source;
  SleepSample(this.start, this.end, this.stage, this.source);
  factory SleepSample.fromMap(Map m) =>
      SleepSample(_date(m['start']), _date(m['end']), m['stage'] as String, m['source'] as String);

  Duration get duration => end.difference(start);
  bool get isAsleep => const {'asleep', 'core', 'deep', 'rem'}.contains(stage);
}

class Workout {
  final DateTime start, end;

  /// Raw `HKWorkoutActivityType` value (e.g. 37 = running, 52 = walking).
  final int activityType;
  final double durationMinutes;
  final double? kcal, distanceMeters;
  Workout(this.start, this.end, this.activityType, this.durationMinutes, this.kcal, this.distanceMeters);
  factory Workout.fromMap(Map m) => Workout(
        _date(m['start']),
        _date(m['end']),
        m['activityType'] as int,
        (m['durationMinutes'] as num).toDouble(),
        (m['kcal'] as num?)?.toDouble(),
        (m['distanceMeters'] as num?)?.toDouble(),
      );
}
