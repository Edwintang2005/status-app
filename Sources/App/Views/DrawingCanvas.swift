import Observation
import PencilKit
import SwiftUI

/// Owns the `PKCanvasView` so the palette can retarget the tool and the composer
/// can rasterise. Held across view updates — recreating the canvas drops strokes.
@MainActor
@Observable
final class DrawingController {
    @ObservationIgnored let canvas = PKCanvasView()
    @ObservationIgnored private let sheetDragBlocker = SheetDragBlocker()
    @ObservationIgnored private let fillTap = FillTap()

    static let palette: [Color] = [
        .black,
        Color(red: 0.96, green: 0.44, blue: 0.56),
        Color(red: 0.44, green: 0.38, blue: 0.92),
        Color(red: 0.30, green: 0.80, blue: 0.70),
        Color(red: 1.00, green: 0.78, blue: 0.25),
        .white,
    ]
    static let widths: [CGFloat] = [4, 10, 22]

    /// Backdrops for photo-less doodles. `isDark` drives the automatic ink
    /// flip, so charcoal never means black-on-black.
    struct Backdrop: Identifiable, Equatable {
        let color: Color
        let isDark: Bool
        var id: String { "\(color)" }

        init(color: Color, isDark: Bool) {
            self.color = color
            self.isDark = isDark
        }

        /// For a hand-picked colour: perceived luminance, not a plain average —
        /// green reads far lighter than blue at the same value.
        init(color: Color) {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
            self.init(color: color, isDark: luminance < 0.5)
        }
    }

    static let backdrops: [Backdrop] = [
        Backdrop(color: .white, isDark: false),
        Backdrop(color: Color(red: 1.00, green: 0.96, blue: 0.90), isDark: false),
        Backdrop(color: Color(red: 1.00, green: 0.88, blue: 0.90), isDark: false),
        Backdrop(color: Color(red: 0.87, green: 0.92, blue: 1.00), isDark: false),
        Backdrop(color: Color(red: 0.86, green: 0.96, blue: 0.92), isDark: false),
        Backdrop(color: Color(red: 0.91, green: 0.88, blue: 1.00), isDark: false),
        Backdrop(color: Color(red: 0.17, green: 0.17, blue: 0.19), isDark: true),
    ]

    var backdrop: Backdrop = backdrops[0] {
        didSet {
            guard backdrop != oldValue else { return }
            // Flip ink only between the two extremes — a pink pen stays pink.
            if backdrop.isDark, color == .black { color = .white }
            if !backdrop.isDark, color == .white { color = .black }
        }
    }

    enum Tool { case pen, eraser, fill }

    var color: Color = .black {
        didSet {
            // Picking a colour exits eraser mode — otherwise it silently does nothing.
            if tool == .eraser { tool = .pen }
            applyTool()
        }
    }

    /// The backdrop as a plain colour, for binding a `ColorPicker` to.
    var backdropColor: Color {
        get { backdrop.color }
        set { backdrop = Backdrop(color: newValue) }
    }
    var width: CGFloat = 10 { didSet { applyTool() } }
    var tool: Tool = .pen { didSet { applyTool() } }

    /// Observable mirror of `canvas.drawing.strokes.count` — views must read
    /// this, not the `@ObservationIgnored` canvas.
    var strokeCount = 0

    init() {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Without this, finger drawing is ignored on Pencil-capable devices.
        canvas.drawingPolicy = .anyInput
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        // PKCanvasView is a scroll view: a safe-area or keyboard inset would
        // shift the strokes off the photo underneath, and off the export.
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.addGestureRecognizer(sheetDragBlocker.recognizer)
        canvas.addGestureRecognizer(fillTap.recognizer)
        // PencilKit inks invert near-black/white in dark mode; the backdrop is an
        // explicit swatch and `Backdrop.isDark` flips ink by hand, so take colours literally.
        canvas.overrideUserInterfaceStyle = .light
        fillTap.onTap = { [weak self] point in self?.fill(at: point) }
        applyTool()
    }

    private func applyTool() {
        canvas.tool = tool == .eraser
            ? PKEraserTool(.bitmap)
            : PKInkingTool(.pen, color: UIColor(color), width: width)
        canvas.drawingGestureRecognizer.isEnabled = tool != .fill
        fillTap.recognizer.isEnabled = tool == .fill
    }

    /// The pen never uses this ink, so a fill is told from a line by it: only
    /// lines bound a fill, and a filled area can be filled again in another colour.
    private static let fillInk = PKInk.InkType.monoline

    /// Fills the area around `point` that the lines enclose (the whole canvas
    /// if none do, small gaps closed), under every line; on a line, recolours
    /// that line. One undo step.
    func fill(at point: CGPoint) {
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        guard width > 0, height > 0 else { return }
        let strokes = canvas.drawing.strokes
        let fills = strokes.filter { $0.ink.inkType == Self.fillInk }
        let lines = strokes.filter { $0.ink.inkType != Self.fillInk }
        guard let coverage = Self.coverage(of: PKDrawing(strokes: lines), width: width, height: height) else { return }
        if FillPlan.isLine(coverage: coverage, width: width, height: height, at: point) {
            recolourLine(at: point, fills: fills, lines: lines)
            return
        }
        guard let passes = FillPlan.passes(coverage: coverage, width: width, height: height, tap: point)
        else { return }

        let ink = PKInk(Self.fillInk, color: UIColor(color))
        let size = CGSize(width: FillPlan.strokeSize, height: FillPlan.strokeSize)
        let added = passes.map { path in
            let points = path.enumerated().map { index, location in
                PKStrokePoint(location: location, timeOffset: TimeInterval(index) * 0.001, size: size,
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        // After earlier fills, so a refill shows; before every line, so lines stay on top.
        replaceDrawing(with: PKDrawing(strokes: fills + added + lines))
    }

    /// A point of grace around a line, for a fingertip just off its edge.
    private static let lineSlop: CGFloat = 2

    private func recolourLine(at point: CGPoint, fills: [PKStroke], lines: [PKStroke]) {
        // Points along each line's centre, in canvas space, leaving out what the eraser cut.
        let centres = lines.map { stroke in
            stroke.path.interpolatedPoints(by: .distance(1)).compactMap { sample -> (point: CGPoint, radius: CGFloat)? in
                if let mask = stroke.mask, !mask.contains(sample.location) { return nil }
                return (sample.location.applying(stroke.transform), max(sample.size.width, sample.size.height) / 2)
            }
        }
        guard let index = FillPlan.lineHit(centres, at: point, slop: Self.lineSlop) else { return }
        let colour = UIColor(color)
        guard !lines[index].ink.color.isEqual(colour) else { return }
        var recoloured = lines
        recoloured[index].ink = PKInk(lines[index].ink.inkType, color: colour)
        replaceDrawing(with: PKDrawing(strokes: fills + recoloured))
    }

    /// Setting `drawing` isn't an undo step of its own; registered on the
    /// canvas's manager so it takes turns with strokes.
    private func replaceDrawing(with drawing: PKDrawing) {
        let previous = canvas.drawing
        canvas.drawing = drawing
        strokeCount = drawing.strokes.count
        canvas.undoManager?.registerUndo(withTarget: self) { $0.replaceDrawing(with: previous) }
    }

    /// The lines' alpha at one cell per point, top row first.
    private static func coverage(of drawing: PKDrawing, width: Int, height: Int) -> [UInt8]? {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(x: 0, y: 0, width: width, height: height), scale: 1)
        }
        guard let cgImage = image?.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = context.data
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
    }

    func undo() {
        canvas.undoManager?.undo()
        strokeCount = canvas.drawing.strokes.count
    }

    func clear() {
        canvas.drawing = PKDrawing()
        strokeCount = 0
    }

    /// Flattens photo (if any) and strokes into one square image at the stored
    /// full size, off the main thread: a 2048-pixel composite takes a while.
    func render(size: CGFloat = MomentStore.fullMaxDimension, over photo: UIImage?) async -> UIImage {
        // The composer shows the centred square of the canvas; should the canvas
        // ever be laid out wider or taller, export that square, not a stretch of the whole.
        let bounds = Self.centredSquare(in: canvas.bounds)
        let drawing = canvas.drawing
        let ground = backdrop.color
        return await Task.detached(priority: .userInitiated) {
            Self.composite(drawing, bounds: bounds, backdrop: ground, photo: photo, size: size)
        }.value
    }

    private nonisolated static func composite(_ drawing: PKDrawing, bounds: CGRect, backdrop: Color,
                                              photo: UIImage?, size: CGFloat) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor(backdrop).setFill()
            context.fill(rect)
            photo?.drawAspectFill(in: rect)

            guard bounds.width > 0 else { return }
            // Rasterise at export resolution to avoid a blurry upscale; pinned
            // light because `PKDrawing.image` reads current traits and inverts ink in dark mode.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                drawing
                    .image(from: bounds, scale: size / bounds.width)
                    .draw(in: rect)
            }
        }
    }

    nonisolated static func centredSquare(in bounds: CGRect) -> CGRect {
        let side = min(bounds.width, bounds.height)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }
}

/// The fill tool's tap, in the canvas's own coordinates — the drawing's.
@MainActor
private final class FillTap: NSObject {
    let recognizer = UITapGestureRecognizer()
    var onTap: ((CGPoint) -> Void)?

    override init() {
        super.init()
        recognizer.addTarget(self, action: #selector(tapped))
        recognizer.isEnabled = false
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }
        onTap?(recognizer.location(in: view))
    }
}

/// A two-finger drag on the canvas otherwise grabs the sheet (and the page's
/// scroll view): outside recognizers wait for this one, which never acts.
@MainActor
private final class SheetDragBlocker: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()

    override init() {
        super.init()
        recognizer.minimumNumberOfTouches = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // PencilKit's own recognizers live on the canvas and must never wait.
        guard let view = other.view, let canvas = recognizer.view else { return false }
        return !view.isDescendant(of: canvas)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard let view = other.view, let canvas = recognizer.view else { return false }
        return view.isDescendant(of: canvas)
    }
}

struct DrawingCanvas: UIViewRepresentable {
    let controller: DrawingController

    func makeUIView(context: Context) -> PKCanvasView {
        controller.canvas.delegate = context.coordinator
        return controller.canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let controller: DrawingController

        init(controller: DrawingController) {
            self.controller = controller
        }

        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // PencilKit always calls this on the main thread; assume rather than hop.
            MainActor.assumeIsolated {
                controller.strokeCount = canvasView.drawing.strokes.count
            }
        }
    }
}

/// The palette: colours, three widths, fill, eraser, undo, clear.
struct DrawingPalette: View {
    @Bindable var controller: DrawingController
    /// Hidden when a photo is behind the canvas — a backdrop would never show.
    var showsBackdrop: Bool = true

    @State private var confirmingClear = false

    /// One per entry of `DrawingController.backdrops`, in order.
    private static var backdropNames: [String] {
        [String(localized: "White background"),
         String(localized: "Cream background"),
         String(localized: "Pink background"),
         String(localized: "Sky blue background"),
         String(localized: "Mint background"),
         String(localized: "Lavender background"),
         String(localized: "Charcoal background")]
    }

    var body: some View {
        // Rows share the width they're given — fixed gaps pushed the card off a
        // narrow screen; each slot keeps room for its selection ring.
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Array(DrawingController.palette.enumerated()), id: \.offset) { index, colour in
                    Button {
                        controller.color = colour
                    } label: {
                        Circle()
                            .fill(colour)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .strokeBorder(Theme.accent, lineWidth: 3)
                                    .padding(-4)
                                    .opacity(isSelected(colour) ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Colour \(index + 1)"))
                    .accessibilityAddTraits(isSelected(colour) ? .isSelected : [])
                    .frame(minWidth: 38, maxWidth: .infinity)
                }

                // Any colour at all, including the eyedropper.
                ColorPicker("Any colour", selection: $controller.color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.accent, lineWidth: 3)
                            .padding(-4)
                            .opacity(isCustomInk ? 1 : 0)
                            .allowsHitTesting(false)
                    )
                    .frame(minWidth: 38, maxWidth: .infinity)
            }

            HStack(spacing: 0) {
                // Clear is irreversible, so it sits far from undo — and asks first.
                toolButton("trash", label: "Clear the drawing", active: false) {
                    if controller.strokeCount > 0 { confirmingClear = true }
                }
                .confirmationDialog("Clear the drawing?",
                                    isPresented: $confirmingClear,
                                    titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { controller.clear() }
                    Button("Keep drawing", role: .cancel) {}
                } message: {
                    Text("This drawing will be lost.")
                }
                .frame(minWidth: 34, maxWidth: .infinity)

                Divider().frame(height: 24)

                ForEach(DrawingController.widths, id: \.self) { width in
                    Button {
                        controller.width = width
                        controller.tool = .pen
                    } label: {
                        Circle()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: width + 6, height: width + 6)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(
                                    controller.width == width && controller.tool == .pen
                                    ? Theme.accent.opacity(0.18) : .clear
                                )
                            )
                            .toolHitArea()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Brush size \(Int(width))"))
                    .accessibilityAddTraits(controller.width == width && controller.tool == .pen ? .isSelected : [])
                    .frame(minWidth: 34, maxWidth: .infinity)
                }

                Divider().frame(height: 24)

                toolButton(Self.fillSymbol, label: "Fill", active: controller.tool == .fill) {
                    controller.tool = controller.tool == .fill ? .pen : .fill
                }
                .accessibilityHint("Tap an area to fill it with the colour, or a line to recolour it")
                .frame(minWidth: 34, maxWidth: .infinity)
                toolButton("eraser", label: "Eraser", active: controller.tool == .eraser) {
                    controller.tool = controller.tool == .eraser ? .pen : .eraser
                }
                .frame(minWidth: 34, maxWidth: .infinity)
                toolButton("arrow.uturn.backward", label: "Undo", active: false) { controller.undo() }
                    .frame(minWidth: 34, maxWidth: .infinity)
            }

            if showsBackdrop {
                Divider()
                // Label above, not beside: inline, it wraps beside seven swatches.
                VStack(alignment: .leading, spacing: 10) {
                    Text("BACKGROUND")
                        .eyebrow(size: 10)

                    HStack(spacing: 0) {
                        ForEach(Array(DrawingController.backdrops.enumerated()), id: \.element.id) { index, backdrop in
                            Button {
                                controller.backdrop = backdrop
                            } label: {
                                Circle()
                                    .fill(backdrop.color)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15),
                                                                   lineWidth: 1))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Theme.accent, lineWidth: 2.5)
                                            .padding(-3.5)
                                            .opacity(controller.backdrop == backdrop ? 1 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.backdropNames[safe: index]
                                                ?? String(localized: "Background colour \(index + 1)"))
                            .accessibilityAddTraits(controller.backdrop == backdrop ? .isSelected : [])
                            .frame(minWidth: 34, maxWidth: .infinity)
                        }
                        ColorPicker("Any background",
                                    selection: $controller.backdropColor,
                                    supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                                    .padding(-3.5)
                                    .opacity(isCustomBackdrop ? 1 : 0)
                                    .allowsHitTesting(false)
                            )
                            .frame(minWidth: 34, maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// SF Symbols' paint bucket arrived in iOS 26.
    private static var fillSymbol: String {
        if #available(iOS 26, *) { return "paint.bucket.classic" }
        return "drop.fill"
    }

    private func isSelected(_ colour: Color) -> Bool {
        controller.tool != .eraser && controller.color == colour
    }

    /// True when the ink isn't a preset — the ring moves to the picker so
    /// something looks selected.
    private var isCustomInk: Bool {
        controller.tool != .eraser && !DrawingController.palette.contains(controller.color)
    }

    private var isCustomBackdrop: Bool {
        !DrawingController.backdrops.contains(controller.backdrop)
    }

    private func toolButton(_ symbol: String,
                            label: LocalizedStringKey,
                            active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.rounded(16, .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(active ? Theme.accent.opacity(0.18) : .clear))
                .toolHitArea()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private extension View {
    /// The tool row's 34 pt circles answer taps across their whole slot, 44 pt
    /// tall: a 375 pt phone gives each about 44 pt, the tap-target minimum.
    func toolHitArea() -> some View {
        frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension UIImage {
    /// Fills `rect` completely, cropping the overflowing axis — the same
    /// behaviour as SwiftUI's `.scaledToFill()` inside a clip.
    func drawAspectFill(in rect: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: rect.midX - scaled.width / 2,
                             y: rect.midY - scaled.height / 2)
        draw(in: CGRect(origin: origin, size: scaled))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
