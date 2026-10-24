import Foundation
import HealthKit
import SharedModels

/// Heart rate on the watch.
///
/// Outside a workout, watchOS measures heart rate every few minutes and no API changes that. While
/// a workout session runs, the sensor stays on and HealthKit records a reading every few seconds,
/// so "Live heart rate" runs one (activity type `.other`). Costs: battery (hours, not a day), the
/// system's workout indicator, and App Store review may object to a workout that isn't one.
///
/// Readings are read back from HealthKit with an anchored query rather than from the workout
/// builder's statistics, so each one keeps its HealthKit UUID. The iPhone's collector later sees
/// the same samples through Health sync and uploads them under the same ID, which the server
/// de-duplicates.
@MainActor
@Observable
final class LiveHeartRate: NSObject {
    private(set) var latestBpm: Int?
    private(set) var latestAt: Date?
    private(set) var isLive = false
    private(set) var problem: String?

    /// Called with each new reading (at most one per `minimumInterval` while live).
    var onReading: ((TelemetrySample) -> Void)?
    let minimumInterval: TimeInterval = 5

    private let store = HKHealthStore()
    private let heartRate = HKQuantityType(.heartRate)
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var query: HKAnchoredObjectQuery?
    private var lastForwarded = Date.distantPast

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [HKWorkoutType.workoutType()], read: [heartRate])
            return true
        } catch {
            problem = "Health access wasn't granted"
            return false
        }
    }

    /// Shows the most recent reading the watch already has, and keeps listening for new ones.
    func startObserving() {
        guard isAvailable, query == nil else { return }
        let start = Date().addingTimeInterval(-6 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: [])
        let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, added, _, _, _ in
            let readings = (added as? [HKQuantitySample] ?? []).map(Reading.init)
            Task { @MainActor in self?.receive(readings) }
        }
        let q = HKAnchoredObjectQuery(type: heartRate, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        store.execute(q)
        query = q
    }

    func start() async {
        guard !isLive, isAvailable else { return }
        guard await requestAuthorization() else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            self.session = session
            self.builder = builder
            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)
            isLive = true
            problem = nil
            startObserving()
        } catch {
            problem = "Couldn't start live heart rate"
            session = nil
            builder = nil
        }
    }

    /// Ends the session without saving a workout to Fitness. Heart-rate samples already recorded
    /// stay in Health.
    func stop() {
        guard let session else { return }
        session.end()
        builder?.discardWorkout()
        self.session = nil
        builder = nil
        isLive = false
    }

    private func receive(_ readings: [Reading]) {
        for r in readings.sorted(by: { $0.date < $1.date }) {
            if latestAt == nil || r.date >= latestAt! {
                latestBpm = r.bpm
                latestAt = r.date
            }
            guard isLive, r.date.timeIntervalSince(lastForwarded) >= minimumInterval - 0.5 else { continue }
            lastForwarded = r.date
            onReading?(.heartRate(.init(sampleId: r.id, timestamp: r.date, bpm: Double(r.bpm), sourceDevice: "Apple Watch")))
        }
    }

    /// Sendable copy of the parts of a sample we use.
    private struct Reading: Sendable {
        let id: String
        let date: Date
        let bpm: Int
        init(_ s: HKQuantitySample) {
            id = s.uuid.uuidString
            date = s.endDate
            bpm = Int(s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        }
    }
}

extension LiveHeartRate: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        guard toState == .ended || toState == .stopped else { return }
        Task { @MainActor in
            // Ended by the system (e.g. another workout app started).
            if self.session === workoutSession, toState == .ended { self.session = nil; self.builder = nil; self.isLive = false }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.problem = "Live heart rate stopped"
            self.isLive = false
            self.session = nil
            self.builder = nil
        }
    }
}
