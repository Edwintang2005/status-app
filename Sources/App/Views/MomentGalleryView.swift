import Photos
import SwiftUI

/// Swipe back through everything this device has received or sent, and save
/// any of it to Photos.
///
/// The list is purely local — see `MomentStore` and the note in the README
/// about the server holding only the newest moment per person.
struct MomentGalleryView: View {
    let moments: [Moment]
    let startAt: Moment

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var saveState: SaveState = .idle

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    init(moments: [Moment], startAt: Moment) {
        self.moments = moments
        self.startAt = startAt
        _selection = State(initialValue: startAt.id)
    }

    private var current: Moment? {
        moments.first { $0.id == selection }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                if moments.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "photo.on.rectangle.angled")
                } else {
                    TabView(selection: $selection) {
                        ForEach(moments) { moment in
                            page(moment).tag(moment.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: moments.count > 1 ? .automatic : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    saveButton
                }
            }
            .onChange(of: selection) { _, _ in saveState = .idle }
        }
    }

    // MARK: - Page

    private func page(_ moment: Moment) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            if let image = MomentStore.shared.image(for: moment.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        // The index outlived its file — possible if the image
                        // was pruned while this moment was still listed.
                        Label("Image unavailable", systemImage: "photo")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(spacing: 5) {
                if !moment.caption.isEmpty {
                    Text(moment.caption)
                        .font(Theme.rounded(20, .semibold))
                        .multilineTextAlignment(.center)
                }
                Text(attribution(moment))
                    .font(Theme.rounded(13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            // Clear of the paging dots.
            Color.clear.frame(height: 24)
        }
        .padding(.horizontal, 20)
    }

    private func attribution(_ moment: Moment) -> String {
        let who = moment.fromMe
            ? "You"
            : (moment.senderName.isEmpty ? "Them" : moment.senderName)
        let when = moment.sentAt.formatted(.relative(presentation: .named))
        return "\(who) · \(when)"
    }

    // MARK: - Saving

    @ViewBuilder
    private var saveButton: some View {
        switch saveState {
        case .saving:
            ProgressView()
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.mint)
        default:
            Button {
                Task { await save() }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(current == nil)
        }
    }

    /// Add-only authorisation: this never needs to *read* the photo library,
    /// and asking for less means a gentler permission prompt.
    private func save() async {
        guard let moment = current,
              let image = MomentStore.shared.image(for: moment.id) else { return }
        saveState = .saving

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed("Allow photo access in Settings to save.")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}

#if DEBUG
#Preview("Gallery") {
    let moment = Snapshot.preview.moments[0]
    return MomentGalleryView(moments: Snapshot.preview.moments, startAt: moment)
        .tint(Theme.accent)
}
#endif
