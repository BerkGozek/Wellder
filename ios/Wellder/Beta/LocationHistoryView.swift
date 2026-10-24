import DesignSystem
import MapKit
import MonitoringCore
import Networking
import SharedModels
import SwiftUI

/// Movement trail. Segments are drawn only between consecutive recorded points; gaps longer than
/// 15 minutes break the line and are listed, so the map never implies unrecorded movement.
struct LocationHistoryView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    let canSeeHistory: Bool
    @State private var range: HistoryRange = .h6
    @State private var customFrom = Date().addingTimeInterval(-24 * 3600)
    @State private var customTo = Date()
    @State private var trail: LocationTrail?
    @State private var window: (Date, Date)?
    @State private var error: String?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 8) {
            if !canSeeHistory {
                ContentUnavailableView("History not shared", systemImage: "lock", description: Text("They share their current location only."))
            } else {
                Picker("Range", selection: $range) { ForEach(HistoryRange.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .accessibilityIdentifier("rangePicker")
                if range == .custom {
                    HStack {
                        DatePicker("From", selection: $customFrom, in: Date().addingTimeInterval(-31 * 86400)...customTo).labelsHidden()
                        Text("to")
                        DatePicker("To", selection: $customTo, in: customFrom...Date()).labelsHidden()
                    }
                    .padding(.horizontal)
                }
                if let error { ErrorBanner(error).padding(.horizontal) }
                map.frame(minHeight: 300)
                details
            }
        }
        .task(id: "\(range.rawValue)\(customFrom.timeIntervalSince1970)\(customTo.timeIntervalSince1970)") { await load() }
    }

    private var map: some View {
        Map(position: $camera) {
            if let trail {
                ForEach(trail.segments) { seg in
                    if seg.points.count > 1 {
                        MapPolyline(coordinates: seg.points.map(\.coordinate)).stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    ForEach(seg.points.filter { $0.horizontalAccuracy > LocationTrail.poorAccuracyMeters }, id: \.sampleId) { p in
                        MapCircle(center: p.coordinate, radius: p.horizontalAccuracy).foregroundStyle(.orange.opacity(0.12))
                    }
                }
                if let first = trail.first {
                    Annotation("Start \(first.timestamp.formatted(date: .omitted, time: .shortened))", coordinate: first.coordinate) {
                        Image(systemName: "flag.fill").padding(6).background(.green, in: Circle()).foregroundStyle(.white)
                    }
                }
                if let last = trail.last {
                    Annotation("Last known \(last.timestamp.formatted(date: .omitted, time: .shortened))", coordinate: last.coordinate) {
                        Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red)
                    }
                    MapCircle(center: last.coordinate, radius: last.horizontalAccuracy).foregroundStyle(.red.opacity(0.15))
                }
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .accessibilityLabel(trail.map { "Map with \($0.segments.reduce(0) { $0 + $1.points.count }) recorded locations" } ?? "Map")
    }

    @ViewBuilder private var details: some View {
        List {
            if let trail, let (from, to) = window {
                let gaps = trail.gaps(within: from, to: to)
                if let last = trail.last {
                    LabeledContent("Last known location", value: "\(last.timestamp.formatted(date: .abbreviated, time: .shortened)), ±\(Int(last.horizontalAccuracy)) m")
                }
                LabeledContent("Recorded points", value: "\(trail.segments.reduce(0) { $0 + $1.points.count })")
                    .accessibilityIdentifier("recordedPoints")
                if trail.segments.isEmpty { Text("No location was recorded in this period.").foregroundStyle(.secondary) }
                if !gaps.isEmpty {
                    Section("No location recorded") {
                        ForEach(gaps) { g in
                            Text("\(g.from.formatted(date: .omitted, time: .shortened)) – \(g.to.formatted(date: .omitted, time: .shortened)) (\(Int(g.duration / 60)) min)")
                                .font(.callout)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
    }

    private func load() async {
        let to = range == .custom ? customTo : Date()
        let from = range == .custom ? customFrom : to.addingTimeInterval(-(range.duration ?? 3600))
        do {
            let h = try await model.api.locations(alphaId: alphaId, from: from, to: to)
            trail = LocationTrail(samples: h.samples)
            window = (from, to)
            error = nil
            camera = .automatic
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension TelemetrySample.Location {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
