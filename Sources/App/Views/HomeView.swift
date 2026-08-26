import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingComposer = false
    @State private var showingVoiceComposer = false
    @State private var showingLibrary = false
    /// One player for the memo rows, owned here so leaving the screen — or
    /// starting a second memo — stops whatever was playing.
    @State private var voicePlayer = VoicePlayer()
    /// Captured when the carousel opens. Reading `model.carouselMoments`
    /// straight from the sheet would shrink the list underneath the user:
    /// paging marks each one seen, which removes it from the unseen set.
    @State private var carouselQueue: [Moment] = []

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack {
                // Inside the stack, not behind it: NavigationStack paints an
                // opaque system background over anything layered underneath.
                Theme.Background()
                ScrollView {
                    // Ordered by what you came here to do: set your own status,
                    // send something, see how they are, then whatever is
                    // waiting for you.
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
            MoodPickerView(initialEmoji: model.snapshot.mine?.emoji ?? "",
                           initialMessage: model.snapshot.mine?.message ?? "",
                           initialIsCelebration: model.snapshot.mine?.isCelebration ?? false) { emoji, message, isCelebration in
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
        .onChange(of: model.pendingComposer) { _, pending in
            if pending {
                showingComposer = true
                model.pendingComposer = false
            }
        }
        // `onChange` only fires on *changes*: a widget tap that landed while
        // this view wasn't mounted (unpaired, mid-onboarding) latched the flag
        // true, and every later tap was true→true — the deep link stayed dead
        // until relaunch. Consume whatever is pending on mount too.
        .onAppear {
            if model.pendingComposer {
                showingComposer = true
                model.pendingComposer = false
            }
        }
    }

    // MARK: - Actions

    /// Two ways to send something, side by side. Equal weight on purpose — a
    /// memo is as much a moment as a photo is, not a secondary option buried
    /// inside the photo composer.
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

    /// Laid out sideways rather than as a tall centred block: their status is
    /// the thing you check most often, and it shouldn't cost most of a screen
    /// to read.
    private var partnerCard: some View {
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
                    Text(theirs.updatedAt, format: .relative(presentation: .named))
                        .font(Theme.rounded(11))
                        .foregroundStyle(.tertiary)
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
        }
        .card(padding: 16)
    }

    // MARK: - Latest moment

    private func momentCard(_ moment: Moment) -> some View {
        let unseen = model.unseenVisualMoments.count

        // Only what's waiting — or, when caught up, just the latest. The whole
        // archive lives behind the library button instead.
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
    }

    // MARK: - Latest voice memo

    /// Plays in place. Nothing opens, because there is nothing to look at.
    /// The row stays put after it's been played — it's the last thing they
    /// said, and wanting to hear that twice is normal — while playing it marks
    /// it heard, which is what clears the widget's badge.
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
                // Recent memos are already cached; one that isn't comes back
                // from CloudKit first.
                guard await model.ensureMedia(for: memo),
                      let url = MomentStore.shared.mediaURL(for: memo) else {
                    // A tap that produces neither sound nor explanation reads
                    // as the app being broken, not the network.
                    model.errorMessage = "Couldn't fetch that voice memo from iCloud. Try again in a moment."
                    return
                }
                voicePlayer.play(url)
                model.markSeen(memo)
            }
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

    /// A single slim row at the top of the screen. Setting your own status is
    /// the most frequent thing anyone does here, so it wants to be reachable
    /// without scrolling — and a whole card's worth of height buys nothing,
    /// since it's one emoji and one line of text.
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
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
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

/// Owns its own countdown so the ticking is scoped to this button rather than
/// invalidating the whole screen — and, more importantly, so no timer runs at
/// all outside the sixty seconds after a nudge.
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
        .buttonStyle(PrimaryButtonStyle(tint: ready ? Theme.warm : Color.secondary.opacity(0.4)))
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
