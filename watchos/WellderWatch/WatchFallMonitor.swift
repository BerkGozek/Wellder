import CoreMotion
import Foundation
import MonitoringCore

/// EXPERIMENTAL wrist fall detection: 50 Hz device motion into `FallDetector` with the `.wrist`
/// configuration. watchOS only delivers motion while the app runs, so this works while the app is
/// open or while Live heart rate's workout session keeps it running with the wrist down. It is not
/// Apple's Fall Detection (that needs Apple's entitlement) and hasn't been validated on real falls.
@MainActor
final class WatchFallMonitor {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    var onCandidate: ((FallCandidate) -> Void)?

    var isRunning: Bool { manager.isDeviceMotionActive }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: queue, withHandler: Self.motionHandler(detector: FallDetector(config: .wrist)) { [weak self] candidate in
            Task { @MainActor in self?.onCandidate?(candidate) }
        })
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Built outside the main actor: CoreMotion calls it on `queue`, and a closure written inside
    /// this @MainActor class would inherit main-actor isolation and trip Swift 6's runtime check
    /// (the iPhone version crashed this way). The detector is only touched from the serial queue.
    private nonisolated static func motionHandler(detector: FallDetector, onCandidate: @escaping @Sendable (FallCandidate) -> Void) -> CMDeviceMotionHandler {
        { motion, _ in
            guard let motion else { return }
            let g = motion.gravity, u = motion.userAcceleration
            let sample = MotionSample(timestamp: motion.timestamp, acceleration: SIMD3(g.x + u.x, g.y + u.y, g.z + u.z), gravity: SIMD3(g.x, g.y, g.z))
            if let candidate = detector.process(sample) { onCandidate(candidate) }
        }
    }
}
