import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingComposer = false
    @State private var showingVoiceComposer = false
    @State private var showingLibrary = false
    @State private var showingStatusHistory = false
    /// The easter egg — see `EasterEggView`.
    @State private var showingAnniversary = false
    /// The partner's fresh start request, or a clear that keeps failing.
    @State private var showingFreshStart = false
    /// Owned here so leaving the screen or starting a second memo stops playback.
    @State private var voicePlayer = VoicePlayer()
    /// Local, not `model.confirmingInviteReseat`: Settings hosts that one, and
    /// two views presenting from one flag collide.
    @State private var confirmingCloseLink = false
    /// Snapshot taken when the carousel opens — paging marks moments seen, so
    /// reading `model.carouselMoments` live would shrink the list under the user.
    @State private var carouselQueue: [Moment] = []
    /// Where the carousel opens, when a route named one; otherwise its first.
    @State private var carouselStart: Moment?
    /// The title is being held: a thread draws under it until the egg opens.
    @State private var titlePressing = false
    /// Bumped when their heart, status or a picture lands while Home is in
    /// front: a soft haptic and an in-place flourish, under the system banner.
    @State private var heartArrivals = 0
    @State private var statusArrivals = 0
    @State private var momentArrivals = 0
    /// "Sent to …" in the footer for a moment after a send is confirmed.
    @State private var showsSent = false

    /// How long the footer says "Sent to …" after a confirmed send.
    private static let sentPillSeconds: TimeInterval = 3

    var body: some View {
        // A filter over the whole history: read once per pass.
        let unseen = model.unseenVisualMoments

        NavigationStack {
            ZStack {
                // Inside the stack: NavigationStack paints an opaque background
                // over anything layered underneath.
                Theme.Background()
                ScrollView {
                    content(unseen: unseen)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.isOffline)
                        // Pin the scrollable content to the viewport: a child with a
                        // wide *ideal* size (a long single-line Text) can otherwise
                        // inflate the content's horizontal extent on some OS builds,
                        // letting the whole screen pan sideways.
                        .containerRelativeFrame(.horizontal)
                }
                .scrollIndicators(.hidden)
                .topBarBacking()
                .refreshable { await model.refresh() }
            }
            .navigationTitle(AppConfig.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .modifier(sheets)
        .modifier(lifecycle(unseenCount: unseen.count))
        .closeInviteLinkDialog(isPresented: $confirmingCloseLink)
        // Waits out any sheet (Settings shows its own copy): one presentation
        // per view, so over a sheet it would be dropped.
        .alert("Invite link", isPresented: Binding(get: { model.inviteNotice != nil && !anySheetShowing
                                                           && !model.rootSheetShowing },
                                                   set: { if !$0 { model.inviteNotice = nil } })) {
            Button("OK", role: .cancel) { model.inviteNotice = nil }
        } message: {
            Text(model.inviteNotice ?? "")
        }
    }

    /// Them first: what you open the app to see, then your reply to it. Each
    /// derived value is read once here and handed down as a plain value.
    private func content(unseen: [Moment]) -> some View {
        let partnerName = model.partnerName
        let pendingCount = model.pendingSendCount
        let notice = activeNotice
        let filterOn = model.contentFilterEnabled
        let theirs = model.snapshot.theirs

        return VStack(spacing: 12) {
            // In the scroll content, not pinned above it: a sibling that resizes
            // the scroll view looped layout against the bar (invariant 21).
            if model.isOffline {
                OfflineBanner(pendingCount: pendingCount,
                              mobileDataDenied: model.mobileDataDenied,
                              storageFull: model.storageFullAt != nil)
                    .transition(.opacity)
            }
            if let notice, notice.urgent {
                noticeView(notice, partnerName: partnerName)
            }
            PartnerCard(partnerName: partnerName,
                        status: theirs?.moderation(reportedAt: model.hiddenPartnerStatusAt,
                                                   revealed: model.partnerStatusRevealed,
                                                   filterEnabled: filterOn),
                        wordsAt: theirs?.wordsAt ?? .distantPast,
                        lastHeartAt: theirs?.lastNudgeAt,
                        partnerHasLeft: model.partnerHasLeft,
                        statusArrivals: statusArrivals,
                        heartArrivals: heartArrivals,
                        onOpen: { showingStatusHistory = true },
                        onReport: { model.reportPartnerStatus() },
                        onReveal: { model.revealPartnerStatus() })
                .equatable()
            MyStatusRow(mine: model.snapshot.mine,
                        unsent: model.myStatusWaitingToSend,
                        seenAt: model.myStatusSeenAt,
                        onOpen: { showingPicker = true })
                .equatable()
            NudgeButton(lastSentAt: model.snapshot.lastNudgeSentAt,
                        lastFailedAt: model.snapshot.lastNudgeFailedAt,
                        sending: model.isSendingNudge) {
                await model.sendNudge()
            }
            sendRow
            if let notice, !notice.urgent {
                noticeView(notice, partnerName: partnerName)
            }
            if let moment = unseen.first ?? model.latestVisualMoment {
                MomentCard(moment: moment,
                           unseenCount: unseen.count,
                           label: MomentCard.label(for: moment, filterEnabled: filterOn),
                           isOffline: model.isOffline,
                           onOpen: { carouselQueue = model.carouselMoments },
                           fetchThumbnail: { await model.ensureThumbnail(for: moment) })
                    .equatable()
                    .id(moment.id)
                    .transition(.opacity)
            }
            if let memo = model.latestReceivedVoiceMemo {
                voiceMemoRow(memo)
            }
            SyncFooter(partnerName: partnerName,
                       showsSent: showsSent,
                       isOffline: model.isOffline,
                       lastSyncedAt: model.snapshot.lastSyncedAt,
                       isRefreshing: model.isRefreshing,
                       needsICloudAttention: model.readinessMessage != nil,
                       isSending: model.isRetryingUploads || model.isSendingNow,
                       pendingCount: pendingCount,
                       onlyStatusPending: model.myStatusWaitingToSend,
                       storageFull: model.storageFullAt != nil,
                       isParticipant: model.role == .participant,
                       onRetry: { Task { await model.retryPendingNow() } })
                .equatable()
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: unseen.first?.id)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The title is drawn by hand so a long press on it can open the
        // easter egg; `navigationTitle` stays for the back button.
        ToolbarItem(placement: .principal) {
            Text(AppConfig.appName)
                .font(.headline)
                .overlay(alignment: .bottomLeading) { titleThread }
                .onLongPressGesture(minimumDuration: 0.8, pressing: { down in
                    withAnimation(down && !reduceMotion ? .linear(duration: 0.8) : .easeOut(duration: 0.25)) {
                        titlePressing = down
                    }
                }) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    titlePressing = false
                    showingAnniversary = true
                }
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: Text("Our time together")) {
                    showingAnniversary = true
                }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showingLibrary = true
            } label: {
                Image(systemName: "photo.stack")
            }
            .disabled(model.history.isEmpty)
            .accessibilityLabel("Moments")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Sheets

    /// Every sheet hosts the model's error alert (`presentsModelErrors`): an
    /// error raised while one is up can't present from the root. Sheets inherit
    /// the model from this view's environment.
    private var sheets: HomeSheets {
        HomeSheets(showingPicker: $showingPicker,
                   showingSettings: $showingSettings,
                   showingComposer: $showingComposer,
                   showingVoiceComposer: $showingVoiceComposer,
                   showingLibrary: $showingLibrary,
                   showingStatusHistory: $showingStatusHistory,
                   showingAnniversary: $showingAnniversary,
                   showingFreshStart: $showingFreshStart,
                   carouselQueue: $carouselQueue,
                   carouselStart: $carouselStart)
    }

    // MARK: - Lifecycle

    private func lifecycle(unseenCount: Int) -> HomeLifecycle {
        HomeLifecycle(anySheetShowing: anySheetShowing,
                      homeInFront: homeInFront,
                      unseenCount: unseenCount,
                      voicePlayer: voicePlayer,
                      heartArrivals: $heartArrivals,
                      statusArrivals: $statusArrivals,
                      momentArrivals: $momentArrivals,
                      showsSent: $showsSent,
                      sentPillSeconds: Self.sentPillSeconds,
                      consumePendingRoute: consumePendingRoute)
    }

    // MARK: - Notices

    /// At most one at a time, most urgent first.
    private var activeNotice: HomeNotice? {
        if model.showsPartnerLeftNotice { return .partnerLeft }
        if let count = model.extraShareMembers { return .extraMembers(count) }
        // Offline the account check fails as a network error; the offline card covers it.
        if let problem = model.readinessMessage, !model.isOffline { return .iCloud(problem) }
        if model.freshStartNeedsAttention { return .freshStartStuck }
        if model.showsFreshStartRequest { return .freshStartRequest }
        if let problem = model.notificationsNotice { return .notificationsOff(problem) }
        if model.showsCloseLinkPrompt { return .closeLink }
        if model.showsWidgetTip { return .widgetTip }
        return nil
    }

    private func noticeView(_ notice: HomeNotice, partnerName: String) -> some View {
        HomeNoticeView(notice: notice,
                       partnerName: partnerName,
                       isOwner: model.role == .owner,
                       busy: model.isChangingInviteLink,
                       onAction: { act(on: notice) },
                       onDismiss: { dismiss(notice) })
            .equatable()
    }

    private func act(on notice: HomeNotice) {
        switch notice {
        case .partnerLeft:
            model.unlinkRequested = true
            showingSettings = true
        case .extraMembers:
            showingSettings = true
        case .iCloud:
            Task { await model.refresh() }
        case .freshStartStuck, .freshStartRequest:
            showingFreshStart = true
        case .notificationsOff:
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .closeLink:
            confirmingCloseLink = true
        case .widgetTip:
            model.dismissWidgetTip()
        }
    }

    private func dismiss(_ notice: HomeNotice) {
        switch notice {
        case .partnerLeft: model.dismissPartnerLeftNotice()
        case .freshStartRequest: model.dismissFreshStartRequest()
        case .notificationsOff: model.dismissNotificationsNotice()
        case .closeLink: model.dismissCloseLinkPrompt()
        case .extraMembers, .iCloud, .freshStartStuck, .widgetTip: break
        }
    }

    /// Grows under the title while it's held; fades in instead under Reduce Motion.
    private var titleThread: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Theme.accent)
                .frame(width: reduceMotion || titlePressing ? geometry.size.width : 0, height: 2)
                .opacity(reduceMotion && !titlePressing ? 0 : 1)
        }
        .frame(height: 2)
        .offset(y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Nobody is looking at Home otherwise, so nothing "arrives" on it.
    private var homeInFront: Bool {
        scenePhase == .active && !anySheetShowing && !model.rootSheetShowing
    }

    /// SwiftUI drops a second concurrent presentation, so the composer deep link
    /// is only consumed when it can actually be shown.
    private var anySheetShowing: Bool {
        showingPicker || showingSettings || showingComposer || showingVoiceComposer
            || showingLibrary || showingStatusHistory || showingAnniversary
            || showingFreshStart || !carouselQueue.isEmpty
    }

    private func consumePendingRoute() {
        guard let route = model.pendingRoute, !anySheetShowing, !model.rootSheetShowing else { return }
        model.pendingRoute = nil
        switch route {
        case .compose:
            showingComposer = true
        case .anniversary:
            showingAnniversary = true
        case .newMoments:
            carouselQueue = model.carouselMoments
        case .moment(let id):
            // Not filed yet (the widget can run ahead of the app): the new arrivals.
            guard let moment = model.history.first(where: { $0.id == id && !$0.isVoice }) else {
                carouselQueue = model.carouselMoments
                return
            }
            let unseen = model.unseenVisualMoments
            carouselStart = moment
            carouselQueue = unseen.contains { $0.id == id } ? unseen : [moment]
        }
    }

    // MARK: - Actions

    private var sendRow: some View {
        HStack(spacing: 10) {
            Button {
                showingComposer = true
            } label: {
                Label("Moment", systemImage: "camera.viewfinder")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                showingVoiceComposer = true
            } label: {
                Label("Voice memo", systemImage: "mic.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: - Latest voice memo

    /// Plays in place; playing marks it heard, which clears the widget's badge.
    private func voiceMemoRow(_ memo: Moment) -> some View {
        VoiceMemoRow(moment: memo,
                     audioURL: MomentStore.shared.mediaURL(for: memo),
                     player: voicePlayer,
                     filterEnabled: model.contentFilterEnabled) {
            if let url = MomentStore.shared.mediaURL(for: memo),
               voicePlayer.isPlaying(url) {
                voicePlayer.pause()
                return
            }
            Task {
                // Fetches from CloudKit first when the memo isn't cached.
                guard await model.ensureMedia(for: memo),
                      let url = MomentStore.shared.mediaURL(for: memo) else {
                    model.errorTitle = String(localized: "Can't play that yet")
                    model.errorMessage = model.isOffline
                        ? String(localized: "That voice memo isn't saved on this iPhone, so it can't play while you're offline. It will once you're back online.")
                        : String(localized: "Couldn't fetch that voice memo from iCloud. Try again in a moment.")
                    return
                }
                voicePlayer.play(url)
                model.markSeen(memo)
            }
        } onScrub: {
            model.markSeen(memo)
        }
    }
}

/// Home's sheets, apart from its body so neither is one long expression.
private struct HomeSheets: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var showingPicker: Bool
    @Binding var showingSettings: Bool
    @Binding var showingComposer: Bool
    @Binding var showingVoiceComposer: Bool
    @Binding var showingLibrary: Bool
    @Binding var showingStatusHistory: Bool
    @Binding var showingAnniversary: Bool
    @Binding var showingFreshStart: Bool
    @Binding var carouselQueue: [Moment]
    @Binding var carouselStart: Moment?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingPicker) {
                MoodPickerView(initialEmoji: model.snapshot.mine?.emoji ?? "",
                               currentMessage: model.snapshot.mine?.message ?? "",
                               recent: model.recentStatuses) { emoji, message, isCelebration in
                    Task {
                        await model.setStatus(emoji: emoji,
                                              message: message,
                                              isCelebration: isCelebration)
                    }
                }
                .presentsModelErrors()
            }
            // Hosts its own error alert, at its Form.
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingComposer) {
                MomentComposerView { image, kind, caption in
                    Task { await model.sendMoment(image: image, kind: kind, caption: caption) }
                }
                .presentsModelErrors()
            }
            .sheet(isPresented: $showingVoiceComposer) {
                VoiceMemoComposerView { url, duration, waveform, caption in
                    Task {
                        await model.sendVoiceMemo(fileURL: url,
                                                  duration: duration,
                                                  waveform: waveform,
                                                  caption: caption)
                    }
                }
                .presentsModelErrors()
            }
            .sheet(isPresented: Binding(get: { !carouselQueue.isEmpty },
                                        set: { if !$0 { carouselQueue = []; carouselStart = nil } })) {
                if let first = carouselStart ?? carouselQueue.first {
                    MomentGalleryView(moments: carouselQueue, startAt: first)
                        .presentsModelErrors()
                }
            }
            .sheet(isPresented: $showingLibrary) {
                MomentLibraryView()
                    .presentsModelErrors()
            }
            .sheet(isPresented: $showingStatusHistory) {
                StatusHistoryView()
                    .presentsModelErrors()
            }
            .sheet(isPresented: $showingAnniversary) {
                EasterEggView()
                    .presentsModelErrors()
            }
            .sheet(isPresented: $showingFreshStart) {
                NavigationStack {
                    FreshStartView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingFreshStart = false }
                            }
                        }
                }
                .presentsModelErrors()
            }
    }
}

/// Routes, the status read receipt, arrivals and announcements: everything
/// Home does on a change rather than draws.
private struct HomeLifecycle: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let anySheetShowing: Bool
    let homeInFront: Bool
    let unseenCount: Int
    let voicePlayer: VoicePlayer
    @Binding var heartArrivals: Int
    @Binding var statusArrivals: Int
    @Binding var momentArrivals: Int
    @Binding var showsSent: Bool
    let sentPillSeconds: TimeInterval
    let consumePendingRoute: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingRoute) { _, route in
                if route != nil { consumePendingRoute() }
            }
            // `onChange` misses a route latched while this view wasn't mounted, so
            // consume any pending one on mount too.
            .onAppear { consumePendingRoute() }
            // A deep link that arrived while another sheet was up stays latched;
            // present it once that sheet closes instead of silently dropping it.
            .onChange(of: anySheetShowing) { _, showing in
                // Root-level presentations (the anniversary prompt) wait on this.
                model.homeSheetShowing = showing
                guard !showing else {
                    // Otherwise the memo plays on under the sheet with no control in sight;
                    // paused, not stopped, so it keeps its place.
                    voicePlayer.pause()
                    return
                }
                consumePendingRoute()
                // A status that landed under a sheet is seen once it's uncovered —
                // unless the queued composer just covered it again.
                model.homeSheetShowing = anySheetShowing
                model.markPartnerStatusSeen()
            }
            .onChange(of: model.rootSheetShowing) { _, showing in
                if showing {
                    voicePlayer.pause()
                } else {
                    model.markPartnerStatusSeen()
                    consumePendingRoute()
                }
            }
            // Arrivals while Home is in front: the card updates in place under the
            // system banner, with a soft haptic.
            .onChange(of: model.snapshot.theirs?.lastNudgeAt) { old, new in
                if let new, new > old ?? .distantPast, homeInFront { heartArrivals += 1 }
            }
            .onChange(of: model.snapshot.theirs?.wordsAt) { old, new in
                if let new, new > old ?? .distantPast, homeInFront { statusArrivals += 1 }
            }
            .onChange(of: unseenCount) { old, new in
                if new > old, homeInFront { momentArrivals += 1 }
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: heartArrivals)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: statusArrivals)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: momentArrivals)
            .task(id: model.sendConfirmedAt) {
                guard let at = model.sendConfirmedAt, Date().timeIntervalSince(at) < sentPillSeconds else { return }
                withAnimation(.smooth) { showsSent = true }
                AccessibilityNotification.Announcement(String(localized: "Sent to \(model.partnerName)")).post()
                try? await Task.sleep(for: .seconds(sentPillSeconds))
                withAnimation(.smooth) { showsSent = false }
            }
            // Torn down with a sheet up (an unlink, a block) never fires the change
            // above; a flag left true would hold the anniversary prompt back for good.
            .onAppear { model.homeSheetShowing = anySheetShowing }
            .onDisappear { model.homeSheetShowing = false }
            // The status read receipt: their status counts as seen whenever it is
            // on this screen in the foreground — on arrival, and on every return.
            .onAppear { model.markPartnerStatusSeen() }
            .onChange(of: model.snapshot.theirs?.updatedAt) { _, _ in model.markPartnerStatusSeen() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                model.markPartnerStatusSeen()
                Task { await model.checkNotificationSettings() }
            }
            .task { await model.checkNotificationSettings() }
            // The card and the footer change silently; VoiceOver hears both.
            .onChange(of: model.isOffline) { _, offline in
                guard offline else { return }
                AccessibilityNotification.Announcement(String(localized: "You're offline. What you send waits on this iPhone.")).post()
            }
            .onChange(of: model.freshStartPhase) { old, new in
                guard case .clearing = old else { return }
                if case .clearing = new { return }
                AccessibilityNotification.Announcement(String(localized: "Your shared history is cleared on this iPhone.")).post()
            }
    }
}

#if DEBUG
#Preview("Home") {
    HomeView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
