import MonitoringCore
import SharedModels
import SwiftUI

/// "Measured 12 min ago" with an explicit stale/unavailable state. Never shows a stale value as live.
public struct FreshnessLabel: View {
    let timestamp: Date?
    let freshness: Freshness
    let now: Date

    public init(timestamp: Date?, freshness: Freshness, now: Date) {
        self.timestamp = timestamp
        self.freshness = freshness
        self.now = now
    }

    public var body: some View {
        Group {
            switch freshness {
            case .unavailable:
                Label("No data", systemImage: "questionmark.circle")
            case .stale:
                Label("Old: \(RelativeTime.short(timestamp ?? now, now: now))", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
            case .current, .recent:
                Text("Measured \(RelativeTime.short(timestamp ?? now, now: now))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A metric value with its freshness. Stale values are de-emphasised; unavailable shows "—".
public struct MetricTile: View {
    let title: String
    let systemImage: String
    let value: String?
    let unit: String?
    let timestamp: Date?
    let freshness: Freshness
    let now: Date

    public init(title: String, systemImage: String, value: String?, unit: String? = nil, timestamp: Date?, freshness: Freshness, now: Date) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.unit = unit
        self.timestamp = timestamp
        self.freshness = freshness
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(freshness == .unavailable ? "—" : (value ?? "—"))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(freshness == .stale ? .secondary : .primary)
                if let unit, freshness != .unavailable { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
            }
            FreshnessLabel(timestamp: timestamp, freshness: freshness, now: now)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// Persistent banner shown whenever simulated data is involved.
public struct SimulationBanner: View {
    let text: String
    public init(_ text: String = "Simulation mode — data shown is synthetic, not from real sensors") { self.text = text }
    public var body: some View {
        Label(text, systemImage: "testtube.2")
            .font(.footnote.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.purple.opacity(0.18))
            .foregroundStyle(.purple)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Large, high-contrast primary action, sized for users with limited dexterity.
public struct BigButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    public init(_ title: String, systemImage: String, tint: Color = .accentColor, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
    }
}

public struct InitialsAvatar: View {
    let name: String
    let level: StatusLevel?
    public init(name: String, level: StatusLevel? = nil) {
        self.name = name
        self.level = level
    }
    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
    public var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.headline)
            .frame(width: 48, height: 48)
            .background((level?.color ?? .accentColor).opacity(0.2), in: Circle())
            .overlay(Circle().strokeBorder(level?.color ?? .clear, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

public struct ErrorBanner: View {
    let message: String
    let retry: (() -> Void)?
    public init(_ message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }
    public var body: some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle").font(.callout)
            Spacer()
            if let retry { Button("Retry", action: retry).buttonStyle(.bordered) }
        }
        .padding()
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Wording shown wherever monitoring results appear, so nobody reads them as a guarantee.
public enum MonitoringDisclaimer {
    public static let short = "Wellder can miss emergencies. It is not a medical device or an emergency service."
    public static let long = """
    Wellder shares information from an iPhone and Apple Watch when iOS allows it to run. Readings can be delayed or \
    missing — for example when the phone is off, out of battery, offline, or not carried. Heart rate is measured \
    periodically, not continuously. Fall detection in this app is experimental. Never rely on Wellder alone in an emergency: call emergency services.
    """
}
