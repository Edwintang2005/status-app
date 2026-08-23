import Photos
import SwiftUI

/// Swipe back through the whole history, and save any of it to Photos.
///
/// Entries older than `AppConfig.momentImageCacheLimit` keep their metadata but
/// not their image files, so a page may have to fetch its picture from CloudKit
/// when you reach it. That's the trade that lets the history be unlimited
/// without the device carrying every photo forever.
struct MomentGalleryView: View {
    let moments: [Moment]
    let startAt: Moment

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String
    @State private var saveState: SaveState = .idle
    /// Ids currently being pulled back from CloudKit.
    @State private var loading: Set<String> = []
    /// Ids whose fetch failed, so we show a message instead of a forever-spinner.
    @State private var unavailable: Set<String> = []

    private enum SaveState: Equatable {
        case idle, saving, saved
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
            .navigationTitle(counterLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    saveButton
                }
            }
            .task(id: selection) {
                saveState = .idle
                markCurrentSeen()
                await loadIfNeeded()
            }
        }
    }

    private var counterLabel: String {
        guard moments.count > 1,
              let index = moments.firstIndex(where: { $0.id == selection }) else { return "" }
        return "\(index + 1) of \(moments.count)"
    }

    // MARK: - Page

    @ViewBuilder
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
                placeholder(for: moment)
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

    private func placeholder(for moment: Moment) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if loading.contains(moment.id) {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Fetching from iCloud…")
                            .font(Theme.rounded(13))
                            .foregroundStyle(.secondary)
                    }
                } else if unavailable.contains(moment.id) {
                    Label("Couldn't load this one", systemImage: "icloud.slash")
                        .font(Theme.rounded(14))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
            }
    }

    /// Shows the name the sender attached when they sent it. Falls back to
    /// their current name only if the record carries none — which happens for
    /// anything sent before they'd set one.
    private func attribution(_ moment: Moment) -> String {
        let sender = moment.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = moment.fromMe
            ? "You"
            : (sender.isEmpty ? model.partnerName : sender)
        let when = moment.sentAt.formatted(.relative(presentation: .named))
        return "\(who) · \(when)"
    }

    /// Paging onto something counts as having looked at it.
    private func markCurrentSeen() {
        guard let moment = current else { return }
        model.markSeen(moment)
    }

    // MARK: - Lazy loading

    private func loadIfNeeded() async {
        guard let moment = current,
              !MomentStore.shared.hasImage(for: moment.id),
              !loading.contains(moment.id) else { return }

        loading.insert(moment.id)
        unavailable.remove(moment.id)
        let ok = await model.ensureImage(for: moment)
        loading.remove(moment.id)
        if !ok { unavailable.insert(moment.id) }
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
            .disabled(current.map { !MomentStore.shared.hasImage(for: $0.id) } ?? true)
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
    MomentGalleryView(moments: [Snapshot.preview.latestPartnerMoment!],
                      startAt: Snapshot.preview.latestPartnerMoment!)
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
