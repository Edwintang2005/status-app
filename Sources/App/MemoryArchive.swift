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
        /// Of a kind from a newer build: this one can't save them, so no connection helps.
        let unsupported: Int
        /// With no file in iCloud or on this phone (`ArchiveMedia.gone`): nothing to save,
        /// and nothing a delete could take — but listed, and asked about first.
        let gone: Int
        /// What it allows before a delete (`ArchiveGate`).
        let gate: ArchiveGate
        /// The zone was read, every record in it was readable and every picture and
        /// memo was saved; anything short of that must not be the last copy before a delete.
        var isComplete: Bool { gate == .proceed }
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
        let filterEnabled = SharedStore.shared.contentFilterEnabled
        let names = Names(me: myName, partner: partnerName, filterEnabled: filterEnabled)
        let statuses = contents.statuses.map { $0.moderated(reportedAt: reportedStatusAt, filterEnabled: filterEnabled) }
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

        // Each file is copied into staging as soon as it's on the phone: a moment
        // arriving mid-archive prunes full copies older than five minutes, and a
        // long archive's first downloads are older than that by the end.
        var copied: [String: String] = [:]
        var reserved: Set<String> = []
        func destination(for moment: Moment, extension ext: String) -> (url: URL, relative: String) {
            let directory = staging.appendingPathComponent(Self.subfolder(for: moment.kind), isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = Self.fileName(for: moment, names: names, extension: ext)
            let url = Self.unusedURL(in: directory, named: name, reserved: &reserved)
            return (url, Self.subfolder(for: moment.kind) + "/" + url.lastPathComponent)
        }
        func copy(_ moment: Moment) {
            guard copied[moment.id] == nil, let source = store.mediaURL(for: moment) else { return }
            let destination = destination(for: moment, extension: source.pathExtension).url
            do {
                try fileManager.copyItem(at: source, to: destination)
                copied[moment.id] = Self.subfolder(for: moment.kind) + "/" + destination.lastPathComponent
            } catch {
                log.error("Couldn't copy \(moment.id): \(error.localizedDescription)")
            }
        }

        for moment in ordered where moment.kind.isSupported {
            try Task.checkCancellation()
            copy(moment)
        }
        // Most of a long archive is fetched back from CloudKit rather than copied:
        // straight into staging, each file's name fixed before its download.
        let missing = ordered.filter { $0.kind.isSupported && copied[$0.id] == nil }
        let planned = Dictionary(uniqueKeysWithValues: missing.map {
            ($0.id, destination(for: $0, extension: $0.isVoice ? "m4a" : "jpg"))
        })
        let fetched = await fetchMedia(for: missing, to: planned.mapValues(\.url), progress: progress)
        try Task.checkCancellation()
        for moment in missing where fetched[moment.id] == .saved {
            copied[moment.id] = planned[moment.id]?.relative
        }
        // What iCloud has no file for: the square thumbnail, if this phone kept one,
        // is better than nothing — still counted gone, as the photo itself is.
        for moment in missing where copied[moment.id] == nil && !moment.isVoice {
            guard contents.isGone(fetched[moment.id], momentID: moment.id),
                  let thumb = store.thumbURL(for: moment.id), fileManager.fileExists(atPath: thumb.path) else { continue }
            let small = destination(for: moment, extension: "small.jpg")
            if (try? fileManager.copyItem(at: thumb, to: small.url)) != nil { copied[moment.id] = small.relative }
        }

        var entries: [Entry] = []
        var unrecovered = 0
        var unsupported = 0
        var gone = 0
        for moment in ordered {
            let path = copied[moment.id]
            let isGone = moment.kind.isSupported && contents.isGone(fetched[moment.id], momentID: moment.id)
            if !moment.kind.isSupported {
                unsupported += 1
            } else if isGone {
                gone += 1
            } else if path == nil {
                unrecovered += 1
            }
            entries.append(Entry(moment: moment, relativePath: path, gone: isGone))
        }
        let gate = ArchiveGate(contentsComplete: contents.isComplete, unrecovered: unrecovered,
                               unsupported: unsupported, gone: gone)

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
                           unrecovered: unrecovered, unsupported: unsupported, gone: gone, gate: gate,
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
                       unrecovered: unrecovered, unsupported: unsupported, gone: gone, gate: gate,
                       includesZone: contents.includesZone, unreadable: contents.unreadable)
    }

    /// Chunked, bounded and retried by `ArchiveFetcher`; a download abandoned at
    /// its deadline that lands anyway is counted by its file.
    private static func fetchMedia(for moments: [Moment], to destinations: [String: URL],
                                   progress: @escaping @Sendable (Double) -> Void) async -> [String: ArchiveMedia] {
        guard !moments.isEmpty else { return [:] }
        let backend = Backend.current
        let total = Double(moments.count)
        let fetcher = ArchiveFetcher(
            fetch: { try await backend.fetchArchiveMedia($0, to: destinations) },
            landed: { moment in destinations[moment.id].map { FileManager.default.fileExists(atPath: $0.path) } ?? false })
        let results = await fetcher.run(moments) { done in progress(min(Double(done) / total, 0.95)) }
        let failed = results.values.filter { if case .failed = $0 { true } else { false } }.count
        if failed > 0 { log.error("\(failed) archive downloads failed twice.") }
        return results
    }

    // MARK: - Naming

    private struct Entry {
        let moment: Moment
        /// `nil` when the file couldn't be recovered.
        let relativePath: String?
        /// No file anywhere to recover (`ArchiveMedia.gone`).
        var gone = false
    }

    private struct Names {
        let me: String
        let partner: String
        /// Read once for the whole archive.
        let filterEnabled: Bool

        func sender(of moment: Moment) -> String {
            let fallback = moment.fromMe ? me : partner
            let shown = moment.displaySenderName(fallback: fallback, filterEnabled: filterEnabled)
            return shown.isEmpty ? fallback : shown
        }

        func caption(of moment: Moment) -> String? { moment.displayCaption(filterEnabled: filterEnabled) }

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
        let caption = sanitised(names.caption(of: moment) ?? "")
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
    /// `reserved`: names already promised to a download still under way.
    private static func unusedURL(in directory: URL, named name: String, reserved: inout Set<String>) -> URL {
        let url = unusedURL(in: directory, named: name, taken: reserved)
        reserved.insert(url.path)
        return url
    }

    private static func unusedURL(in directory: URL, named name: String, taken: Set<String> = []) -> URL {
        func free(_ url: URL) -> Bool { !taken.contains(url.path) && !FileManager.default.fileExists(atPath: url.path) }
        let candidate = directory.appendingPathComponent(name)
        guard !free(candidate) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        for suffix in 2...999 {
            let next = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            let url = directory.appendingPathComponent(next)
            if free(url) { return url }
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
            if let caption = names.caption(of: moment) { line += "  ·  \u{201C}\(caption)\u{201D}" }
            if moment.isVoice, moment.duration > 0 {
                line += "  ·  \(Int(moment.duration.rounded()))s"
            }
            line += "  ·  " + (entry.relativePath ?? (entry.gone ? "[no longer in iCloud]" : "[couldn't be fetched]"))
            if entry.gone, entry.relativePath != nil { line += "  ·  a small copy; the photo is no longer in iCloud" }
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
            let caption = names.caption(of: moment).map { "<p class=\"caption\">\(escaped($0))</p>" } ?? ""

            let media: String
            var trailing = "\(who) · \(when)"
            switch (entry.relativePath, moment.kind) {
            case (nil, _):
                media = entry.gone ? "<p class=\"missing\">This one is no longer in iCloud.</p>"
                    : "<p class=\"missing\">This one couldn't be fetched from iCloud.</p>"
            case (let path?, .voice):
                media = "<audio controls src=\"\(href(path))\"></audio>"
                if moment.duration > 0 {
                    trailing += " · \(Int(moment.duration.rounded()))s"
                }
            case (let path?, _):
                let alt = names.caption(of: moment)
                    ?? "A \(moment.kind == .drawing ? "drawing" : "photo") from \(sender)"
                media = "<img src=\"\(href(path))\" alt=\"\(escaped(alt))\">"
                if entry.gone { trailing += " · a small copy; the photo is no longer in iCloud" }
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
