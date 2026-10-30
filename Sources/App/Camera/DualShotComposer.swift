import ImageIO
import UIKit

/// Draws a two-camera shot: the main photo, the other camera inset where
/// `DualShotLayout` puts it. Off the main actor — two decodes and a draw — and
/// at the size a moment keeps, so neither 12 MP original is ever held whole.
enum DualShotComposer {
    static func compose(main: Data, inset: Data, corner: DualShotLayout.Corner) -> UIImage? {
        guard let base = decoded(main, maxPixel: MomentStore.fullMaxDimension) else { return nil }
        let size = CGSize(width: base.width, height: base.height)
        // The inset's long side is under half the main's short side.
        guard let small = decoded(inset, maxPixel: min(size.width, size.height) * 0.6) else { return nil }
        let rect = DualShotLayout.insetRect(main: size,
                                            inset: CGSize(width: small.width, height: small.height),
                                            corner: corner)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: base).draw(in: CGRect(origin: .zero, size: size))
            let outline = UIBezierPath(roundedRect: rect, cornerRadius: DualShotLayout.cornerRadius(inset: rect.size))
            context.cgContext.saveGState()
            outline.addClip()
            UIImage(cgImage: small).draw(in: rect)
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
