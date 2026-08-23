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
    /// The name the sender had set for themselves at the time. This is what
    /// the recipient sees — a name belongs to the person it names, so there's
    /// no local override anywhere in the app. Captured per moment, so an old
    /// one keeps the name they were using then.
    var senderName: String
    var sentAt: Date
    /// `true` if this device sent it. The widget only ever shows the partner's.
    var fromMe: Bool
    /// Whether the recipient has actually looked at it. Local only — never
    /// written to CloudKit, since "seen" means seen *on this device*.
    var seen: Bool

    init(id: String = UUID().uuidString,
         kind: Kind,
         caption: String,
         senderName: String,
         sentAt: Date = Date(),
         fromMe: Bool,
         seen: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.caption = caption
        self.senderName = senderName
        self.sentAt = sentAt
        self.fromMe = fromMe
        // Your own sends are seen by definition.
        self.seen = seen ?? fromMe
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, caption, senderName, sentAt, fromMe, seen
    }

    /// Hand-written so an index file from a build without `seen` still decodes
    /// — synthesised `Codable` treats a missing key as an error rather than
    /// falling back to the property's default, which would wipe the history.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        caption = try container.decode(String.self, forKey: .caption)
        senderName = try container.decode(String.self, forKey: .senderName)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        fromMe = try container.decode(Bool.self, forKey: .fromMe)
        seen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? fromMe
    }
}
