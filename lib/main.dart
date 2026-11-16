import 'package:flutter/material.dart';

import 'healthkit.dart';
import 'hrv.dart';

void main() => runApp(const MaterialApp(home: HomePage()));

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _loading = false;
  String? _error;
  int? _stepsToday;
  double? _restingHr;
  Duration? _sleepLastNight;
  List<HeartbeatSeries> _series = [];
  List<HealthSample> _appleSdnn = [];

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await HealthKit.requestAuthorization();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final weekAgo = now.subtract(const Duration(days: 7));
      final results = await Future.wait([
        HealthKit.dailySum('steps', today, now),
        HealthKit.quantity('restingHeartRate', weekAgo, now),
        HealthKit.sleep(today.subtract(const Duration(hours: 6)), today.add(const Duration(hours: 12))),
        HealthKit.heartbeatSeries(weekAgo, now),
        HealthKit.quantity('hrvSdnn', weekAgo, now),
      ]);
      final steps = results[0] as List<HealthSample>;
      final resting = results[1] as List<HealthSample>;
      final sleep = results[2] as List<SleepSample>;
      setState(() {
        _stepsToday = steps.isEmpty ? 0 : steps.last.value.round();
        _restingHr = resting.isEmpty ? null : resting.last.value;
        _sleepLastNight = _asleep(sleep);
        _series = (results[3] as List<HeartbeatSeries>).reversed.toList();
        _appleSdnn = results[4] as List<HealthSample>;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Sums asleep stages. Prefers Apple Watch data when several sources logged the same night.
  Duration _asleep(List<SleepSample> samples) {
    final asleep = samples.where((s) => s.isAsleep).toList();
    final watch = asleep.where((s) => s.source.toLowerCase().contains('watch')).toList();
    return (watch.isNotEmpty ? watch : asleep).fold(Duration.zero, (sum, s) => sum + s.duration);
  }

  /// Apple's own SDNN reading for the same recording, if any.
  double? _appleSdnnFor(HeartbeatSeries s) {
    for (final h in _appleSdnn) {
      if (h.start.difference(s.start).inSeconds.abs() < 120) return h.value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sleep = _sleepLastNight;
    return Scaffold(
      appBar: AppBar(title: const Text('HealthKit HRV')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _load,
        icon: const Icon(Icons.favorite),
        label: Text(_loading ? 'Loading…' : 'Read Apple Health'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
          _Tile('Steps today', _stepsToday?.toString()),
          _Tile('Resting heart rate', _restingHr == null ? null : '${_restingHr!.round()} bpm'),
          _Tile('Sleep last night', sleep == null ? null : '${sleep.inHours}h ${sleep.inMinutes % 60}m'),
          const SizedBox(height: 16),
          Text('Beat-to-beat recordings (7 days)', style: Theme.of(context).textTheme.titleMedium),
          if (_series.isEmpty) const Text('None yet. Open Breathe/Mindfulness on Apple Watch to record one.'),
          for (final s in _series) _SeriesTile(s, HrvMetrics.fromRr(s.rr), _appleSdnnFor(s)),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final String label;
  final String? value;
  const _Tile(this.label, this.value);
  @override
  Widget build(BuildContext context) => ListTile(title: Text(label), trailing: Text(value ?? '—'));
}

class _SeriesTile extends StatelessWidget {
  final HeartbeatSeries series;
  final HrvMetrics? m;
  final double? appleSdnn;
  const _SeriesTile(this.series, this.m, this.appleSdnn);

  @override
  Widget build(BuildContext context) {
    final t = series.start;
    final when = '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    final m = this.m;
    return Card(
      child: ListTile(
        title: Text(when),
        subtitle: m == null
            ? const Text('Not enough clean beats')
            : Text('RMSSD ${m.rmssd.toStringAsFixed(1)} ms · SDNN ${m.sdnn.toStringAsFixed(1)} ms'
                '${appleSdnn == null ? '' : ' (Apple ${appleSdnn!.toStringAsFixed(1)})'}\n'
                '${m.beats} beats · ${m.heartRate.round()} bpm · pNN50 ${m.pnn50.toStringAsFixed(0)}%'),
        isThreeLine: m != null,
      ),
    );
  }
}
