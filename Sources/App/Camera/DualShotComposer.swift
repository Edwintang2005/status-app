import ImageIO
import UIKit

/// What the camera hands back: one photo, or both cameras' still apart.
enum CameraShot {
    case photo(UIImage)
    case both(DualShot)
}

/// A two-camera shot before it's flattened, so the composer can move the inset.
/// Both at scale 1, the main at the size a moment keeps.
struct DualShot: Sendable {
    var main: UIImage
    var inset: UIImage
    var placement: DualShotLayout.Placement
}

/// Decodes a two-camera shot and draws it into one picture, the inset where
/// `DualShotLayout` puts it. Off the main actor, and at the size a moment
/// keeps, so neither 12 MP original is ever held whole.
enum DualShotComposer {
    static func prepare(main: Data, inset: Data, placement: DualShotLayout.Placement) -> DualShot? {
        guard let base = decoded(main, maxPixel: MomentStore.fullMaxDimension) else { return nil }
        // The inset's long side is under half the main's short side.
        let side = CGFloat(min(base.width, base.height))
        guard let small = decoded(inset, maxPixel: side * 0.6) else { return nil }
        return DualShot(main: UIImage(cgImage: base), inset: UIImage(cgImage: small), placement: placement)
    }

    static func compose(_ shot: DualShot) -> UIImage {
        let size = shot.main.size
        let rect = DualShotLayout.insetRect(main: size, inset: shot.inset.size, placement: shot.placement)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            shot.main.draw(in: CGRect(origin: .zero, size: size))
            let outline = UIBezierPath(roundedRect: rect, cornerRadius: DualShotLayout.cornerRadius(inset: rect.size))
            context.cgContext.saveGState()
            outline.addClip()
            shot.inset.draw(in: rect)
            context.cgContext.restoreGState()
            UIColor.white.setStroke()
            outline.lineWidth = DualShotLayout.borderWidth(main: size)
            outline.stroke()
        }
    }

    /// Level as shot: the capture's rotation may sit in the EXIF orientation.
    private static func decoded(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
