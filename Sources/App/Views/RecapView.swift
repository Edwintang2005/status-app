import AVKit
import Photos
import SwiftUI

/// Makes the year's montage on this iPhone, then offers to keep or share it.
/// Nothing is uploaded; the file lives only until this screen closes.
struct RecapView: View {
    @Environment(AppModel.self) private var model
    let period: RecapPlan.Period

    private enum Phase: Equatable {
        case gathering
        case fetching(Double)
        case rendering(Double)
        case ready(URL)
        case empty
        case failed(String)
    }

    private enum SaveState: Equatable {
        case idle, saving, saved
        case failed(String)
    }

    @State private var phase: Phase = .gathering
    @State private var player: AVPlayer?
    @State private var saveState: SaveState = .idle
    @State private var attempt = 0
    /// Per run, removed when the screen closes.
    @State private var folder: URL?

    var body: some View {
        ZStack {
            Theme.Background()
            content
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await build() }
        .onDisappear {
            player?.pause()
            UIApplication.shared.isIdleTimerDisabled = false
            if let folder { try? FileManager.default.removeItem(at: folder) }
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
        case .fetching(let fraction):
            working(String(localized: "Fetching photos from iCloud…"), progress: fraction)
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
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func working(_ label: String, progress: Double?) -> some View {
        VStack(spacing: 18) {
            if let progress {
                ProgressView(value: progress) { Text(label) }
                    .font(Theme.rounded(17, .semibold))
            } else {
                ProgressView()
                Text(label).font(Theme.rounded(17, .semibold))
            }
            Text("Made on this iPhone — nothing is uploaded. Keep \(AppConfig.appName) open until it's done.")
                .font(Theme.rounded(14))
                .foregroundStyle(Theme.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
    }

    private func ready(_ url: URL) -> some View {
        VStack(spacing: 18) {
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

    private func build() async {
        phase = .gathering
        saveState = .idle
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        guard let plan = await model.recapPlan(for: period) else {
            phase = .empty
            return
        }
        // Older pictures keep only a thumbnail here; the video wants the full one.
        let missing = plan.slides.compactMap { slide -> Moment? in
            guard case .picture(let moment) = slide, !MomentStore.shared.hasMedia(for: moment) else { return nil }
            return moment
        }
        if !missing.isEmpty {
            phase = .fetching(0)
            await MemoryArchive.fetchMedia(for: missing) { fraction in
                Task { @MainActor in if case .fetching = phase { phase = .fetching(fraction) } }
            }
        }
        guard !Task.isCancelled else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString)", isDirectory: true)
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = directory
        let name: String = switch period {
        case .year(let year): "\(AppConfig.appName) \(String(year))"
        case .lastTwelveMonths: "\(AppConfig.appName) recap"
        }
        let url = directory.appendingPathComponent(name).appendingPathExtension("mp4")
        let words = model.recapWords(for: plan)
        phase = .rendering(0)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Nonisolated: draws off the main actor, and stops with this screen's task.
            try await RecapVideo.render(plan, words: words, to: url) { fraction in
                Task { @MainActor in if case .rendering = phase { phase = .rendering(fraction) } }
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        player = AVPlayer(url: url)
        phase = .ready(url)
        // Opened is as good as waved away: the card has done its job.
        if case .year = period, model.recapPeriodOnHome == period { model.dismissRecapNotice() }
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
