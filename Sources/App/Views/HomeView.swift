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
    /// The user chose to see a filter-hidden status message this once.
    @State private var revealFilteredStatus = false
    @State private var confirmingStatusReport = false
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

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack {
                // Inside the stack: NavigationStack paints an opaque background
                // over anything layered underneath.
                Theme.Background()
                ScrollView {
                    // Them first: what you open the app to see, then your reply to it.
                    VStack(spacing: 12) {
                        // In the scroll content, not pinned above it: a sibling
                        // that resizes the scroll view looped layout against the bar.
                        if model.isOffline {
                            OfflineBanner(pendingCount: model.pendingSendCount,
                                          mobileDataDenied: model.mobileDataDenied,
                                          storageFull: model.storageFullAt != nil)
                                .transition(.opacity)
                        }
                        if let notice = activeNotice, notice.urgent {
                            noticeCard(notice)
                        }
                        partnerCard
                        myStatusRow
                        NudgeButton(lastSentAt: model.snapshot.lastNudgeSentAt,
                                    lastFailedAt: model.snapshot.lastNudgeFailedAt) {
                            await model.sendNudge()
                        }
                        sendRow
                        if let notice = activeNotice, !notice.urgent {
                            noticeCard(notice)
                        }
                        if let moment = model.unseenVisualMoments.first ?? model.latestVisualMoment {
                            momentCard(moment)
                                .id(moment.id)
                                .transition(.opacity)
                        }
                        if let memo = model.latestReceivedVoiceMemo {
                            voiceMemoRow(memo)
                        }
                        syncFooter
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4),
                               value: model.unseenVisualMoments.first?.id)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .animation(.smooth(duration: 0.3), value: model.isOffline)
                    // Pin the scrollable content to the viewport: a child with a
                    // wide *ideal* size (a long single-line Text) can otherwise
                    // inflate the content's horizontal extent on some OS builds,
                    // letting the whole screen pan sideways.
                    .containerRelativeFrame(.horizontal)
                }
                .scrollIndicators(.hidden)
                .hardTopScrollEdge()
                .refreshable { await model.refresh() }
            }
            .navigationTitle(AppConfig.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        }
        // Every sheet hosts the model's error alert (`presentsModelErrors`):
        // an error raised while one is up can't present from the root.
        .sheet(isPresented: $showingPicker) {
            MoodPickerView(initialEmoji: model.snapshot.mine?.emoji ?? "",
                           currentMessage: model.snapshot.mine?.message ?? "",
                           recent: model.recentOwnStatuses()) { emoji, message, isCelebration in
                Task {
                    await model.setStatus(emoji: emoji,
                                          message: message,
                                          isCelebration: isCelebration)
                }
            }
            .presentsModelErrors()
        }
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
                    .environment(model)
                    .presentsModelErrors()
            }
        }
        .sheet(isPresented: $showingLibrary) {
            MomentLibraryView()
                .environment(model)
                .presentsModelErrors()
        }
        .sheet(isPresented: $showingStatusHistory) {
            StatusHistoryView()
                .environment(model)
                .presentsModelErrors()
        }
        .sheet(isPresented: $showingAnniversary) {
            EasterEggView()
                .environment(model)
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
            .environment(model)
            .presentsModelErrors()
        }
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
            guard !showing else { return }
            consumePendingRoute()
            // A status that landed under a sheet is seen once it's uncovered —
            // unless the queued composer just covered it again.
            model.homeSheetShowing = anySheetShowing
            model.markPartnerStatusSeen()
        }
        .onChange(of: model.rootSheetShowing) { _, showing in
            if !showing {
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
        .onChange(of: model.unseenVisualMoments.count) { old, new in
            if new > old, homeInFront { momentArrivals += 1 }
        }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: heartArrivals)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: statusArrivals)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: momentArrivals)
        .task(id: model.sendConfirmedAt) {
            guard let at = model.sendConfirmedAt, Date().timeIntervalSince(at) < 3 else { return }
            withAnimation(.smooth) { showsSent = true }
            try? await Task.sleep(for: .seconds(3))
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
            if phase == .active { model.markPartnerStatusSeen() }
        }
        .confirmationDialog("Close the invite link?",
                            isPresented: $confirmingCloseLink,
                            titleVisibility: .visible) {
            Button("Close and re-seat \(model.partnerName)", role: .destructive) {
                Task { await model.closeInviteReseatingPartner() }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Closing it briefly takes \(model.partnerName) off your shared space and re-adds them privately. Have them ready: they tap the invite link once more to get back in. If anything fails, the app tries to reopen the link and tells you how it went.")
        }
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

    // MARK: - Notices

    private enum Notice {
        case extraMembers(Int), iCloud(String), freshStartStuck, freshStartRequest, closeLink, widgetTip

        /// Urgent ones sit above the partner card; the rest below the send row.
        var urgent: Bool {
            switch self {
            case .extraMembers, .iCloud, .freshStartStuck: true
            case .freshStartRequest, .closeLink, .widgetTip: false
            }
        }
    }

    /// At most one at a time, most urgent first.
    private var activeNotice: Notice? {
        if let count = model.extraShareMembers { return .extraMembers(count) }
        // Offline the account check fails as a network error; the offline card covers it.
        if let problem = model.readinessMessage, !model.isOffline { return .iCloud(problem) }
        if model.freshStartNeedsAttention { return .freshStartStuck }
        if model.showsFreshStartRequest { return .freshStartRequest }
        if model.showsCloseLinkPrompt { return .closeLink }
        if model.showsWidgetTip { return .widgetTip }
        return nil
    }

    @ViewBuilder
    private func noticeCard(_ notice: Notice) -> some View {
        switch notice {
        case .extraMembers(let count):
            HomeNoticeCard(systemImage: "person.2.badge.gearshape",
                           title: "Someone else has joined",
                           message: "\(count) people besides you are on your shared space, not just \(model.partnerName). Closing the invite link can't remove them. If that isn't right, unlink in Settings — it deletes the shared space for both of you — and send \(model.partnerName) a new link.",
                           actionTitle: "Open Settings",
                           urgent: true) {
                showingSettings = true
            }
        case .iCloud(let problem):
            // The footer only had room for this in 12 pt; nothing syncs until it's fixed.
            HomeNoticeCard(systemImage: "exclamationmark.icloud",
                           title: "iCloud needs attention",
                           message: "\(problem)",
                           actionTitle: "Check again",
                           urgent: true) {
                Task { await model.refresh() }
            }
        case .freshStartStuck:
            HomeNoticeCard(systemImage: "exclamationmark.arrow.circlepath",
                           title: "Your fresh start hasn't finished",
                           message: "This iPhone couldn't clear its side yet. It tries again whenever the app opens.",
                           actionTitle: "Review…",
                           urgent: true) {
                showingFreshStart = true
            }
        case .freshStartRequest:
            // The request's only delivery: no push, no banner (it rides any refresh).
            HomeNoticeCard(systemImage: "sparkles",
                           title: "\(model.partnerName) asked for a fresh start",
                           message: "Clearing the history you share — moments, status history and read receipts — from both iPhones. Your link, your statuses and the heart stay. Nothing changes unless you agree.",
                           actionTitle: "Review…",
                           dismissTitle: "Not now",
                           onDismiss: { model.dismissFreshStartRequest() }) {
                showingFreshStart = true
            }
        case .closeLink:
            HomeNoticeCard(systemImage: "lock.open",
                           title: "\(model.partnerName)'s in",
                           message: "Your invite link still lets anyone who has it join. Close it while you're together: \(model.partnerName) taps the link once more to get back in.",
                           actionTitle: "Close the link…",
                           dismissTitle: "Don't show again",
                           busy: model.isChangingInviteLink,
                           onDismiss: { model.dismissCloseLinkPrompt() }) {
                confirmingCloseLink = true
            }
        case .widgetTip:
            HomeNoticeCard(systemImage: "lock.iphone",
                           title: "Put \(model.partnerName) on your Lock Screen",
                           message: "Touch and hold your Lock Screen, tap Customize, then the Lock Screen, and add \(AppConfig.appName) to the widget row: their status, and the heart that sends a nudge, without unlocking.",
                           actionTitle: "Got it") {
                model.dismissWidgetTip()
            }
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

    // MARK: - Partner status

    /// Tapping the card opens the status history.
    private var partnerCard: some View {
        Button {
            showingStatusHistory = true
        } label: {
            partnerCardContent
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .keyframeAnimator(initialValue: 0.0, trigger: statusArrivals + heartArrivals) { glow, opacity in
                    glow.opacity(opacity)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(0.7, duration: 0.15)
                        LinearKeyframe(0, duration: 0.9)
                    }
                }
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if !reduceMotion {
                Image(systemName: "heart.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                    .keyframeAnimator(initialValue: FloatingHeart(), trigger: heartArrivals) { heart, value in
                        heart.opacity(value.opacity).offset(y: value.rise).scaleEffect(value.scale)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.15)
                            LinearKeyframe(1, duration: 0.45)
                            LinearKeyframe(0, duration: 0.4)
                        }
                        KeyframeTrack(\.rise) {
                            CubicKeyframe(-48, duration: 1.0)
                        }
                        KeyframeTrack(\.scale) {
                            SpringKeyframe(1.2, duration: 0.3)
                            CubicKeyframe(0.9, duration: 0.7)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(partnerSummary)
        .accessibilityHint("Shows status history")
        .contextMenu {
            if model.snapshot.theirs != nil, !model.isPartnerStatusReported {
                Button(role: .destructive) {
                    confirmingStatusReport = true
                } label: {
                    Label("Report this status…", systemImage: "flag")
                }
            }
            if partnerMessageIsFiltered, !revealFilteredStatus {
                Button {
                    revealFilteredStatus = true
                } label: {
                    Label("Show hidden text", systemImage: "eye")
                }
            }
        }
        .confirmationDialog("Report this status?",
                            isPresented: $confirmingStatusReport,
                            titleVisibility: .visible) {
            Button("Report", role: .destructive) { model.reportPartnerStatus() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text is hidden on this iPhone straight away, and the details go to us by email. We act on reports within 24 hours.")
        }
        .onChange(of: model.snapshot.theirs?.updatedAt) { _, _ in revealFilteredStatus = false }
    }

    private var partnerMessageIsFiltered: Bool {
        guard let theirs = model.snapshot.theirs else { return false }
        return ContentFilter.hides(theirs.message)
    }

    /// The partner's message as shown: reported → says so; filtered → the
    /// placeholder until revealed; otherwise the words.
    private var partnerMessage: (text: String, muted: Bool) {
        guard let theirs = model.snapshot.theirs else { return ("", true) }
        if model.isPartnerStatusReported { return (String(localized: "Reported"), true) }
        if partnerMessageIsFiltered && !revealFilteredStatus {
            return (ContentFilter.hiddenPlaceholder, true)
        }
        // Emoji-only is a status, not a missing one: the emoji stands alone.
        return (theirs.message, false)
    }

    /// Their last heart, while it's under a day old — the banner is swept when
    /// the app opens, so otherwise nothing in the app would say it came.
    private var partnerHeartAt: Date? {
        guard let at = model.snapshot.theirs?.lastNudgeAt, Date().timeIntervalSince(at) < 24 * 60 * 60 else { return nil }
        // A clock ahead of ours never reads "in 3 hours".
        return min(at, Date())
    }

    /// VoiceOver's reading of the partner card: name, emoji, message, age.
    private var partnerSummary: String {
        guard let theirs = model.snapshot.theirs else {
            return String(localized: "\(model.partnerName): waiting for their first status")
        }
        let when = theirs.wordsAt.relativeWording()
        // Same as the card: a reported status reads 💭 here too.
        let emoji = model.isPartnerStatusReported ? "💭" : theirs.emoji
        let words = partnerMessage.text.isEmpty ? "" : " \(partnerMessage.text)"
        var summary = "\(model.partnerName): \(emoji)\(words), \(when)"
        if let heartAt = partnerHeartAt {
            summary += String(localized: ". Thinking of you, \(heartAt.relativeWording())")
        }
        return summary
    }

    private var partnerCardContent: some View {
        HStack(spacing: 14) {
            if let theirs = model.snapshot.theirs {
                // A reported status loses its emoji too — a custom emoji can be
                // the offence — matching the widget and the banner.
                Text(model.isPartnerStatusReported ? "💭" : theirs.emoji)
                    .font(.system(size: partnerMessage.text.isEmpty ? 56 : 46))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: theirs.emoji)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.partnerName.uppercased())
                        .font(Theme.rounded(11, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.mutedText)
                    if !partnerMessage.text.isEmpty {
                        Text(partnerMessage.text)
                            .font(Theme.rounded(20, .semibold))
                            .lineLimit(2)
                            // Wrap within the proposed width rather than reporting a
                            // single-line ideal — see the containerRelativeFrame note.
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(partnerMessage.muted ? Theme.mutedText : .primary)
                            .contentTransition(.opacity)
                            .animation(.smooth, value: partnerMessage.text)
                    }
                    RelativeTime(theirs.wordsAt)
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                    if let heartAt = partnerHeartAt {
                        RelativeTime(heartAt) { when in
                            Label("thinking of you · \(when)", systemImage: "heart.fill")
                        }
                        .font(Theme.rounded(13, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .symbolEffect(.bounce, value: reduceMotion ? 0 : heartArrivals)
                        .padding(.top, 3)
                    }
                }
            } else {
                Text("💭").font(.system(size: 46)).opacity(0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.partnerName.uppercased())
                        .font(Theme.rounded(11, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text("Waiting for their first status")
                        .font(Theme.rounded(16, .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "clock.arrow.circlepath")
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(.tertiary)
        }
        .card(padding: 16)
    }

    // MARK: - Latest moment

    private func momentCard(_ moment: Moment) -> some View {
        let unseen = model.unseenVisualMoments.count

        return Button {
            carouselQueue = model.carouselMoments
        } label: {
            VStack(spacing: 0) {
                SquareFill {
                    if let image = MomentStore.shared.thumbnail(for: moment.id) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
                .clipped()

                HStack(spacing: 8) {
                    Image(systemName: moment.symbolName)
                        .font(Theme.rounded(12))
                        .foregroundStyle(.secondary)
                    Text(momentLabel(moment))
                        .font(Theme.rounded(15, .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unseen > 0 {
                        Text(unseen == 1 ? "new" : "\(unseen) new")
                            .font(Theme.rounded(11, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.warmDeep, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseen > 1
                            ? String(localized: "\(momentLabel(moment)). \(unseen) new")
                            : unseen == 1 ? String(localized: "\(momentLabel(moment)). New") : momentLabel(moment))
        .accessibilityHint("Opens it")
        // On the whole card, not the picture: zooming only the square would be
        // cut off by the card's rounded clip.
        .pinchToZoom()
    }

    // MARK: - Latest voice memo

    /// Plays in place; playing marks it heard, which clears the widget's badge.
    private func voiceMemoRow(_ memo: Moment) -> some View {
        VoiceMemoRow(moment: memo,
                     audioURL: MomentStore.shared.mediaURL(for: memo),
                     player: voicePlayer) {
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

    private func momentLabel(_ moment: Moment) -> String {
        // A filtered caption reads as no caption; the gallery can reveal it.
        guard let caption = moment.displayCaption else {
            return moment.fromMe
                ? String(localized: "You sent a \(moment.noun)")
                : String(localized: "Sent you a \(moment.noun)")
        }
        return moment.fromMe ? String(localized: "You: \(caption)") : caption
    }

    // MARK: - Mine

    private var myStatusRow: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 12) {
                Text(model.snapshot.mine?.emoji ?? "➕")
                    .font(.system(size: 26))

                VStack(alignment: .leading, spacing: 1) {
                    Text(myStatusText)
                        .font(myStatusHasWords ? Theme.rounded(17, .semibold) : Theme.rounded(16))
                        .foregroundStyle(myStatusHasWords ? .primary : Theme.mutedText)
                        .lineLimit(1)
                    if myStatusUnsent {
                        // Retried on every refresh; the footer offers it now.
                        Label("Not sent yet · will retry", systemImage: "icloud.and.arrow.up")
                            .font(Theme.rounded(12, .semibold))
                            .foregroundStyle(Theme.warmText)
                    } else if let seenAt = model.myStatusSeenAt {
                        // The status read receipt — read receipts on, both sides.
                        RelativeTime(seenAt) { when in
                            Label("Seen \(when)", systemImage: "eye.fill")
                        }
                        .font(Theme.rounded(12))
                        .foregroundStyle(Theme.mutedText)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.rounded(13, .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(myStatusSummary)
        .accessibilityHint("Changes your status")
    }

    /// An emoji-only status is a status: the emoji stands beside an invitation
    /// to add words, rather than "Set your status" or a blank line.
    private var myStatusText: String {
        guard let mine = model.snapshot.mine else { return String(localized: "Set your status") }
        if !mine.message.isEmpty { return mine.message }
        return mine.emoji.isEmpty ? String(localized: "Set your status") : String(localized: "Tap to add words")
    }

    private var myStatusHasWords: Bool { model.snapshot.mine?.message.isEmpty == false }

    /// Set while offline (or a publish failed) and not being sent right now.
    private var myStatusUnsent: Bool { model.myStatusWaitingToSend }

    private var myStatusSummary: String {
        guard let mine = model.snapshot.mine, !mine.message.isEmpty || !mine.emoji.isEmpty else {
            return String(localized: "Set your status")
        }
        var summary = String(localized: "Your status: \(mine.emoji) \(mine.message)")
        if myStatusUnsent {
            summary += String(localized: ". Not sent yet, will retry")
        } else if let seenAt = model.myStatusSeenAt {
            summary += String(localized: ". Seen \(seenAt.relativeWording())")
        }
        return summary
    }

    /// Says whose storage is full when that's why sends are stuck — only the owner can fix it.
    private var pendingLabel: String {
        let count = model.pendingSendCount
        if count == 1, myStatusUnsent, model.storageFullAt == nil {
            return String(localized: "Your status is waiting to send · tap to retry")
        }
        guard model.storageFullAt != nil else {
            return count == 1
                ? String(localized: "1 waiting to send · tap to retry")
                : String(localized: "\(count) waiting to send · tap to retry")
        }
        return model.role == .participant
            ? String(localized: "\(model.partnerName)'s iCloud is full · \(count) waiting · tap to retry")
            : String(localized: "Your iCloud is full · \(count) waiting · tap to retry")
    }

    /// How fresh the screen is; the offline card up top carries what's queued.
    @ViewBuilder
    private var offlineLabel: some View {
        if let synced = model.snapshot.lastSyncedAt {
            RelativeTime(synced) { Text("Offline · synced \($0)") }
        } else {
            Text("Offline")
        }
    }

    /// The bottom line: sync state, and — as a pill — a send just confirmed or
    /// one still waiting, which taps to retry.
    private var syncFooter: some View {
        HStack(spacing: 6) {
            if showsSent {
                Label("Sent to \(model.partnerName)", systemImage: "checkmark")
                    .modifier(FooterPill(tint: Theme.accentText))
                    .transition(.opacity)
            } else if model.isOffline {
                // Ahead of the rest: offline, a refresh fails at once and readiness reads as a network error.
                Image(systemName: "wifi.slash")
                offlineLabel
            } else if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if model.readinessMessage != nil {
                // The full story is in the notice at the top.
                Image(systemName: "exclamationmark.icloud")
                Text("iCloud needs attention")
            } else if model.isRetryingUploads || model.isSendingNow {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            } else if model.pendingSendCount > 0 {
                // Ahead of "Synced …", which would mislead while a send is
                // still sitting on this device. Tapping retries now.
                Button {
                    Task { await model.retryPendingNow() }
                } label: {
                    Label(pendingLabel,
                          systemImage: model.storageFullAt == nil ? "icloud.and.arrow.up" : "exclamationmark.icloud")
                        .modifier(FooterPill(tint: Theme.warmText))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Retries the send now")
            } else if let synced = model.snapshot.lastSyncedAt {
                Image(systemName: "checkmark.icloud")
                RelativeTime(synced) { Text("Synced \($0)") }
            } else {
                Image(systemName: "icloud.slash")
                Text("Not synced yet")
            }
        }
        .font(Theme.rounded(12))
        .foregroundStyle(Theme.mutedText)
        .padding(.top, 4)
        // Combined into one line for VoiceOver, except while the retry
        // button is showing — combining would swallow its action.
        .accessibilityElement(children: model.pendingSendCount > 0 && !model.isRetryingUploads
                              && !model.isSendingNow && !model.isOffline
                              ? .contain : .combine)
    }
}

/// Home's offline notice: everything on this iPhone still works, and what's
/// queued goes when the connection does.
private struct OfflineBanner: View {
    let pendingCount: Int
    let mobileDataDenied: Bool
    /// Reconnecting won't send it: the owner's iCloud has no room.
    let storageFull: Bool

    private var title: String {
        mobileDataDenied ? String(localized: "Mobile data is off for Red String") : String(localized: "You're offline")
    }

    private var detail: String {
        switch pendingCount {
        case 1... where storageFull: String(localized: "What you've sent is saved here, waiting for iCloud space.")
        case 0 where mobileDataDenied: String(localized: "Turn it on in Settings, or join Wi-Fi. You can still look back and send.")
        case 0: String(localized: "You can still look back and send — it goes when you reconnect.")
        case 1: String(localized: "1 thing will send when you're back online.")
        default: String(localized: "\(pendingCount) things will send when you're back online.")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(Theme.rounded(17, .semibold))
                .foregroundStyle(Theme.warmText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.rounded(15, .semibold))
                Text(detail)
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The footer's send state, as a pill rather than a line of small print.
private struct FooterPill: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(Theme.rounded(13, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The partner card's rising heart, one keyframe track per property.
private struct FloatingHeart {
    var opacity = 0.0
    var rise = 0.0
    var scale = 0.6
}

/// One of Home's one-at-a-time notices (see `HomeView.homeNotice`).
private struct HomeNoticeCard: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    var dismissTitle: LocalizedStringKey?
    /// Orange for a warning, crimson otherwise — each in its AA-safe shade.
    var urgent = false
    /// The action is running (the close handshake takes seconds): not tappable again.
    var busy = false
    var onDismiss: () -> Void = {}
    let action: () -> Void

    private var tint: Color { urgent ? Theme.warmText : Theme.accentText }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(Theme.rounded(16, .semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(Theme.rounded(14))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(actionTitle)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .font(Theme.rounded(15, .semibold))
                .foregroundStyle(tint)
                .disabled(busy)
                if let dismissTitle {
                    Button(action: onDismiss) {
                        Text(dismissTitle)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .font(Theme.rounded(15))
                    .foregroundStyle(.primary.opacity(0.7))
                    .disabled(busy)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .accessibilityElement(children: .contain)
    }
}

/// Owns its countdown so ticking is scoped to this button and no timer runs
/// outside the cooldown after a nudge (`AppConfig.nudgeCooldown`). A failed
/// send says so on the button for `AppConfig.nudgeFailureNotice`, like the
/// lock-screen heart — no alert.
private struct NudgeButton: View {
    let lastSentAt: Date?
    let lastFailedAt: Date?
    let action: () async -> Void

    @State private var remaining: TimeInterval = 0
    @State private var failed = false

    private var ready: Bool { remaining == 0 }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if !ready {
                Label("Sent · \(Int(remaining))s", systemImage: "checkmark")
            } else if failed {
                Label("Didn't send · tap to retry", systemImage: "heart.slash.fill")
            } else {
                Label("Thinking of you", systemImage: "heart.fill")
            }
        }
        // Accent, not warm: the heart wears the red string's crimson.
        .buttonStyle(PrimaryButtonStyle(tint: !ready ? Color.secondary.opacity(0.4)
                                        : failed ? Theme.warmDeep : Theme.accent))
        .disabled(!ready)
        .accessibilityLabel(!ready ? "Nudge sent" : failed ? "Nudge didn't send. Send again" : "Send a nudge")
        .animation(.smooth, value: ready)
        .animation(.smooth, value: failed)
        .task(id: lastSentAt) { await countDown() }
        .task(id: lastFailedAt) { await watchFailure() }
    }

    private func countDown() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(lastSentAt ?? .distantPast)
            remaining = max(0, AppConfig.nudgeCooldown - elapsed)
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func watchFailure() async {
        let left = lastFailedAt.map { AppConfig.nudgeFailureNotice - Date().timeIntervalSince($0) } ?? 0
        failed = left > 0
        guard left > 0 else { return }
        try? await Task.sleep(for: .seconds(left))
        if !Task.isCancelled { failed = false }
    }
}

#if DEBUG
#Preview("Home") {
    HomeView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
