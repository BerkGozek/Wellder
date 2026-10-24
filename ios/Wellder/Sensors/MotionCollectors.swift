import CoreMotion
import Foundation
import MonitoringCore
import SharedModels

/// Activity classification history from the motion coprocessor. iOS records it continuously
/// (when Motion & Fitness is enabled) and keeps about 7 days, so it can be read retrospectively
/// on any wake — no continuous sensor sampling by this app.
struct MotionActivityCollector: TelemetryCollector {
    let name = "coremotion.activity"
    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }
    static var authorization: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

    func collect(since: Date, until: Date) async throws -> [TelemetrySample] {
        guard Self.isAvailable else { return [] }
        let manager = CMMotionActivityManager()
        // Convert to Sendable values inside the callback, before crossing back to the caller.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TelemetrySample], Error>) in
            manager.queryActivityStarting(from: since, to: until, to: OperationQueue()) { result, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (result ?? []).filter { $0.startDate > since }.map(Self.sample))
            }
        }
    }

    private static func sample(_ a: CMMotionActivity) -> TelemetrySample {
        let type: ActivityType = a.running ? .running : a.cycling ? .cycling : a.walking ? .walking : a.automotive ? .automotive : a.stationary ? .stationary : .unknown
        let confidence: Confidence = switch a.confidence {
        case .high: .high
        case .medium: .medium
        default: .low
        }
        return .activity(.init(sampleId: "act-\(Int(a.startDate.timeIntervalSince1970))-\(type.rawValue)", timestamp: a.startDate,
                               activityType: type, confidence: confidence))
    }
}

/// Step counts in 30-minute buckets from the pedometer history (also ~7 days retained).
struct PedometerCollector: TelemetryCollector {
    let name = "coremotion.steps"
    static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }
    private let bucket: TimeInterval = 30 * 60

    func collect(since: Date, until: Date) async throws -> [TelemetrySample] {
        guard Self.isAvailable else { return [] }
        let pedometer = CMPedometer()
        var out: [TelemetrySample] = []
        // Align to bucket boundaries so re-collection produces the same sample IDs.
        var start = Date(timeIntervalSince1970: (since.timeIntervalSince1970 / bucket).rounded(.down) * bucket)
        while start < until && out.count < 400 {
            let end = min(start.addingTimeInterval(bucket), until)
            let steps: Int? = try await withCheckedThrowingContinuation { cont in
                pedometer.queryPedometerData(from: start, to: end) { d, error in
                    if let error = error as NSError?, error.code != Int(CMErrorNotAvailable.rawValue) { cont.resume(throwing: error) } else { cont.resume(returning: d?.numberOfSteps.intValue) }
                }
            }
            if let steps, steps > 0 {
                // A partial bucket is re-sent later with the full count under the same ID (server overwrites).
                out.append(.steps(.init(sampleId: "steps-\(Int(start.timeIntervalSince1970))", timestamp: start, endTimestamp: end, count: steps)))
            }
            start = start.addingTimeInterval(bucket)
        }
        return out
    }
}

/// Feeds 50 Hz device motion into the EXPERIMENTAL FallDetector. iOS only delivers device motion
/// while the app is running in the foreground, so this works only while Wellder is open — it is
/// not background fall detection. (Apple Watch system Fall Detection is the background path.)
@MainActor
final class DeviceMotionFallMonitor {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    var onCandidate: ((FallCandidate) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isRunning: Bool { manager.isDeviceMotionActive }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: queue, withHandler: Self.motionHandler(detector: FallDetector()) { [weak self] candidate in
            Task { @MainActor in self?.onCandidate?(candidate) }
        })
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Built outside the main actor on purpose: CoreMotion calls the handler on `queue`, and a
    /// closure written inside this @MainActor class would inherit main-actor isolation, which
    /// Swift 6 checks at runtime (crashed with dispatch_assert_queue_fail on a real iPhone). The
    /// detector is only touched from the serial `queue`.
    private nonisolated static func motionHandler(detector: FallDetector, onCandidate: @escaping @Sendable (FallCandidate) -> Void) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            let g = motion.gravity, u = motion.userAcceleration
            let sample = MotionSample(timestamp: motion.timestamp, acceleration: SIMD3(g.x + u.x, g.y + u.y, g.z + u.z), gravity: SIMD3(g.x, g.y, g.z))
            if let candidate = detector.process(sample) { onCandidate(candidate) }
        }
    }
}
