import AVKit
import Photos
import SwiftUI

/// Makes the year's montage on this iPhone, then offers to keep or share it.
/// Nothing is uploaded. The finished video is kept (`RecapStore`), so the
/// screen reopens on it. iOS doesn't let a backgrounded app use the video
/// encoder, so leaving the app mid-way pauses, and the return resumes at the
/// first slide not yet written (`Staged`).
struct RecapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let period: RecapPlan.Period

    private enum Phase: Equatable {
        case gathering
        case rendering(Double)
        case ready(RecapStore.Saved)
        case empty
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .gathering, .rendering: true
            case .ready, .empty, .failed: false
            }
        }
    }

    /// The build task's identity: a new attempt rebuilds, and a pause cancels
    /// the build and its return starts it again.
    private struct Run: Equatable {
        var attempt = 0
        var paused = false
    }

    /// The run under way: its plan and slide files outlive a pause, so the
    /// return carries on rather than gathering and drawing it all again.
    private struct Staged {
        let attempt: Int
        let plan: RecapPlan
        let words: RecapVideo.Words
        let directory: URL
    }

    /// The slide just drawn, shown while the video is made.
    private struct Preview {
        let image: UIImage
        let index: Int
        let count: Int
    }

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    @State private var phase: Phase = .gathering
    @State private var player: AVPlayer?
    @State private var saveState: SaveState = .idle
    @State private var run = Run()
    @State private var staged: Staged?
    @State private var preview: Preview?
    /// Read inside the build, where an `@Environment` value can be stale.
    @State private var inBackground = false

    var body: some View {
        ZStack {
            Theme.Background()
            content
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: run) { await start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                inBackground = true
                if self.phase.isWorking { run.paused = true }
            case .active:
                inBackground = false
                if run.paused { run.paused = false }
            default:
                break
            }
        }
        .onDisappear {
            player?.pause()
            UIApplication.shared.isIdleTimerDisabled = false
            discardStaged()
        }
    }

    private var title: String {
        switch period {
        case .year(let year): String(localized: "Your \(String(year))")
        case .lastTwelveMonths: String(localized: "Your year")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .gathering:
            working(String(localized: "Gathering your year…"), progress: nil)
        case .rendering(let fraction):
            working(String(localized: "Making your video…"), progress: fraction)
        case .ready(let url):
            ready(url)
        case .empty:
            ContentUnavailableView("Nothing to put in a recap yet",
                                   systemImage: "photo.on.rectangle.angled",
                                   description: Text("Photos and drawings you send each other make the recap."))
        case .failed(let reason):
            VStack(spacing: 16) {
                ContentUnavailableView("Couldn't make the video", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
                Button("Try again") { run.attempt += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func working(_ label: String, progress: Double?) -> some View {
        VStack(spacing: 18) {
            if let preview, progress != nil {
                // The year coming together, a slide at a time.
                Image(uiImage: preview.image)
                    .resizable()
                    .aspectRatio(RecapVideo.size.width / RecapVideo.size.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .id(preview.index)
                    .transition(.opacity)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            if let progress {
                ProgressView(value: progress) { Text(label) }
                    .font(Theme.rounded(17, .semibold))
                if let preview {
                    Text("Slide \(preview.index + 1) of \(preview.count)")
                        .font(Theme.rounded(14))
                        .foregroundStyle(Theme.mutedText)
                        .monospacedDigit()
                }
            } else {
                ProgressView()
                Text(label).font(Theme.rounded(17, .semibold))
            }
            Text("Made on this iPhone — nothing is uploaded. If you leave \(AppConfig.appName), it carries on when you're back.")
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.4), value: preview?.index)
    }

    private func ready(_ saved: RecapStore.Saved) -> some View {
        let url = saved.url
        return VStack(spacing: 18) {
            VideoPlayer(player: player)
                .aspectRatio(RecapVideo.size.width / RecapVideo.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .frame(maxHeight: .infinity)
                .accessibilityLabel(Text("Your recap video"))
            HStack(spacing: 12) {
                Button {
                    Task { await save(url) }
                } label: {
                    Label(saveLabel, systemImage: saveState == .saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(saveState == .saving || saveState == .saved)
                ShareLink(item: url) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
            .font(Theme.rounded(16, .semibold))
            if case .failed(let reason) = saveState {
                Text(reason)
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.warmText)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Text("Made \(saved.madeAt.formatted(.dateTime.day().month(.wide)))")
                    .foregroundStyle(Theme.mutedText)
                Text("·").foregroundStyle(Theme.mutedText).accessibilityHidden(true)
                // Newer moments since: a fresh one picks them up.
                Button("Make it again") { run.attempt += 1 }
                    .foregroundStyle(Theme.accentText)
                    .frame(minHeight: 44)
            }
            .font(Theme.rounded(14))
        }
        .padding(.vertical, 12)
    }

    private var saveLabel: String {
        switch saveState {
        case .idle, .failed: String(localized: "Save to Photos")
        case .saving: String(localized: "Saving…")
        case .saved: String(localized: "Saved")
        }
    }

    // MARK: - Work

    /// The kept video when there is one and no rebuild was asked for; a paused run waits.
    private func start() async {
        guard !run.paused else { return }
        if run.attempt == 0, let saved = RecapStore.shared.saved(for: period) {
            show(saved)
            return
        }
        await build()
    }

    private func show(_ saved: RecapStore.Saved) {
        player = AVPlayer(url: saved.url)
        preview = nil
        phase = .ready(saved)
        // Opened is as good as waved away: the card has done its job.
        if case .year = period, model.recapPeriodOnHome == period { model.dismissRecapNotice() }
    }

    private func build() async {
        player?.pause()
        player = nil
        saveState = .idle
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        let current: Staged
        if let staged, staged.attempt == run.attempt {
            current = staged
        } else {
            discardStaged()
            preview = nil
            phase = .gathering
            guard let plan = await model.recapPlan(for: period) else {
                phase = .empty
                return
            }
            guard !Task.isCancelled else { return }
            current = Staged(attempt: run.attempt, plan: plan, words: model.recapWords(for: plan),
                             directory: RecapStore.stagingDirectory())
            staged = current
        }
        let plan = current.plan
        // Pictures already here go straight in; older ones keep only a thumbnail
        // here, so their full copies download ahead while earlier slides draw.
        let media = RecapMedia(plan.slides.flatMap { slide -> [Moment] in
            if case .pictures(let moments) = slide { return moments }
            return []
        })
        defer { media.cancel() }
        guard !Task.isCancelled else { return }

        let directory = current.directory
        let url = directory.appendingPathComponent(RecapStore.fileName(for: period))
        if case .rendering = phase {} else { phase = .rendering(0) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Nonisolated: draws off the main actor, and stops with this screen's task.
            let count = plan.slides.count
            try await RecapVideo.render(plan, words: current.words, in: directory, to: url,
                                        picture: { await media.picture(for: $0) },
                                        drawn: { image, index in
                                            let shown = UIImage(cgImage: image)
                                            Task { @MainActor in preview = Preview(image: shown, index: index, count: count) }
                                        }) { fraction in
                Task { @MainActor in if case .rendering = phase { phase = .rendering(fraction) } }
            }
        } catch is CancellationError {
            return
        } catch {
            // The encoder goes when the app leaves the screen, sometimes before
            // the phase change arrives: wait for the return instead of failing.
            if inBackground { run.paused = true } else { phase = .failed(error.localizedDescription) }
            return
        }
        guard !Task.isCancelled else { return }
        do {
            show(try RecapStore.shared.keep(url, for: period))
        } catch {
            phase = .failed(error.localizedDescription)
        }
        discardStaged()
    }

    private func discardStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged.directory) }
        staged = nil
    }

    /// Add-only authorisation: never reads the library.
    private func save(_ url: URL) async {
        saveState = .saving
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveState = .failed(String(localized: "Allow photo access in Settings to save."))
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            }
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }
}
