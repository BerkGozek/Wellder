import Foundation

/// One motion reading in units of g. `acceleration` is total acceleration (gravity + user
/// acceleration, as from CMDeviceMotion), `gravity` the gravity direction estimate.
public struct MotionSample: Sendable, Equatable {
    public var timestamp: TimeInterval // seconds, monotonic
    public var acceleration: SIMD3<Double>
    public var gravity: SIMD3<Double>

    public init(timestamp: TimeInterval, acceleration: SIMD3<Double>, gravity: SIMD3<Double>) {
        self.timestamp = timestamp
        self.acceleration = acceleration
        self.gravity = gravity
    }

    public var magnitude: Double { (acceleration * acceleration).sum().squareRoot() }
}

public struct FallCandidate: Sendable, Equatable {
    public var impactTime: TimeInterval
    public var peakG: Double
    public var freeFallSeconds: Double
    public var orientationChangeDegrees: Double
    public var stillAfterImpact: Bool
    /// Heuristic 0…1 score — NOT a validated probability.
    public var confidence: Double
}

/// EXPERIMENTAL threshold-based fall detector (free-fall → impact → orientation change →
/// stillness), in the style of published accelerometer heuristics. It has not been clinically
/// validated, produces false positives (e.g. a dropped phone) and misses falls (e.g. slow slides).
/// Every candidate therefore goes through the "Are you okay?" confirmation step before anyone is
/// notified. See docs/feasibility.md#fall-detection.
public final class FallDetector {
    public struct Configuration: Sendable {
        public var freeFallThresholdG = 0.5
        public var minFreeFallSeconds = 0.06
        public var impactThresholdG = 2.5
        public var hardImpactThresholdG = 4.0
        public var impactWindowAfterFreeFall = 1.0
        public var postImpactSettleSeconds = 1.5
        public var postImpactWindowSeconds = 4.0
        public var stillnessStdDevG = 0.08
        public var orientationChangeDegrees = 45.0
        public var candidateThreshold = 0.6
        public var refractorySeconds = 30.0
        public init() {}

        /// Apple Watch on the wrist (EXPERIMENTAL, untuned against real falls). A wrist sees sharp
        /// spikes from everyday gestures (clapping, knocking on a table), so it needs a harder
        /// impact, a longer look afterwards, and more evidence — stillness or a lasting
        /// orientation change on top of the impact — before asking "Are you okay?".
        public static var wrist: Configuration {
            var c = Configuration()
            c.impactThresholdG = 3.0
            c.hardImpactThresholdG = 5.0
            c.postImpactWindowSeconds = 5.0
            c.stillnessStdDevG = 0.1
            c.candidateThreshold = 0.7
            c.refractorySeconds = 60
            return c
        }
    }

    public let config: Configuration
    private var buffer: [MotionSample] = []
    private var freeFallStart: TimeInterval?
    private var lastFreeFall: (start: TimeInterval, end: TimeInterval)?
    private var pendingImpact: (time: TimeInterval, peak: Double, freeFall: Double, preGravity: SIMD3<Double>)?
    private var refractoryUntil: TimeInterval = -.infinity

    public init(config: Configuration = Configuration()) { self.config = config }

    /// Feed samples in timestamp order. Returns a candidate once the post-impact window has been observed.
    public func process(_ s: MotionSample) -> FallCandidate? {
        buffer.append(s)
        let horizon = s.timestamp - 12
        if let firstKeep = buffer.firstIndex(where: { $0.timestamp >= horizon }), firstKeep > 0 { buffer.removeFirst(firstKeep) }

        let g = s.magnitude
        // Free-fall tracking
        if g < config.freeFallThresholdG {
            if freeFallStart == nil { freeFallStart = s.timestamp }
        } else if let start = freeFallStart {
            if s.timestamp - start >= config.minFreeFallSeconds { lastFreeFall = (start, s.timestamp) }
            freeFallStart = nil
        }

        if let p = pendingImpact {
            // Track the true peak of the impact spike.
            if s.timestamp - p.time < 0.2 && g > p.peak { pendingImpact?.peak = g }
            if s.timestamp >= p.time + config.postImpactSettleSeconds + config.postImpactWindowSeconds {
                pendingImpact = nil
                return evaluate(impactTime: p.time, peak: p.peak, freeFall: p.freeFall, preGravity: p.preGravity)
            }
            return nil
        }

        guard s.timestamp >= refractoryUntil, g >= config.impactThresholdG else { return nil }
        var freeFall = 0.0
        if let ff = lastFreeFall, s.timestamp - ff.end <= config.impactWindowAfterFreeFall { freeFall = ff.end - ff.start }
        let preStart = (lastFreeFall?.start ?? s.timestamp) - 1.0
        let pre = buffer.filter { $0.timestamp >= preStart && $0.timestamp < preStart + 1.0 }
        pendingImpact = (s.timestamp, g, freeFall, Self.mean(pre.map(\.gravity)) ?? s.gravity)
        return nil
    }

    private func evaluate(impactTime: TimeInterval, peak: Double, freeFall: Double, preGravity: SIMD3<Double>) -> FallCandidate? {
        let windowStart = impactTime + config.postImpactSettleSeconds
        let post = buffer.filter { $0.timestamp >= windowStart && $0.timestamp <= windowStart + config.postImpactWindowSeconds }
        guard !post.isEmpty, let postGravity = Self.mean(post.map(\.gravity)) else { return nil }
        let mags = post.map(\.magnitude)
        let mean = mags.reduce(0, +) / Double(mags.count)
        let std = (mags.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mags.count)).squareRoot()
        let still = std < config.stillnessStdDevG
        let angle = Self.angleDegrees(preGravity, postGravity)

        var confidence = 0.3
        if freeFall > 0 { confidence += 0.2 }
        if angle >= config.orientationChangeDegrees { confidence += 0.25 }
        if still { confidence += 0.25 }
        if peak >= config.hardImpactThresholdG { confidence += 0.1 }
        confidence = min(confidence, 1)
        let qualifies = confidence >= config.candidateThreshold && (still || angle >= config.orientationChangeDegrees)
        guard qualifies else { return nil }
        refractoryUntil = impactTime + config.refractorySeconds
        return FallCandidate(impactTime: impactTime, peakG: peak, freeFallSeconds: freeFall, orientationChangeDegrees: angle,
                             stillAfterImpact: still, confidence: confidence)
    }

    static func mean(_ v: [SIMD3<Double>]) -> SIMD3<Double>? {
        guard !v.isEmpty else { return nil }
        return v.reduce(SIMD3<Double>(repeating: 0), +) / Double(v.count)
    }

    static func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let la = (a * a).sum().squareRoot(), lb = (b * b).sum().squareRoot()
        guard la > 0, lb > 0 else { return 0 }
        let cos = max(-1, min(1, (a * b).sum() / (la * lb)))
        return acos(cos) * 180 / .pi
    }
}
