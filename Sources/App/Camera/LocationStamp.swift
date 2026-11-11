import CoreLocation
import os

/// Where the camera is, for the shot's GPS tags (`PhotoLocation`). Asked for the
/// first time the camera opens; runs from then until the shot has a fix (or the
/// composer closes), never through a whole doodle. Only a fix from since the
/// camera opened counts — an old one may be somewhere else. Declined, or no fix
/// yet, a shot simply carries no place.
@MainActor
final class LocationStamp: NSObject {
    static let shared = LocationStamp()

    /// Coarser than this, it's a guess, not where the photo was taken.
    private static let roughest: Double = 100

    private let manager = CLLocationManager()
    private var latest: PhotoLocation?
    private var startedAt = Date.distantFuture
    private var running = false
    /// A shot is waiting on a fix: the first good one ends the run.
    private var stopsAtNextFix = false

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var current: PhotoLocation? {
        guard let latest, let at = latest.at, at >= startedAt.wholeSeconds else { return nil }
        return latest
    }

    /// The shot's place, if there's one yet; either way the run ends at the first good fix.
    func takeForShot() -> PhotoLocation? {
        if let current {
            stop()
            return current
        }
        stopsAtNextFix = true
        return nil
    }

    func start() {
        running = true
        stopsAtNextFix = false
        startedAt = Date()
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: break
        }
    }

    func stop() {
        running = false
        stopsAtNextFix = false
        manager.stopUpdatingLocation()
    }

    fileprivate func authorizationChanged() {
        guard running else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: manager.stopUpdatingLocation()
        }
    }

    fileprivate func found(_ location: PhotoLocation) {
        guard (location.accuracy ?? .infinity) <= Self.roughest else { return }
        latest = location
        if stopsAtNextFix, current != nil { stop() }
    }
}

extension LocationStamp: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in LocationStamp.shared.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }),
              let location = PhotoLocation(latitude: fix.coordinate.latitude,
                                           longitude: fix.coordinate.longitude,
                                           altitude: fix.verticalAccuracy >= 0 ? fix.altitude : nil,
                                           accuracy: fix.horizontalAccuracy,
                                           at: fix.timestamp.wholeSeconds) else { return }
        Task { @MainActor in LocationStamp.shared.found(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Logger(subsystem: AppConfig.appGroupID, category: "LocationStamp")
            .error("No location fix: \(error.localizedDescription, privacy: .public)")
    }
}
