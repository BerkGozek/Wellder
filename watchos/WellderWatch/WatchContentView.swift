import SwiftUI

struct WatchContentView: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmHelp = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 10) {
                if model.simulation { Text("SIMULATION").font(.caption2.bold()).foregroundStyle(.purple) }
                Text(model.stateTitle).font(.headline)
                HeartRateTile(heart: model.heart) { Task { await model.toggleLiveHeartRate() } }
                if model.experimentalFallDetection {
                    Label(model.fallDetectionRunning ? "Fall detection on (experimental)" : "Fall detection: open app or start Live heart rate",
                          systemImage: model.fallDetectionRunning ? "figure.fall" : "figure.fall.circle")
                        .font(.caption2).foregroundStyle(model.fallDetectionRunning ? .green : .secondary)
                }
                Button { confirmHelp = true } label: {
                    Label("Get help", systemImage: "sos").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 56)
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                Button { model.checkIn() } label: { Label("I'm okay", systemImage: "hand.thumbsup.fill").frame(maxWidth: .infinity) }
                    .tint(.green)
                Button { model.callEmergency() } label: { Label("Call \(model.emergencyNumber)", systemImage: "phone.fill") }
                if let s = model.lastSent { Text(s).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .confirmationDialog("Alert your caregivers?", isPresented: $confirmHelp) {
            Button("Alert caregivers", role: .destructive) { model.requestHelp() }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: Binding(get: { model.alarm != nil }, set: { if !$0 { model.stopAlarm() } })) {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill").font(.title).foregroundStyle(.red).symbolEffect(.pulse)
                    Text(model.alarm?.text ?? "").font(.headline).multilineTextAlignment(.center)
                    if let d = model.alarm?.deadline {
                        Text("Caregivers alerted in \(max(0, Int(d.timeIntervalSince(model.now).rounded(.up)))) s")
                            .font(.title3.monospacedDigit())
                        Button("False alarm") { Task { await model.answerAlarm(.ok) } }.tint(.green).buttonStyle(.borderedProminent)
                        Button("Get help") { Task { await model.answerAlarm(.help) } }.tint(.red)
                    } else {
                        Text("Caregivers alerted.").font(.caption)
                        Button("Stop alarm") { model.stopAlarm() }.tint(.red).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $model.showFallPrompt) {
            VStack(spacing: 8) {
                Text("Possible fall").font(.headline)
                Text("Are you okay?")
                if let r = model.fall.secondsRemaining(now: model.now) { Text("\(r) s").font(.title2.monospacedDigit()) }
                Button("I'm okay") { model.respond(.userOk) }.tint(.green)
                Button("I need help") { model.respond(.needHelp) }.tint(.red)
            }
        }
    }
}

/// Latest heart rate with its age, and the "Live heart rate" switch (a workout session that
/// measures every few seconds; see LiveHeartRate).
private struct HeartRateTile: View {
    let heart: LiveHeartRate
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: heart.isLive)
                Text(heart.latestBpm.map(String.init) ?? "--").font(.system(.title, design: .rounded).bold().monospacedDigit())
                Text("BPM").font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(heart.latestBpm.map { "Heart rate \($0) beats per minute" } ?? "No heart rate yet")
            if let at = heart.latestAt {
                TimelineView(.periodic(from: .now, by: 5)) { ctx in
                    Text(age(at, now: ctx.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button(action: toggle) {
                Label(heart.isLive ? "Stop live heart rate" : "Live heart rate", systemImage: heart.isLive ? "stop.fill" : "waveform.path.ecg")
                    .frame(maxWidth: .infinity)
            }
            .tint(heart.isLive ? .gray : .pink)
            if heart.isLive { Text("Measuring every few seconds. Uses more battery.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let p = heart.problem { Text(p).font(.caption2).foregroundStyle(.orange) }
        }
    }

    private func age(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        return s < 60 ? "\(s) s ago" : s < 3600 ? "\(s / 60) min ago" : date.formatted(date: .omitted, time: .shortened)
    }
}
