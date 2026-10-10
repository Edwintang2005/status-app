import ImageIO
import UIKit

/// The photo widget's picture: the full JPEG downsampled to the tile's pixel
/// size — the 512 px square thumbnail drew soft on a medium or large tile —
/// or the thumbnail while the full copy isn't on disk.
enum WidgetPhoto {
    static func image(for moment: Moment, pointSize: CGSize) -> UIImage? {
        let traitScale = UITraitCollection.current.displayScale
        let scale = traitScale > 0 ? traitScale : 3
        let target = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
        if let url = MomentStore.shared.imageURL(for: moment.id), let image = downsampled(url, filling: target) {
            return image
        }
        return MomentStore.shared.thumbnail(for: moment.id)
    }

    /// Reads the header for the size, then decodes straight to `maxPixel`:
    /// never a full decode, under the extension's memory ceiling.
    private static func downsampled(_ url: URL, filling target: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        // EXIF orientations 5–8 turn the frame a quarter: the tile fills the upright one.
        let quarterTurned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        let upright = quarterTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        guard let maxPixel = WidgetPhotoSize.maxPixel(image: upright, filling: target) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
