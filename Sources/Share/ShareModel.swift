import Foundation
import os
import UIKit
import UniformTypeIdentifiers

/// One shared photo, sent the way the composer's are: its files and index entry
/// first (a pending own send, so the app's retry pass finishes it if this sheet
/// can't), then the upload through an `Outbox` of its own over the real stores.
/// The app leaves it alone while the sheet's claim stands (`ShareIntake.isClaimed`).
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case blocked(ShareIntake.Blocked)
        case unreadable
        /// The photo couldn't be written here: nothing was filed.
        case unsaved
        case sending(Double)
        case sent
        /// Filed here; the app sends it. The words say why.
        case queued(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var image: UIImage?
    var caption = ""
    let partnerName: String

    @ObservationIgnored private var location: PhotoLocation?
    /// The moment this sheet filed and may still be sending.
    @ObservationIgnored private var filed: String?
    /// The sheet has closed: a send still running mustn't renew the full hold.
    @ObservationIgnored private var left = false
    @ObservationIgnored private let store = SharedStore.shared
    @ObservationIgnored private let log = Logger(subsystem: AppConfig.appGroupID, category: "Share")
    @ObservationIgnored private lazy var outbox = Outbox(
        store: store,
        index: .shared,
        statusLog: .shared,
        backend: { Backend.current },
        hasMedia: { MomentStore.shared.hasMedia(for: $0) },
        deleteMedia: { MomentStore.shared.delete(id: $0) },
        clearRecaps: { RecapStore.shared.removeAll() },
        // The sheet is on screen while it waits; one closed early leaves the send to the app.
        protect: { _, body in try await body() },
        indexChanged: { [store] in store.refreshDerived() })

    init() {
        partnerName = store.snapshot.partnerName(filterEnabled: store.contentFilterEnabled)
        if let blocked { phase = .blocked(blocked) }
    }

    /// Read again at Send: the app may have unlinked while the sheet was open.
    private var blocked: ShareIntake.Blocked? {
        ShareIntake.blocked(termsAccepted: store.acceptedTermsVersion >= AppConfig.termsVersion,
                            paired: store.pairing != nil,
                            partnerLeft: store.snapshot.partnerHasLeft)
    }

    // MARK: - Loading

    func load(from items: [NSExtensionItem]) async {
        guard phase == .loading else { return }
        let provider = items.lazy.flatMap { $0.attachments ?? [] }
            .first { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard let provider, let picture = await Self.picture(from: provider) else {
            phase = .unreadable
            return
        }
        image = picture.image
        location = picture.location
        phase = .ready
    }

    private struct Picture: Sendable {
        var image: UIImage
        var location: PhotoLocation?
    }

    /// The file when there is one (Photos, Files), read at the stored size and
    /// inside the callback — the copy is deleted when it returns; otherwise
    /// whatever the provider hands over (a screenshot's markup gives an image).
    private static func picture(from provider: NSItemProvider) async -> Picture? {
        let type = UTType.image.identifier
        let fromFile: Picture? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url, let image = MomentStore.imported(url) else { return continuation.resume(returning: nil) }
                continuation.resume(returning: Picture(image: image, location: PhotoLocation.read(from: url)))
            }
        }
        if let fromFile { return fromFile }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type) { item, _ in
                switch item {
                case let url as URL:
                    continuation.resume(returning: MomentStore.imported(url).map {
                        Picture(image: $0, location: PhotoLocation.read(from: url))
                    })
                case let data as Data:
                    continuation.resume(returning: MomentStore.imported(data).map {
                        Picture(image: $0, location: PhotoLocation.read(from: data))
                    })
                case let image as UIImage:
                    continuation.resume(returning: Picture(image: image, location: nil))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Sending

    func send() async {
        guard phase == .ready, let image else { return }
        if let blocked {
            phase = .blocked(blocked)
            return
        }
        let words = Moment.caption(from: caption)
        let moment = Moment(kind: .photo,
                            caption: words,
                            senderName: store.snapshot.mine?.displayName ?? "",
                            fromMe: true,
                            uploaded: false)
        let location = location
        phase = .sending(0)
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try MomentStore.shared.write(image, id: moment.id, location: location)
            }.value
        } catch {
            log.error("Couldn't save the shared photo: \(error.localizedDescription, privacy: .public)")
            phase = .unsaved
            return
        }
        // Claimed before it's filed, so no retry pass can catch it in between.
        store.shareUploadClaims = ShareIntake.claiming(moment.id, in: store.shareUploadClaims)
        filed = moment.id
        store.record(moment)

        let progress = Task { @MainActor [weak self] in
            // The outbox reports no progress to its caller; the bar creeps until the landing.
            var shown = 0.0
            while !Task.isCancelled, case .sending = self?.phase {
                shown += (0.9 - shown) * 0.08
                self?.phase = .sending(shown)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { progress.cancel() }
        do {
            try await outbox.upload(moment, taskName: "share-upload")
            release(moment.id)
            // Returning isn't landing: a pairing that moved mid-send files nothing as sent.
            let sent = MomentIndex.shared.load().first { $0.id == moment.id }?.uploaded == true
            phase = sent ? .sent : .queued(String(localized: "It's saved and will send next time Red String opens."))
        } catch {
            log.error("Shared photo didn't send yet: \(error.localizedDescription, privacy: .public)")
            if ShareIntake.releasesClaim(after: error) {
                // Filed and pending: the app's next pass sends it, so let it start now.
                release(moment.id)
            } else {
                // Still moving here: renewed, so the app doesn't send it alongside,
                // and the sheet closes as sent if it lands while it's open.
                store.shareUploadClaims = ShareIntake.afterTimeout(moment.id, in: store.shareUploadClaims, left: left)
                if !left { watchForLanding(moment.id) }
            }
            phase = .queued(SendFailure(error) == .offline
                ? String(localized: "You're offline. It's saved and will send once Red String is back online.")
                : String(localized: "It's saved and will send next time Red String opens."))
        }
    }

    /// Closed before the send settled: the app takes it over shortly
    /// (`ShareIntake.closing`), not minutes later.
    func leave() {
        left = true
        guard let filed, phase != .sent else { return }
        store.shareUploadClaims = ShareIntake.closing(filed, in: store.shareUploadClaims)
    }

    private func watchForLanding(_ id: String) {
        Task { @MainActor [weak self] in
            let until = Date().addingTimeInterval(AppConfig.shareUploadHold)
            while Date() < until, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, case .queued = phase else { return }
                if MomentIndex.shared.load().first(where: { $0.id == id })?.uploaded == true {
                    release(id)
                    phase = .sent
                    return
                }
            }
        }
    }

    private func release(_ id: String) {
        var claims = store.shareUploadClaims
        claims[id] = nil
        store.shareUploadClaims = claims
    }
}
