import Foundation

/// A photo, a doodle, or a voice memo sent to the other person — the
/// Locket-style half of the app. Distinct from `StatusPayload`, which is the
/// always-on state; a moment is a one-off thing you send.
struct Moment: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case photo
        case drawing
        case voice
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
    /// Whether this device's copy has made it to CloudKit. Local only, and
    /// only meaningful on `fromMe` moments: a send that failed mid-upload
    /// leaves this `false`, and `AppModel.retryPendingUploads()` picks it up
    /// on the next foreground. Received moments are `true` by construction —
    /// they came *from* the server.
    var uploaded: Bool

    /// Length of the recording, in seconds. Voice memos only — `0` for
    /// anything visual. Carried in the metadata so the grid and the widget can
    /// show how long a memo is without the audio file being on this device.
    var duration: TimeInterval
    /// Loudness envelope sampled while recording, `0...1`, oldest first. Voice
    /// memos only. These are real measurements, not decoration, which is why
    /// they're stored rather than synthesised at draw time: a memo whose audio
    /// has been evicted from the cache still draws its own shape. Empty for
    /// anything visual, and for memos from a build that didn't record them.
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
        self.uploaded = uploaded
        self.duration = duration
        self.waveform = waveform
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, caption, senderName, sentAt, fromMe, seen, uploaded, duration, waveform
    }

    /// Hand-written so an index file from a build without `seen` still decodes
    /// — synthesised `Codable` treats a missing key as an error rather than
    /// falling back to the property's default, which would wipe the history.
    /// `duration` and `waveform` arrived with voice memos and are absent from
    /// every entry written before them, so they get the same treatment.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        caption = try container.decode(String.self, forKey: .caption)
        senderName = try container.decode(String.self, forKey: .senderName)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        fromMe = try container.decode(Bool.self, forKey: .fromMe)
        seen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? fromMe
        // Entries written before this flag existed predate the retry queue;
        // assuming they made it avoids re-uploading (or eternally flagging)
        // the whole history on first launch after the update.
        uploaded = try container.decodeIfPresent(Bool.self, forKey: .uploaded) ?? true
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        waveform = try container.decodeIfPresent([Double].self, forKey: .waveform) ?? []
    }
}

// MARK: - Presentation

extension Moment {
    /// Voice memos are audio rather than an image, which almost every screen
    /// has to branch on — the file on disk, the widget's background, whether
    /// "Save to Photos" even means anything.
    var isVoice: Bool { kind == .voice }

    /// What to call this in a sentence: "sent you a …".
    var noun: String {
        switch kind {
        case .photo: return "photo"
        case .drawing: return "drawing"
        case .voice: return "voice memo"
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
        case .photo: return "sent you a photo 📷"
        case .drawing: return "sent you a drawing ✏️"
        case .voice: return "sent you a voice memo 🎙️"
        }
    }

    /// `0:07`, `1:24`. Voice memos only.
    var durationLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
