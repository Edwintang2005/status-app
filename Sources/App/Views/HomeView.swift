import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingComposer = false
    @State private var showingVoiceComposer = false
    @State private var showingLibrary = false
    @State private var showingStatusHistory = false
    /// Owned here so leaving the screen or starting a second memo stops playback.
    @State private var voicePlayer = VoicePlayer()
    /// Snapshot taken when the carousel opens — paging marks moments seen, so
    /// reading `model.carouselMoments` live would shrink the list under the user.
    @State private var carouselQueue: [Moment] = []

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack {
                // Inside the stack: NavigationStack paints an opaque background
                // over anything layered underneath.
                Theme.Background()
                ScrollView {
                    VStack(spacing: 12) {
                        myStatusRow
                        NudgeButton(lastSentAt: model.snapshot.lastNudgeSentAt) {
                            await model.sendNudge()
                        }
                        sendRow
                        partnerCard
                        if let moment = model.unseenVisualMoments.first ?? model.latestVisualMoment {
                            momentCard(moment)
                        }
                        if let memo = model.latestReceivedVoiceMemo {
                            voiceMemoRow(memo)
                        }
                        syncFooter
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }
            }
            .navigationTitle(AppConfig.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingLibrary = true
                    } label: {
                        Image(systemName: "photo.stack")
                    }
                    .disabled(model.history.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingPicker) {
            MoodPickerView(initialEmoji: model.snapshot.mine?.emoji ?? "") { emoji, message, isCelebration in
                Task {
                    await model.setStatus(emoji: emoji,
                                          message: message,
                                          isCelebration: isCelebration)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingComposer) {
            MomentComposerView { image, kind, caption in
                Task { await model.sendMoment(image: image, kind: kind, caption: caption) }
            }
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
        }
        .sheet(isPresented: Binding(get: { !carouselQueue.isEmpty },
                                    set: { if !$0 { carouselQueue = [] } })) {
            if let first = carouselQueue.first {
                MomentGalleryView(moments: carouselQueue, startAt: first)
                    .environment(model)
            }
        }
        .sheet(isPresented: $showingLibrary) {
            MomentLibraryView()
                .environment(model)
        }
        .sheet(isPresented: $showingStatusHistory) {
            StatusHistoryView()
                .environment(model)
        }
        .onChange(of: model.pendingComposer) { _, pending in
            if pending { consumePendingComposer() }
        }
        // `onChange` misses a flag latched true while this view wasn't mounted
        // (true→true never fires), so consume any pending flag on mount too.
        .onAppear { consumePendingComposer() }
        // A deep link that arrived while another sheet was up stays latched;
        // present it once that sheet closes instead of silently dropping it.
        .onChange(of: anySheetShowing) { _, showing in
            if !showing { consumePendingComposer() }
        }
    }

    /// SwiftUI drops a second concurrent presentation, so the composer deep link
    /// is only consumed when it can actually be shown.
    private var anySheetShowing: Bool {
        showingPicker || showingSettings || showingComposer || showingVoiceComposer
            || showingLibrary || showingStatusHistory || !carouselQueue.isEmpty
    }

    private func consumePendingComposer() {
        guard model.pendingComposer, !anySheetShowing else { return }
        showingComposer = true
        model.pendingComposer = false
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
    }

    private var partnerCardContent: some View {
        HStack(spacing: 14) {
            if let theirs = model.snapshot.theirs {
                Text(theirs.emoji)
                    .font(.system(size: 46))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: theirs.emoji)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.partnerName.uppercased())
                        .font(Theme.rounded(11, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                    Text(theirs.message.isEmpty ? "no message" : theirs.message)
                        .font(Theme.rounded(20, .semibold))
                        .lineLimit(2)
                        .foregroundStyle(theirs.message.isEmpty ? .secondary : .primary)
                    // TimelineView because `.relative(presentation:)` renders
                    // once and never ticks on its own.
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(theirs.updatedAt, format: .relative(presentation: .named))
                            .font(Theme.rounded(11))
                            .foregroundStyle(.tertiary)
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
                            .background(Theme.warm, in: Capsule())
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
                    model.errorMessage = "Couldn't fetch that voice memo from iCloud. Try again in a moment."
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
        if moment.caption.isEmpty {
            return moment.fromMe
                ? "You sent a \(moment.noun)"
                : "Sent you a \(moment.noun)"
        }
        return moment.fromMe ? "You: \(moment.caption)" : moment.caption
    }

    // MARK: - Mine

    private var myStatusRow: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 12) {
                Text(model.snapshot.mine?.emoji ?? "➕")
                    .font(.system(size: 26))

                Text(model.snapshot.mine?.message.isEmpty == false
                     ? model.snapshot.mine!.message
                     : "Set your status")
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(model.snapshot.mine?.message.isEmpty == false
                                     ? .primary
                                     : .secondary)
                    .lineLimit(1)

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
    }

    private var syncFooter: some View {
        // TimelineView so the relative timestamp keeps ticking.
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            HStack(spacing: 6) {
                if model.isRefreshing {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…")
                } else if let problem = model.readinessMessage {
                    // Only place a paired user hears about iCloud account
                    // problems — the pairing screen isn't mounted any more.
                    Image(systemName: "exclamationmark.icloud")
                    Text(problem)
                } else if model.pendingUploadCount > 0 {
                    // Ahead of "Synced …", which would mislead while an upload
                    // is still sitting on this device.
                    Image(systemName: "icloud.and.arrow.up")
                    Text(model.pendingUploadCount == 1
                         ? "1 waiting to send"
                         : "\(model.pendingUploadCount) waiting to send")
                } else if let synced = model.snapshot.lastSyncedAt {
                    Image(systemName: "checkmark.icloud")
                    Text("Synced \(synced, format: .relative(presentation: .named))")
                } else {
                    Image(systemName: "icloud.slash")
                    Text("Not synced yet")
                }
            }
            .font(Theme.rounded(12))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
    }
}

/// Owns its countdown so ticking is scoped to this button and no timer runs
/// outside the sixty seconds after a nudge.
private struct NudgeButton: View {
    let lastSentAt: Date?
    let action: () async -> Void

    @State private var remaining: TimeInterval = 0

    private var ready: Bool { remaining == 0 }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(ready ? "Thinking of you" : "Sent · \(Int(remaining))s",
                  systemImage: ready ? "heart.fill" : "checkmark")
        }
        // Accent, not warm: the heart wears the red string's crimson.
        .buttonStyle(PrimaryButtonStyle(tint: ready ? Theme.accent : Color.secondary.opacity(0.4)))
        .disabled(!ready)
        .animation(.smooth, value: ready)
        .task(id: lastSentAt) { await countDown() }
    }

    private func countDown() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(lastSentAt ?? .distantPast)
            remaining = max(0, AppConfig.nudgeCooldown - elapsed)
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
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
