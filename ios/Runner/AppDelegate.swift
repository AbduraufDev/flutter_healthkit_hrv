import Flutter
import HealthKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let healthKit = HealthKitBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let registrar = self.registrar(forPlugin: "HealthKitBridge")!
    let channel = FlutterMethodChannel(name: "healthkit_hrv", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      self?.healthKit.handle(call, result: result)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// Thin HealthKit -> Flutter bridge. Every date crosses the channel as epoch milliseconds.
final class HealthKitBridge {
  private let store = HKHealthStore()
  private let sortAsc = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

  private static let bpm = HKUnit.count().unitDivided(by: .minute())

  /// Point-in-time samples. Name -> (HealthKit type, unit returned to Dart).
  private let quantities: [String: (HKQuantityTypeIdentifier, HKUnit)] = [
    "heartRate": (.heartRate, bpm),
    "restingHeartRate": (.restingHeartRate, bpm),
    "walkingHeartRateAverage": (.walkingHeartRateAverage, bpm),
    "hrvSdnn": (.heartRateVariabilitySDNN, .secondUnit(with: .milli)),
    "respiratoryRate": (.respiratoryRate, bpm),
    "oxygenSaturation": (.oxygenSaturation, .percent()),
    "bodyMass": (.bodyMass, .gramUnit(with: .kilo)),
    "vo2Max": (.vo2Max, HKUnit(from: "ml/kg*min")),
  ]

  /// Cumulative types. Summed with HKStatistics so iPhone + Watch samples are not double counted.
  private let cumulative: [String: (HKQuantityTypeIdentifier, HKUnit)] = [
    "steps": (.stepCount, .count()),
    "activeEnergy": (.activeEnergyBurned, .kilocalorie()),
    "distance": (.distanceWalkingRunning, .meter()),
    "exerciseMinutes": (.appleExerciseTime, .minute()),
  ]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      return result(FlutterError(code: "UNAVAILABLE", message: "HealthKit is not available on this device", details: nil))
    }
    let args = call.arguments as? [String: Any] ?? [:]
    let start = date(args["start"]) ?? Calendar.current.startOfDay(for: Date())
    let end = date(args["end"]) ?? Date()
    let type = args["type"] as? String ?? ""

    switch call.method {
    case "requestAuthorization":
      requestAuthorization(result)
    case "getHeartbeatSeries":
      heartbeatSeries(start, end, result)
    case "getQuantity":
      guard let (id, unit) = quantities[type] else { return result(badType(type)) }
      quantity(id, unit, start, end, result)
    case "getDailySum":
      guard let (id, unit) = cumulative[type] else { return result(badType(type)) }
      dailySum(id, unit, start, end, result)
    case "getSleep":
      sleep(start, end, result)
    case "getWorkouts":
      workouts(start, end, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Authorization

  private func requestAuthorization(_ result: @escaping FlutterResult) {
    var read = Set<HKObjectType>()
    for (id, _) in quantities.values { read.insert(HKQuantityType.quantityType(forIdentifier: id)!) }
    for (id, _) in cumulative.values { read.insert(HKQuantityType.quantityType(forIdentifier: id)!) }
    read.insert(HKSeriesType.heartbeat())
    read.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
    read.insert(HKObjectType.workoutType())
    // HealthKit never tells an app whether *read* access was granted; `success` only means the sheet was shown.
    store.requestAuthorization(toShare: nil, read: read) { success, error in
      DispatchQueue.main.async { error != nil ? result(self.flutterError(error!)) : result(success) }
    }
  }

  // MARK: - Beat-to-beat (RR intervals)

  /// Apple Watch records a heartbeat series alongside each HRV (SDNN) reading.
  /// Returns one entry per series with RR intervals in ms. Intervals that follow a gap are dropped.
  private func heartbeatSeries(_ start: Date, _ end: Date, _ result: @escaping FlutterResult) {
    let query = HKSampleQuery(sampleType: HKSeriesType.heartbeat(), predicate: predicate(start, end),
                              limit: HKObjectQueryNoLimit, sortDescriptors: sortAsc) { _, samples, error in
      if let error = error { return self.reply(result, self.flutterError(error)) }
      let series = samples as? [HKHeartbeatSeriesSample] ?? []
      var out = [[String: Any]?](repeating: nil, count: series.count)
      let lock = NSLock()
      let group = DispatchGroup()

      for (i, sample) in series.enumerated() {
        group.enter()
        var rr: [Double] = []
        var previous: TimeInterval?
        let beats = HKHeartbeatSeriesQuery(heartbeatSeries: sample) { _, sinceStart, precededByGap, done, error in
          if error == nil {
            // sinceStart is the beat's offset from the series start, so RR = difference of consecutive offsets.
            if let p = previous, !precededByGap { rr.append((sinceStart - p) * 1000) }
            previous = sinceStart
          }
          guard done || error != nil else { return }
          lock.lock()
          out[i] = ["start": self.ms(sample.startDate), "end": self.ms(sample.endDate), "rr": rr]
          lock.unlock()
          group.leave()
        }
        self.store.execute(beats)
      }
      group.notify(queue: .main) { result(out.compactMap { $0 }) }
    }
    store.execute(query)
  }

  // MARK: - Quantities

  private func quantity(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date,
                        _ result: @escaping FlutterResult) {
    let query = HKSampleQuery(sampleType: HKQuantityType.quantityType(forIdentifier: id)!,
                              predicate: predicate(start, end), limit: HKObjectQueryNoLimit,
                              sortDescriptors: sortAsc) { _, samples, error in
      if let error = error { return self.reply(result, self.flutterError(error)) }
      let rows = (samples as? [HKQuantitySample] ?? []).map {
        ["start": self.ms($0.startDate), "end": self.ms($0.endDate), "value": $0.quantity.doubleValue(for: unit)]
      }
      self.reply(result, rows)
    }
    store.execute(query)
  }

  private func dailySum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ start: Date, _ end: Date,
                        _ result: @escaping FlutterResult) {
    let calendar = Calendar.current
    let anchor = calendar.startOfDay(for: start)
    let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType.quantityType(forIdentifier: id)!,
                                            quantitySamplePredicate: predicate(anchor, end),
                                            options: .cumulativeSum, anchorDate: anchor,
                                            intervalComponents: DateComponents(day: 1))
    query.initialResultsHandler = { _, collection, error in
      if let error = error { return self.reply(result, self.flutterError(error)) }
      var rows: [[String: Any]] = []
      collection?.enumerateStatistics(from: anchor, to: end) { stats, _ in
        rows.append(["start": self.ms(stats.startDate), "end": self.ms(stats.endDate),
                     "value": stats.sumQuantity()?.doubleValue(for: unit) ?? 0])
      }
      self.reply(result, rows)
    }
    store.execute(query)
  }

  // MARK: - Sleep

  private func sleep(_ start: Date, _ end: Date, _ result: @escaping FlutterResult) {
    let query = HKSampleQuery(sampleType: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
                              predicate: predicate(start, end), limit: HKObjectQueryNoLimit,
                              sortDescriptors: sortAsc) { _, samples, error in
      if let error = error { return self.reply(result, self.flutterError(error)) }
      let rows = (samples as? [HKCategorySample] ?? []).map {
        ["start": self.ms($0.startDate), "end": self.ms($0.endDate), "stage": self.sleepStage($0.value),
         "source": $0.sourceRevision.source.name]
      }
      self.reply(result, rows)
    }
    store.execute(query)
  }

  private func sleepStage(_ value: Int) -> String {
    if #available(iOS 16.0, *) {
      switch HKCategoryValueSleepAnalysis(rawValue: value) {
      case .asleepCore: return "core"
      case .asleepDeep: return "deep"
      case .asleepREM: return "rem"
      case .asleepUnspecified: return "asleep"
      default: break
      }
    }
    switch HKCategoryValueSleepAnalysis(rawValue: value) {
    case .inBed: return "inBed"
    case .awake: return "awake"
    case .asleep: return "asleep"  // pre-iOS 16 value, same raw value as asleepUnspecified
    default: return "unknown"
    }
  }

  // MARK: - Workouts

  private func workouts(_ start: Date, _ end: Date, _ result: @escaping FlutterResult) {
    let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate(start, end),
                              limit: HKObjectQueryNoLimit, sortDescriptors: sortAsc) { _, samples, error in
      if let error = error { return self.reply(result, self.flutterError(error)) }
      let rows: [[String: Any]] = (samples as? [HKWorkout] ?? []).map {
        var row: [String: Any] = ["start": self.ms($0.startDate), "end": self.ms($0.endDate),
                                  "activityType": Int($0.workoutActivityType.rawValue),
                                  "durationMinutes": $0.duration / 60]
        if let kcal = $0.totalEnergyBurned?.doubleValue(for: .kilocalorie()) { row["kcal"] = kcal }
        if let meters = $0.totalDistance?.doubleValue(for: .meter()) { row["distanceMeters"] = meters }
        return row
      }
      self.reply(result, rows)
    }
    store.execute(query)
  }

  // MARK: - Helpers

  private func predicate(_ start: Date, _ end: Date) -> NSPredicate {
    HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
  }

  private func date(_ value: Any?) -> Date? {
    (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
  }

  private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

  private func reply(_ result: @escaping FlutterResult, _ value: Any) {
    DispatchQueue.main.async { result(value) }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    FlutterError(code: "HEALTHKIT", message: error.localizedDescription, details: nil)
  }

  private func badType(_ type: String) -> FlutterError {
    FlutterError(code: "BAD_TYPE", message: "Unsupported type: \(type)", details: nil)
  }
}
