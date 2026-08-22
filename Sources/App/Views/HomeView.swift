import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPicker = false
    @State private var showingSettings = false
    /// Drives the nudge cooldown countdown without a timer per view update.
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                // Inside the stack, not behind it: NavigationStack paints an
                // opaque system background over anything layered underneath.
                Theme.Background()
                ScrollView {
                    VStack(spacing: 18) {
                        partnerCard
                        nudgeButton
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
            MoodPickerView { emoji, message in
                Task { await model.setStatus(emoji: emoji, message: message) }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Partner

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

    // MARK: - Nudge

    private var nudgeButton: some View {
        let remaining = max(0, AppConfig.nudgeCooldown - now.timeIntervalSince(model.snapshot.lastNudgeSentAt ?? .distantPast))
        let ready = remaining == 0

        return Button {
            Task { await model.sendNudge() }
        } label: {
            Label(ready ? "Thinking of you" : "Sent · \(Int(remaining))s",
                  systemImage: ready ? "heart.fill" : "checkmark")
        }
        .buttonStyle(PrimaryButtonStyle(tint: ready ? Theme.warm : Color.secondary.opacity(0.4)))
        .disabled(!ready)
        .animation(.smooth, value: ready)
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

#if DEBUG
#Preview("Home") {
    HomeView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
