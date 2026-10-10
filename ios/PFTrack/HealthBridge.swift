import Foundation
import HealthKit

/// HealthKit facade for PF//TRACK (iOS 17+, async/await). On-device only.
/// Reads: workouts, sleep, body mass, dietary water, active energy (+ HR / resting HR / HRV / steps for Recovery).
/// Writes: workouts, sleep, body mass, dietary water, active energy. Every write is refused unless the web UI
/// passes `optIn: true` (set by an explicit toggle in More), and HealthKit's own per-type sharing still applies.
final class HealthBridge {
    static let shared = HealthBridge()
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let bodyMass = HKQuantityType(.bodyMass)
    private let water = HKQuantityType(.dietaryWater)
    private let energy = HKQuantityType(.activeEnergyBurned)
    private let sleep = HKCategoryType(.sleepAnalysis)

    private var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), sleep, bodyMass, water, energy,
         HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate),
         HKQuantityType(.heartRateVariabilitySDNN), HKQuantityType(.stepCount)]
    }
    private var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), sleep, bodyMass, water, energy] }

    func requestAuthorization() async throws {
        guard isAvailable else { throw BridgeError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    // MARK: Reads

    func summary() async -> [String: Any] {
        guard isAvailable else { return ["ok": false, "error": "unavailable"] }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        async let hr = latest(.heartRate, bpm)
        async let rhr = latest(.restingHeartRate, bpm)
        async let hrv = latest(.heartRateVariabilitySDNN, .secondUnit(with: .milli))
        async let mass = latest(.bodyMass, .pound())
        async let steps = todaySum(.stepCount, .count())
        async let kcal = todaySum(.activeEnergyBurned, .kilocalorie())
        async let oz = todaySum(.dietaryWater, .fluidOunceUS())
        async let sleepH = lastNightSleepHours()
        async let workouts = recentWorkouts(days: 7)
        var out: [String: Any] = ["ok": true]
        if let v = await hr { out["heartRate"] = Int(v.rounded()) }
        if let v = await rhr { out["restingHR"] = Int(v.rounded()) }
        if let v = await hrv { out["hrv"] = Int(v.rounded()) }
        if let v = await mass { out["bodyMassLb"] = (v * 10).rounded() / 10 }
        if let v = await steps { out["steps"] = Int(v) }
        if let v = await kcal { out["activeEnergy"] = Int(v.rounded()) }
        if let v = await oz { out["waterOz"] = Int(v.rounded()) }
        if let v = await sleepH { out["sleepHours"] = (v * 100).rounded() / 100 }
        out["workouts"] = await workouts
        return out
    }

    private func latest(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> Double? {
        let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id))],
                                        sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        return try? await d.result(for: store).first?.quantity.doubleValue(for: unit)
    }

    private func todaySum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: .now)
        let pred = HKQuery.predicateForSamples(withStart: start, end: .now)
        let d = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id), predicate: pred),
                                            options: .cumulativeSum)
        return try? await d.result(for: store)?.sumQuantity()?.doubleValue(for: unit)
    }

    /// Asleep time (core + deep + REM + unspecified) between 18:00 yesterday and 14:00 today.
    private func lastNightSleepHours() async -> Double? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let start = cal.date(byAdding: .hour, value: -6, to: today),
              let end = cal.date(byAdding: .hour, value: 14, to: today) else { return nil }
        let pred = HKQuery.predicateForSamples(withStart: start, end: end)
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: sleep, predicate: pred)], sortDescriptors: [])
        guard let samples = try? await d.result(for: store), !samples.isEmpty else { return nil }
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        let secs = samples.filter { asleep.contains($0.value) }.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        return secs > 0 ? secs / 3600 : nil
    }

    private func recentWorkouts(days: Int) async -> [[String: Any]] {
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: .now) else { return [] }
        let d = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: .now))],
                                        sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 20)
        let iso = ISO8601DateFormatter()
        return ((try? await d.result(for: store)) ?? []).map { w in
            ["type": Int(w.workoutActivityType.rawValue), "start": iso.string(from: w.startDate),
             "minutes": Int(w.duration / 60), "source": w.sourceRevision.source.name]
        }
    }

    // MARK: Writes (opt-in only)

    func writeBodyMass(lb: Double, date: Date) async throws {
        guard (50...600).contains(lb) else { throw BridgeError.invalid("weight") }
        try await store.save(HKQuantitySample(type: bodyMass, quantity: HKQuantity(unit: .pound(), doubleValue: lb), start: date, end: date))
    }

    func writeWater(oz: Double, date: Date) async throws {
        guard (1...200).contains(oz) else { throw BridgeError.invalid("water") }
        try await store.save(HKQuantitySample(type: water, quantity: HKQuantity(unit: .fluidOunceUS(), doubleValue: oz), start: date, end: date))
    }

    func writeEnergy(kcal: Double, start: Date, end: Date) async throws {
        guard (1...5000).contains(kcal), end > start else { throw BridgeError.invalid("energy") }
        try await store.save(HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))
    }

    func writeSleep(bed: Date, wake: Date) async throws {
        guard wake > bed, wake.timeIntervalSince(bed) < 16 * 3600 else { throw BridgeError.invalid("sleep") }
        try await store.save(HKCategorySample(type: sleep, value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, start: bed, end: wake))
    }

    /// Strength session from the Lift screen, via HKWorkoutBuilder (HKWorkout initializers are deprecated in iOS 17).
    func writeWorkout(start: Date, end: Date, kcal: Double?) async throws {
        guard end > start else { throw BridgeError.invalid("workout") }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        try await builder.beginCollection(at: start)
        if let kcal, kcal > 0 {
            try await builder.addSamples([HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end)])
        }
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    enum BridgeError: LocalizedError {
        case unavailable, invalid(String), notOptedIn
        var errorDescription: String? {
            switch self {
            case .unavailable: "Health data unavailable on this device"
            case .invalid(let what): "invalid \(what)"
            case .notOptedIn: "Health writes are off. Turn them on in More first."
            }
        }
    }
}
