import Photos
import SwiftUI

/// Swipe back through the whole history: photos, voice memos, save/share.
/// Entries past `AppConfig.momentImageCacheLimit` keep metadata only, so a
/// page may fetch its media from CloudKit on arrival.
struct MomentGalleryView: View {
    let moments: [Moment]
    let startAt: Moment

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String
    @State private var saveState: SaveState = .idle
    /// One player for the whole gallery, so paging never layers two voices.
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
                // Paging away from a memo stops it.
                player.stop()
                markCurrentSeen()
                await loadIfNeeded()
            }
            .onDisappear { player.stop() }
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
                // Own view with its own load: a page-style TabView builds every
                // page eagerly, so decoding here would decode all cached photos at open.
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
                if let seen = seenLine(moment) {
                    Label(seen, systemImage: "eye.fill")
                        .font(Theme.rounded(12))
                        .foregroundStyle(.tertiary)
                }
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
                    // Released off-screen: the paged TabView keeps every page alive,
                    // and holding all decoded images risks a jetsam. `.task` reloads on return.
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
                    // Keyed on `isLoading` too, so a finished CloudKit fetch
                    // re-runs this and picks up the new file.
                    .task(id: "\(momentID)-\(isLoading)") {
                        let id = momentID
                        image = await Task.detached(priority: .userInitiated) {
                            MomentStore.shared.image(for: id)
                        }.value
                    }
            }
        }
    }

    /// A memo's card is drawn from metadata, so a missing recording is a line
    /// of text under it rather than a placeholder in its place.
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

    /// Shows the name attached at send time; falls back to the current partner
    /// name only when the record carries none.
    private func attribution(_ moment: Moment) -> String {
        let sender = moment.senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = moment.fromMe
            ? "You"
            : (sender.isEmpty ? model.partnerName : sender)
        let when = moment.sentAt.formatted(.relative(presentation: .named))
        return "\(who) · \(when)"
    }

    /// "Seen 2 hours ago" on own moments — read receipts on, partner confirmed.
    /// `.distantPast` means seen before per-moment timestamps existed.
    private func seenLine(_ moment: Moment) -> String? {
        guard model.readReceiptsEnabled, moment.fromMe,
              let seenAt = moment.seenByPartnerAt else { return nil }
        guard seenAt > .distantPast else { return "Seen" }
        return "Seen \(seenAt.formatted(.relative(presentation: .named)))"
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
        // Swiping away cancels mid-fetch; "user left" isn't "couldn't load".
        if !ok, !Task.isCancelled { unavailable.insert(moment.id) }
    }

    // MARK: - Keeping a copy

    /// A photo goes to Photos; a voice memo has nowhere there to go, so it
    /// gets the share sheet instead.
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

    /// Add-only authorisation: never reads the library, so a gentler prompt.
    private func save() async {
        guard let moment = current,
              let image = MomentStore.shared.image(for: moment.id) else { return }
        // Checked after every `await`: the user can page away mid-save, and a
        // late "Saved"/failure would then claim the wrong photo.
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
