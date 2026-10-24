import Foundation
import HealthKit
import MonitoringCore
import SharedModels

/// Reads heart-rate samples from HealthKit. Apple Watch measures heart rate periodically in the
/// background (roughly every few minutes when still; more often during workouts) and syncs them
/// to the iPhone with some delay. We therefore use an anchored query — which returns samples
/// *added* since the last anchor, even if their measurement time is older — instead of a time
/// window, so late-arriving readings are never skipped.
final class HealthKitHeartRateCollector: TelemetryCollector, @unchecked Sendable {
    let name = "healthkit.heartRate"
    private let store = HKHealthStore()
    private let type = HKQuantityType(.heartRate)
    private let anchorKey: String
    private let floorKey: String
    private var observer: HKObserverQuery?

    init(scope: String) {
        anchorKey = "hk.heartRate.anchor.\(scope)"
        floorKey = "hk.heartRate.floor.\(scope)"
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
            return true
        } catch {
            return false
        }
    }

    /// HealthKit does not reveal whether *read* access was granted (privacy), so we can only
    /// tell whether the user has been asked. Data presence is the real signal.
    var hasBeenAsked: Bool { store.authorizationStatus(for: type) != .notDetermined }

    func collect(since: Date, until: Date) async throws -> [TelemetrySample] {
        let anchor = loadAnchor()
        // Never upload the user's Health history from before monitoring started. The floor is fixed
        // on the first run and applied to every query: the result limit pages through samples
        // oldest-first, so filtering only the first page would walk back through years of history.
        let floor = (UserDefaults.standard.object(forKey: floorKey) as? Date) ?? since
        UserDefaults.standard.set(floor, forKey: floorKey)
        let predicate = HKQuery.predicateForSamples(withStart: floor, end: nil, options: [])
        let (samples, newAnchor): ([HKQuantitySample], HKQueryAnchor?) = try await withCheckedThrowingContinuation { cont in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: 2000) { _, added, _, newAnchor, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: ((added as? [HKQuantitySample]) ?? [], newAnchor)) }
            }
            store.execute(query)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let result = samples.filter { $0.endDate > floor }.map { s in
            TelemetrySample.heartRate(.init(sampleId: s.uuid.uuidString, timestamp: s.endDate, bpm: s.quantity.doubleValue(for: unit).rounded(),
                                            sourceDevice: s.sourceRevision.productType?.hasPrefix("Watch") == true ? "Apple Watch" : s.sourceRevision.source.name))
        }
        if let newAnchor { saveAnchor(newAnchor) }
        return result
    }

    /// Asks HealthKit to wake the app when new heart-rate samples arrive. Delivery is best-effort:
    /// iOS may delay or coalesce wakes (observed from minutes to about an hour).
    func enableBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) {
        guard Self.isAvailable, observer == nil else { return }
        let q = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            // HealthKit requires calling completion when done; it's safe to call from any thread.
            let done = CompletionBox(completion)
            Task {
                await onUpdate()
                done.call()
            }
        }
        observer = q
        store.execute(q)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    func stop() {
        if let observer { store.stop(observer) }
        observer = nil
        store.disableAllBackgroundDelivery { _, _ in }
    }

    private func loadAnchor() -> HKQueryAnchor? {
        UserDefaults.standard.data(forKey: anchorKey).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
    }

    private func saveAnchor(_ a: HKQueryAnchor) {
        if let d = try? NSKeyedArchiver.archivedData(withRootObject: a, requiringSecureCoding: true) { UserDefaults.standard.set(d, forKey: anchorKey) }
    }

    func resetAnchor() {
        UserDefaults.standard.removeObject(forKey: anchorKey)
        UserDefaults.standard.removeObject(forKey: floorKey)
    }
}

/// HealthKit's completion handler isn't annotated Sendable but may be called from any thread.
private struct CompletionBox: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
