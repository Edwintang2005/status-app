import Foundation

/// A photo, doodle, or voice memo sent to the other person — a one-off send,
/// unlike the always-on `StatusPayload`.
struct Moment: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case photo
        case drawing
        case voice
    }

    let id: String
    var kind: Kind
    var caption: String
    /// The sender's name at send time (no local override anywhere in the app);
    /// captured per moment so old ones keep the name in use then.
    var senderName: String
    var sentAt: Date
    /// `true` if this device sent it. The widget only ever shows the partner's.
    var fromMe: Bool
    /// Whether the recipient has actually looked at it. Local only — never
    /// written to CloudKit, since "seen" means seen *on this device*.
    var seen: Bool
    /// When this device marked it seen. Feeds read receipts; `nil` on entries
    /// seen before this field existed (receipt then carries no time).
    var seenAt: Date?
    /// When the partner's receipt said they saw this (own moments only, and
    /// only while read receipts are on). `.distantPast` means "seen, time unknown".
    var seenByPartnerAt: Date?
    /// Whether this copy reached CloudKit. Local only, meaningful on `fromMe`
    /// moments; a failed send stays `false` and is retried on next foreground.
    var uploaded: Bool

    /// Recording length in seconds; voice memos only. In the metadata so length
    /// shows without the audio file being on this device.
    var duration: TimeInterval
    /// Loudness envelope `0...1`, oldest first; voice memos only. Stored, not
    /// synthesised at draw time, so an evicted memo still draws its own shape.
    var waveform: [Double]

    init(id: String = UUID().uuidString,
         kind: Kind,
         caption: String,
         senderName: String,
         sentAt: Date = Date(),
         fromMe: Bool,
         seen: Bool? = nil,
         uploaded: Bool = true,
         duration: TimeInterval = 0,
         waveform: [Double] = []) {
        self.id = id
        self.kind = kind
        self.caption = caption
        self.senderName = senderName
        self.sentAt = sentAt
        self.fromMe = fromMe
        // Your own sends are seen by definition.
        self.seen = seen ?? fromMe
        self.seenAt = nil
        self.seenByPartnerAt = nil
        self.uploaded = uploaded
        self.duration = duration
        self.waveform = waveform
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, caption, senderName, sentAt, fromMe, seen, uploaded, duration, waveform
        case seenAt, seenByPartnerAt
    }

    /// Hand-written: synthesised `Codable` errors on keys missing from entries
    /// written by older builds, which would wipe the history. Newer fields fall back.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        caption = try container.decode(String.self, forKey: .caption)
        senderName = try container.decode(String.self, forKey: .senderName)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        fromMe = try container.decode(Bool.self, forKey: .fromMe)
        seen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? fromMe
        seenAt = try container.decodeIfPresent(Date.self, forKey: .seenAt)
        seenByPartnerAt = try container.decodeIfPresent(Date.self, forKey: .seenByPartnerAt)
        // Pre-flag entries predate the retry queue; assume uploaded to avoid
        // re-uploading the whole history.
        uploaded = try container.decodeIfPresent(Bool.self, forKey: .uploaded) ?? true
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        waveform = try container.decodeIfPresent([Double].self, forKey: .waveform) ?? []
    }
}

// MARK: - Presentation

extension Moment {
    /// Voice memos are audio rather than an image, which most screens branch on.
    var isVoice: Bool { kind == .voice }

    /// What to call this in a sentence: "sent you a …".
    var noun: String {
        switch kind {
        case .photo: return String(localized: "photo")
        case .drawing: return String(localized: "drawing")
        case .voice: return String(localized: "voice memo")
        }
    }

    /// SF Symbol standing in for the kind, in labels and on tiles.
    var symbolName: String {
        switch kind {
        case .photo: return "camera.fill"
        case .drawing: return "scribble"
        case .voice: return "waveform"
        }
    }

    /// The notification body when there's no caption to show instead.
    var arrivalSummary: String {
        switch kind {
        case .photo: return String(localized: "sent you a photo 📷")
        case .drawing: return String(localized: "sent you a drawing ✏️")
        case .voice: return String(localized: "sent you a voice memo 🎙️")
        }
    }

    /// `0:07`, `1:24`. Voice memos only.
    var durationLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
