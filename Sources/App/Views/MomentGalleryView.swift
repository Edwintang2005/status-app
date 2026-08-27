import Photos
import SwiftUI

/// Swipe back through the whole history: look at the photos, play the voice
/// memos, and save or share any of it.
///
/// Entries older than `AppConfig.momentImageCacheLimit` keep their metadata but
/// not their media files, so a page may have to fetch its photo or recording
/// from CloudKit when you reach it. That's the trade that lets the history be
/// unlimited without the device carrying every photo forever.
struct MomentGalleryView: View {
    let moments: [Moment]
    let startAt: Moment

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String
    @State private var saveState: SaveState = .idle
    /// One player for the whole gallery, so paging to the next memo takes over
    /// from the last rather than layering two voices.
    @State private var player = VoicePlayer()
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
                    exportButton
                }
            }
            .task(id: selection) {
                saveState = .idle
                // Paging away from a memo stops it — hearing the previous page
                // over the new one is never what you meant.
                player.stop()
                markCurrentSeen()
                await loadIfNeeded()
            }
            .onDisappear { player.stop() }
            // `.failed` used to be set and never rendered — a denied photo
            // permission looked exactly like a successful save.
            .alert("Couldn't save", isPresented: saveFailedBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                if case .failed(let message) = saveState { Text(message) }
            }
        }
    }

    private var saveFailedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = saveState { return true } else { return false } },
            set: { if !$0 { saveState = .idle } }
        )
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

            if moment.isVoice {
                VoicePlaybackCard(moment: moment,
                                  audioURL: MomentStore.shared.mediaURL(for: moment),
                                  player: player)
                if !MomentStore.shared.hasAudio(for: moment.id) {
                    fetchStatus(for: moment)
                }
            } else {
                // Its own view with its own load, because a page-style TabView
                // builds every page eagerly: reading the full-size JPEG here in
                // `page(_:)` meant ~all cached photos decoded on the main
                // thread the moment the gallery opened.
                GalleryImageView(momentID: moment.id,
                                 isLoading: loading.contains(moment.id),
                                 isUnavailable: unavailable.contains(moment.id))
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

    /// One gallery page's photo. Loads (and re-checks after a CloudKit fetch
    /// finishes) on appearance, decoding off the main thread.
    private struct GalleryImageView: View {
        let momentID: String
        let isLoading: Bool
        let isUnavailable: Bool
        @State private var image: UIImage?

        var body: some View {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                    // Two-finger, so it never fights the one-finger page swipe.
                    .pinchToZoom()
                    // Released when the page scrolls away: the paged TabView
                    // keeps every page alive, and holding each visited page's
                    // decoded full-size image (~6 MB apiece) climbed toward a
                    // jetsam on a long swipe through the history. Coming back
                    // re-runs the placeholder's `.task` and reloads from disk.
                    .onDisappear { self.image = nil }
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if isLoading {
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("Fetching from iCloud…")
                                    .font(Theme.rounded(13))
                                    .foregroundStyle(.secondary)
                            }
                        } else if isUnavailable {
                            Label("Couldn't load this one", systemImage: "icloud.slash")
                                .font(Theme.rounded(14))
                                .foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 30))
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Keyed on `isLoading` as well as the id: when the
                    // CloudKit fetch flips it back to false, this re-runs and
                    // picks up the file that just landed.
                    .task(id: "\(momentID)-\(isLoading)") {
                        let id = momentID
                        image = await Task.detached(priority: .userInitiated) {
                            MomentStore.shared.image(for: id)
                        }.value
                    }
            }
        }
    }

    /// A memo's card is drawn from metadata and is useful on its own, so a
    /// missing recording is a line of text under it rather than a placeholder
    /// in place of it.
    @ViewBuilder
    private func fetchStatus(for moment: Moment) -> some View {
        if loading.contains(moment.id) {
            Label("Fetching from iCloud…", systemImage: "icloud.and.arrow.down")
                .font(Theme.rounded(13))
                .foregroundStyle(.secondary)
        } else if unavailable.contains(moment.id) {
            Label("Couldn't load this one", systemImage: "icloud.slash")
                .font(Theme.rounded(13))
                .foregroundStyle(.secondary)
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
              !MomentStore.shared.hasMedia(for: moment),
              !loading.contains(moment.id) else { return }

        loading.insert(moment.id)
        unavailable.remove(moment.id)
        let ok = await model.ensureMedia(for: moment)
        loading.remove(moment.id)
        // Swiping away cancels this task mid-fetch; the fetch then reports
        // failure, but "user left the page" isn't "couldn't load". The page
        // retries via `loadIfNeeded` when they come back.
        if !ok, !Task.isCancelled { unavailable.insert(moment.id) }
    }

    // MARK: - Keeping a copy

    /// A photo goes to Photos; a voice memo has nowhere in Photos to go, so it
    /// gets the share sheet instead — which is what lets someone keep a memo in
    /// Voice Memos, Files, or a message thread.
    @ViewBuilder
    private var exportButton: some View {
        if let moment = current, moment.isVoice {
            if let url = MomentStore.shared.mediaURL(for: moment) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tertiary)
            }
        } else {
            saveButton
        }
    }

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
        // Everything after an `await` checks this: the permission prompt and
        // the Photos write take long enough to swipe away from the page, and
        // a late "Saved" (or failure alert) then claims the *wrong* photo.
        let saving = moment.id
        saveState = .saving

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            if selection == saving { saveState = .failed("Allow photo access in Settings to save.") }
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            if selection == saving { saveState = .saved }
        } catch {
            if selection == saving { saveState = .failed(error.localizedDescription) }
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
