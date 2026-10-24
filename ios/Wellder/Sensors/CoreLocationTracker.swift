import CoreLocation
import Foundation
import MonitoringCore
import SharedModels

/// Battery-conscious location tracking:
///  - balanced: standard updates at ~100 m accuracy with a 50 m distance filter, paused
///    automatically by iOS when stationary, plus significant-change and visit monitoring so iOS
///    relaunches the app after it is terminated.
///  - lowPower (night / low battery): significant-change + visits only (cell/Wi-Fi based, ~500 m).
/// Continuous GPS in every background state is NOT possible or attempted: iOS suspends updates,
/// and a force-quit app only comes back via significant-change/visit events.
@MainActor
final class CoreLocationTracker: NSObject, LocationTracking, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onSample: (@MainActor (TelemetrySample.Location) -> Void)?
    var onAuthorizationChange: (@MainActor (CLAuthorizationStatus) -> Void)?
    private(set) var mode: LocationMode = .off

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }
    var isAlways: Bool { manager.authorizationStatus == .authorizedAlways }
    var isAuthorized: Bool { isAlways || manager.authorizationStatus == .authorizedWhenInUse }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization() // iOS shows the upgrade prompt later, at its discretion
        default: break
        }
    }

    func apply(mode: LocationMode) {
        self.mode = mode
        guard isAuthorized else { return }
        switch mode {
        case .off:
            manager.stopUpdatingLocation()
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        case .balanced:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
            if isAlways {
                manager.allowsBackgroundLocationUpdates = true
                manager.showsBackgroundLocationIndicator = true // the Alpha can always see that sharing is active
            }
            manager.startUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        case .lowPower:
            manager.stopUpdatingLocation()
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
        apply(mode: mode)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let source: LocationSource = self.mode == .lowPower ? .significantChange : .standard
        for l in locations where l.horizontalAccuracy >= 0 {
            onSample?(.init(timestamp: l.timestamp, latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                            horizontalAccuracy: l.horizontalAccuracy, source: source))
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let at = visit.departureDate == .distantFuture ? visit.arrivalDate : visit.departureDate
        guard at != .distantPast else { return }
        onSample?(.init(timestamp: at, latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
                        horizontalAccuracy: visit.horizontalAccuracy, source: .visit))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; denial is reported via authorization changes.
    }
}
