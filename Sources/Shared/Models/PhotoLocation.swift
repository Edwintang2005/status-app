import Foundation
import ImageIO

/// Where a photo was taken, carried in the full JPEG's own GPS tags — the file
/// iCloud already encrypts — so it needs no record field, and "Save to Photos"
/// files it under its place. Thumbnails never carry it.
struct PhotoLocation: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    /// Metres; what the GPS tags call horizontal positioning error.
    var accuracy: Double?
    var at: Date?

    /// `nil` off the globe: a partner's file can claim anything.
    init?(latitude: Double, longitude: Double, altitude: Double? = nil, accuracy: Double? = nil, at: Date? = nil) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude.flatMap { $0.isFinite ? $0 : nil }
        self.accuracy = accuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.at = at
    }

    /// The place a composed moment goes with: a blank-canvas doodle has none;
    /// a photo (doodled on or not) keeps its own — a library pick's tags, or the
    /// fix taken at the shutter — and a camera shot that had no fix yet takes one
    /// that arrived since.
    static func forSend(hasPhoto: Bool, photo: PhotoLocation?, fromCamera: Bool,
                        cameraFix: () -> PhotoLocation?) -> PhotoLocation? {
        guard hasPhoto else { return nil }
        return photo ?? (fromCamera ? cameraFix() : nil)
    }

    /// About 100 m square: photos from one spot share a place name, and one look.
    var areaKey: String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    // MARK: - GPS tags

    init?(gps: [CFString: Any]) {
        guard let latitude = Self.number(gps[kCGImagePropertyGPSLatitude]),
              let longitude = Self.number(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        let below = Self.number(gps[kCGImagePropertyGPSAltitudeRef]) == 1
        var at: Date?
        if let day = gps[kCGImagePropertyGPSDateStamp] as? String,
           let time = gps[kCGImagePropertyGPSTimeStamp] as? String {
            at = Self.stampFormatter.date(from: "\(day) \(time.prefix(8))")
        }
        self.init(latitude: south ? -abs(latitude) : abs(latitude),
                  longitude: west ? -abs(longitude) : abs(longitude),
                  altitude: Self.number(gps[kCGImagePropertyGPSAltitude]).map { below ? -abs($0) : abs($0) },
                  accuracy: Self.number(gps[kCGImagePropertyGPSHPositioningError]),
                  at: at)
    }

    var gps: [CFString: Any] {
        var tags: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(latitude),
            kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(longitude),
            kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
        ]
        if let altitude {
            tags[kCGImagePropertyGPSAltitude] = abs(altitude)
            tags[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
        }
        if let accuracy { tags[kCGImagePropertyGPSHPositioningError] = accuracy }
        // Written through XMP, where the time is one ISO stamp that fills the
        // date too: a bare "HH:mm:ss" is misread, and a separate date stamp,
        // set after it, overwrites the time.
        if let at { tags[kCGImagePropertyGPSTimeStamp] = at.formatted(.iso8601) }
        return tags
    }

    // MARK: - Files

    static func read(from data: Data) -> PhotoLocation? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(read)
    }

    static func read(from url: URL) -> PhotoLocation? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(read)
    }

    private static func read(_ source: CGImageSource) -> PhotoLocation? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] else { return nil }
        return PhotoLocation(gps: gps)
    }

    /// `jpeg` with these GPS tags merged in, the pixels copied, not re-encoded.
    static func stamped(_ image: Data, with location: PhotoLocation) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let type = CGImageSourceGetType(source) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        for (key, value) in location.gps {
            guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary,
                                                               key, value as CFTypeRef) else { return nil }
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata,
                                        kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return nil }
        return output as Data
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }

    /// GPS stamps are UTC: "yyyy:MM:dd" and "HH:mm:ss".
    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }
}
