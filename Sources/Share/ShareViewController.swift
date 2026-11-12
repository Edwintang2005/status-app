import SwiftUI
import UIKit

/// The share sheet's principal class: hosts `ShareView` and ends the request
/// when it closes. Sending is `ShareModel`'s.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let host = UIHostingController(rootView: ShareView(model: model, items: items) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } holdOpen: { [weak self] sending in
            // On the presented controller itself: a modifier inside the host doesn't reach the sheet.
            self?.isModalInPresentation = sending
        }
        .tint(Theme.accent))
        // Clear, so the sheet is the app's own backdrop, cream or black with the system.
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// However it closes — Done, a swipe, the system — a send still settling is the app's soon.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model.leave()
    }
}

struct ShareView: View {
    @State var model: ShareModel
    let items: [NSExtensionItem]
    var close: () -> Void
    /// While sending, a swipe down mustn't end the extension under the upload.
    var holdOpen: (Bool) -> Void

    @FocusState private var captionFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        content
                    }
                    .padding(12)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
        }
        .task { await model.load(from: items) }
        // Sent needs no announcing: a tap of the haptic, and the sheet is gone.
        .onChange(of: model.phase == .sent) { _, sent in
            guard sent else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            close()
        }
        .onChange(of: isSending, initial: true) { _, sending in holdOpen(sending) }
    }

    private var title: String {
        switch model.phase {
        case .blocked, .unreadable, .unsaved: String(localized: "Red String")
        default: String(localized: "Send to \(model.partnerName)")
        }
    }

    private var isSending: Bool {
        if case .sending = model.phase { true } else { false }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .ready, .loading:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: close)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { Task { await model.send() } }
                    .font(Theme.rounded(17, .semibold))
                    .disabled(model.phase != .ready)
            }
        default:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: close)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .blocked(let reason):
            notice(systemImage: "link", text: blockedWords(reason))
        case .unreadable:
            notice(systemImage: "photo.badge.exclamationmark",
                   text: String(localized: "Couldn't open that picture. If it's in iCloud, check your connection and try again."))
        case .unsaved:
            notice(systemImage: "exclamationmark.triangle",
                   text: String(localized: "Couldn't save that photo on this iPhone. Check there's free space, then share it again."))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        case .ready, .sending, .sent, .queued:
            picture
            status
        }
    }

    private var picture: some View {
        Group {
            if let image = model.image {
                // The square every surface shows, as the expanded banner draws
                // it; the whole frame still goes.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel("The photo you're sharing")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("To \(model.partnerName)").eyebrow(size: 12)
            statusLine
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .ready:
            TextField("Add a caption", text: $model.caption, axis: .vertical)
                .font(Theme.rounded(18, .medium))
                .lineLimit(1...3)
                .focused($captionFocused)
                .submitLabel(.send)
                // Wraps, but never breaks (`ShareIntake.captionEdit`): return sends.
                .onChange(of: model.caption) { old, text in
                    guard text.contains(where: \.isNewline) || text.count > AppConfig.captionMaxLength else { return }
                    let edit = ShareIntake.captionEdit(from: old, to: text)
                    model.caption = edit.caption
                    if edit.send { Task { await model.send() } }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 4)
        case .sending(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                captionShown
                ProgressView(value: fraction)
                Text("Sending… you can close this, it'll keep going in Red String.")
                    .font(Theme.rounded(13))
                    .foregroundStyle(Theme.mutedText)
            }
        case .sent:
            captionShown
        case .queued(let words):
            captionShown
            Label(words, systemImage: "clock")
                .font(Theme.rounded(13))
                .foregroundStyle(Theme.mutedText)
        default:
            EmptyView()
        }
    }

    /// Once it's on its way, the caption reads as the banner will show it.
    @ViewBuilder
    private var captionShown: some View {
        let words = model.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            Text(words).font(Theme.rounded(18, .medium))
        }
    }

    private func notice(systemImage: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(Theme.mutedText)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.rounded(16))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func blockedWords(_ reason: ShareIntake.Blocked) -> String {
        switch reason {
        case .terms: String(localized: "Open Red String first to finish setting up, then share again.")
        case .unlinked: String(localized: "Link up with your partner in Red String first, then share again.")
        case .partnerLeft: String(localized: "\(model.partnerName) has left your shared space, so there's no one to send this to.")
        }
    }
}
