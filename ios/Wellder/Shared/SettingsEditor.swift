import SharedModels
import SwiftUI

/// Form sections for monitoring settings. `editable` limits which sections a caller may change
/// (Betas only get the sections their permissions allow).
struct SettingsEditor: View {
    @Binding var settings: MonitoringSettings
    var editable: Set<Section> = Set(Section.allCases)

    enum Section: CaseIterable { case sleep, heartRate, movement, fall, notifications, emergency, retention }

    var body: some View {
        SwiftUI.Section {
            Toggle("Night mode", isOn: $settings.sleepSchedule.enabled).accessibilityIdentifier("nightModeToggle")
            if settings.sleepSchedule.enabled {
                TimePicker(title: "Bedtime", hhmm: $settings.sleepSchedule.bedtime, timeZone: settings.sleepSchedule.timeZone)
                TimePicker(title: "Wake-up", hhmm: $settings.sleepSchedule.wakeTime, timeZone: settings.sleepSchedule.timeZone)
                Toggle("Keep fall detection on at night", isOn: $settings.sleepSchedule.keepFallDetectionAtNight)
            }
            LabeledContent("Time zone", value: settings.sleepSchedule.timeZone)
            if settings.sleepSchedule.timeZone != TimeZone.current.identifier {
                Button("Use this phone's time zone (\(TimeZone.current.identifier))") { settings.sleepSchedule.timeZone = TimeZone.current.identifier }
            }
            if let o = settings.sleepSchedule.override, o.until > Date() {
                LabeledContent(o.mode == .forceNight ? "Night mode on until" : "Night mode off until", value: o.until.formatted(date: .omitted, time: .shortened))
                Button("Cancel override") { settings.sleepSchedule.override = nil }
            } else {
                Button("Start night mode now (until wake-up)") {
                    let wake = NightScheduleHelper.nextWake(settings.sleepSchedule) ?? Date().addingTimeInterval(8 * 3600)
                    settings.sleepSchedule.override = .init(mode: .forceNight, until: wake)
                }
            }
        } header: {
            Text("Night")
        } footer: {
            Text("At night, location sharing switches to a low-power mode. Help requests always work. Heart rate is still shared when Apple Watch records it.")
        }
        .disabled(!editable.contains(.sleep))

        SwiftUI.Section {
            Toggle("Share heart rate", isOn: $settings.heartRate.enabled)
            Stepper("Alert above \(settings.heartRate.upperBpm) bpm", value: $settings.heartRate.upperBpm, in: max(settings.heartRate.lowerBpm + 10, 60)...220, step: 5)
                .accessibilityIdentifier("upperBpm")
            Stepper("Alert below \(settings.heartRate.lowerBpm) bpm", value: $settings.heartRate.lowerBpm, in: 25...min(settings.heartRate.upperBpm - 10, 100), step: 5)
            Picker("Must last at least", selection: $settings.heartRate.persistenceSeconds) {
                Text("One reading").tag(0); Text("5 min").tag(300); Text("10 min").tag(600); Text("20 min").tag(1200)
            }
            Picker("Don't repeat for", selection: $settings.heartRate.cooldownSeconds) {
                Text("15 min").tag(900); Text("30 min").tag(1800); Text("1 h").tag(3600); Text("4 h").tag(14400)
            }
        } header: {
            Text("Heart rate")
        } footer: {
            Text("Apple Watch measures heart rate every few minutes, not continuously, so an alert can come several minutes after a change.")
        }
        .disabled(!editable.contains(.heartRate))

        SwiftUI.Section("Movement & location") {
            Toggle("Share activity and steps", isOn: $settings.movement.enabled)
            Toggle("Share location", isOn: $settings.movement.locationEnabled)
            Picker("Alert after no movement for", selection: $settings.movement.inactivityThresholdMinutes) {
                Text("2 h").tag(120); Text("4 h").tag(240); Text("6 h").tag(360); Text("8 h").tag(480); Text("12 h").tag(720)
            }
            Picker("Keep location history", selection: $settings.movement.locationHistoryRetentionDays) {
                Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }
        }
        .disabled(!editable.contains(.movement))

        SwiftUI.Section {
            Toggle("Apple Watch Fall Detection", isOn: $settings.fallDetection.systemFallDetectionEnabled)
            Toggle("Experimental iPhone fall detection", isOn: $settings.fallDetection.experimentalEnabled).accessibilityIdentifier("experimentalFall")
            Picker("Time to cancel a false alarm (falls and heart rate)", selection: $settings.fallDetection.confirmationCountdownSeconds) {
                Text("30 s").tag(30); Text("60 s").tag(60); Text("90 s").tag(90); Text("2 min").tag(120)
            }
        } header: {
            Text("Falls")
        } footer: {
            Text("Experimental detection is not validated, only works while Wellder is open on screen, and may miss falls or react to a dropped phone. Apple Watch Fall Detection requires the watch app and Apple's approval of this app.")
        }
        .disabled(!editable.contains(.fall))

        SwiftUI.Section {
            Toggle("Push notifications", isOn: $settings.notifications.push)
            Toggle("Text messages if not acknowledged", isOn: $settings.notifications.sms)
            Toggle("Phone calls if still not acknowledged", isOn: $settings.notifications.voice)
            Picker("Wait before escalating", selection: $settings.notifications.escalationDelaySeconds) {
                Text("1 min").tag(60); Text("3 min").tag(180); Text("5 min").tag(300); Text("10 min").tag(600)
            }
        } header: {
            Text("Caregiver notifications")
        } footer: {
            Text("Texts and calls only happen for urgent alerts, and only if the service has been set up for this account. Simulated alerts never text or call.")
        }
        .disabled(!editable.contains(.notifications))

        SwiftUI.Section {
            LabeledContent("Emergency number", value: settings.emergency.emergencyNumber)
            ForEach(settings.emergency.contacts) { c in
                LabeledContent(c.name, value: c.phoneNumber)
            }
            .onDelete { settings.emergency.contacts.remove(atOffsets: $0) }
            AddContactRow { settings.emergency.contacts.append($0) }
        } header: {
            Text("Emergency contacts")
        } footer: {
            Text("Wellder never calls emergency services automatically. The \"Call\" button opens your phone app.")
        }
        .disabled(!editable.contains(.emergency))

        SwiftUI.Section("Data kept") {
            Picker("Heart rate & activity", selection: $settings.dataRetention.telemetryDays) {
                Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }
        }
        .disabled(!editable.contains(.retention))
    }
}

private struct AddContactRow: View {
    let add: (EmergencyContact) -> Void
    @State private var name = ""
    @State private var phone = ""
    var body: some View {
        HStack {
            TextField("Name", text: $name)
            TextField("+15551234567", text: $phone).keyboardType(.phonePad)
            Button("Add") {
                add(EmergencyContact(name: name, phoneNumber: phone))
                name = ""
                phone = ""
            }
            .disabled(name.isEmpty || phone.range(of: #"^\+[1-9]\d{6,14}$"#, options: .regularExpression) == nil)
        }
    }
}

struct TimePicker: View {
    let title: String
    @Binding var hhmm: String
    let timeZone: String

    var body: some View {
        DatePicker(title, selection: Binding(get: { date }, set: { hhmm = format($0) }), displayedComponents: .hourAndMinute)
            .environment(\.timeZone, TimeZone(identifier: timeZone) ?? .current)
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: timeZone) ?? .current
        return c
    }

    private var date: Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        return calendar.date(bySettingHour: parts.first ?? 22, minute: parts.last ?? 0, second: 0, of: Date()) ?? Date()
    }

    private func format(_ d: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

enum NightScheduleHelper {
    static func nextWake(_ s: SleepSchedule) -> Date? {
        guard let tz = TimeZone(identifier: s.timeZone) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let parts = s.wakeTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return cal.nextDate(after: Date(), matching: DateComponents(hour: parts[0], minute: parts[1]), matchingPolicy: .nextTime)
    }
}
