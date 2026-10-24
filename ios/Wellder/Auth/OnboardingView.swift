import DesignSystem
import SharedModels
import SwiftUI

/// Collects a name and roles. Choosing the Alpha role requires reading and accepting a plain
/// explanation of what is shared and what the app cannot do (informed consent).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var phone = ""
    @State private var isAlpha = false
    @State private var isBeta = false
    @State private var consent = false
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("About you") {
                    TextField("Your name", text: $name).textContentType(.name).accessibilityIdentifier("name")
                    TextField("Mobile number (optional, +1…)", text: $phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                        .accessibilityIdentifier("phone")
                }
                Section {
                    Toggle(isOn: $isAlpha) {
                        Label { VStack(alignment: .leading) { Text("Share my wellbeing"); Text("I want people I trust to be able to check on me.").font(.caption).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "figure.wave") }
                    }
                    .accessibilityIdentifier("roleAlpha")
                    Toggle(isOn: $isBeta) {
                        Label { VStack(alignment: .leading) { Text("Look after someone"); Text("I want to check on a family member or friend.").font(.caption).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "person.2") }
                    }
                    .accessibilityIdentifier("roleBeta")
                } header: {
                    Text("How will you use Wellder?")
                } footer: {
                    Text("You can choose both.")
                }
                if isAlpha {
                    Section("What sharing means") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nobody can see anything until you approve them, and you choose what each person sees.")
                            Text("You can stop sharing with anyone, at any time.")
                            Text(MonitoringDisclaimer.long).font(.callout).foregroundStyle(.secondary)
                        }
                        Toggle("I understand and want to share", isOn: $consent).accessibilityIdentifier("consent")
                    }
                    Section {
                        Toggle("Use simulated sensors (testing)", isOn: $model.simulationEnabled).accessibilityIdentifier("simulationToggle")
                    } footer: {
                        Text("For trying the app without real health or location data. Simulated data is clearly labelled and never sends text messages or calls.")
                    }
                }
                if let e = model.lastError { Section { Text(e).foregroundStyle(.red) } }
                Section {
                    Button("Continue") {
                        busy = true
                        let roles: [Role] = (isAlpha ? [.alpha] : []) + (isBeta ? [.beta] : [])
                        Task {
                            _ = await model.saveProfile(name: name, phone: phone.isEmpty ? nil : phone, roles: roles)
                            busy = false
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || (!isAlpha && !isBeta) || (isAlpha && !consent))
                    .accessibilityIdentifier("continueOnboarding")
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                }
            }
            .navigationTitle("Welcome")
        }
    }
}
