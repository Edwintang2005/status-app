import CloudKit
import ImageIO
import UIKit
import XCTest

/// A photo's place travels in the full JPEG's GPS tags (`PhotoLocation`).
final class PhotoLocationTests: XCTestCase {
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    func testTheTagsRoundTripEveryHemisphere() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        for (latitude, longitude) in [(-33.8886, 151.2094), (51.5072, -0.1276), (40.7128, -74.006), (-22.9, -43.2)] {
            let place = try XCTUnwrap(PhotoLocation(latitude: latitude, longitude: longitude,
                                                    altitude: -4, accuracy: 12, at: at))
            let stamped = try XCTUnwrap(PhotoLocation.stamped(jpeg(), with: place))
            let read = try XCTUnwrap(PhotoLocation.read(from: stamped))
            XCTAssertEqual(read.latitude, latitude, accuracy: 0.0001)
            XCTAssertEqual(read.longitude, longitude, accuracy: 0.0001)
            XCTAssertEqual(try XCTUnwrap(read.altitude), -4, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(read.accuracy), 12, accuracy: 0.01)
            XCTAssertEqual(read.at, at)
        }
    }

    func testStampingKeepsThePicture() throws {
        let original = jpeg()
        let place = try XCTUnwrap(PhotoLocation(latitude: 1, longitude: 2))
        let stamped = try XCTUnwrap(PhotoLocation.stamped(original, with: place))
        let image = try XCTUnwrap(UIImage(data: stamped))
        XCTAssertEqual(image.size, CGSize(width: 40, height: 30))
    }

    func testAPlainPictureHasNoPlace() {
        XCTAssertNil(PhotoLocation.read(from: jpeg()))
    }

    /// A partner's file can claim anything: nothing off the globe, nor "null island".
    func testImpossiblePlacesAreRefused() {
        XCTAssertNil(PhotoLocation(latitude: 91, longitude: 0))
        XCTAssertNil(PhotoLocation(latitude: 0, longitude: 181))
        XCTAssertNil(PhotoLocation(latitude: .nan, longitude: 3))
        XCTAssertNil(PhotoLocation(latitude: 0, longitude: 0))
        XCTAssertNil(PhotoLocation(gps: [:]))
    }

    /// Only the full copy carries it: the thumbnail every tile and widget shows doesn't.
    func testTheStoreStampsTheFullCopyOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MomentStore(directory: directory)
        let place = try XCTUnwrap(PhotoLocation(latitude: -33.9, longitude: 151.2))
        let image = try XCTUnwrap(UIImage(data: jpeg()))
        try store.write(image, id: "m", location: place)
        XCTAssertEqual(try XCTUnwrap(PhotoLocation.read(from: XCTUnwrap(store.imageURL(for: "m")))).latitude,
                       -33.9, accuracy: 0.0001)
        XCTAssertNil(PhotoLocation.read(from: try XCTUnwrap(store.thumbURL(for: "m"))))
        try store.write(image, id: "n")
        XCTAssertNil(PhotoLocation.read(from: try XCTUnwrap(store.imageURL(for: "n"))))
    }
}

extension PhotoLocationTests {
    /// What a camera writes: numbers as numbers, a fractional time, lower-case refs.
    func testReadsCameraStyleTags() throws {
        let place = try XCTUnwrap(PhotoLocation(gps: [
            kCGImagePropertyGPSLatitude: NSNumber(value: 33.8915), kCGImagePropertyGPSLatitudeRef: "s",
            kCGImagePropertyGPSLongitude: NSNumber(value: 151.2767), kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: NSNumber(value: 12.5), kCGImagePropertyGPSAltitudeRef: NSNumber(value: 1),
            kCGImagePropertyGPSDateStamp: "2026:09:21", kCGImagePropertyGPSTimeStamp: "14:13:20.50",
        ]))
        XCTAssertEqual(place.latitude, -33.8915, accuracy: 0.00001)
        XCTAssertEqual(place.longitude, 151.2767, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(place.altitude), -12.5, accuracy: 0.001, "below sea level")
        XCTAssertEqual(place.at, Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// A partner's build can write anything into the tags.
    func testHostileTagsAreRefusedOrIgnored() {
        XCTAssertNil(PhotoLocation(gps: [kCGImagePropertyGPSLatitude: "north", kCGImagePropertyGPSLongitude: "2"]))
        XCTAssertNil(PhotoLocation(gps: [kCGImagePropertyGPSLatitude: "1e309", kCGImagePropertyGPSLongitude: "2"]))
        XCTAssertNil(PhotoLocation(gps: [kCGImagePropertyGPSLatitude: [1, 2], kCGImagePropertyGPSLongitude: 2]))
        let place = PhotoLocation(gps: [kCGImagePropertyGPSLatitude: 10, kCGImagePropertyGPSLongitude: 20,
                                        kCGImagePropertyGPSHPositioningError: -5,
                                        kCGImagePropertyGPSDateStamp: "garbage", kCGImagePropertyGPSTimeStamp: "x"])
        XCTAssertNotNil(place)
        XCTAssertNil(place?.accuracy, "a negative error is no error")
        XCTAssertNil(place?.at)
    }

    func testAComposedMomentsPlace() throws {
        let shot = try XCTUnwrap(PhotoLocation(latitude: 1, longitude: 2))
        let late = try XCTUnwrap(PhotoLocation(latitude: 3, longitude: 4))
        XCTAssertNil(PhotoLocation.forSend(hasPhoto: false, photo: shot, fromCamera: true) { late },
                     "a blank-canvas doodle has none")
        XCTAssertEqual(PhotoLocation.forSend(hasPhoto: true, photo: shot, fromCamera: true) { late }, shot,
                       "the shot's own, doodled on or not")
        XCTAssertEqual(PhotoLocation.forSend(hasPhoto: true, photo: nil, fromCamera: true) { late }, late,
                       "a fix that came after the shutter")
        XCTAssertNil(PhotoLocation.forSend(hasPhoto: true, photo: nil, fromCamera: false) { late },
                     "a library pick without tags isn't given where you are")
    }

    func testNearbyPhotosShareAnArea() throws {
        let a = try XCTUnwrap(PhotoLocation(latitude: -33.89121, longitude: 151.27671))
        let b = try XCTUnwrap(PhotoLocation(latitude: -33.89139, longitude: 151.27668))
        let c = try XCTUnwrap(PhotoLocation(latitude: -33.8800, longitude: 151.2767))
        XCTAssertEqual(a.areaKey, b.areaKey)
        XCTAssertNotEqual(a.areaKey, c.areaKey)
    }

    /// The share sheet reads at the stored size, upright, never decoding the original whole.
    func testAnImportIsDownsizedAndUpright() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        // Orientation 6: stored landscape, shown portrait, as a phone held upright writes it.
        CGImageDestinationAddImage(destination, try XCTUnwrap(wide.cgImage),
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try XCTUnwrap(MomentStore.imported(data as Data))
        XCTAssertEqual(image.size, CGSize(width: 1536, height: 2048))
        XCTAssertEqual(image.imageOrientation, .up)
    }
}

/// The share sheet's rules (`ShareIntake`).
final class ShareIntakeTests: XCTestCase {
    func testTheSheetSendsOnlyWhenLinkedAndSetUp() {
        XCTAssertNil(ShareIntake.blocked(termsAccepted: true, paired: true, partnerLeft: false))
        XCTAssertEqual(ShareIntake.blocked(termsAccepted: false, paired: true, partnerLeft: false), .terms)
        XCTAssertEqual(ShareIntake.blocked(termsAccepted: true, paired: false, partnerLeft: false), .unlinked)
        XCTAssertEqual(ShareIntake.blocked(termsAccepted: true, paired: true, partnerLeft: true), .partnerLeft)
    }

    func testAClaimLapsesAndOldOnesAreDropped() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let claims = ShareIntake.claiming("a", in: ["old": now.addingTimeInterval(-AppConfig.shareUploadHold - 1)], now: now)
        XCTAssertEqual(Array(claims.keys), ["a"], "a lapsed claim goes when another is made")
        XCTAssertTrue(ShareIntake.isClaimed("a", in: claims, now: now.addingTimeInterval(30)))
        XCTAssertFalse(ShareIntake.isClaimed("a", in: claims, now: now.addingTimeInterval(AppConfig.shareUploadHold)))
        XCTAssertFalse(ShareIntake.isClaimed("b", in: claims, now: now))
        XCTAssertFalse(ShareIntake.isClaimed("a", in: claims, now: now.addingTimeInterval(-3600)),
                       "a claim from the future is a clock that moved")
        XCTAssertTrue(ShareIntake.anyClaimed(in: claims, now: now))
        XCTAssertFalse(ShareIntake.anyClaimed(in: claims, now: now.addingTimeInterval(AppConfig.shareUploadHold)))
    }

    /// Timing out isn't failing: the upload runs on in the sheet, so its claim stands.
    func testOnlyARealFailureGivesTheSendBack() {
        XCTAssertFalse(ShareIntake.releasesClaim(after: CancellationError()))
        XCTAssertTrue(ShareIntake.releasesClaim(after: CKError(.networkUnavailable)))
    }
}
