import Foundation
import SharedModels

/// A pull-based source of telemetry (HealthKit anchored queries, Core Motion activity history,
/// pedometer history, simulation). Real implementations live in the app targets because they
/// depend on iOS-only frameworks; tests and Simulation Mode use the implementations here.
public protocol TelemetryCollector: Sendable {
    var name: String { get }
    /// Samples measured in the half-open window (since, until].
    func collect(since: Date, until: Date) async throws -> [TelemetrySample]
}

/// Push-based location source (Core Location delegate in the app, simulator here).
public enum LocationMode: String, Sendable, Codable {
    /// Standard updates with a distance filter, paused automatically by iOS when stationary.
    case balanced
    /// Significant-change + visit monitoring only (night mode, low battery).
    case lowPower
    case off
}

@MainActor
public protocol LocationTracking: AnyObject {
    var onSample: (@MainActor (TelemetrySample.Location) -> Void)? { get set }
    func apply(mode: LocationMode)
}

/// Destination for queued telemetry. Networking.TelemetryUploader implements this.
/// Upload errors the pipeline treats specially. Uploaders map their transport's errors onto these;
/// anything else (server errors, expired sign-in) is kept queued and retried.
public enum UploadFailure: Error, Equatable, CustomStringConvertible {
    /// No connection to the server. Data stays queued.
    case unreachable(String)
    /// The server answered that the batch is invalid. Retrying the same batch can't succeed.
    case rejected(String)

    public var description: String {
        switch self {
        case .unreachable(let m): "Server unreachable (\(m))"
        case .rejected(let m): "Rejected by server: \(m)"
        }
    }
}

public protocol TelemetryUploading: Sendable {
    /// Sends one batch; returns the server's settings version so the caller can refresh settings.
    func upload(_ batch: TelemetryOutbox.Batch) async throws -> Int
}

/// Remembers how far each collector has read, so each wake only collects new data.
public protocol CollectionCursorStore: Sendable {
    func cursor(for collector: String) -> Date?
    func setCursor(_ date: Date, for collector: String)
}

/// Cursors are scoped to one account (`scope`, normally the Alpha's user ID) so that switching
/// accounts on a device never skips or mixes data between them.
public final class UserDefaultsCursorStore: CollectionCursorStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let scope: String
    public init(scope: String, defaults: UserDefaults = .standard) {
        self.scope = scope
        self.defaults = defaults
    }
    public func cursor(for collector: String) -> Date? { defaults.object(forKey: "cursor.\(scope).\(collector)") as? Date }
    public func setCursor(_ date: Date, for collector: String) { defaults.set(date, forKey: "cursor.\(scope).\(collector)") }
}

public final class InMemoryCursorStore: CollectionCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Date] = [:]
    public init() {}
    public func cursor(for collector: String) -> Date? { lock.withLock { values[collector] } }
    public func setCursor(_ date: Date, for collector: String) { lock.withLock { values[collector] = date } }
}

/// One collection + upload cycle, run on every wake (app foreground, BGAppRefreshTask, HealthKit
/// background delivery, location update). Collection never blocks on the network.
public struct MonitoringPipeline: Sendable {
    public struct CycleResult: Sendable, Equatable {
        public var collected: Int
        public var uploadedSamples: Int
        public var uploadedEvents: Int
        public var uploadError: String?
        public var settingsVersion: Int?
        /// The server couldn't be reached at all (as opposed to answering with an error).
        public var serverUnreachable = false
        /// Items discarded because the server rejected them as invalid; retrying can't succeed.
        public var rejectedItems = 0
    }

    public let collectors: [TelemetryCollector]
    public let outbox: TelemetryOutbox
    public let uploader: TelemetryUploading
    public let cursors: CollectionCursorStore
    /// How far back to look the very first time (Core Motion keeps about 7 days).
    public let initialLookback: TimeInterval

    public init(collectors: [TelemetryCollector], outbox: TelemetryOutbox, uploader: TelemetryUploading, cursors: CollectionCursorStore,
                initialLookback: TimeInterval = 6 * 3600) {
        self.collectors = collectors
        self.outbox = outbox
        self.uploader = uploader
        self.cursors = cursors
        self.initialLookback = initialLookback
    }

    /// The backend drops samples older than 8 days; don't keep queueing them.
    public static let maxSampleAge: TimeInterval = 7 * 86_400

    public func runCycle(now: Date, maxBatches: Int = 10) async -> CycleResult {
        try? await outbox.discardSamples(olderThan: now.addingTimeInterval(-Self.maxSampleAge))
        var collected = 0
        for c in collectors {
            let since = cursors.cursor(for: c.name) ?? now.addingTimeInterval(-initialLookback)
            do {
                let samples = try await c.collect(since: since, until: now)
                try await outbox.enqueue(samples: samples)
                cursors.setCursor(now, for: c.name)
                collected += samples.count
            } catch {
                // Cursor not advanced: the next cycle retries the same window.
                continue
            }
        }
        return await flush(collected: collected, maxBatches: maxBatches)
    }

    public func flush(collected: Int = 0, maxBatches: Int = 10) async -> CycleResult {
        var result = CycleResult(collected: collected, uploadedSamples: 0, uploadedEvents: 0)
        for _ in 0..<maxBatches {
            let batch = await outbox.nextBatch()
            if batch.isEmpty { break }
            do {
                result.settingsVersion = try await uploader.upload(batch)
                try await outbox.confirm(batch)
                result.uploadedSamples += batch.samples.count
                result.uploadedEvents += batch.events.count
            } catch UploadFailure.rejected {
                // A permanently invalid batch would otherwise block everything queued behind it.
                try? await outbox.discard(batch)
                result.rejectedItems += batch.samples.count + batch.events.count
            } catch {
                result.uploadError = String(describing: error)
                if case UploadFailure.unreachable = error { result.serverUnreachable = true }
                break // keep everything queued; retry on the next wake
            }
        }
        return result
    }
}
