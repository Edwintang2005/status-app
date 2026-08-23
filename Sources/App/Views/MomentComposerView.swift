import PhotosUI
import SwiftUI

/// Compose a photo, a doodle, or a doodle drawn over a photo, and send it to
/// the other person's widget.
///
/// The frame is square because that's what the widget is — composing in the
/// same shape as the destination means nothing gets unexpectedly cropped later.
struct MomentComposerView: View {
    var title: String = "Send a moment"
    var sendLabel: String = "Send"
    var onSend: (UIImage, Moment.Kind, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var controller = DrawingController()
    @State private var photo: UIImage?
    @State private var caption = ""
    @State private var isDrawing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @FocusState private var captionFocused: Bool

    /// Reads `strokeCount`, not `controller.isEmpty`: the canvas itself is
    /// `@ObservationIgnored`, so a view that only consulted `isEmpty` would
    /// never be re-evaluated when a stroke lands and the button would stay
    /// disabled until some other state happened to change.
    private var canSend: Bool { photo != nil || controller.strokeCount > 0 }

    /// A doodle on a blank canvas is a drawing; anything built on a photo
    /// stays a photo, however much has been scribbled on it.
    private var kind: Moment.Kind { photo == nil ? .drawing : .photo }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(spacing: 18) {
                        square
                        if isDrawing {
                            DrawingPalette(controller: controller,
                                           showsBackdrop: photo == nil)
                                .card(padding: 16)
                        }
                        sourceRow
                        captionField
                    }
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sendLabel) { send() }
                        .font(Theme.rounded(17, .semibold))
                        .disabled(!canSend)
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                photo = image
                isDrawing = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    photo = image
                }
            }
        }
    }

    // MARK: - Canvas

    private var square: some View {
        SquareFill {
            ZStack {
                Rectangle().fill(controller.backdrop.color)

                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else if !isDrawing {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34))
                        Text("Pick a photo, or start drawing")
                            .font(Theme.rounded(14))
                    }
                    .foregroundStyle(controller.backdrop.isDark
                                     ? Color.white.opacity(0.6)
                                     : Color.secondary)
                }

                // Always mounted so strokes survive toggling the palette; only
                // accepts touches while drawing is on.
                DrawingCanvas(controller: controller)
                    .allowsHitTesting(isDrawing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
    }

    private var sourceRow: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                sourceLabel("Library", systemImage: "photo")
            }
            .buttonStyle(.plain)

            if CameraPicker.isAvailable {
                Button { showingCamera = true } label: {
                    sourceLabel("Camera", systemImage: "camera")
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation(.smooth(duration: 0.25)) { isDrawing.toggle() }
                captionFocused = false
            } label: {
                sourceLabel(isDrawing ? "Done" : "Draw",
                            systemImage: "scribble.variable",
                            active: isDrawing)
            }
            .buttonStyle(.plain)

            if photo != nil {
                Button {
                    photo = nil
                } label: {
                    sourceLabel("Clear", systemImage: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sourceLabel(_ text: String,
                             systemImage: String,
                             active: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage).font(Theme.rounded(17, .medium))
            Text(text).font(Theme.rounded(11, .medium))
        }
        .foregroundStyle(active ? .white : Color.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(active ? Theme.accent : Color.primary.opacity(0.06))
        )
    }

    private var captionField: some View {
        TextField("Add a caption (optional)", text: $caption)
            .font(Theme.rounded(16))
            .focused($captionFocused)
            .submitLabel(.done)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func send() {
        guard canSend else { return }
        onSend(controller.render(over: photo), kind, caption)
        dismiss()
    }
}

#if DEBUG
#Preview("Composer") {
    MomentComposerView { _, _, _ in }
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
