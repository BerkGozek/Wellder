import Charts
import DesignSystem
import MonitoringCore
import Networking
import SharedModels
import SwiftUI

struct HeartRateView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    @State private var range: HistoryRange = .h24
    @State private var history: HeartRateHistory?
    @State private var error: String?

    var body: some View {
        List {
            Picker("Range", selection: $range) { ForEach(HistoryRange.allCases.filter { $0 != .custom }) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            if let error { ErrorBanner(error) }
            if let h = history {
                if h.samples.isEmpty {
                    Text("No heart-rate readings in this period. Apple Watch must be worn and paired for readings to appear.").foregroundStyle(.secondary)
                } else {
                    chart(h).frame(height: 240)
                    if let s = h.stats {
                        LabeledContent("Lowest", value: "\(Int(s.min)) bpm")
                        LabeledContent("Highest", value: "\(Int(s.max)) bpm")
                        LabeledContent("Readings", value: "\(s.count)").accessibilityIdentifier("hrReadings")
                    }
                    LabeledContent("Alert range", value: "\(Int(h.thresholds.lowerBpm))–\(Int(h.thresholds.upperBpm)) bpm")
                    if let last = h.samples.last {
                        LabeledContent("Most recent", value: "\(Int(last.bpm)) bpm at \(last.timestamp.formatted(date: .omitted, time: .shortened))")
                    }
                    Section("Readings") {
                        ForEach(h.samples.reversed().prefix(50), id: \.sampleId) { s in
                            LabeledContent(s.timestamp.formatted(date: .abbreviated, time: .shortened), value: "\(Int(s.bpm)) bpm")
                        }
                    }
                }
            } else {
                ProgressView()
            }
            Text("Each point is a separate measurement. Lines connect readings that may be several minutes apart; values between them were not measured.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task(id: range) { await load() }
        .refreshable { await load() }
    }

    private func chart(_ h: HeartRateHistory) -> some View {
        Chart {
            RuleMark(y: .value("Upper", h.thresholds.upperBpm)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(dash: [4]))
                .annotation(position: .top, alignment: .leading) { Text("\(Int(h.thresholds.upperBpm))").font(.caption2).foregroundStyle(.red) }
            RuleMark(y: .value("Lower", h.thresholds.lowerBpm)).foregroundStyle(.blue.opacity(0.6)).lineStyle(StrokeStyle(dash: [4]))
            ForEach(h.samples, id: \.sampleId) { s in
                LineMark(x: .value("Time", s.timestamp), y: .value("bpm", s.bpm)).foregroundStyle(.pink.opacity(0.5))
                PointMark(x: .value("Time", s.timestamp), y: .value("bpm", s.bpm))
                    .foregroundStyle(s.bpm > h.thresholds.upperBpm || s.bpm < h.thresholds.lowerBpm ? .red : .pink)
                    .symbolSize(20)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .accessibilityLabel("Heart rate chart")
    }

    private func load() async {
        let to = Date()
        do {
            history = try await model.api.heartRate(alphaId: alphaId, from: to.addingTimeInterval(-(range.duration ?? 86400)), to: to)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    @State private var history: ActivityHistory?
    @State private var error: String?

    var body: some View {
        List {
            if let error { ErrorBanner(error) }
            if let h = history {
                let now = Date()
                let lastMove = (h.activity.filter { $0.activityType.isMoving }.map(\.timestamp) + h.steps.filter { $0.count > 0 }.map(\.endTimestamp)).max()
                Section("Summary (last 24 h)") {
                    LabeledContent("Steps", value: "\(h.steps.reduce(0) { $0 + $1.count })")
                    LabeledContent("Last movement", value: lastMove.map { RelativeTime.short($0, now: now) } ?? "None recorded")
                    LabeledContent("Not moving for", value: lastMove.map { "about \(Int(now.timeIntervalSince($0) / 60)) min" } ?? "Unknown")
                    if let i = h.interactions.last { LabeledContent("Last opened Wellder", value: RelativeTime.short(i.timestamp, now: now)) }
                }
                if !h.steps.isEmpty {
                    Chart(h.steps, id: \.sampleId) { s in
                        BarMark(x: .value("Time", s.timestamp, unit: .hour), y: .value("Steps", s.count)).foregroundStyle(.green)
                    }
                    .frame(height: 160)
                }
                Section("Timeline") {
                    let timeline = (h.activity.map { ($0.timestamp, "\($0.activityType.rawValue.capitalized) (\($0.confidence.rawValue) confidence)") }
                        + h.interactions.map { ($0.timestamp, $0.source == .checkIn ? "Checked in: \"I'm okay\"" : "Opened Wellder") })
                        .sorted { $0.0 > $1.0 }
                    if timeline.isEmpty { Text("No activity recorded.").foregroundStyle(.secondary) }
                    ForEach(Array(timeline.prefix(100).enumerated()), id: \.offset) { _, item in
                        LabeledContent(item.1, value: item.0.formatted(date: .omitted, time: .shortened))
                    }
                }
            } else {
                ProgressView()
            }
            Text("Activity comes from the iPhone's motion sensors. It cannot tell where in the home someone is, and shows no movement when the phone is not carried.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            history = try await model.api.activity(alphaId: alphaId, from: Date().addingTimeInterval(-86400), to: Date())
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
