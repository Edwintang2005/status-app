import Observation
import PencilKit
import SwiftUI

/// Owns the `PKCanvasView` so the palette can retarget the tool and the composer
/// can rasterise. Held across view updates — recreating the canvas drops strokes.
@MainActor
@Observable
final class DrawingController {
    @ObservationIgnored let canvas = PKCanvasView()

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

    var color: Color = .black {
        didSet {
            // Picking a colour exits eraser mode — otherwise it silently does nothing.
            if isErasing { isErasing = false }
            applyTool()
        }
    }

    /// The backdrop as a plain colour, for binding a `ColorPicker` to.
    var backdropColor: Color {
        get { backdrop.color }
        set { backdrop = Backdrop(color: newValue) }
    }
    var width: CGFloat = 10 { didSet { applyTool() } }
    var isErasing = false { didSet { applyTool() } }

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
        // PencilKit inks invert near-black/white in dark mode; the backdrop is an
        // explicit swatch and `Backdrop.isDark` flips ink by hand, so take colours literally.
        canvas.overrideUserInterfaceStyle = .light
        applyTool()
    }

    private func applyTool() {
        canvas.tool = isErasing
            ? PKEraserTool(.bitmap)
            : PKInkingTool(.pen, color: UIColor(color), width: width)
    }

    func undo() {
        canvas.undoManager?.undo()
        strokeCount = canvas.drawing.strokes.count
    }

    func clear() {
        canvas.drawing = PKDrawing()
        strokeCount = 0
    }

    /// Flattens photo (if any) and strokes into one square image.
    func render(size: CGFloat = 1024, over photo: UIImage?) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let bounds = canvas.bounds
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            UIColor(backdrop.color).setFill()
            context.fill(rect)
            photo?.drawAspectFill(in: rect)

            guard bounds.width > 0 else { return }
            // Rasterise at export resolution to avoid a blurry upscale; pinned
            // light because `PKDrawing.image` reads current traits and inverts ink in dark mode.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                canvas.drawing
                    .image(from: bounds, scale: size / bounds.width)
                    .draw(in: rect)
            }
        }
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

/// The palette: colours, three widths, eraser, undo, clear.
struct DrawingPalette: View {
    @Bindable var controller: DrawingController
    /// Hidden when a photo is behind the canvas — a backdrop would never show.
    var showsBackdrop: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(Array(DrawingController.palette.enumerated()), id: \.offset) { _, colour in
                    Button {
                        controller.color = colour
                        controller.isErasing = false
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
            }

            HStack(spacing: 18) {
                // Clear is irreversible, so it sits far from undo.
                toolButton("trash", active: false) { controller.clear() }

                Divider().frame(height: 24)

                ForEach(DrawingController.widths, id: \.self) { width in
                    Button {
                        controller.width = width
                        controller.isErasing = false
                    } label: {
                        Circle()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: width + 6, height: width + 6)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle().fill(
                                    controller.width == width && !controller.isErasing
                                    ? Theme.accent.opacity(0.18) : .clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 24)

                toolButton("eraser", active: controller.isErasing) {
                    controller.isErasing.toggle()
                }
                toolButton("arrow.uturn.backward", active: false) { controller.undo() }
            }

            if showsBackdrop {
                Divider()
                // Label above, not beside — inline it wrapped once seven swatches filled the row.
                VStack(alignment: .leading, spacing: 10) {
                    Text("BACKGROUND")
                        .font(Theme.rounded(10, .semibold))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        ForEach(DrawingController.backdrops) { backdrop in
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

                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func isSelected(_ colour: Color) -> Bool {
        !controller.isErasing && controller.color == colour
    }

    /// True when the ink isn't a preset — the ring moves to the picker so
    /// something looks selected.
    private var isCustomInk: Bool {
        !controller.isErasing && !DrawingController.palette.contains(controller.color)
    }

    private var isCustomBackdrop: Bool {
        !DrawingController.backdrops.contains(controller.backdrop)
    }

    private func toolButton(_ symbol: String,
                            active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Theme.rounded(16, .medium))
                .frame(width: 34, height: 34)
                .background(Circle().fill(active ? Theme.accent.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain)
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
