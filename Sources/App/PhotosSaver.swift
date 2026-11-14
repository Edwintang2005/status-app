import CoreLocation
import Photos

/// Save to Photos, for the gallery's pictures and the recap's video: add-only
/// access, which never reads the library and asks more gently.
enum PhotosSaver {
    enum Item {
        case photo(Data)
        case photoFile(URL)
        case video(URL)
    }

    /// - Parameters:
    ///   - createdAt: filed under this date, as Photos would its own shot.
    ///   - location: and this place.
    /// - Returns: `.saved`, or `.failed` with the words to show.
    static func save(_ item: Item, createdAt: Date? = nil, location: CLLocation? = nil) async -> SaveState {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .failed(String(localized: "Allow photo access in Settings to save."))
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                switch item {
                case .photo(let data): request.addResource(with: .photo, data: data, options: nil)
                case .photoFile(let url): request.addResource(with: .photo, fileURL: url, options: nil)
                case .video(let url): request.addResource(with: .video, fileURL: url, options: nil)
                }
                if let createdAt { request.creationDate = createdAt }
                if let location { request.location = location }
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
