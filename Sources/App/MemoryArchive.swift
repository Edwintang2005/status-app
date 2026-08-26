import Foundation
import os

/// Writes the shared history out as ordinary files, so that ending the link
/// doesn't have to mean losing what was in it.
///
/// Everything here is deliberately boring: dated JPEGs, `.m4a` recordings, an
/// HTML page and a plain text list. No archive format, no database, nothing
/// that needs this app — or any app of ours — to open in ten years. The folder
/// goes into iCloud Drive where the Files app can see it; if iCloud Drive isn't
/// available, the caller is handed the folder to share instead.
enum MemoryArchive {
    private static let log = Logger(subsystem: AppConfig.appGroupID, category: "MemoryArchive")

    struct Outcome: Sendable {
        enum Destination: Sendable, Equatable {
            /// Saved and safe: nothing more for the user to do.
            case iCloudDrive
            /// Written on this device only, because iCloud Drive wasn't
            /// available. The caller must offer to share it before anything is
            /// deleted.
            case deviceOnly
        }

        let folder: URL
        let destination: Destination
        let momentCount: Int
        /// Moments whose photo or recording couldn't be brought back from
        /// CloudKit — listed in the archive rather than quietly dropped.
        let unrecovered: Int
    }

    enum ArchiveError: LocalizedError {
        case nothingToSave

        var errorDescription: String? {
            switch self {
            case .nothingToSave: return "There's nothing saved on this iPhone to archive yet."
            }
        }
    }

    /// - Parameters:
    ///   - moments: the whole history, in any order.
    ///   - progress: called with `0...1` as media is gathered.
    static func write(_ moments: [Moment],
                      partnerName: String,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        guard !moments.isEmpty else { throw ArchiveError.nothingToSave }

        let ordered = moments.sorted { $0.sentAt < $1.sentAt }
        let store = MomentStore.shared
        let fileManager = FileManager.default

        let folderName = Self.folderName(partnerName: partnerName)
        let staging = fileManager.temporaryDirectory.appendingPathComponent(folderName,
                                                                           isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var entries: [Entry] = []
        var unrecovered = 0

        for (index, moment) in ordered.enumerated() {
            progress(Double(index) / Double(ordered.count))

            // Older moments keep their metadata but not their files, so most of
            // an archive of a long relationship is fetched here rather than
            // copied. Best effort: one missing photo shouldn't cost the rest.
            if store.mediaURL(for: moment) == nil {
                try? await Backend.current.fetchMedia(for: moment)
            }

            guard let source = store.mediaURL(for: moment) else {
                unrecovered += 1
                entries.append(Entry(moment: moment, relativePath: nil))
                continue
            }

            let directory = staging.appendingPathComponent(Self.subfolder(for: moment.kind),
                                                           isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let name = Self.fileName(for: moment, extension: source.pathExtension)
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

        try Self.html(for: entries, partnerName: partnerName)
            .write(to: staging.appendingPathComponent("Memories.html"), atomically: true, encoding: .utf8)
        try Self.text(for: entries, partnerName: partnerName)
            .write(to: staging.appendingPathComponent("Memories.txt"), atomically: true, encoding: .utf8)

        progress(1)

        // `url(forUbiquityContainerIdentifier:)` can block on first use, hence
        // the hop off whatever thread we're on.
        let container = await Task.detached { () -> URL? in
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value

        guard let container else {
            log.notice("No iCloud Drive; archive left on the device for sharing.")
            return Outcome(folder: staging,
                           destination: .deviceOnly,
                           momentCount: ordered.count,
                           unrecovered: unrecovered)
        }

        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        let final = Self.unusedURL(in: documents, named: folderName)
        try fileManager.moveItem(at: staging, to: final)

        log.notice("Archived \(ordered.count) moments to iCloud Drive.")
        return Outcome(folder: final,
                       destination: .iCloudDrive,
                       momentCount: ordered.count,
                       unrecovered: unrecovered)
    }

    // MARK: - Naming

    private struct Entry {
        let moment: Moment
        /// `nil` when the file couldn't be recovered.
        let relativePath: String?
    }

    private static func subfolder(for kind: Moment.Kind) -> String {
        switch kind {
        case .photo: return "Photos"
        case .drawing: return "Drawings"
        case .voice: return "Voice memos"
        }
    }

    /// Fixed-format strings need `en_US_POSIX` + Gregorian pinned: with the
    /// device defaults, a Buddhist-calendar phone writes "2569-08-26" into
    /// folder names, and a 12/24-hour override can inject AM/PM into "HHmm".
    /// (`readableDate` below deliberately keeps the device locale — it's the
    /// human-facing text, not a filename.)
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
        let partner = sanitised(partnerName)
        let today = folderDateFormat.string(from: Date())
        return partner.isEmpty
            ? "\(AppConfig.appName) memories \(today)"
            : "\(AppConfig.appName) memories with \(partner) \(today)"
    }

    /// Dated, attributed and captioned, because the filename is the only
    /// metadata that survives being copied somewhere else.
    private static func fileName(for moment: Moment, extension ext: String) -> String {
        var name = fileDateFormat.string(from: moment.sentAt) + " " + sanitised(moment.senderName)
        let caption = sanitised(moment.caption)
        if !caption.isEmpty {
            name += " — " + String(caption.prefix(40))
        }
        return name + "." + (ext.isEmpty ? "dat" : ext)
    }

    /// Strips what a filesystem — or a person reading a filename — can't use.
    private static func sanitised(_ text: String) -> String {
        let stripped = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r"))
            .joined(separator: " ")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two photos sent in the same minute with the same caption are entirely
    /// possible, and silently overwriting one of them isn't acceptable here.
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

    private static func text(for entries: [Entry], partnerName: String) -> String {
        var lines = ["\(AppConfig.appName) — memories with \(partnerName)",
                     "\(entries.count) moments, oldest first.",
                     ""]
        for entry in entries {
            let moment = entry.moment
            var line = readableDate.string(from: moment.sentAt) + "  ·  " + moment.senderName
            if !moment.caption.isEmpty { line += "  ·  \u{201C}\(moment.caption)\u{201D}" }
            if moment.isVoice, moment.duration > 0 {
                line += "  ·  \(Int(moment.duration.rounded()))s"
            }
            line += "  ·  " + (entry.relativePath ?? "[file no longer available]")
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func html(for entries: [Entry], partnerName: String) -> String {
        let items = entries.map { entry -> String in
            let moment = entry.moment
            let when = escaped(readableDate.string(from: moment.sentAt))
            let who = escaped(moment.senderName)
            let caption = moment.caption.isEmpty ? "" :
                "<p class=\"caption\">\(escaped(moment.caption))</p>"

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
                let alt = moment.caption.isEmpty
                    ? "A \(moment.kind == .drawing ? "drawing" : "photo") from \(moment.senderName)"
                    : moment.caption
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

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(AppConfig.appName)) memories with \(escaped(partnerName))</title>
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 17px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            margin: 0 auto; padding: 40px 20px 80px; max-width: 720px;
          }
          header { margin-bottom: 48px; }
          h1 { font-size: 30px; margin: 0 0 8px; }
          .lede { opacity: 0.65; margin: 0; }
          figure { margin: 0 0 44px; }
          img { width: 100%; height: auto; border-radius: 18px; display: block; }
          audio { width: 100%; }
          .caption { font-size: 20px; font-weight: 600; margin: 14px 0 4px; }
          figcaption, .meta { font-size: 14px; opacity: 0.6; margin: 6px 0 0; }
          .missing { font-size: 15px; opacity: 0.6; font-style: italic; margin: 0; }
        </style>
        </head>
        <body>
        <header>
          <h1>Memories with \(escaped(partnerName))</h1>
          <p class="lede">\(entries.count) moments, oldest first. \
        The photos and recordings sit beside this page in their own folders.</p>
        </header>
        \(items)
        </body>
        </html>
        """
    }

    /// A relative path safe to put in an attribute. The filenames carry spaces
    /// and em dashes on purpose — they're meant to be read — so they have to be
    /// percent-encoded before a browser sees them.
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
