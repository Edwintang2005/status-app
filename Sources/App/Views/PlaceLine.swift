import CoreLocation
import os
import SwiftUI

/// "Surry Hills, Sydney" under a gallery picture whose full file carries GPS
/// tags (`PhotoLocation`); the gallery runs the look (`PlaceNames`) and shows
/// this only once there's an answer, so a moment without a place has no line at all.
struct PlaceLine: View {
    let place: String

    var body: some View {
        Label(place, systemImage: "mappin.and.ellipse")
            .font(Theme.rounded(12))
            .foregroundStyle(Theme.mutedText)
            .lineLimit(1)
            .accessibilityLabel(String(localized: "Taken in \(place)"))
    }
}

/// Names a moment's place from its full copy: older moments, blank-canvas
/// doodles and declined permissions have none. Looks go one at a time — the
/// geocoder fails a second request while one runs, and pages are built in
/// pairs — and are kept for the launch by area (`PhotoLocation.areaKey`), so a
/// run of photos from one spot asks once. A failed look (offline) isn't kept:
/// the next visit asks again.
@MainActor
final class PlaceNames {
    static let shared = PlaceNames()

    private var byArea: [String: String] = [:]
    /// Moments whose full file has no place: never worth reading again.
    private var placeless: Set<String> = []
    private let geocoder = CLGeocoder()
    private var queue: Task<Void, Never>?

    func name(for id: String) async -> String? {
        guard !placeless.contains(id), let url = MomentStore.shared.imageURL(for: id),
              MomentStore.shared.hasImage(for: id) else { return nil }
        guard let location = await Task.detached(priority: .utility, operation: { PhotoLocation.read(from: url) }).value else {
            placeless.insert(id)
            return nil
        }
        if let known = byArea[location.areaKey] { return known }
        let previous = queue
        let look = Task { @MainActor [self] in
            await previous?.value
            // A page swiped past while it waited: skipped, so the one stopped on isn't behind it.
            guard !Task.isCancelled else { return nil as String? }
            return await lookUp(location)
        }
        queue = Task { _ = await look.value }
        return await withTaskCancellationHandler { await look.value } onCancel: { look.cancel() }
    }

    private func lookUp(_ location: PhotoLocation) async -> String? {
        if let known = byArea[location.areaKey] { return known }
        let point = CLLocation(latitude: location.latitude, longitude: location.longitude)
        do {
            guard let placemark = try await geocoder.reverseGeocodeLocation(point).first,
                  let name = Self.wording(placemark) else { return nil }
            byArea[location.areaKey] = name
            return name
        } catch {
            Logger(subsystem: AppConfig.appGroupID, category: "PlaceNames")
                .error("Couldn't name a moment's place: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The neighbourhood and its town, or the nearest thing to one; the country
    /// only when it isn't this phone's.
    private static func wording(_ placemark: CLPlacemark) -> String? {
        let local = placemark.subLocality ?? placemark.locality ?? placemark.administrativeArea ?? placemark.name
        guard let local else { return placemark.country }
        var parts = [local]
        if let town = placemark.locality, town != local {
            parts.append(town)
        } else if let country = placemark.country, placemark.isoCountryCode != Locale.current.region?.identifier {
            parts.append(country)
        }
        return parts.joined(separator: ", ")
    }
}
