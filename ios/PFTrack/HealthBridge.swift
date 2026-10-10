import Foundation
import HealthKit

/// HealthKit facade for PF//TRACK (iOS 17+, async/await). On-device only.
/// Reads (asked per feature, starting with steps + active energy): workouts, sleep, body mass, water, energy.
/// Writes: workouts, sleep, body mass, dietary water, active energy, only after the native opt-in alert
/// (HealthConsent, app-only UserDefaults). Nothing from the web page can enable writes.
final class HealthBridge {
    static let shared = HealthBridge()
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let bodyMass = HKQuantityType(.bodyMass)
    private let water = HKQuantityType(.dietaryWater)
    private let energy = HKQuantityType(.activeEnergyBurned)
    private let sleep = HKCategoryType(.sleepAnalysis)

    /// Read scopes, asked only when a feature needs them. Recovery (the first feature) = steps + active energy.
    enum ReadScope { case recovery, sleep, workouts, body
        var types: Set<HKObjectType> {
            switch self {
            case .recovery: [HKQuantityType(.stepCount), HKQuantityType(.activeEnergyBurned)]
            case .sleep: [HKCategoryType(.sleepAnalysis)]
            case .workouts: [HKObjectType.workoutType()]
            case .body: [HKQuantityType(.bodyMass), HKQuantityType(.dietaryWater)]
            }
        }
    }
    private var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType(), sleep, bodyMass, water, energy] }

    /// Read-only request; never asks for write (share) access.
    func requestRead(_ scope: ReadScope) async throws {
        guard isAvailable else { throw BridgeError.unavailable }
        try await store.requestAuthorization(toShare: [], read: scope.types)
    }

    /// Only called after the native opt-in alert said yes (HealthConsent).
    func requestWriteAuthorization() async throws {
        guard isAvailable else { throw BridgeError.unavailable }
        guard HealthConsent.writesAllowed else { throw BridgeError.notOptedIn }
        try await store.requestAuthorization(toShare: shareTypes, read: [])
    }

    // MARK: Reads

    func summary() async -> [String: Any] {
        guard isAvailable else { return ["ok": false, "error": "unavailable"] }
        // Recovery scope only (steps + active energy). Sleep / workouts / body readers below are used once those
        // features request their own scope via requestRead(_:).
        async let steps = todaySum(.stepCount, .count())
        async let kcal = todaySum(.activeEnergyBurned, .kilocalorie())
        var out: [String: Any] = ["ok": true]
        if let v = await steps { out["steps"] = Int(v) }
        if let v = await kcal { out["activeEnergy"] = Int(v.rounded()) }
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
            case .notOptedIn: "Health writes are off. Allow them in the app's own prompt first."
            }
        }
    }
}
