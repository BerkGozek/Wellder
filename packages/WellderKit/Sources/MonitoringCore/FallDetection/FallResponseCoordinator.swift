import Foundation
import SharedModels

/// "Possible fall detected. Are you okay?" — the confirmation/countdown state machine.
/// Pure and clock-injected so it can be unit-tested; the UI and notifications drive it.
/// Each transition returns the DeviceEvent to enqueue for upload. The backend ALSO runs its own
/// timer from the fallCandidate event, so Betas are notified even if this device dies.
public struct FallResponseCoordinator: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case prompting(candidateEventId: String, deadline: Date)
        case finished(Outcome)
    }

    public enum Outcome: Sendable, Equatable { case userOk, needHelp, noResponse }

    public private(set) var state: State = .idle
    public let simulated: Bool

    public init(simulated: Bool = false) { self.simulated = simulated }

    public var isPrompting: Bool { if case .prompting = state { true } else { false } }

    public func secondsRemaining(now: Date) -> Int? {
        guard case .prompting(_, let deadline) = state else { return nil }
        return max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// Starts a prompt. Ignored while another prompt is active (the backend folds repeats anyway).
    public mutating func begin(confidence: Double, detector: String, countdownSeconds: Int, now: Date) -> DeviceEvent? {
        if isPrompting { return nil }
        let event = DeviceEvent(type: .fallCandidate, detectedAt: now, confidence: confidence, countdownSeconds: countdownSeconds,
                                details: ["detector": .string(detector)], simulated: simulated ? true : nil)
        state = .prompting(candidateEventId: event.eventId, deadline: now.addingTimeInterval(TimeInterval(countdownSeconds)))
        return event
    }

    public mutating func respond(_ outcome: Outcome, now: Date) -> DeviceEvent? {
        guard case .prompting(let id, _) = state else { return nil }
        state = .finished(outcome)
        let type: DeviceEventType = switch outcome {
        case .userOk: .fallUserOk
        case .needHelp: .fallNeedHelp
        case .noResponse: .fallNoResponse
        }
        return DeviceEvent(type: type, detectedAt: now, relatedEventId: id, simulated: simulated ? true : nil)
    }

    /// Call periodically (e.g. each second while the prompt is shown).
    public mutating func tick(now: Date) -> DeviceEvent? {
        guard case .prompting(_, let deadline) = state, now >= deadline else { return nil }
        return respond(.noResponse, now: now)
    }

    public mutating func reset() { state = .idle }
}
