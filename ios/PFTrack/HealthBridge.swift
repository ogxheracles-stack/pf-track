import Foundation
import HealthKit

/// Thin HealthKit facade for PF//TRACK. Privacy-first: on-device only, no Face ID / biometric types.
final class HealthBridge {
    static let shared = HealthBridge()

    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        let ids: [HKQuantityTypeIdentifier] = [
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .activeEnergyBurned,
            .stepCount,
            .bodyMass
        ]
        for id in ids {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            set.insert(sleep)
        }
        return set
    }

    private var writeTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        if let mass = HKObjectType.quantityType(forIdentifier: .bodyMass) {
            set.insert(mass)
        }
        if let workout = HKObjectType.workoutType() as HKSampleType? {
            set.insert(workout)
        }
        return set
    }

    /// Request read (HR, resting HR, HRV, sleep, energy, steps, body mass) + optional write (body mass, workouts).
    func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        guard isAvailable else {
            completion(false, "Health data unavailable on this device")
            return
        }
        store.requestAuthorization(toShare: writeTypes, read: readTypes) { ok, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(ok, nil)
                }
            }
        }
    }

    /// Latest useful recovery summary for the web UI.
    func fetchSummary(completion: @escaping ([String: Any]) -> Void) {
        guard isAvailable else {
            completion(["ok": false, "error": "unavailable"])
            return
        }

        let group = DispatchGroup()
        var out: [String: Any] = ["ok": true, "authorized": true]

        group.enter()
        latestQuantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute())) { v in
            if let v = v { out["heartRate"] = Int(v.rounded()) }
            group.leave()
        }

        group.enter()
        latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute())) { v in
            if let v = v { out["restingHR"] = Int(v.rounded()) }
            group.leave()
        }

        group.enter()
        latestQuantity(.heartRateVariabilitySDNN, unit: HKUnit.secondUnit(with: .milli)) { v in
            if let v = v { out["hrv"] = (v * 10).rounded() / 10 }
            group.leave()
        }

        group.enter()
        latestQuantity(.bodyMass, unit: HKUnit.pound()) { v in
            if let v = v { out["bodyMassLb"] = (v * 10).rounded() / 10 }
            group.leave()
        }

        group.enter()
        todaySum(.stepCount, unit: HKUnit.count()) { v in
            if let v = v { out["steps"] = Int(v.rounded()) }
            group.leave()
        }

        group.enter()
        todaySum(.activeEnergyBurned, unit: HKUnit.kilocalorie()) { v in
            if let v = v { out["activeEnergy"] = Int(v.rounded()) }
            group.leave()
        }

        group.enter()
        lastNightSleepHours { hrs in
            if let hrs = hrs { out["sleepHours"] = (hrs * 10).rounded() / 10 }
            group.leave()
        }

        group.notify(queue: .main) {
            completion(out)
        }
    }

    /// Write scale weight (lb) into HealthKit bodyMass.
    func writeWeight(lb: Double, date: Date = Date(), completion: @escaping (Bool, String?) -> Void) {
        guard isAvailable else {
            completion(false, "unavailable")
            return
        }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            completion(false, "bodyMass type missing")
            return
        }
        let qty = HKQuantity(unit: HKUnit.pound(), doubleValue: lb)
        let sample = HKQuantitySample(type: type, quantity: qty, start: date, end: date)
        store.save(sample) { ok, error in
            DispatchQueue.main.async {
                completion(ok, error?.localizedDescription)
            }
        }
    }

    // MARK: - Queries

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit, done: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            done(nil)
            return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
            let v = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
            done(v)
        }
        store.execute(q)
    }

    private func todaySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, done: @escaping (Double?) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            done(nil)
            return
        }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let pred = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
            let v = stats?.sumQuantity()?.doubleValue(for: unit)
            done(v)
        }
        store.execute(q)
    }

    private func lastNightSleepHours(done: @escaping (Double?) -> Void) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            done(nil)
            return
        }
        let cal = Calendar.current
        let now = Date()
        // Window: yesterday 18:00 → today 14:00 (covers typical overnight)
        guard let yStart = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)),
              let from = cal.date(bySettingHour: 18, minute: 0, second: 0, of: yStart),
              let to = cal.date(bySettingHour: 14, minute: 0, second: 0, of: cal.startOfDay(for: now)) else {
            done(nil)
            return
        }
        let pred = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let q = HKSampleQuery(sampleType: sleepType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                done(nil)
                return
            }
            var seconds: TimeInterval = 0
            // Raw asleep values: legacy asleep=1; iOS16+ unspecified/core/deep/REM = 2...5. Skip inBed=0, awake=6+.
            let asleepValues: Set<Int> = [1, 2, 3, 4, 5]
            for s in samples {
                if asleepValues.contains(s.value) {
                    seconds += s.endDate.timeIntervalSince(s.startDate)
                }
            }
            if seconds <= 0 {
                done(nil)
            } else {
                done(seconds / 3600.0)
            }
        }
        store.execute(q)
    }
}
