import Foundation

/// Deterministic synthetic accelerometer traces for testing and the in-app simulator.
/// These are idealised shapes, not recordings of real falls; they exercise the pipeline, they do
/// not validate it.
public enum SyntheticMotion {
    public enum Scenario: String, CaseIterable, Sendable, Identifiable {
        case fall, walking, sitDownHard, phoneDropped, standingStill
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .fall: "Fall (free-fall, impact, lying still)"
            case .walking: "Normal walking"
            case .sitDownHard: "Sitting down heavily"
            case .phoneDropped: "Phone dropped on floor"
            case .standingStill: "Standing still"
            }
        }
    }

    /// Simple seeded generator (SplitMix64) so traces are reproducible.
    struct RNG {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z) / Double(UInt64.max) * 2 - 1
        }
    }

    public static func trace(_ scenario: Scenario, hz: Double = 50, seed: UInt64 = 42) -> [MotionSample] {
        var rng = RNG(state: seed)
        let dt = 1 / hz
        var t = 0.0
        var out: [MotionSample] = []
        let upright = SIMD3<Double>(0, -1, 0)
        let lying = SIMD3<Double>(0, 0, -1)
        func emit(_ seconds: Double, _ f: (Double) -> (SIMD3<Double>, SIMD3<Double>)) {
            let n = Int(seconds * hz)
            for i in 0..<n {
                let (a, g) = f(Double(i) * dt)
                out.append(MotionSample(timestamp: t, acceleration: a, gravity: g))
                t += dt
            }
        }
        func noise(_ amp: Double) -> SIMD3<Double> { SIMD3(rng.next() * amp, rng.next() * amp, rng.next() * amp) }

        switch scenario {
        case .standingStill:
            emit(10) { _ in (upright + noise(0.01), upright) }
        case .walking:
            emit(12) { s in
                let bounce = 0.25 * sin(2 * .pi * 2 * s)
                return (upright * (1 + bounce) + noise(0.05), upright)
            }
        case .fall:
            emit(2) { _ in (upright + noise(0.02), upright) }
            emit(0.35) { _ in (upright * 0.15 + noise(0.05), upright) }       // free fall
            emit(0.06) { _ in (SIMD3(0, 0, -3.6) + noise(0.2), lying) }     // impact
            emit(0.4) { s in (lying * (1 + 0.6 * cos(20 * s)) + noise(0.1), lying) } // rebound
            emit(7) { _ in (lying + noise(0.01), lying) }                    // lying still
        case .sitDownHard:
            let tilted = SIMD3<Double>(0, -0.94, -0.34)                      // ~20° lean back
            emit(2) { _ in (upright + noise(0.02), upright) }
            emit(0.08) { _ in (upright * 0.45 + noise(0.03), upright) }
            emit(0.06) { _ in (tilted * 1.9 + noise(0.1), tilted) }          // below impact threshold
            emit(7) { s in (tilted + noise(0.03) + SIMD3(0, 0.05 * sin(s), 0), tilted) }
        case .phoneDropped:
            let flat = SIMD3<Double>(0, 0, -1)
            emit(2) { _ in (upright + noise(0.05), upright) }
            emit(0.45) { _ in (noise(0.03), upright) }                       // free fall
            emit(0.04) { _ in (SIMD3(0, 0, -6.5) + noise(0.3), flat) }
            emit(7) { _ in (flat + noise(0.005), flat) }
        }
        return out
    }
}
