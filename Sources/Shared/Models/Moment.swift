import Foundation

/// A photo or a doodle sent to the other person — the Locket-style half of the
/// app. Distinct from `StatusPayload`, which is the always-on state; a moment
/// is a one-off thing you send.
struct Moment: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case photo
        case drawing
    }

    let id: String
    var kind: Kind
    var caption: String
    var senderName: String
    var sentAt: Date
    /// `true` if this device sent it. The widget only ever shows the partner's.
    var fromMe: Bool

    init(id: String = UUID().uuidString,
         kind: Kind,
         caption: String,
         senderName: String,
         sentAt: Date = Date(),
         fromMe: Bool) {
        self.id = id
        self.kind = kind
        self.caption = caption
        self.senderName = senderName
        self.sentAt = sentAt
        self.fromMe = fromMe
    }
}
