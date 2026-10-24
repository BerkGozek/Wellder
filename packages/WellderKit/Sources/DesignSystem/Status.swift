import MonitoringCore
import SharedModels
import SwiftUI

public extension StatusLevel {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .gray: .gray
        }
    }

    /// Distinct glyph per level so status never relies on color alone (color-blind users, VoiceOver).
    var symbol: String {
        switch self {
        case .green: "checkmark.circle.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .red: "exclamationmark.octagon.fill"
        case .gray: "questionmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .green: "No current concern"
        case .yellow: "Attention recommended"
        case .red: "Urgent alert"
        case .gray: "Data unavailable"
        }
    }
}

public struct StatusBadge: View {
    let level: StatusLevel
    let compact: Bool

    public init(_ level: StatusLevel, compact: Bool = false) {
        self.level = level
        self.compact = compact
    }

    public var body: some View {
        Label {
            if !compact { Text(level.label).font(.subheadline.weight(.semibold)) }
        } icon: {
            Image(systemName: level.symbol).foregroundStyle(level.color)
        }
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.vertical, compact ? 0 : 5)
        .background(compact ? Color.clear : level.color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(level.label)")
    }
}

public extension AlertSeverity {
    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

public extension MonitoringState {
    var title: String {
        switch self {
        case .active: "Sharing on"
        case .reduced: "Sharing limited"
        case .night: "Night mode"
        case .temporarilyDisconnected: "Offline"
        case .permissionsUnavailable: "Permissions needed"
        case .dataStale: "Not recently updated"
        case .disabled: "Sharing off"
        }
    }

    var symbol: String {
        switch self {
        case .active: "dot.radiowaves.left.and.right"
        case .reduced: "dot.radiowaves.right"
        case .night: "moon.fill"
        case .temporarilyDisconnected: "wifi.slash"
        case .permissionsUnavailable: "lock.fill"
        case .dataStale: "clock.badge.exclamationmark"
        case .disabled: "pause.circle"
        }
    }

    var tint: Color {
        switch self {
        case .active: .green
        case .reduced, .night: .indigo
        case .temporarilyDisconnected, .dataStale: .orange
        case .permissionsUnavailable, .disabled: .gray
        }
    }
}
