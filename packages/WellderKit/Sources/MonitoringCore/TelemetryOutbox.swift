import Foundation
import SharedModels

/// Persistent queue of telemetry waiting to be uploaded. Survives app termination, so data
/// recorded offline (or during a background wake without network) is sent later.
///
/// Policy: events (falls, help requests) are never dropped. If samples exceed `maxSamples`, the
/// oldest samples are discarded first and the loss is counted, so the UI can say so.
public actor TelemetryOutbox {
    public struct Contents: Codable, Sendable {
        public var samples: [TelemetrySample] = []
        public var events: [DeviceEvent] = []
        public var droppedSamples: Int = 0
        public init() {}
    }

    public struct Batch: Sendable {
        public var samples: [TelemetrySample]
        public var events: [DeviceEvent]
        public var isEmpty: Bool { samples.isEmpty && events.isEmpty }
    }

    private let storage: OutboxStorage
    private let maxSamples: Int
    private var contents: Contents

    public init(storage: OutboxStorage, maxSamples: Int = 20_000) {
        self.storage = storage
        self.maxSamples = maxSamples
        self.contents = (try? storage.load()) ?? Contents()
    }

    public var pendingSamples: Int { contents.samples.count }
    public var pendingEvents: Int { contents.events.count }
    public var droppedSamples: Int { contents.droppedSamples }

    public func enqueue(samples: [TelemetrySample] = [], events: [DeviceEvent] = []) throws {
        guard !samples.isEmpty || !events.isEmpty else { return }
        let known = Set(contents.samples.map(\.id))
        contents.samples.append(contentsOf: samples.filter { !known.contains($0.id) })
        let knownEvents = Set(contents.events.map(\.eventId))
        contents.events.append(contentsOf: events.filter { !knownEvents.contains($0.eventId) })
        if contents.samples.count > maxSamples {
            contents.samples.sort { $0.timestamp < $1.timestamp }
            let overflow = contents.samples.count - maxSamples
            contents.samples.removeFirst(overflow)
            contents.droppedSamples += overflow
        }
        try storage.save(contents)
    }

    /// Events always go first; samples oldest-first.
    public func nextBatch(maxSamples: Int = 500, maxEvents: Int = 50) -> Batch {
        Batch(samples: Array(contents.samples.prefix(maxSamples)), events: Array(contents.events.prefix(maxEvents)))
    }

    /// Removes items the server acknowledged. Called only after a 2xx response.
    public func confirm(_ batch: Batch) throws {
        let sent = Set(batch.samples.map(\.id))
        let sentEvents = Set(batch.events.map(\.eventId))
        contents.samples.removeAll { sent.contains($0.id) }
        contents.events.removeAll { sentEvents.contains($0.eventId) }
        try storage.save(contents)
    }

    /// Drops a batch the server rejected as invalid, counting the samples as lost.
    public func discard(_ batch: Batch) throws {
        try confirm(batch)
        contents.droppedSamples += batch.samples.count
        try storage.save(contents)
    }

    /// Drops samples older than `date` (the server no longer accepts them), counting them as lost.
    /// Events are kept.
    public func discardSamples(olderThan date: Date) throws {
        let before = contents.samples.count
        contents.samples.removeAll { $0.timestamp < date }
        guard contents.samples.count != before else { return }
        contents.droppedSamples += before - contents.samples.count
        try storage.save(contents)
    }

    public func removeAll() throws {
        contents = Contents()
        try storage.save(contents)
    }
}

public protocol OutboxStorage: Sendable {
    func load() throws -> TelemetryOutbox.Contents
    func save(_ contents: TelemetryOutbox.Contents) throws
}

/// JSON file in Application Support, protected until first unlock so background wakes can write.
public struct FileOutboxStorage: OutboxStorage {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`(fileName: String = "telemetry-outbox.json") throws -> FileOutboxStorage {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return FileOutboxStorage(url: dir.appendingPathComponent(fileName))
    }

    public func load() throws -> TelemetryOutbox.Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try WireJSON.decoder().decode(TelemetryOutbox.Contents.self, from: Data(contentsOf: url))
    }

    public func save(_ contents: TelemetryOutbox.Contents) throws {
        let data = try WireJSON.encoder().encode(contents)
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }
}

public final class InMemoryOutboxStorage: OutboxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value = TelemetryOutbox.Contents()
    public init() {}
    public func load() throws -> TelemetryOutbox.Contents { lock.withLock { value } }
    public func save(_ contents: TelemetryOutbox.Contents) throws { lock.withLock { value = contents } }
}
