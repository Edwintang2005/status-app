import Foundation
import os

/// Writes the shared history out as ordinary files — deliberately boring formats
/// that need no app to open in ten years. Goes to iCloud Drive; if that's
/// unavailable, the caller is handed the folder to share instead.
enum MemoryArchive {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "MemoryArchive")

    struct Outcome: Sendable {
        enum Destination: Sendable, Equatable {
            /// Saved and safe: nothing more for the user to do.
            case iCloudDrive
            /// On this device only — the caller must offer to share it before anything is deleted.
            case deviceOnly
        }

        let folder: URL
        let destination: Destination
        let momentCount: Int
        let statusCount: Int
        /// Moments whose media couldn't be recovered — listed in the archive, not quietly dropped.
        let unrecovered: Int
        /// The zone was read and every record in it was readable; anything short
        /// of that must not be the last copy before a delete.
        let isComplete: Bool
        let includesZone: Bool
        let unreadable: Int
    }

    enum ArchiveError: LocalizedError {
        case nothingToSave

        var errorDescription: String? {
            switch self {
            case .nothingToSave: return String(localized: "There's nothing to archive yet.")
            }
        }
    }

    /// The partner's words go through the presentation helpers, like every other
    /// surface (invariant 20): `reportedStatusAt` hides a reported status.
    /// Cancellable: the task's cancellation stops it and removes what it staged.
    /// - Parameter progress: called with `0...1` as media is gathered.
    static func write(_ contents: ArchiveContents,
                      myName: String,
                      partnerName: String,
                      reportedStatusAt: Date?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        guard !contents.isEmpty else { throw ArchiveError.nothingToSave }

        let ordered = contents.moments
        let names = Names(me: myName, partner: partnerName)
        let statuses = contents.statuses.map { $0.moderated(reportedAt: reportedStatusAt) }
        let store = MomentStore.shared
        let fileManager = FileManager.default

        let folderName = Self.folderName(partnerName: partnerName)
        // Per run: a cancelled run still winding down must not touch the next one's files.
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: stagingRoot) } }

        // Most of a long archive is fetched back from CloudKit rather than copied.
        let missing = ordered.filter { $0.kind.isSupported && store.mediaURL(for: $0) == nil }
        await fetchMedia(for: missing, progress: progress)
        try Task.checkCancellation()

        var entries: [Entry] = []
        var unrecovered = 0

        for moment in ordered {
            try Task.checkCancellation()
            guard let source = store.mediaURL(for: moment) else {
                unrecovered += 1
                entries.append(Entry(moment: moment, relativePath: nil))
                continue
            }

            let directory = staging.appendingPathComponent(Self.subfolder(for: moment.kind),
                                                           isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let name = Self.fileName(for: moment, names: names, extension: source.pathExtension)
            let destination = Self.unusedURL(in: directory, named: name)
            do {
                try fileManager.copyItem(at: source, to: destination)
                entries.append(Entry(moment: moment,
                                     relativePath: Self.subfolder(for: moment.kind)
                                        + "/" + destination.lastPathComponent))
            } catch {
                log.error("Couldn't copy \(moment.id): \(error.localizedDescription)")
                unrecovered += 1
                entries.append(Entry(moment: moment, relativePath: nil))
            }
        }

        try Self.html(for: entries, statuses: statuses, contents: contents, names: names)
            .write(to: staging.appendingPathComponent("Memories.html"), atomically: true, encoding: .utf8)
        try Self.text(for: entries, statuses: statuses, contents: contents, names: names)
            .write(to: staging.appendingPathComponent("Memories.txt"), atomically: true, encoding: .utf8)

        progress(1)

        // `url(forUbiquityContainerIdentifier:)` can block on first use — hop off this thread.
        let container = await Task.detached { () -> URL? in
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value

        guard let container else {
            log.notice("No iCloud Drive; archive left on the device for sharing.")
            finished = true
            return Outcome(folder: staging, destination: .deviceOnly,
                           momentCount: ordered.count, statusCount: statuses.count,
                           unrecovered: unrecovered, isComplete: contents.isComplete,
                           includesZone: contents.includesZone, unreadable: contents.unreadable)
        }

        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        let final = Self.unusedURL(in: documents, named: folderName)
        try Task.checkCancellation()
        try fileManager.moveItem(at: staging, to: final)
        finished = true
        try? fileManager.removeItem(at: stagingRoot)

        log.notice("Archived \(ordered.count) moments and \(statuses.count) statuses to iCloud Drive.")
        return Outcome(folder: final, destination: .iCloudDrive,
                       momentCount: ordered.count, statusCount: statuses.count,
                       unrecovered: unrecovered, isComplete: contents.isComplete,
                       includesZone: contents.includesZone, unreadable: contents.unreadable)
    }

    /// A few at a time, each bounded: one stalled download can't hold the rest,
    /// and a missing photo is listed as unrecovered rather than costing the archive.
    /// Stops starting new ones once cancelled.
    private static func fetchMedia(for moments: [Moment],
                                   progress: @escaping @Sendable (Double) -> Void) async {
        guard !moments.isEmpty else { return }
        let backend = Backend.current
        let total = Double(moments.count)
        await withTaskGroup(of: Void.self) { group in
            var queue = moments[...]
            var done = 0
            func start(_ moment: Moment) {
                group.addTask {
                    try? await withDeadline(AppConfig.archiveItemDeadline) { try await backend.fetchMedia(for: moment) }
                }
            }
            for _ in 0..<AppConfig.archiveFetchConcurrency {
                guard let next = queue.popFirst() else { break }
                start(next)
            }
            for await _ in group {
                done += 1
                progress(Double(done) / total)
                if Task.isCancelled {
                    queue.removeAll()
                } else if let next = queue.popFirst() {
                    start(next)
                }
            }
        }
    }

    // MARK: - Naming

    private struct Entry {
        let moment: Moment
        /// `nil` when the file couldn't be recovered.
        let relativePath: String?
    }

    private struct Names {
        let me: String
        let partner: String

        func sender(of moment: Moment) -> String {
            let fallback = moment.fromMe ? me : partner
            let shown = moment.displaySenderName(fallback: fallback)
            return shown.isEmpty ? fallback : shown
        }

        func author(of status: StatusHistoryEntry) -> String { status.fromMe ? me : partner }
    }

    private static func subfolder(for kind: Moment.Kind) -> String {
        switch kind {
        case .photo: return "Photos"
        case .drawing: return "Drawings"
        case .voice: return "Voice memos"
        case .unsupported: return "Other"
        }
    }

    /// Fixed-format strings need `en_US_POSIX` + Gregorian pinned, or device calendar
    /// and 12/24-hour overrides leak into filenames. (`readableDate` keeps the device locale on purpose.)
    private static func fixedFormat(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    private static let folderDateFormat = fixedFormat("yyyy-MM-dd")

    private static let fileDateFormat = fixedFormat("yyyy-MM-dd HHmm")

    private static func folderName(partnerName: String) -> String {
        let partner = prefix(sanitised(partnerName), bytes: 60)
        let today = folderDateFormat.string(from: Date())
        return partner.isEmpty
            ? "\(AppConfig.appName) memories \(today)"
            : "\(AppConfig.appName) memories with \(partner) \(today)"
    }

    /// Dated, attributed and captioned — the filename is the only metadata that survives copying.
    private static func fileName(for moment: Moment, names: Names, extension ext: String) -> String {
        var name = fileDateFormat.string(from: moment.sentAt) + " " + prefix(sanitised(names.sender(of: moment)), bytes: 60)
        let caption = sanitised(moment.displayCaption ?? "")
        if !caption.isEmpty {
            name += " — " + prefix(caption, bytes: 100)
        }
        return name + "." + (ext.isEmpty ? "dat" : ext)
    }

    /// Filenames are capped in bytes (255 on APFS), and emoji run four a character;
    /// past the cap the copy failed and the moment was listed as unrecovered.
    private static func prefix(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strips what a filesystem — or a person reading a filename — can't use.
    private static func sanitised(_ text: String) -> String {
        let stripped = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same-minute, same-caption collisions are possible; silently overwriting isn't acceptable.
    private static func unusedURL(in directory: URL, named name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for suffix in 2...999 {
            let next = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            let url = directory.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return candidate
    }

    // MARK: - The readable part

    private static let readableDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()

    private static let readableDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    /// What the header says beyond the counts: the pair's date, and anything
    /// the archive couldn't hold — said, never silently missing.
    private static func notes(for contents: ArchiveContents) -> [String] {
        var notes: [String] = []
        if let anniversary = contents.anniversary {
            let day = readableDay.string(from: anniversary.startsAt)
            notes.append(String(localized: "Your date: \(day)."))
        }
        if !contents.includesZone {
            notes.append(String(localized: "iCloud couldn't be reached, so this holds only what was on this iPhone."))
        } else if contents.unreadable > 0 {
            notes.append(String(localized: "\(contents.unreadable) items in iCloud couldn't be read on this iPhone and aren't included."))
        }
        return notes
    }

    private static func statusLine(_ status: StatusHistoryEntry, names: Names) -> String {
        var line = readableDate.string(from: status.at) + "  ·  " + names.author(of: status)
            + "  ·  " + status.emoji
        if !status.message.isEmpty { line += " " + status.message }
        if status.isCelebration { line += "  🎉" }
        return line
    }

    private static func text(for entries: [Entry],
                             statuses: [StatusHistoryEntry],
                             contents: ArchiveContents,
                             names: Names) -> String {
        var lines = ["\(AppConfig.appName) — memories with \(names.partner)",
                     "\(entries.count) moments and \(statuses.count) statuses, oldest first."]
        lines += notes(for: contents)
        lines.append("")
        for entry in entries {
            let moment = entry.moment
            var line = readableDate.string(from: moment.sentAt) + "  ·  " + names.sender(of: moment)
            if let caption = moment.displayCaption { line += "  ·  \u{201C}\(caption)\u{201D}" }
            if moment.isVoice, moment.duration > 0 {
                line += "  ·  \(Int(moment.duration.rounded()))s"
            }
            line += "  ·  " + (entry.relativePath ?? "[file no longer available]")
            lines.append(line)
        }
        if !statuses.isEmpty {
            lines += ["", "Statuses", ""]
            lines += statuses.map { statusLine($0, names: names) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func html(for entries: [Entry],
                             statuses: [StatusHistoryEntry],
                             contents: ArchiveContents,
                             names: Names) -> String {
        let items = entries.map { entry -> String in
            let moment = entry.moment
            let sender = names.sender(of: moment)
            let when = escaped(readableDate.string(from: moment.sentAt))
            let who = escaped(sender)
            let caption = moment.displayCaption.map { "<p class=\"caption\">\(escaped($0))</p>" } ?? ""

            let media: String
            var trailing = "\(who) · \(when)"
            switch (entry.relativePath, moment.kind) {
            case (nil, _):
                media = "<p class=\"missing\">This one couldn't be recovered from iCloud.</p>"
            case (let path?, .voice):
                media = "<audio controls src=\"\(href(path))\"></audio>"
                if moment.duration > 0 {
                    trailing += " · \(Int(moment.duration.rounded()))s"
                }
            case (let path?, _):
                let alt = moment.displayCaption
                    ?? "A \(moment.kind == .drawing ? "drawing" : "photo") from \(sender)"
                media = "<img src=\"\(href(path))\" alt=\"\(escaped(alt))\">"
            }

            return """
            <figure>
              \(media)
              \(caption)
              <figcaption>\(trailing)</figcaption>
            </figure>
            """
        }.joined(separator: "\n")

        let statusItems = statuses.map { status -> String in
            let words = status.message.isEmpty ? "" : " \(escaped(status.message))"
            let celebration = status.isCelebration ? " 🎉" : ""
            return """
            <li><span class="status">\(escaped(status.emoji))\(words)\(celebration)</span>\
            <span class="meta">\(escaped(names.author(of: status))) · \(escaped(readableDate.string(from: status.at)))</span></li>
            """
        }.joined(separator: "\n")
        let statusSection = statuses.isEmpty ? "" : """
        <section>
          <h2>Statuses</h2>
          <ul class="statuses">
        \(statusItems)
          </ul>
        </section>
        """
        let notes = notes(for: contents).map { "<p class=\"lede\">\(escaped($0))</p>" }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(AppConfig.appName)) memories with \(escaped(names.partner))</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            margin: 0 auto; padding: 40px 20px 80px; max-width: 720px;
          }
          header { margin-bottom: 48px; }
          h1 { font-size: 30px; margin: 0 0 8px; }
          h2 { font-size: 22px; margin: 56px 0 16px; }
          .lede { opacity: 0.65; margin: 0 0 6px; }
          figure { margin: 0 0 44px; }
          img { width: 100%; height: auto; border-radius: 18px; display: block; }
          audio { width: 100%; }
          .caption { font-size: 20px; font-weight: 600; margin: 14px 0 4px; }
          figcaption, .meta { font-size: 14px; opacity: 0.6; margin: 6px 0 0; }
          .missing { font-size: 15px; opacity: 0.6; font-style: italic; margin: 0; }
          .statuses { list-style: none; padding: 0; margin: 0; }
          .statuses li { margin: 0 0 18px; }
          .statuses .status { display: block; font-size: 18px; }
          .statuses .meta { display: block; margin: 2px 0 0; }
        </style>
        </head>
        <body>
        <header>
          <h1>Memories with \(escaped(names.partner))</h1>
          <p class="lede">\(entries.count) moments and \(statuses.count) statuses, oldest first. \
        The photos and recordings sit beside this page in their own folders.</p>
        \(notes)
        </header>
        \(items)
        \(statusSection)
        </body>
        </html>
        """
    }

    /// A relative path safe for an attribute — the human-readable filenames must
    /// be percent-encoded before a browser sees them.
    private static func href(_ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return escaped(encoded)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
