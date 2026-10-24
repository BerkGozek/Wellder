import DesignSystem
import MonitoringCore
import SwiftUI

/// Development controls for generating synthetic telemetry and events. Only shown when
/// Simulation Mode is on; everything produced is flagged `simulated`.
struct SimulationControlsView: View {
    @Bindable var monitor: AlphaMonitor
    @State private var lastResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Simulation controls", systemImage: "testtube.2").font(.headline).foregroundStyle(.purple)
            Picker("Heart rate", selection: $monitor.scenario.heartRate) {
                ForEach(SimulationScenario.HeartRatePattern.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("simHeartRate")
            Picker("Movement", selection: $monitor.scenario.movement) {
                ForEach(SimulationScenario.MovementPattern.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Simulate connectivity failure", isOn: $monitor.scenario.connectivityFailure)
            Button("Send simulated data now") {
                Task {
                    await monitor.runCycle(reason: "simulation")
                    let r = monitor.lastCycle
                    lastResult = r?.uploadError.map { "Upload failed: \($0)" } ?? "Sent \(r?.uploadedSamples ?? 0) samples"
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sendSimulatedData")
            Menu("Simulate a fall candidate") {
                ForEach(SyntheticMotion.Scenario.allCases) { s in
                    Button(s.label) {
                        let c = monitor.simulateFall(s)
                        lastResult = c.map { String(format: "Detector fired (confidence %.2f)", $0.confidence) } ?? "Detector did not fire for: \(s.label)"
                    }
                }
            }
            .accessibilityIdentifier("simulateFall")
            if !lastResult.isEmpty { Text(lastResult).font(.caption).accessibilityIdentifier("simulationResult") }
        }
        .padding()
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
