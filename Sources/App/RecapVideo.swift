import AVFoundation
import CoreImage
import UIKit

/// Draws a `RecapPlan` into a silent portrait H.264 video, entirely on the
/// phone: each slide is drawn once, then eased in with a slow zoom and a short
/// crossfade from the one before — written slide by slide, so it can resume.
enum RecapVideo {
    static let size = CGSize(width: 1080, height: 1920)
    private static let fps: Int32 = 30
    private static let fade: TimeInterval = 0.35
    private static let zoom: CGFloat = 0.05
    /// GPU-backed: each frame is the slide scaled and blended over the last,
    /// which on the CPU took about 0.1 s a frame — minutes for a year.
    private static let renderer = Renderer()

    /// Thread-safe by Core Image's contract, whether or not this SDK marks it `Sendable`.
    private final class Renderer: @unchecked Sendable {
        let context = CIContext(options: [.cacheIntermediates: false])
    }

    struct Words: Sendable {
        var myName: String
        var partnerName: String
        /// "2026", or a "Nov 2025 – Nov 2026" span for the twelve-month run.
        var title: String
        var closing: String
        /// The content filter as it stood when the recap was asked for.
        var filterEnabled: Bool
    }

    enum Failure: LocalizedError {
        case writer(String)

        var errorDescription: String? {
            switch self {
            case .writer(let reason): String(localized: "The video couldn't be made: \(reason)")
            }
        }
    }

    /// Writes each slide to its own file in `directory` (`slide-<n>.mp4`, or a
    /// `.skip` marker for a collage none of whose pictures came), passing over
    /// those already there, then joins them into `url`. So a run cut off part-way
    /// — the app left the screen and the encoder went — resumes at the first
    /// slide missing. Cancellable; a slide half-written is removed.
    /// `picture` hands over each slide's image as it's ready (`RecapMedia`);
    /// `drawn` shows each slide as it's made, for the screen to preview.
    static func render(_ plan: RecapPlan, words: Words, in directory: URL, to url: URL,
                       picture: @escaping @Sendable (Moment) async -> UIImage?,
                       drawn: @escaping @Sendable (CGImage, Int) -> Void = { _, _ in },
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let fileManager = FileManager.default
        func segment(_ index: Int) -> URL { directory.appendingPathComponent("slide-\(index).mp4") }
        func skipped(_ index: Int) -> URL { directory.appendingPathComponent("slide-\(index).skip") }
        let count = plan.slides.count
        let resumeAt = (0..<count).first {
            !fileManager.fileExists(atPath: segment($0).path) && !fileManager.fileExists(atPath: skipped($0).path)
        } ?? count
        // The slide the next one fades in from, drawn again on a resume.
        let fadeFrom = (0..<resumeAt).last { fileManager.fileExists(atPath: segment($0).path) }

        let totalFrames = max(1, plan.slides.reduce(0) { $0 + frames(for: $1) })
        var frame = 0
        var previous: CGImage?
        var segments: [URL] = []
        for (index, slide) in plan.slides.enumerated() {
            let length = frames(for: slide)
            if index < resumeAt {
                guard fileManager.fileExists(atPath: segment(index).path) else { continue }
                segments.append(segment(index))
                frame += length
                if index == fadeFrom {
                    previous = await image(for: slide, plan: plan, words: words, picture: picture)
                    if let previous { drawn(previous, index) }
                }
                continue
            }
            progress(Double(frame) / Double(totalFrames))
            guard let current = await image(for: slide, plan: plan, words: words, picture: picture) else {
                try Task.checkCancellation()
                fileManager.createFile(atPath: skipped(index).path, contents: nil)
                continue
            }
            try Task.checkCancellation()
            drawn(current, index)
            let start = frame
            try await write(current, after: previous, frames: length, to: segment(index)) { written in
                if written % 15 == 0 { progress(Double(start + written) / Double(totalFrames)) }
            }
            segments.append(segment(index))
            frame += length
            previous = current
        }
        try await join(segments, to: url)
        progress(1)
    }

    private static func frames(for slide: RecapPlan.Slide) -> Int {
        Int((slide.duration * Double(fps)).rounded())
    }

    /// `nil` for a collage none of whose pictures could be had.
    private static func image(for slide: RecapPlan.Slide, plan: RecapPlan, words: Words,
                              picture: @Sendable (Moment) async -> UIImage?) async -> CGImage? {
        var photos: [(Moment, UIImage)] = []
        if case .pictures(let moments) = slide {
            for moment in moments {
                if let image = await picture(moment), image.size.width > 0 { photos.append((moment, image)) }
            }
        }
        return draw(slide, photos: photos, plan: plan, words: words)
    }

    /// One slide's file, written beside its name and moved in only once complete.
    private static func write(_ current: CGImage, after previous: CGImage?, frames: Int, to url: URL,
                              progress: (Int) -> Void) async throws {
        // Its own name per run: a cancelled run unwinding after a resumed one
        // started on the same slide removes only its own.
        let partial = url.deletingPathExtension()
            .appendingPathExtension("\(UUID().uuidString.prefix(8)).part.mp4")
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
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
            // IOSurface-backed, so the GPU draws straight into the encoder's buffers.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
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
                try? FileManager.default.removeItem(at: partial)
            }
        }

        let duration = Double(frames) / Double(fps)
        let currentImage = CIImage(cgImage: current)
        let previousImage = previous.map { CIImage(cgImage: $0) }
        for step in 0..<frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                // A writer that failed between appends is never ready again.
                guard writer.status == .writing else {
                    throw Failure.writer(writer.error?.localizedDescription ?? "the encoder stopped")
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writer("no buffer") }
            let t = Double(step) / Double(fps)
            compose(into: buffer, current: currentImage, progress: t / duration,
                    previous: previousImage, fadeIn: min(1, t / fade))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(step), timescale: fps)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "couldn't add a frame")
            }
            progress(step + 1)
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writer(writer.error?.localizedDescription ?? "couldn't finish")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        finished = true
    }

    /// The slides end to end, copied as they are: no re-encoding, so it's quick.
    private static func join(_ segments: [URL], to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.writer("no video track")
        }
        // The composition only points into these; released early, the export fails (-12780).
        let assets = segments.map { AVURLAsset(url: $0) }
        defer { withExtendedLifetime(assets) {} }
        var cursor = CMTime.zero
        for asset in assets {
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await source.load(.timeRange)
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.writer("couldn't join the slides")
        }
        // Its own name, moved in once whole: a cancelled run's export (pre-iOS 18
        // ignores cancellation) mustn't write over a resumed run's.
        let joined = url.deletingLastPathComponent().appendingPathComponent("joined-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: joined) }
        if #available(iOS 18, *) {
            try await export.export(to: joined, as: .mp4)
        } else {
            export.outputURL = joined
            export.outputFileType = .mp4
            await export.export()
            guard export.status == .completed else {
                throw Failure.writer(export.error?.localizedDescription ?? "couldn't join the slides")
            }
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: joined, to: url)
    }

    // MARK: - Frames

    /// The slide zooms in slowly across its run; the one before stays at its
    /// last zoom as it fades out under it.
    private static func compose(into buffer: CVPixelBuffer, current: CIImage, progress: Double,
                                previous: CIImage?, fadeIn: Double) {
        var frame = zoomed(current, progress)
        if let previous, fadeIn < 1 {
            frame = frame
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(fadeIn))])
                .composited(over: zoomed(previous, 1))
        }
        let canvas = CGRect(origin: .zero, size: size)
        renderer.context.render(frame.cropped(to: canvas), to: buffer, bounds: canvas,
                                colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// Scaled about the centre, so the edges grow out of the frame evenly.
    private static func zoomed(_ image: CIImage, _ progress: Double) -> CIImage {
        let scale = 1 + zoom * CGFloat(min(max(progress, 0), 1))
        return image.transformed(by: CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                       tx: size.width * (1 - scale) / 2,
                                                       ty: size.height * (1 - scale) / 2))
    }

    // MARK: - Slides

    private static let cream = UIColor(red: 0.973, green: 0.945, blue: 0.894, alpha: 1)
    private static let crimson = UIColor(red: 0.78, green: 0.27, blue: 0.32, alpha: 1)
    private static let crimsonText = UIColor(red: 0.55, green: 0.14, blue: 0.20, alpha: 1)
    private static let warm = UIColor(red: 0.92, green: 0.53, blue: 0.25, alpha: 1)
    private static let steel = UIColor(red: 0.44, green: 0.66, blue: 0.86, alpha: 1)
    private static let muted = UIColor(red: 0.42, green: 0.37, blue: 0.36, alpha: 1)

    private static func draw(_ slide: RecapPlan.Slide, photos: [(Moment, UIImage)],
                             plan: RecapPlan, words: Words) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        // Pictures with neither their media nor a thumbnail drop out; a collage with none is skipped.
        if case .pictures = slide, photos.isEmpty { return nil }
        return renderer.image { context in
            let cg = context.cgContext
            switch slide {
            case .opening: opening(plan: plan, words: words, in: cg)
            case .pictures: collage(photos, words: words, in: cg)
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
                             width: CGFloat = 900, centerX: CGFloat = size.width / 2, lines: Int = 0) -> CGFloat {
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
        attributed.draw(with: CGRect(x: centerX - width / 2, y: top, width: width, height: height),
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

    /// Matted prints, each tipped a little and filled edge to edge, its caption
    /// (or sender) beneath; the run's dates close the slide.
    private static func collage(_ photos: [(Moment, UIImage)], words: Words, in context: CGContext) {
        backdrop(in: context)
        let tilts: [CGFloat] = [-1.6, 1.3, 1.1, -1.2]
        let mat: CGFloat = 14
        for (index, (cell, (moment, image))) in zip(RecapPlan.cells(for: photos.count, in: size), photos).enumerated() {
            context.saveGState()
            context.translateBy(x: cell.midX, y: cell.midY)
            context.rotate(by: tilts[index % tilts.count] * .pi / 180)
            context.translateBy(x: -cell.midX, y: -cell.midY)

            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 14), blur: 40,
                              color: UIColor.black.withAlphaComponent(0.22).cgColor)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: cell, cornerRadius: 30).fill()
            context.restoreGState()

            let frame = cell.insetBy(dx: mat, dy: mat)
            UIBezierPath(roundedRect: frame, cornerRadius: 18).addClip()
            // Photos fill their print; a drawing is shown whole, its words often at the edge.
            let fit = min(frame.width / image.size.width, frame.height / image.size.height)
            let scale = moment.kind == .drawing ? fit : max(frame.width / image.size.width, frame.height / image.size.height)
            let fill = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: frame.midX - fill.width / 2, y: frame.midY - fill.height / 2,
                                  width: fill.width, height: fill.height))
            context.restoreGState()

            let who = moment.fromMe ? words.myName
                : moment.displaySenderName(fallback: words.partnerName, filterEnabled: words.filterEnabled)
            text(moment.displayCaption(filterEnabled: words.filterEnabled) ?? who, font(34, .semibold), .black, top: cell.maxY + 10,
                 width: cell.width - 20, centerX: cell.midX, lines: 1)
        }

        guard let start = photos.first?.0.sentAt, let end = photos.last?.0.sentAt else { return }
        let span = Calendar.current.isDate(start, inSameDayAs: end)
            ? start.formatted(.dateTime.day().month(.wide))
            : (start..<max(start, end)).formatted(.interval.day().month(.wide))
        text(span, font(46, .semibold), crimsonText, top: size.height - 260, lines: 1)
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
