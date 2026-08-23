import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPicker = false
    @State private var showingSettings = false
    @State private var showingComposer = false
    @State private var galleryStart: Moment?

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            ZStack {
                // Inside the stack, not behind it: NavigationStack paints an
                // opaque system background over anything layered underneath.
                Theme.Background()
                ScrollView {
                    VStack(spacing: 18) {
                        NudgeButton(lastSentAt: model.snapshot.lastNudgeSentAt) {
                            await model.sendNudge()
                        }
                        momentButton
                        partnerCard
                        if let moment = model.snapshot.moments.first {
                            momentCard(moment)
                        }
                        myStatusCard
                        syncFooter
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.refresh() }
            }
            .navigationTitle(AppConfig.appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                           initialMessage: model.snapshot.mine?.message ?? "") { emoji, message in
                Task { await model.setStatus(emoji: emoji, message: message) }
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
        .sheet(item: $galleryStart) { moment in
            MomentGalleryView(moments: model.snapshot.moments, startAt: moment)
        }
        .onChange(of: model.pendingComposer) { _, pending in
            if pending {
                showingComposer = true
                model.pendingComposer = false
            }
        }
    }

    // MARK: - Actions

    private var momentButton: some View {
        Button {
            showingComposer = true
        } label: {
            Label("Send a photo or doodle", systemImage: "camera.viewfinder")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    // MARK: - Partner status

    private var partnerCard: some View {
        VStack(spacing: 14) {
            Text(model.partnerName.uppercased())
                .font(Theme.rounded(13, .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            if let theirs = model.snapshot.theirs {
                Text(theirs.emoji)
                    .font(.system(size: 88))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: theirs.emoji)

                Text(theirs.message.isEmpty ? "no message" : theirs.message)
                    .font(Theme.rounded(24, .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theirs.message.isEmpty ? .secondary : .primary)

                Text(theirs.updatedAt, format: .relative(presentation: .named))
                    .font(Theme.rounded(13))
                    .foregroundStyle(.tertiary)
            } else {
                Text("💭").font(.system(size: 88)).opacity(0.4)
                Text("Waiting for their first status")
                    .font(Theme.rounded(18, .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 12)
        .card(padding: 24)
    }

    // MARK: - Latest moment

    private func momentCard(_ moment: Moment) -> some View {
        Button {
            galleryStart = moment
        } label: {
            VStack(spacing: 0) {
                if let image = MomentStore.shared.thumbnail(for: moment.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }

                HStack(spacing: 8) {
                    Image(systemName: moment.kind == .photo ? "camera.fill" : "scribble")
                        .font(Theme.rounded(12))
                        .foregroundStyle(.secondary)
                    Text(momentLabel(moment))
                        .font(Theme.rounded(15, .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.snapshot.moments.count > 1 {
                        Text("\(model.snapshot.moments.count)")
                            .font(Theme.rounded(11, .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: Capsule())
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

    private func momentLabel(_ moment: Moment) -> String {
        let noun = moment.kind == .photo ? "photo" : "drawing"
        if moment.caption.isEmpty {
            return moment.fromMe ? "You sent a \(noun)" : "Sent you a \(noun)"
        }
        return moment.fromMe ? "You: \(moment.caption)" : moment.caption
    }

    // MARK: - Mine

    private var myStatusCard: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 16) {
                Text(model.snapshot.mine?.emoji ?? "➕")
                    .font(.system(size: 40))

                VStack(alignment: .leading, spacing: 3) {
                    Text("You")
                        .font(Theme.rounded(12, .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text(model.snapshot.mine?.message.isEmpty == false
                         ? model.snapshot.mine!.message
                         : "Set your status")
                        .font(Theme.rounded(18, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(Theme.rounded(14, .semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    private var syncFooter: some View {
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            } else if model.isLocalDemo {
                Image(systemName: "hammer")
                Text("Demo mode — nothing leaves this device")
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
