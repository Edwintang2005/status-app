import Foundation

/// A photo, doodle, or voice memo sent to the other person — a one-off send,
/// unlike the always-on `StatusPayload`.
struct Moment: Codable, Hashable, Identifiable {
    enum Kind: Hashable, Sendable {
        case photo
        case drawing
        case voice
        /// A kind from a newer build. Filed under its own name, so the build
        /// that knows it reads the entry back as itself, but never shown here.
        case unsupported(String)

        init(rawValue: String) {
            switch rawValue {
            case "photo": self = .photo
            case "drawing": self = .drawing
            case "voice": self = .voice
            default: self = .unsupported(rawValue)
            }
        }

        var rawValue: String {
            switch self {
            case .photo: return "photo"
            case .drawing: return "drawing"
            case .voice: return "voice"
            case .unsupported(let raw): return raw
            }
        }

        var isSupported: Bool {
            if case .unsupported = self { return false }
            return true
        }
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
        /// The waveform as one byte per sample, base64 — the index's compact form.
        case waveformBytes
    }

    /// Set on the moment index's encoder: waveforms go out as bytes, a fifth of the doubles.
    static let compactWaveformsKey = CodingUserInfoKey(rawValue: "compactWaveforms")!

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
        if let bytes = try container.decodeIfPresent(String.self, forKey: .waveformBytes)
            .flatMap({ Data(base64Encoded: $0) }) {
            waveform = bytes.map { Double($0) / 255 }
        } else {
            waveform = try container.decodeIfPresent([Double].self, forKey: .waveform) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(caption, forKey: .caption)
        try container.encode(senderName, forKey: .senderName)
        try container.encode(sentAt, forKey: .sentAt)
        try container.encode(fromMe, forKey: .fromMe)
        try container.encode(seen, forKey: .seen)
        try container.encodeIfPresent(seenAt, forKey: .seenAt)
        try container.encodeIfPresent(seenByPartnerAt, forKey: .seenByPartnerAt)
        try container.encode(uploaded, forKey: .uploaded)
        try container.encode(duration, forKey: .duration)
        if encoder.userInfo[Self.compactWaveformsKey] as? Bool == true {
            if !waveform.isEmpty {
                let bytes = waveform.map { UInt8(($0.isFinite ? min(max($0, 0), 1) : 0) * 255 + 0.5) }
                try container.encode(Data(bytes).base64EncodedString(), forKey: .waveformBytes)
            }
        } else {
            try container.encode(waveform, forKey: .waveform)
        }
    }
}

extension Moment.Kind: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Presentation

extension Moment {
    /// Voice memos are audio rather than an image, which most screens branch on.
    var isVoice: Bool { kind == .voice }

    /// A photo or a doodle — what the home card, the widget and the gallery draw.
    var isPicture: Bool { kind == .photo || kind == .drawing }

    /// What to call this in a sentence: "sent you a …".
    var noun: String {
        switch kind {
        case .photo: return String(localized: "photo")
        case .drawing: return String(localized: "drawing")
        case .voice: return String(localized: "voice memo")
        case .unsupported: return String(localized: "moment")
        }
    }

    /// SF Symbol standing in for the kind, in labels and on tiles.
    var symbolName: String {
        switch kind {
        case .photo: return "camera.fill"
        case .drawing: return "scribble"
        case .voice: return "waveform"
        case .unsupported: return "questionmark.square.dashed"
        }
    }

    /// The notification body when there's no caption to show instead.
    var arrivalSummary: String { kind.arrivalSummary }

    /// `0:07`, `1:24`. Voice memos only.
    var durationLabel: String {
        let total = duration.isFinite ? Int(min(duration.rounded(), 359_999)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension Moment.Kind {
    /// Kind-level so a locked phone's banner can use it: `kind` is plaintext.
    var arrivalSummary: String {
        switch self {
        case .photo: return String(localized: "sent you a photo 📷")
        case .drawing: return String(localized: "sent you a drawing ✏️")
        case .voice: return String(localized: "sent you a voice memo 🎙️")
        case .unsupported: return String(localized: "sent you something new: update \(AppConfig.appName) to see it")
        }
    }
}
