import AVFoundation
import UIKit

/// Draws a `RecapPlan` into a silent portrait H.264 video, entirely on the
/// phone: each slide is drawn once, then eased in with a slow zoom and a short
/// crossfade from the one before.
enum RecapVideo {
    static let size = CGSize(width: 1080, height: 1920)
    private static let fps: Int32 = 30
    private static let fade: TimeInterval = 0.35
    private static let zoom: CGFloat = 0.05

    struct Words: Sendable {
        var myName: String
        var partnerName: String
        /// "2026", or a "Nov 2025 – Nov 2026" span for the twelve-month run.
        var title: String
        var closing: String
    }

    enum Failure: LocalizedError {
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .writer(let reason): String(localized: "The video couldn't be made: \(reason)")
            }
        }
    }

    /// Cancellable: the task's cancellation stops it and removes the file.
    static func render(_ plan: RecapPlan, words: Words, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw Failure.writer("no video track") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? "couldn't start")
        }
        writer.startSession(atSourceTime: .zero)

        var finished = false
        defer {
            if !finished {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }

        let totalFrames = max(1, Int((plan.duration * Double(fps)).rounded()))
        var frame = 0
        var previous: CGImage?
        for (index, slide) in plan.slides.enumerated() {
            guard let current = draw(slide, plan: plan, words: words) else { continue }
            let frames = Int((slide.duration * Double(fps)).rounded())
            for step in 0..<frames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw Failure.writer("no buffer") }
                let t = Double(step) / Double(fps)
                compose(into: buffer, current: current, progress: t / slide.duration,
                        previous: index > 0 ? previous : nil, fadeIn: min(1, t / fade))
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "couldn't add a frame")
                }
                frame += 1
                if frame % 15 == 0 { progress(Double(frame) / Double(totalFrames)) }
            }
            previous = current
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "couldn't finish")
        }
        finished = true
        progress(1)
    }

    // MARK: - Frames

    /// The slide zooms in slowly across its run; the one before stays at its
    /// last zoom as it fades out under it.
    private static func compose(into buffer: CVPixelBuffer, current: CGImage, progress: Double,
                                previous: CGImage?, fadeIn: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.interpolationQuality = .high
        if let previous, fadeIn < 1 {
            context.draw(previous, in: zoomed(1))
            context.setAlpha(CGFloat(fadeIn))
        }
        context.draw(current, in: zoomed(progress))
    }

    private static func zoomed(_ progress: Double) -> CGRect {
        let scale = 1 + zoom * CGFloat(min(max(progress, 0), 1))
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: - Slides

    private static let cream = UIColor(red: 0.973, green: 0.945, blue: 0.894, alpha: 1)
    private static let crimson = UIColor(red: 0.78, green: 0.27, blue: 0.32, alpha: 1)
    private static let crimsonText = UIColor(red: 0.55, green: 0.14, blue: 0.20, alpha: 1)
    private static let warm = UIColor(red: 0.92, green: 0.53, blue: 0.25, alpha: 1)
    private static let steel = UIColor(red: 0.44, green: 0.66, blue: 0.86, alpha: 1)
    private static let muted = UIColor(red: 0.42, green: 0.37, blue: 0.36, alpha: 1)

    private static func draw(_ slide: RecapPlan.Slide, plan: RecapPlan, words: Words) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var photo: UIImage?
        if case .picture(let moment) = slide {
            // Its media never came back: the slide is skipped, not drawn empty.
            guard let image = MomentStore.shared.image(for: moment.id), image.size.width > 0 else { return nil }
            photo = image
        }
        return renderer.image { context in
            let cg = context.cgContext
            switch slide {
            case .opening: opening(plan: plan, words: words, in: cg)
            case .picture(let moment): if let photo { picture(moment, image: photo, words: words, in: cg) }
            case .status(let entry): status(entry, words: words, in: cg)
            case .closing: closing(words: words, in: cg)
            }
        }.cgImage
    }

    /// The app's backdrop: cream, crimson from the top corner, orange from the bottom.
    private static func backdrop(in context: CGContext) {
        cream.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        glow(crimson.withAlphaComponent(0.40), at: .zero, radius: 1300, in: context)
        glow(warm.withAlphaComponent(0.32), at: CGPoint(x: size.width, y: size.height), radius: 1200, in: context)
        glow(steel.withAlphaComponent(0.20), at: CGPoint(x: size.width * 0.95, y: size.height * 0.18),
             radius: 650, in: context)
    }

    private static func glow(_ color: UIColor, at center: CGPoint, radius: CGFloat, in context: CGContext) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
    }

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: size)
    }

    /// Centred text in a band starting at `top`; returns where it ended.
    @discardableResult
    private static func text(_ string: String, _ font: UIFont, _ color: UIColor, top: CGFloat,
                             width: CGFloat = 900, lines: Int = 0) -> CGFloat {
        guard !string.isEmpty else { return top }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let limit = lines > 0 ? font.lineHeight * CGFloat(lines) + 2 : .greatestFiniteMagnitude
        let bounds = attributed.boundingRect(with: CGSize(width: width, height: limit),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = min(ceil(bounds.height), limit)
        attributed.draw(with: CGRect(x: (size.width - width) / 2, y: top, width: width, height: height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        return top + height
    }

    private static func logo(at top: CGFloat, side: CGFloat) -> CGFloat {
        guard let logo = UIImage(named: "Logo") else { return top }
        let rect = CGRect(x: (size.width - side) / 2, y: top, width: side, height: side)
        UIBezierPath(roundedRect: rect, cornerRadius: side * 0.22).addClip()
        logo.draw(in: rect)
        return rect.maxY
    }

    private static func opening(plan: RecapPlan, words: Words, in context: CGContext) {
        backdrop(in: context)
        context.saveGState()
        var y = logo(at: 430, side: 300)
        context.restoreGState()
        if case .year = plan.period {
            y = text(String(localized: "Our"), font(72, .semibold), crimsonText, top: y + 80)
            y = text(words.title, font(190, .heavy), crimsonText, top: y, lines: 1)
        } else {
            y = text(String(localized: "Our year"), font(150, .heavy), crimsonText, top: y + 80, lines: 1)
            y = text(words.title, font(56, .semibold), crimsonText, top: y + 10, lines: 1)
        }
        y = text("\(words.myName) & \(words.partnerName)", font(58, .semibold), .black, top: y + 40, lines: 2)
        let moments = String(localized: "\(plan.momentCount) moments")
        let statuses = String(localized: "\(plan.statusCount) statuses")
        text("\(moments) · \(statuses)", font(46, .medium), muted, top: y + 30)
    }

    private static func picture(_ moment: Moment, image: UIImage, words: Words, in context: CGContext) {
        backdrop(in: context)
        let caption = moment.displayCaption
        let maxSide = CGSize(width: 920, height: caption == nil ? 1320 : 1180)
        let scale = min(maxSide.width / image.size.width, maxSide.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let mat: CGFloat = 22
        let card = CGRect(x: (size.width - fitted.width) / 2 - mat, y: 230 + (maxSide.height - fitted.height) / 2,
                          width: fitted.width + mat * 2, height: fitted.height + mat * 2)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 18), blur: 50,
                          color: UIColor.black.withAlphaComponent(0.22).cgColor)
        UIColor.white.setFill()
        UIBezierPath(roundedRect: card, cornerRadius: 44).fill()
        context.restoreGState()

        context.saveGState()
        let photo = card.insetBy(dx: mat, dy: mat)
        UIBezierPath(roundedRect: photo, cornerRadius: 26).addClip()
        image.draw(in: photo)
        context.restoreGState()

        var y = card.maxY + 60
        if let caption { y = text(caption, font(58, .semibold), .black, top: y, lines: 3) + 18 }
        let who = moment.fromMe ? words.myName : moment.displaySenderName(fallback: words.partnerName)
        let when = moment.sentAt.formatted(.dateTime.day().month(.wide))
        text(who.isEmpty ? when : "\(who) · \(when)", font(42, .medium), muted, top: y, lines: 1)
    }

    private static func status(_ entry: StatusHistoryEntry, words: Words, in context: CGContext) {
        // Crimson into orange: the one slide that stops the run of photos.
        let colors = [crimson.cgColor, warm.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
        let darkened = UIColor.black.withAlphaComponent(0.18)
        darkened.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        var y: CGFloat = 520
        if !entry.emoji.isEmpty { y = text(entry.emoji, .systemFont(ofSize: 260), .white, top: y, lines: 1) + 40 }
        y = text(entry.message, font(80, .bold), .white, top: y, lines: 5)
        let who = entry.fromMe ? words.myName : words.partnerName
        let when = entry.at.formatted(.dateTime.day().month(.wide))
        text(who.isEmpty ? when : "\(who) · \(when)", font(44, .medium), UIColor.white.withAlphaComponent(0.9),
             top: y + 60, lines: 1)
    }

    private static func closing(words: Words, in context: CGContext) {
        backdrop(in: context)
        context.saveGState()
        let y = logo(at: 640, side: 260)
        context.restoreGState()
        let end = text(words.closing, font(84, .bold), crimsonText, top: y + 90, lines: 3)
        text(String(localized: "Made with \(AppConfig.appName)"), font(40, .medium), muted, top: end + 50)
    }
}
