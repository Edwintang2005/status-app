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
    /// Filter-hidden captions the user chose to see.
    @State private var revealedCaptions: Set<String> = []
    @State private var reporting: Moment?

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

    /// `scrollPosition(id:)` wants an optional; the pager never reports `nil`
    /// for a settled page, and `selection` must never become one.
    private var scrolledID: Binding<String?> {
        Binding(get: { selection }, set: { if let id = $0 { selection = id } })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()

                if moments.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "photo.on.rectangle.angled")
                } else {
                    // A horizontal paging ScrollView, not a page-style TabView: the
                    // TabView builds every page up front (seconds of layout for a
                    // long history) and halts halfway between pages when any page's
                    // content changes mid-swipe — which a photo finishing its decode
                    // does. UIKit paging targets come from the viewport, not the
                    // pages, and the lazy stack builds only what is on screen.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(moments) { moment in
                                page(moment)
                                    .containerRelativeFrame(.horizontal)
                                    .id(moment.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: scrolledID)
                    .scrollIndicators(.hidden)
                    .overlay(alignment: .bottom) { pageDots }
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
                if let current, !current.fromMe {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if captionIsFiltered(current) && !revealedCaptions.contains(current.id) {
                                Button {
                                    revealedCaptions.insert(current.id)
                                } label: {
                                    Label("Show hidden caption", systemImage: "eye")
                                }
                            }
                            Button(role: .destructive) {
                                reporting = current
                            } label: {
                                Label("Report…", systemImage: "flag")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .confirmationDialog("Report this \(reporting?.noun ?? "moment")?",
                                isPresented: Binding(get: { reporting != nil },
                                                     set: { if !$0 { reporting = nil } }),
                                titleVisibility: .visible) {
                Button("Report", role: .destructive) {
                    if let reporting { model.report(reporting) }
                    reporting = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { reporting = nil }
            } message: {
                Text("It's removed from this iPhone straight away, and the details go to us by email. We act on reports within 24 hours.")
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

    /// The TabView's dots, drawn by hand; the title already counts, so a long
    /// history gets no row of fifty dots.
    @ViewBuilder
    private var pageDots: some View {
        if (2...12).contains(moments.count) {
            HStack(spacing: 8) {
                ForEach(moments) { moment in
                    Circle()
                        .fill(moment.id == selection ? Color.primary : Color.primary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)
        }
    }

    private var counterLabel: String {
        guard moments.count > 1,
              let index = moments.firstIndex(where: { $0.id == selection }) else { return "" }
        return String(localized: "\(index + 1) of \(moments.count)")
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
                // Own view with its own load, so a page decodes only when it appears.
                GalleryImageView(momentID: moment.id,
                                 isLoading: loading.contains(moment.id),
                                 isUnavailable: unavailable.contains(moment.id))
            }

            VStack(spacing: 5) {
                if !moment.caption.isEmpty {
                    if captionIsFiltered(moment) && !revealedCaptions.contains(moment.id) {
                        Text(ContentFilter.hiddenPlaceholder)
                            .font(Theme.rounded(15))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(moment.caption)
                            .font(Theme.rounded(20, .semibold))
                            .multilineTextAlignment(.center)
                    }
                }
                Text(attribution(moment))
                    .font(Theme.rounded(13))
                    .foregroundStyle(.secondary)
                if let seen = seenLine(moment) {
                    Label(seen, systemImage: "eye.fill")
                        .font(Theme.rounded(12))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            // Clear of the paging dots.
            Color.clear.frame(height: 24)
        }
        .padding(.horizontal, 20)
    }

    /// One gallery page's photo. Loads (and re-checks after a CloudKit fetch
    /// finishes) on appearance, decoding off the main thread, and releases the
    /// decode off-screen — the lazy stack keeps pages it has built, and holding
    /// every decoded photo of a long history risks a jetsam.
    private struct GalleryImageView: View {
        let momentID: String
        let isLoading: Bool
        let isUnavailable: Bool
        @State private var image: UIImage?

        var body: some View {
            if let image {
                // Always the centred square, whatever frame the file keeps.
                SquareFill { Image(uiImage: image).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                    // Two-finger, so it never fights the one-finger page swipe.
                    .pinchToZoom()
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

    private func captionIsFiltered(_ moment: Moment) -> Bool {
        !moment.fromMe && ContentFilter.hides(moment.caption)
    }

    /// Shows the name attached at send time; falls back to the current partner
    /// name only when the record carries none (or the filter hides it).
    private func attribution(_ moment: Moment) -> String {
        let who = moment.fromMe
            ? String(localized: "You")
            : moment.displaySenderName(fallback: model.partnerName)
        let when = moment.sentAt.relativeWording()
        return "\(who) · \(when)"
    }

    /// "Seen 2 hours ago" on own moments — read receipts on, partner confirmed.
    /// `.distantPast` means seen before per-moment timestamps existed.
    private func seenLine(_ moment: Moment) -> String? {
        guard model.readReceiptsEnabled, moment.fromMe,
              let seenAt = moment.seenByPartnerAt else { return nil }
        guard seenAt > .distantPast else { return String(localized: "Seen") }
        return String(localized: "Seen \(seenAt.relativeWording())")
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
                .accessibilityLabel("Share voice memo")
            } else {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Share voice memo")
                    .accessibilityHint("Not on this device yet")
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
            .accessibilityLabel("Save to Photos")
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
            if selection == saving { saveState = .failed(String(localized: "Allow photo access in Settings to save.")) }
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
