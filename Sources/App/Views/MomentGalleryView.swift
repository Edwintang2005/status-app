import CoreLocation
import Photos
import SwiftUI

/// Swipe back through the whole history: photos, voice memos, save/share.
/// Full media is kept only for the newest `AppConfig.momentImageCacheLimit`;
/// past that a page shows the kept thumbnail and fetches the rest on arrival.
struct MomentGalleryView: View {
    /// The pages as opened; `moments` drops any that has since left the history.
    private let opened: [Moment]
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
    /// Reported here: gone at once, even when the history it leaves is empty.
    @State private var reported: Set<String> = []
    /// A reply's composer, over the gallery: sending returns here.
    @State private var replying: ReplyKind?
    /// An own moment whose caption is being edited, and the words so far.
    @State private var editingCaption: Moment?
    @State private var captionDraft = ""
    @State private var deleting: Moment?
    /// Tapped: every page's time reads as the full date until tapped again.
    @State private var showsFullDate = false
    @State private var starTaps = 0
    /// Where each page's picture was taken, once named (`PlaceNames`).
    @State private var places: [String: String] = [:]

    private enum ReplyKind: String, Identifiable {
        case moment, voiceMemo
        var id: String { rawValue }
    }

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    init(moments: [Moment], startAt: Moment) {
        self.opened = moments
        self.startAt = startAt
        _selection = State(initialValue: startAt.id)
    }

    /// Deleted here or by its sender: its page goes. An index that couldn't be
    /// read is empty, which isn't everything deleted.
    private var moments: [Moment] {
        let here = model.historyByID
        let shown = opened.filter { !reported.contains($0.id) }
        return here.isEmpty ? shown : shown.filter { here[$0.id] != nil }
    }

    /// The page after a removed one, else the one before; none left closes the gallery.
    private func settle(on pages: [String]) {
        guard !pages.contains(selection) else { return }
        let order = opened.map(\.id)
        let gone = order.firstIndex(of: selection) ?? 0
        let next = order[gone...].first(where: pages.contains) ?? order[..<gone].last(where: pages.contains)
        if let next { selection = next } else { dismiss() }
    }

    /// By id, not a walk of the pages: `selection` is always one of them (`settle`).
    private var current: Moment? {
        guard !reported.contains(selection) else { return nil }
        let here = model.historyByID
        return here.isEmpty ? opened.first { $0.id == selection } : here[selection]
    }

    /// The model's copy: `moments` was taken when the gallery opened, and an
    /// edited caption (here, or the partner's arriving) is newer.
    private func live(_ moment: Moment) -> Moment {
        model.historyByID[moment.id] ?? moment
    }

    /// `scrollPosition(id:)` wants an optional; the pager never reports `nil`
    /// for a settled page, and `selection` must never become one.
    private var scrolledID: Binding<String?> {
        Binding(get: { selection }, set: { if let id = $0 { selection = id } })
    }

    var body: some View {
        let partnerName = model.partnerName
        let filterOn = model.contentFilterEnabled
        // Once per body: a padded history is 5,000 pages.
        let pages = moments

        NavigationStack {
            ZStack {
                Theme.Background()

                if pages.isEmpty {
                    ContentUnavailableView("Nothing here yet",
                                           systemImage: "photo.on.rectangle.angled")
                } else {
                    // Never a page-style TabView: it builds every page, and stalls
                    // mid-swipe when one changes.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(pages) { moment in
                                page(moment, partnerName: partnerName, filterOn: filterOn)
                                    .containerRelativeFrame(.horizontal)
                                    .id(moment.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: scrolledID)
                    .scrollIndicators(.hidden)
                    .overlay(alignment: .bottom) { pageDots(pages) }
                }
            }
            .navigationTitle(counterLabel(pages))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let current {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.setFavourite(current, !current.isFavourite)
                            starTaps += 1
                        } label: {
                            Image(systemName: current.isFavourite ? "star.fill" : "star")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        // The tap, not the state: paging between starred and not would buzz.
                        .sensoryFeedback(.selection, trigger: starTaps)
                        .accessibilityLabel("Favourite")
                        .accessibilityValue(current.isFavourite ? "On" : "Off")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    exportButton
                }
                if let current, current.fromMe, current.kind.isSupported || current.canDelete() {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if current.kind.isSupported {
                                Button {
                                    captionDraft = current.caption
                                    editingCaption = current
                                } label: {
                                    Label("Edit caption…", systemImage: "pencil")
                                }
                            }
                            if current.canDelete() {
                                Button(role: .destructive) {
                                    deleting = current
                                } label: {
                                    Label("Delete for both of you…", systemImage: "trash")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
                if let current, !current.fromMe {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if current.moderatedCaption(revealed: revealedCaptions.contains(current.id),
                                                        filterEnabled: filterOn)?.isPlaceholder == true {
                                Button {
                                    revealedCaptions.insert(current.id)
                                } label: {
                                    Label("Show hidden caption", systemImage: "eye")
                                }
                            }
                            WidgetPictureToggle(moment: current)
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
            .alert("Edit caption", isPresented: $editingCaption.isPresent()) {
                TextField("Caption", text: $captionDraft)
                Button("Save") {
                    if let editing = editingCaption {
                        let words = captionDraft
                        Task { await model.editCaption(of: editing, to: words) }
                    }
                    editingCaption = nil
                }
                Button("Cancel", role: .cancel) { editingCaption = nil }
            } message: {
                Text("\(partnerName) sees the new caption, quietly. Leave it empty to remove it.")
            }
            .confirmationDialog("Report this \(reporting?.noun ?? "moment")?",
                                isPresented: $reporting.isPresent(),
                                titleVisibility: .visible) {
                Button("Report", role: .destructive) {
                    // Gone from the history, so the pager moves on (`settle`), as after a delete.
                    if let reporting {
                        model.report(reporting)
                        reported.insert(reporting.id)
                    }
                    reporting = nil
                }
                Button("Cancel", role: .cancel) { reporting = nil }
            } message: {
                Text("It's removed from this iPhone straight away, and an email to us opens with the details — send it and we'll respond within 24 hours.")
            }
            .deleteMomentDialog($deleting, model: model)
            .onChange(of: pages.map(\.id)) { _, ids in settle(on: ids) }
            .onChange(of: model.isOffline) { _, offline in
                guard !offline else { return }
                unavailable.removeAll()
                Task {
                    await loadIfNeeded()
                    markCurrentPhotoSeen()
                }
            }
            .task(id: selection) {
                saveState = .idle
                // Paging away from a memo stops it.
                player.stop()
                await loadIfNeeded()
                guard !Task.isCancelled else { return }
                markCurrentPhotoSeen()
            }
            // A memo counts as heard once it plays, not when its page shows —
            // the same rule as the home screen's memo row.
            .onChange(of: player.isPlaying) { _, playing in
                guard playing, let moment = current, moment.isVoice,
                      let url = MomentStore.shared.mediaURL(for: moment),
                      player.currentURL == url else { return }
                model.markSeen(moment, reloadWidgets: false)
            }
            .onDisappear {
                player.stop()
                // One widget reload for the pages seen, not one per page.
                model.flushWidgetReload()
            }
            .alert("Couldn't save", isPresented: saveFailedBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                if case .failed(let message) = saveState { Text(message) }
            }
            .sheet(item: $replying) { kind in
                replyComposer(kind)
            }
        }
    }

    /// A new moment of its own — nothing links it to the one it answers.
    @ViewBuilder
    private func replyComposer(_ kind: ReplyKind) -> some View {
        switch kind {
        case .moment:
            MomentComposerView { image, kind, caption, location in
                Task { await model.sendMoment(image: image, kind: kind, caption: caption, location: location) }
            }
            .presentsModelErrors()
        case .voiceMemo:
            VoiceMemoComposerView { url, duration, waveform, caption in
                Task {
                    await model.sendVoiceMemo(fileURL: url, duration: duration,
                                              waveform: waveform, caption: caption)
                }
            }
            .presentsModelErrors()
        }
    }

    private var saveFailedBinding: Binding<Bool> {
        Binding(
            get: { if case .failed = saveState { return true } else { return false } },
            set: { if !$0 { saveState = .idle } }
        )
    }

    /// Page dots for a short run; the title already counts, so a long history
    /// gets no row of fifty dots.
    @ViewBuilder
    private func pageDots(_ pages: [Moment]) -> some View {
        if (2...12).contains(pages.count) {
            HStack(spacing: 8) {
                ForEach(pages) { moment in
                    Circle()
                        .fill(moment.id == selection ? Color.primary : Color.primary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 8)
            .accessibilityHidden(true)
        }
    }

    private func counterLabel(_ pages: [Moment]) -> String {
        guard pages.count > 1,
              let index = pages.firstIndex(where: { $0.id == selection }) else { return "" }
        return String(localized: "\(index + 1) of \(pages.count)")
    }

    // MARK: - Page

    private func page(_ moment: Moment, partnerName: String, filterOn: Bool) -> some View {
        let moment = live(moment)
        let attribution = attribution(moment, partnerName: partnerName, filterOn: filterOn)
        return pageContent(moment, attribution: attribution, filterOn: filterOn)
    }

    @ViewBuilder
    private func pageContent(_ moment: Moment, attribution: String, filterOn: Bool) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            if moment.isVoice {
                VoicePlaybackCard(moment: moment,
                                  audioURL: MomentStore.shared.mediaURL(for: moment),
                                  player: player)
                if !MomentStore.shared.hasAudio(for: moment.id) {
                    fetchStatus(for: moment)
                }
            } else if !moment.kind.isSupported {
                UnsupportedMomentView(compact: false)
            } else {
                // Own view with its own load, so a page decodes only when it appears.
                GalleryImageView(momentID: moment.id,
                                 summary: String(localized: "\(moment.noun) from \(attribution)"),
                                 isLoading: loading.contains(moment.id),
                                 isUnavailable: unavailable.contains(moment.id),
                                 isOffline: model.isOffline)
                    // A pinched photo covers the caption and heart below it, not the reverse.
                    .raisedWhilePinched()
            }

            VStack(spacing: 5) {
                if let caption = moment.moderatedCaption(revealed: revealedCaptions.contains(moment.id),
                                                         filterEnabled: filterOn) {
                    if caption.isPlaceholder {
                        Text(caption.text)
                            .font(Theme.rounded(15))
                            .foregroundStyle(Theme.mutedText)
                    } else {
                        Text(caption.text)
                            .font(Theme.rounded(20, .semibold))
                            .multilineTextAlignment(.center)
                    }
                }
                Button {
                    showsFullDate.toggle()
                } label: {
                    Text(showsFullDate ? self.attribution(moment, partnerName: model.partnerName,
                                                          filterOn: filterOn, fullDate: true) : attribution)
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.mutedText)
                        .multilineTextAlignment(.center)
                        // A 13 pt line is a small target: 44 pt tall to tap.
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        // Swapped outright, never animated: a cross-fade drew both
                        // wordings at once, and an eased frame slid the new one in.
                        .transaction { $0.animation = nil }
                }
                // No press dimming: with the swap it blinked the line out and back.
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityHint(showsFullDate ? "Shows how long ago" : "Shows the full date and time")
                .accessibilityIdentifier("gallery.attribution")
                // Here, not in the line: a moment without a place gets no view, so no gap.
                .task(id: "\(moment.id)-\(loading.contains(moment.id))") {
                    // The full copy carries the place: a page showing only the thumbnail asks again once it lands.
                    guard !moment.isVoice, moment.kind.isSupported, !loading.contains(moment.id),
                          places[moment.id] == nil else { return }
                    if let place = await PlaceNames.shared.name(for: moment.id) { places[moment.id] = place }
                }
                if let place = places[moment.id] {
                    PlaceLine(place: place)
                }
                if let seen = seenLine(moment) {
                    Label(seen, systemImage: "eye.fill")
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                }
                // Answer what you're looking at: the banner's "Send a heart back", here
                // too, or a moment back.
                if !moment.fromMe {
                    VStack(spacing: 10) { answerButtons }
                        .padding(.top, 10)
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
    /// every decoded photo of a long history risks a jetsam. Without the full
    /// file (past the media cache, offline) the kept thumbnail stands in, labelled.
    private struct GalleryImageView: View {
        let momentID: String
        /// What VoiceOver reads for the picture itself; the caption is read below it.
        let summary: String
        let isLoading: Bool
        let isUnavailable: Bool
        let isOffline: Bool
        @State private var image: UIImage?
        @State private var isPreview = false

        var body: some View {
            // A container, not a `Group`: a group's modifiers attach to each
            // branch, so swapping branches would fire `onDisappear` and drop the image.
            ZStack {
                if let image {
                    // Always the centred square, whatever frame the file keeps.
                    SquareFill {
                        Image(uiImage: image).resizable().scaledToFill()
                            .accessibilityLabel(summary)
                    }
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        // Over the photo, not under it: the page centres its content,
                        // and a note coming and going would shift the picture.
                        .overlay(alignment: .bottom) {
                            if isPreview { previewNote.padding(12) }
                        }
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                        // Two-finger, so it never fights the one-finger page swipe.
                        .pinchToZoom()
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
                                        .foregroundStyle(Theme.mutedText)
                                }
                            } else if isUnavailable {
                                Label(isOffline ? "Loads when you're back online" : "Couldn't load this one",
                                      systemImage: isOffline ? "wifi.slash" : "icloud.slash")
                                    .font(Theme.rounded(14))
                                    .foregroundStyle(Theme.mutedText)
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundStyle(Theme.mutedText)
                            }
                        }
                }
            }
            .onDisappear { image = nil }
            // Keyed on `isLoading` and `isUnavailable` too, so a finished fetch —
            // or the reconnect clearing the failure — re-runs this and picks up the file.
            .task(id: "\(momentID)-\(isLoading)-\(isUnavailable)") {
                guard image == nil || isPreview else { return }
                let id = momentID
                let loaded = await Task.detached(priority: .userInitiated) { () -> (UIImage?, Bool) in
                    if let full = MomentStore.shared.image(for: id) { return (full, false) }
                    return (MomentStore.shared.thumbnail(for: id), true)
                }.value
                guard !Task.isCancelled else { return }
                image = loaded.0
                isPreview = loaded.0 != nil && loaded.1
            }
        }

        @ViewBuilder
        private var previewNote: some View {
            Group {
                if isLoading {
                    Label("Fetching full size…", systemImage: "icloud.and.arrow.down")
                } else if isOffline {
                    Label("Preview · full size loads when you're back online", systemImage: "wifi.slash")
                } else if isUnavailable {
                    Label("Preview · full size couldn't load", systemImage: "icloud.slash")
                }
            }
            .font(Theme.rounded(12))
            .foregroundStyle(Theme.mutedText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// A memo's card is drawn from metadata, so a missing recording is a line
    /// of text under it rather than a placeholder in its place.
    @ViewBuilder
    private func fetchStatus(for moment: Moment) -> some View {
        if loading.contains(moment.id) {
            Label("Fetching from iCloud…", systemImage: "icloud.and.arrow.down")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
        } else if unavailable.contains(moment.id) {
            Label(model.isOffline ? "Plays once you're back online" : "Couldn't load this one",
                  systemImage: model.isOffline ? "wifi.slash" : "icloud.slash")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
        }
    }

    @ViewBuilder
    private var answerButtons: some View {
        HeartBackButton(prominent: false)
        Menu {
            Button {
                reply(with: .moment)
            } label: {
                Label("Photo or doodle", systemImage: "camera.viewfinder")
            }
            Button {
                reply(with: .voiceMemo)
            } label: {
                Label("Voice memo", systemImage: "mic.fill")
            }
        } label: {
            Label("Send a moment", systemImage: "paperplane.fill")
        }
        .menuStyle(.button)
        .buttonStyle(SecondaryButtonStyle())
    }

    /// A playing memo would bleed into a new recording.
    private func reply(with kind: ReplyKind) {
        player.stop()
        replying = kind
    }

    /// Shows the name attached at send time; falls back to the current partner
    /// name only when the record carries none (or the filter hides it).
    private func attribution(_ moment: Moment, partnerName: String, filterOn: Bool,
                             fullDate: Bool = false) -> String {
        let who = moment.fromMe
            ? String(localized: "You")
            : moment.displaySenderName(fallback: partnerName, filterEnabled: filterOn)
        let when = fullDate
            ? moment.sentAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
            : moment.sentAt.relativeWording()
        guard moment.captionEditedAt != nil else { return "\(who) · \(when)" }
        return String(localized: "\(who) · \(when) · Edited")
    }

    /// "Seen 2 hours ago" on own moments — read receipts on, partner confirmed.
    /// `.distantPast` means seen before per-moment timestamps existed.
    private func seenLine(_ moment: Moment) -> String? {
        guard model.readReceiptsEnabled, moment.fromMe,
              let seenAt = moment.seenByPartnerAt else { return nil }
        guard seenAt > .distantPast else { return String(localized: "Seen") }
        return String(localized: "Seen \(seenAt.relativeWording())")
    }

    /// A picture counts as looked at once it's on screen: its file is here
    /// after the load, so "Couldn't load this one" never sends a "Seen".
    private func markCurrentPhotoSeen() {
        guard let moment = current, !moment.isVoice,
              MomentStore.shared.hasImage(for: moment.id) else { return }
        model.markSeen(moment, reloadWidgets: false)
    }

    // MARK: - Lazy loading

    private func loadIfNeeded() async {
        guard let moment = current, moment.kind.isSupported,
              !MomentStore.shared.hasMedia(for: moment),
              !loading.contains(moment.id) else { return }

        // Offline there's nothing to fetch; the reconnect re-runs this.
        guard !model.isOffline else {
            unavailable.insert(moment.id)
            return
        }
        loading.insert(moment.id)
        unavailable.remove(moment.id)
        let ok = await model.ensureMedia(for: moment)
        loading.remove(moment.id)
        // Swiping away cancels mid-fetch (or, for the reconnect's retry, moves
        // `selection` on); "user left" isn't "couldn't load".
        if !ok, !Task.isCancelled, selection == moment.id { unavailable.insert(moment.id) }
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
              let file = MomentStore.shared.imageURL(for: moment.id),
              MomentStore.shared.hasImage(for: moment.id) else { return }
        // Checked after every `await`: the user can page away mid-save, and a
        // late "Saved"/failure would then claim the wrong photo.
        let saving = moment.id
        saveState = .saving

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            if selection == saving { saveState = .failed(String(localized: "Allow photo access in Settings to save.")) }
            return
        }

        // Our own file goes as it is. The partner's is anything their build wrote
        // (invariant 23): redrawn, carrying only the place that passed `PhotoLocation`.
        let fromMe = moment.fromMe
        let copy: Data? = fromMe ? nil : await Task.detached(priority: .userInitiated) {
            MomentStore.shared.image(for: saving)?.jpegData(compressionQuality: 0.92)
        }.value
        guard fromMe || copy != nil else {
            if selection == saving { saveState = .failed(String(localized: "Couldn't read that photo.")) }
            return
        }
        let place = PhotoLocation.read(from: file)
        let sentAt = moment.sentAt
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let copy {
                    request.addResource(with: .photo, data: copy, options: nil)
                } else {
                    request.addResource(with: .photo, fileURL: file, options: nil)
                }
                // Filed under when it was sent and where it was taken, as Photos would its own.
                request.creationDate = sentAt
                request.location = place.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
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

/// A moment of a kind from a newer build (`Moment.Kind.unsupported`): kept in
/// the index so an update shows it, drawn here as a prompt. Never fetched, and
/// opening it isn't seeing it — no "Seen" goes back for it.
struct UnsupportedMomentView: View {
    /// A library tile rather than a gallery page.
    var compact: Bool

    var body: some View {
        // Square at full width, like a photo page.
        SquareFill {
            ZStack {
                Color.primary.opacity(0.06)
                VStack(spacing: compact ? 4 : 10) {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: compact ? 22 : 40))
                    Text("Update \(AppConfig.appName) to see this")
                        .font(Theme.rounded(compact ? 11 : 16, .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.mutedText)
                .padding(compact ? 6 : 24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 28, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The heart, sent from wherever their content is: the nudge itself, so the
/// cooldown and its failure handling are `CloudSync.sendNudge`'s.
struct HeartBackButton: View {
    /// The celebration's main button, or a quieter one under a photo.
    var prominent = true
    var afterSending: () -> Void = {}

    @Environment(AppModel.self) private var model
    @State private var remaining: TimeInterval = 0

    var body: some View {
        Button {
            Task {
                await model.sendNudge()
                afterSending()
            }
        } label: {
            if remaining > 0 {
                Label("Sent · \(Int(remaining.rounded(.up)))s", systemImage: "checkmark")
            } else {
                Label("Send a heart back", systemImage: "heart.fill")
            }
        }
        .buttonStyle(styled)
        .disabled(remaining > 0 || !model.canNudge || model.isSendingNudge)
        .nudgeCooldown(after: model.snapshot.lastNudgeSentAt, remaining: $remaining)
    }

    private var styled: AnyButtonStyle {
        prominent ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle())
    }
}

/// A tap target that draws its label as is, pressed or not.
struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Either of the app's two button styles, chosen at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
