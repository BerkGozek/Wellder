import Foundation
import SharedModels
import Testing
@testable import MonitoringCore

struct FallDetectorTests {
    func run(_ scenario: SyntheticMotion.Scenario, config: FallDetector.Configuration = .init()) -> [FallCandidate] {
        let d = FallDetector(config: config)
        return SyntheticMotion.trace(scenario).compactMap { d.process($0) }
    }

    @Test func wristConfigDetectsFallAndIgnoresEverydayMotion() {
        #expect(!run(.fall, config: .wrist).isEmpty)
        for s in [SyntheticMotion.Scenario.walking, .sitDownHard, .standingStill] {
            #expect(run(s, config: .wrist).isEmpty, "\(s)")
        }
    }

    /// A clap or knock: a sharp spike while the arm keeps moving and ends up where it started.
    @Test func wristConfigIgnoresAGestureSpike() {
        let d = FallDetector(config: .wrist)
        let down = SIMD3<Double>(0, 0, -1)
        var candidates: [FallCandidate] = []
        for i in 0..<(50 * 10) {
            let t = Double(i) / 50
            var a = down + SIMD3(0.4 * sin(t * 9), 0.3 * cos(t * 7), 0)
            if (250...252).contains(i) { a = SIMD3(5.5, 0, -1) }
            if let c = d.process(MotionSample(timestamp: t, acceleration: a, gravity: down)) { candidates.append(c) }
        }
        #expect(candidates.isEmpty)
    }

    @Test func detectsSyntheticFall() throws {
        let c = try #require(run(.fall).first)
        #expect(c.peakG > 3)
        #expect(c.freeFallSeconds > 0.2)
        #expect(c.orientationChangeDegrees > 60)
        #expect(c.stillAfterImpact)
        #expect(c.confidence >= 0.9)
    }

    @Test(arguments: [SyntheticMotion.Scenario.walking, .sitDownHard, .standingStill])
    func ignoresNonFalls(_ scenario: SyntheticMotion.Scenario) {
        #expect(run(scenario).isEmpty)
    }

    /// Known limitation, kept as a test so it stays documented: a dropped phone looks like a
    /// fall to accelerometer heuristics. The confirmation prompt is the mitigation.
    @Test func droppedPhoneIsAKnownFalsePositive() {
        #expect(!run(.phoneDropped).isEmpty)
    }

    @Test func refractoryPeriodPreventsDuplicateCandidates() {
        let d = FallDetector()
        var trace = SyntheticMotion.trace(.fall)
        let offset = (trace.last?.timestamp ?? 0) + 0.02
        trace += SyntheticMotion.trace(.fall, seed: 7).map { MotionSample(timestamp: $0.timestamp + offset, acceleration: $0.acceleration, gravity: $0.gravity) }
        #expect(trace.compactMap { d.process($0) }.count == 1)
    }
}

struct FallResponseCoordinatorTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func userOk() throws {
        var c = FallResponseCoordinator()
        let candidateMaybe = c.begin(confidence: 0.8, detector: "experimental", countdownSeconds: 60, now: t0)
        let candidate = try #require(candidateMaybe)
        #expect(candidate.type == .fallCandidate)
        #expect(candidate.countdownSeconds == 60)
        #expect(c.secondsRemaining(now: t0.addingTimeInterval(15)) == 45)
        #expect(c.begin(confidence: 0.9, detector: "experimental", countdownSeconds: 60, now: t0) == nil, "one prompt at a time")
        let okMaybe = c.respond(.userOk, now: t0.addingTimeInterval(10))
        let ok = try #require(okMaybe)
        #expect(ok.type == .fallUserOk)
        #expect(ok.relatedEventId == candidate.eventId)
        #expect(c.tick(now: t0.addingTimeInterval(120)) == nil)
    }

    @Test func noResponseAfterCountdown() throws {
        var c = FallResponseCoordinator(simulated: true)
        let candidateMaybe = c.begin(confidence: 0.7, detector: "experimental", countdownSeconds: 30, now: t0)
        let candidate = try #require(candidateMaybe)
        #expect(candidate.simulated == true)
        #expect(c.tick(now: t0.addingTimeInterval(29)) == nil)
        let eMaybe = c.tick(now: t0.addingTimeInterval(30))
        let e = try #require(eMaybe)
        #expect(e.type == .fallNoResponse)
        #expect(c.state == .finished(.noResponse))
    }

    @Test func needHelp() throws {
        var c = FallResponseCoordinator()
        _ = c.begin(confidence: 0.7, detector: "experimental", countdownSeconds: 30, now: t0)
        #expect(c.respond(.needHelp, now: t0)?.type == .fallNeedHelp)
    }
}

struct OutboxTests {
    func hr(_ i: Int) -> TelemetrySample {
        .heartRate(.init(sampleId: "s\(i)", timestamp: Date(timeIntervalSince1970: Double(i)), bpm: 70, sourceDevice: "w"))
    }

    @Test func dedupesAndConfirms() async throws {
        let outbox = TelemetryOutbox(storage: InMemoryOutboxStorage())
        try await outbox.enqueue(samples: [hr(1), hr(2)])
        try await outbox.enqueue(samples: [hr(2), hr(3)])
        #expect(await outbox.pendingSamples == 3)
        let batch = await outbox.nextBatch(maxSamples: 2)
        #expect(batch.samples.map(\.id) == ["s1", "s2"])
        try await outbox.confirm(batch)
        #expect(await outbox.pendingSamples == 1)
    }

    @Test func overflowDropsOldestSamplesButNeverEvents() async throws {
        let outbox = TelemetryOutbox(storage: InMemoryOutboxStorage(), maxSamples: 3)
        try await outbox.enqueue(events: [DeviceEvent(type: .manualHelpRequest, detectedAt: .now)])
        try await outbox.enqueue(samples: (1...5).map(hr))
        #expect(await outbox.pendingSamples == 3)
        #expect(await outbox.droppedSamples == 2)
        #expect(await outbox.pendingEvents == 1)
        #expect(await outbox.nextBatch().samples.first?.id == "s3")
    }

    @Test func persistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = TelemetryOutbox(storage: FileOutboxStorage(url: url))
        try await a.enqueue(samples: [hr(1)], events: [DeviceEvent(type: .fallCandidate, detectedAt: .now)])
        let b = TelemetryOutbox(storage: FileOutboxStorage(url: url))
        #expect(await b.pendingSamples == 1)
        #expect(await b.pendingEvents == 1)
    }
}

struct PipelineTests {
    final class RecordingUploader: TelemetryUploading, @unchecked Sendable {
        let lock = NSLock()
        var batches: [TelemetryOutbox.Batch] = []
        func upload(_ batch: TelemetryOutbox.Batch) async throws -> Int {
            lock.withLock { batches.append(batch) }
            return 7
        }
    }

    final class Toggle: @unchecked Sendable { var on = true }

    @Test func queuesDuringOutageAndUploadsLater() async throws {
        let outbox = TelemetryOutbox(storage: InMemoryOutboxStorage())
        let recorder = RecordingUploader()
        let outage = Toggle()
        let scenario = SimulationScenario()
        let pipeline = MonitoringPipeline(
            collectors: [SimulatedCollector(.heartRate) { scenario }, SimulatedCollector(.location) { scenario }],
            outbox: outbox,
            uploader: FlakyUploader(base: recorder) { outage.on },
            cursors: InMemoryCursorStore(),
            initialLookback: 3600)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let offline = await pipeline.runCycle(now: now)
        #expect(offline.collected > 0)
        #expect(offline.uploadedSamples == 0)
        #expect(offline.uploadError != nil)
        #expect(offline.serverUnreachable, "an outage is what the Offline state means")
        #expect(await outbox.pendingSamples == offline.collected)

        outage.on = false
        let online = await pipeline.runCycle(now: now.addingTimeInterval(600))
        #expect(online.uploadError == nil)
        #expect(online.settingsVersion == 7)
        #expect(await outbox.pendingSamples == 0)
        let uploaded = recorder.batches.flatMap(\.samples)
        #expect(uploaded.count == offline.collected + online.collected)
        #expect(Set(uploaded.map(\.id)).count == uploaded.count, "no duplicates from overlapping windows")
    }

    /// Regression: on a real iPhone, years-old Apple Health history was rejected by the server and
    /// retried forever, so the queue filled to its cap and the app showed "Offline".
    @Test func rejectedBatchIsDiscardedAndDoesNotBlockTheQueue() async throws {
        final class RejectFirst: TelemetryUploading, @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            var accepted: [TelemetryOutbox.Batch] = []
            func upload(_ batch: TelemetryOutbox.Batch) async throws -> Int {
                try lock.withLock {
                    calls += 1
                    if calls == 1 { throw UploadFailure.rejected("timestamp is too far in the past") }
                    accepted.append(batch)
                }
                return 1
            }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outbox = TelemetryOutbox(storage: InMemoryOutboxStorage())
        let hr = { (i: Int) in TelemetrySample.heartRate(.init(timestamp: now.addingTimeInterval(Double(-i * 60)), bpm: 70, sourceDevice: "Apple Watch")) }
        try await outbox.enqueue(samples: (0..<600).map(hr))
        let uploader = RejectFirst()
        let pipeline = MonitoringPipeline(collectors: [], outbox: outbox, uploader: uploader, cursors: InMemoryCursorStore())

        let r = await pipeline.runCycle(now: now)
        #expect(r.rejectedItems == 500)
        #expect(r.uploadedSamples == 100, "the batch behind the rejected one still goes out")
        #expect(r.uploadError == nil)
        #expect(!r.serverUnreachable)
        #expect(await outbox.pendingSamples == 0)
        #expect(await outbox.droppedSamples == 500)
    }

    @Test func samplesTooOldForTheServerArePurged() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outbox = TelemetryOutbox(storage: InMemoryOutboxStorage())
        try await outbox.enqueue(
            samples: [.heartRate(.init(timestamp: now.addingTimeInterval(-3 * 365 * 86_400), bpm: 60, sourceDevice: "Apple Watch")),
                      .heartRate(.init(timestamp: now.addingTimeInterval(-60), bpm: 61, sourceDevice: "Apple Watch"))],
            events: [DeviceEvent(type: .manualHelpRequest, detectedAt: now.addingTimeInterval(-30 * 86_400))])
        let recorder = RecordingUploader()
        let pipeline = MonitoringPipeline(collectors: [], outbox: outbox, uploader: recorder, cursors: InMemoryCursorStore())
        _ = await pipeline.runCycle(now: now)
        #expect(recorder.batches.flatMap(\.samples).count == 1)
        #expect(recorder.batches.flatMap(\.events).count == 1, "events are never purged")
        #expect(await outbox.droppedSamples == 1)
    }

    @Test func simulatedDataIsAlwaysMarked() {
        let s = SimulationScenario(heartRate: .highEpisode)
        let samples = SyntheticTelemetry.heartRate(s, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200))
            + SyntheticTelemetry.locations(s, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200))
            + SyntheticTelemetry.activity(s, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200))
        #expect(!samples.isEmpty)
        for sample in samples {
            switch sample {
            case .heartRate(let v): #expect(v.simulated == true)
            case .location(let v): #expect(v.simulated == true)
            case .activity(let v): #expect(v.simulated == true)
            case .steps(let v): #expect(v.simulated == true)
            case .interaction(let v): #expect(v.simulated == true)
            }
        }
        let last = samples.compactMap { if case .heartRate(let h) = $0 { h } else { nil } }.last
        #expect((last?.bpm ?? 0) > 120, "high episode at end of window")
    }

    @Test func cursorsAreScopedPerAccount() throws {
        let defaults = try #require(UserDefaults(suiteName: "cursor-test-\(UUID().uuidString)"))
        let a = UserDefaultsCursorStore(scope: "alpha-a", defaults: defaults)
        let b = UserDefaultsCursorStore(scope: "alpha-b", defaults: defaults)
        a.setCursor(Date(timeIntervalSince1970: 100), for: "hr")
        #expect(a.cursor(for: "hr") == Date(timeIntervalSince1970: 100))
        #expect(b.cursor(for: "hr") == nil, "a new account on the same device starts fresh")
    }

    @Test func syntheticTrailHasDeliberateGaps() {
        let s = SimulationScenario()
        let locs = SyntheticTelemetry.locations(s, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 7200))
            .compactMap { if case .location(let l) = $0 { l } else { nil } }
        #expect(!LocationTrail(samples: locs).gaps.isEmpty)
    }
}
