import UIKit
import UniformTypeIdentifiers

/// Everything the app copies expires (`AppConfig.clipboardLifetime`): the
/// invite link is a bearer token to the shared space, and a report quotes the
/// partner's words — neither should sit on the pasteboard for any app to read.
enum Clipboard {
    /// `localOnly` keeps it off Universal Clipboard. The invite link may travel —
    /// pasting it on a Mac is a fair reason to copy it — the rest stays here.
    static func copy(_ item: [String: Any], localOnly: Bool) {
        UIPasteboard.general.setItems([item], options: [
            .expirationDate: Date().addingTimeInterval(AppConfig.clipboardLifetime),
            .localOnly: localOnly,
        ])
    }

    static func copy(text: String, localOnly: Bool) {
        copy([UTType.utf8PlainText.identifier: text], localOnly: localOnly)
    }

    static var lifetimeMinutes: Int { Int(AppConfig.clipboardLifetime / 60) }
}
