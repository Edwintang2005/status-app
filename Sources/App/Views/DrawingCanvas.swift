import Observation
import PencilKit
import SwiftUI

/// Owns the `PKCanvasView` so the palette can retarget the tool and the
/// composer can rasterise the result. Held across view updates — recreating
/// the canvas would throw away the strokes.
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

    var color: Color = .black { didSet { applyTool() } }
    var width: CGFloat = 10 { didSet { applyTool() } }
    var isErasing = false { didSet { applyTool() } }

    /// The observable mirror of `canvas.drawing.strokes.count`. Views must
    /// read *this* rather than the canvas, which is `@ObservationIgnored` and
    /// therefore invisible to SwiftUI's dependency tracking.
    var strokeCount = 0

    init() {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Without this, finger drawing is ignored on devices that support
        // Apple Pencil — which is most of them.
        canvas.drawingPolicy = .anyInput
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
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
            UIColor.white.setFill()
            context.fill(rect)
            photo?.drawAspectFill(in: rect)

            guard bounds.width > 0 else { return }
            // Rasterise the strokes at the export resolution rather than the
            // on-screen one, so the result isn't a blurry upscale.
            canvas.drawing
                .image(from: bounds, scale: size / bounds.width)
                .draw(in: rect)
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
            // PencilKit always calls this on the main thread; asserting that
            // lets us read `drawing` without hopping and losing the update.
            MainActor.assumeIsolated {
                controller.strokeCount = canvasView.drawing.strokes.count
            }
        }
    }
}

/// The palette: colours, three widths, eraser, undo, clear.
struct DrawingPalette: View {
    @Bindable var controller: DrawingController

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
            }

            HStack(spacing: 18) {
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
                toolButton("trash", active: false) { controller.clear() }
            }
        }
    }

    private func isSelected(_ colour: Color) -> Bool {
        !controller.isErasing && controller.color == colour
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
