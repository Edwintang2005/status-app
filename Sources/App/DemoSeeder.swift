#if DEBUG
import AVFoundation
import UIKit

/// Fills the real App Group store with plausible content for App Store screenshots.
/// Runs only when `REDSTRING_DEMO=1` (see `DemoMode`); reseeds every launch with fixed ids.
enum DemoSeeder {
    static func seedIfRequested() {
        guard DemoMode.isActive else { return }

        let store = SharedStore.shared
        let now = Date()

        store.pairing = PairingInfo(role: .owner,
                                    zoneName: AppConfig.coupleZoneName,
                                    zoneOwnerName: "__defaultOwner__",
                                    pairedAt: now.addingTimeInterval(-86_400 * 90))

        // Wipe any previous demo history so reseeding can't duplicate.
        MomentIndex.shared.clear()

        var moments: [Moment] = []

        func add(_ id: String, kind: Moment.Kind, caption: String, from sam: Bool,
                 age: TimeInterval, seen: Bool, image: UIImage? = nil,
                 duration: TimeInterval = 0, waveform: [Double] = []) {
            if let image {
                try? MomentStore.shared.write(image, id: id)
            }
            moments.append(Moment(id: id,
                                  kind: kind,
                                  caption: caption,
                                  senderName: sam ? "Sam" : "Alex",
                                  sentAt: now.addingTimeInterval(-age),
                                  fromMe: !sam,
                                  seen: seen,
                                  duration: duration,
                                  waveform: waveform))
        }

        add("demo-heart", kind: .drawing, caption: "for you 💌", from: true,
            age: 2 * 3_600, seen: false, image: heartDoodle())
        add("demo-voice", kind: .voice, caption: "on my way!", from: true,
            age: 5 * 3_600, seen: false,
            duration: 9, waveform: speechWaveform())
        writeVoiceClip(id: "demo-voice", duration: 9)
        add("demo-coffee", kind: .photo, caption: "morning ☕️", from: true,
            age: 26 * 3_600, seen: true, image: coffeePhoto())
        add("demo-us", kind: .drawing, caption: "us 🥰", from: false,
            age: 2 * 86_400, seen: true, image: usDoodle())
        add("demo-sky", kind: .photo, caption: "look at this sky", from: true,
            age: 3 * 86_400, seen: true, image: skyPhoto())
        add("demo-goodnight", kind: .drawing, caption: "goodnight 🌙", from: true,
            age: 4 * 86_400, seen: true, image: goodnightDoodle())
        add("demo-beach", kind: .photo, caption: "wish you were here", from: false,
            age: 6 * 86_400, seen: true, image: beachPhoto())
        add("demo-dinner", kind: .drawing, caption: "dinner at 7?", from: false,
            age: 8 * 86_400, seen: true, image: dinnerDoodle())

        store.record(moments)

        store.mutate { snapshot in
            snapshot.isPaired = true
            snapshot.lastSyncedAt = now.addingTimeInterval(-120)
            snapshot.mine = StatusPayload(emoji: "🎨",
                                          message: "making something for you",
                                          displayName: "Alex",
                                          updatedAt: now.addingTimeInterval(-45 * 60),
                                          nudgeCount: 12,
                                          lastNudgeAt: now.addingTimeInterval(-9_000))
            snapshot.theirs = StatusPayload(emoji: "🥰",
                                            message: "missing you",
                                            displayName: "Sam",
                                            updatedAt: now.addingTimeInterval(-18 * 60),
                                            nudgeCount: 14,
                                            lastNudgeAt: now.addingTimeInterval(-7_200))
            snapshot.lastSeenPartnerNudgeCount = 14
            snapshot.lastNudgeSentAt = nil
            snapshot.lastNotifiedMomentID = "demo-heart"
        }
    }

    // MARK: - Drawn content

    private static let side: CGFloat = 1024

    private static func canvas(_ draw: (CGContext, CGRect) -> Void) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            draw(context.cgContext, rect)
        }
    }

    private static func fill(_ context: CGContext, _ rect: CGRect,
                             top: UIColor, bottom: UIColor) {
        let colors = [top.cgColor, bottom.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX, y: 0),
                                   end: CGPoint(x: rect.midX, y: rect.maxY),
                                   options: [])
    }

    private static func handFont(_ size: CGFloat) -> UIFont {
        UIFont(name: "BradleyHandITCTT-Bold", size: size)
            ?? UIFont(name: "Noteworthy-Bold", size: size)
            ?? .systemFont(ofSize: size, weight: .bold)
    }

    private static func write(_ text: String, at point: CGPoint, size: CGFloat,
                              color: UIColor, angle: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: handFont(size), .foregroundColor: color,
        ]
        let rendered = NSAttributedString(string: text, attributes: attributes)
        let bounds = rendered.size()
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        rendered.draw(at: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2))
        context.restoreGState()
    }

    /// A hand-drawn-looking stroke: the path plus slight jitter, rounded caps.
    private static func stroke(_ context: CGContext, _ path: UIBezierPath,
                               color: UIColor, width: CGFloat) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path.cgPath)
        context.strokePath()
        context.restoreGState()
    }

    private static func heartPath(center: CGPoint, size: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let s = size / 2
        path.move(to: CGPoint(x: center.x, y: center.y + s * 0.9))
        path.addCurve(to: CGPoint(x: center.x - s, y: center.y - s * 0.3),
                      controlPoint1: CGPoint(x: center.x - s * 0.9, y: center.y + s * 0.35),
                      controlPoint2: CGPoint(x: center.x - s, y: center.y + s * 0.1))
        path.addArc(withCenter: CGPoint(x: center.x - s * 0.5, y: center.y - s * 0.3),
                    radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(withCenter: CGPoint(x: center.x + s * 0.5, y: center.y - s * 0.3),
                    radius: s * 0.5, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: center.x, y: center.y + s * 0.9),
                      controlPoint1: CGPoint(x: center.x + s, y: center.y + s * 0.1),
                      controlPoint2: CGPoint(x: center.x + s * 0.9, y: center.y + s * 0.35))
        return path
    }

    private static func heartDoodle() -> UIImage {
        canvas { context, rect in
            UIColor(red: 1.00, green: 0.88, blue: 0.90, alpha: 1).setFill()
            context.fill(rect)
            let red = UIColor(red: 0.92, green: 0.26, blue: 0.38, alpha: 1)
            stroke(context, heartPath(center: CGPoint(x: 512, y: 430), size: 460),
                   color: red, width: 26)
            stroke(context, heartPath(center: CGPoint(x: 200, y: 200), size: 110),
                   color: red.withAlphaComponent(0.6), width: 14)
            stroke(context, heartPath(center: CGPoint(x: 830, y: 260), size: 80),
                   color: red.withAlphaComponent(0.5), width: 12)
            write("for you", at: CGPoint(x: 512, y: 820), size: 120,
                  color: UIColor(red: 0.35, green: 0.18, blue: 0.22, alpha: 1),
                  angle: -0.05)
        }
    }

    private static func usDoodle() -> UIImage {
        canvas { context, rect in
            UIColor(red: 1.00, green: 0.96, blue: 0.90, alpha: 1).setFill()
            context.fill(rect)
            let ink = UIColor(red: 0.24, green: 0.22, blue: 0.28, alpha: 1)

            func figure(x: CGFloat, headTint: UIColor) {
                let head = UIBezierPath(ovalIn: CGRect(x: x - 60, y: 330, width: 120, height: 120))
                stroke(context, head, color: ink, width: 18)
                context.setFillColor(headTint.cgColor)
                context.fillEllipse(in: CGRect(x: x - 52, y: 338, width: 104, height: 104))
                let body = UIBezierPath()
                body.move(to: CGPoint(x: x, y: 450))
                body.addLine(to: CGPoint(x: x, y: 660))
                body.move(to: CGPoint(x: x, y: 660))
                body.addLine(to: CGPoint(x: x - 55, y: 800))
                body.move(to: CGPoint(x: x, y: 660))
                body.addLine(to: CGPoint(x: x + 55, y: 800))
                stroke(context, body, color: ink, width: 18)
            }
            figure(x: 380, headTint: UIColor(red: 0.98, green: 0.80, blue: 0.72, alpha: 1))
            figure(x: 644, headTint: UIColor(red: 0.94, green: 0.72, blue: 0.78, alpha: 1))

            // Held hands.
            let arms = UIBezierPath()
            arms.move(to: CGPoint(x: 380, y: 520))
            arms.addQuadCurve(to: CGPoint(x: 512, y: 590), controlPoint: CGPoint(x: 445, y: 560))
            arms.addQuadCurve(to: CGPoint(x: 644, y: 520), controlPoint: CGPoint(x: 579, y: 560))
            stroke(context, arms, color: ink, width: 18)

            let red = UIColor(red: 0.92, green: 0.26, blue: 0.38, alpha: 1)
            stroke(context, heartPath(center: CGPoint(x: 512, y: 210), size: 120),
                   color: red, width: 16)
            write("us", at: CGPoint(x: 512, y: 900), size: 110, color: ink, angle: 0.04)
        }
    }

    private static func goodnightDoodle() -> UIImage {
        canvas { context, rect in
            UIColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1).setFill()
            context.fill(rect)
            let chalk = UIColor(white: 0.96, alpha: 1)

            // Crescent moon: full circle minus an offset bite.
            let moon = UIBezierPath(arcCenter: CGPoint(x: 512, y: 400), radius: 190,
                                    startAngle: 0.6, endAngle: 0.6 + .pi * 1.55,
                                    clockwise: true)
            moon.addQuadCurve(to: CGPoint(x: moon.currentPoint.x, y: moon.currentPoint.y),
                              controlPoint: CGPoint(x: 512, y: 400))
            stroke(context, UIBezierPath(arcCenter: CGPoint(x: 512, y: 400), radius: 190,
                                         startAngle: 1.0, endAngle: 1.0 + .pi * 1.5,
                                         clockwise: true),
                   color: chalk, width: 22)

            for (x, y, r) in [(230, 190, 5), (320, 620, 7), (780, 210, 6),
                              (840, 560, 5), (170, 430, 6), (700, 700, 5)] {
                context.setFillColor(chalk.withAlphaComponent(0.9).cgColor)
                context.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y),
                                               width: CGFloat(r * 2), height: CGFloat(r * 2)))
            }
            write("goodnight", at: CGPoint(x: 512, y: 850), size: 110, color: chalk,
                  angle: -0.03)
        }
    }

    private static func dinnerDoodle() -> UIImage {
        canvas { context, rect in
            UIColor(red: 0.87, green: 0.92, blue: 1.00, alpha: 1).setFill()
            context.fill(rect)
            let ink = UIColor(red: 0.24, green: 0.22, blue: 0.28, alpha: 1)
            stroke(context,
                   UIBezierPath(ovalIn: CGRect(x: 262, y: 230, width: 500, height: 500)),
                   color: ink, width: 20)
            stroke(context,
                   UIBezierPath(ovalIn: CGRect(x: 342, y: 310, width: 340, height: 340)),
                   color: ink.withAlphaComponent(0.5), width: 10)
            // Spaghetti swirl.
            let swirl = UIBezierPath()
            swirl.move(to: CGPoint(x: 430, y: 480))
            for turn in stride(from: 0.0, through: 4.4, by: 0.15) {
                let radius = 20 + turn * 22
                let point = CGPoint(x: 512 + cos(turn * 1.9) * radius,
                                    y: 480 + sin(turn * 1.9) * radius * 0.8)
                swirl.addLine(to: point)
            }
            stroke(context, swirl, color: UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1),
                   width: 16)
            write("dinner at 7?", at: CGPoint(x: 512, y: 880), size: 100, color: ink)
        }
    }

    private static func skyPhoto() -> UIImage {
        canvas { context, rect in
            fill(context, rect,
                 top: UIColor(red: 0.28, green: 0.32, blue: 0.58, alpha: 1),
                 bottom: UIColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1))
            // Sun low on the horizon.
            context.setFillColor(UIColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 420, y: 600, width: 184, height: 184))
            // Layered hills.
            for (height, alpha) in [(760.0, 0.75), (830.0, 0.9)] {
                let hills = UIBezierPath()
                hills.move(to: CGPoint(x: 0, y: side))
                hills.addLine(to: CGPoint(x: 0, y: height))
                hills.addQuadCurve(to: CGPoint(x: 512, y: height + 40),
                                   controlPoint: CGPoint(x: 250, y: height - 70))
                hills.addQuadCurve(to: CGPoint(x: side, y: height - 30),
                                   controlPoint: CGPoint(x: 800, y: height + 90))
                hills.addLine(to: CGPoint(x: side, y: side))
                hills.close()
                context.setFillColor(UIColor(red: 0.16, green: 0.14, blue: 0.26,
                                             alpha: alpha).cgColor)
                context.addPath(hills.cgPath)
                context.fillPath()
            }
            // A few birds.
            let ink = UIColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 0.8)
            for (x, y, s) in [(300, 280, 22.0), (370, 320, 16.0), (680, 240, 19.0)] {
                let bird = UIBezierPath()
                bird.move(to: CGPoint(x: CGFloat(x) - s, y: CGFloat(y)))
                bird.addQuadCurve(to: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                  controlPoint: CGPoint(x: CGFloat(x) - s / 2, y: CGFloat(y) - s))
                bird.addQuadCurve(to: CGPoint(x: CGFloat(x) + s, y: CGFloat(y)),
                                  controlPoint: CGPoint(x: CGFloat(x) + s / 2, y: CGFloat(y) - s))
                stroke(context, bird, color: ink, width: 6)
            }
        }
    }

    private static func coffeePhoto() -> UIImage {
        canvas { context, rect in
            // Warm wooden table.
            fill(context, rect,
                 top: UIColor(red: 0.55, green: 0.38, blue: 0.26, alpha: 1),
                 bottom: UIColor(red: 0.42, green: 0.28, blue: 0.19, alpha: 1))
            context.setFillColor(UIColor(white: 0, alpha: 0.08).cgColor)
            for x in stride(from: CGFloat(0), to: side, by: 146) {
                context.fill(CGRect(x: x, y: 0, width: 5, height: side))
            }
            // Saucer, cup, coffee.
            context.setFillColor(UIColor(white: 0.94, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 187, y: 187, width: 650, height: 650))
            context.setFillColor(UIColor(white: 1.0, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 262, y: 262, width: 500, height: 500))
            context.setFillColor(UIColor(red: 0.44, green: 0.27, blue: 0.16, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 302, y: 302, width: 420, height: 420))
            // Latte-art heart in milk foam.
            let foam = UIColor(red: 0.94, green: 0.85, blue: 0.72, alpha: 1)
            foam.setFill()
            let heart = heartPath(center: CGPoint(x: 512, y: 505), size: 220)
            context.addPath(heart.cgPath)
            context.fillPath()
        }
    }

    private static func beachPhoto() -> UIImage {
        canvas { context, rect in
            fill(context, CGRect(x: 0, y: 0, width: side, height: 470),
                 top: UIColor(red: 0.53, green: 0.79, blue: 0.94, alpha: 1),
                 bottom: UIColor(red: 0.72, green: 0.89, blue: 0.97, alpha: 1))
            context.setFillColor(UIColor(red: 0.22, green: 0.60, blue: 0.74, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 470, width: side, height: 240))
            fill(context, CGRect(x: 0, y: 710, width: side, height: side - 710),
                 top: UIColor(red: 0.96, green: 0.87, blue: 0.70, alpha: 1),
                 bottom: UIColor(red: 0.91, green: 0.79, blue: 0.60, alpha: 1))
            // Sun and a light haze line where sea meets sky.
            context.setFillColor(UIColor(red: 1.0, green: 0.95, blue: 0.75, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 700, y: 120, width: 150, height: 150))
            context.setFillColor(UIColor(white: 1, alpha: 0.5).cgColor)
            context.fill(CGRect(x: 0, y: 462, width: side, height: 10))
            // Foam arcs on the sand.
            for (y, alpha) in [(700.0, 0.9), (660.0, 0.45)] {
                let foam = UIBezierPath()
                foam.move(to: CGPoint(x: 0, y: y + 20))
                foam.addQuadCurve(to: CGPoint(x: 512, y: y),
                                  controlPoint: CGPoint(x: 256, y: y + 45))
                foam.addQuadCurve(to: CGPoint(x: side, y: y + 25),
                                  controlPoint: CGPoint(x: 780, y: y - 35))
                stroke(context, foam, color: UIColor(white: 1, alpha: alpha), width: 12)
            }
        }
    }

    // MARK: - Voice

    /// Envelope that reads as a short spoken sentence: bursts with gaps.
    private static func speechWaveform() -> [Double] {
        let pattern: [Double] = [
            0.15, 0.42, 0.66, 0.58, 0.71, 0.35, 0.12, 0.08,
            0.31, 0.62, 0.79, 0.66, 0.44, 0.52, 0.23, 0.10,
            0.27, 0.55, 0.72, 0.83, 0.61, 0.38, 0.49, 0.29,
            0.11, 0.36, 0.64, 0.57, 0.40, 0.18, 0.09, 0.05,
        ]
        return pattern
    }

    /// A soft synthesized chime, so the demo memo is genuinely playable.
    private static func writeVoiceClip(id: String, duration: Double) {
        guard let url = MomentStore.shared.audioURL(for: id) else { return }
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleRate * duration))
        else { return }

        let frames = Int(sampleRate * duration)
        buffer.frameLength = AVAudioFrameCount(frames)
        let notes: [Double] = [523.25, 659.25, 783.99, 659.25]  // C5 E5 G5 E5
        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            let note = notes[min(Int(time / (duration / Double(notes.count))), notes.count - 1)]
            let envelope = 0.25 * max(0, 1 - (time.truncatingRemainder(dividingBy: duration / 4))
                                        / (duration / 4))
            buffer.floatChannelData?[0][frame] = Float(sin(2 * .pi * note * time) * envelope)
        }
        try? file.write(from: buffer)
    }
}
#endif
