import Foundation

/// Finished year-in-review videos, one per period, so the recap screen reopens on
/// the last one made. In the App Group beside the moments, so whichever process
/// erases those (an unlink, a block, a fresh start) erases these too; excluded
/// from backup, since they're remade from the history any time.
struct RecapStore {
    static let shared = RecapStore()

    struct Saved: Equatable, Sendable {
        var url: URL
        var madeAt: Date
    }

    /// `nil` is the App Group's `Recaps` folder; tests pass a temporary one.
    private let root: URL?

    init(directory: URL? = nil) {
        root = directory
    }

    private var directory: URL? {
        root ?? FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent("Recaps", isDirectory: true)
    }

    /// Also the name it's shared under.
    static func fileName(for period: RecapPlan.Period) -> String {
        switch period {
        case .year(let year): "\(AppConfig.appName) \(String(year)).mp4"
        case .lastTwelveMonths: "\(AppConfig.appName) recap.mp4"
        }
    }

    func saved(for period: RecapPlan.Period) -> Saved? {
        guard let url = directory?.appendingPathComponent(Self.fileName(for: period)),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              (values.fileSize ?? 0) > 0 else { return nil }
        return Saved(url: url, madeAt: values.contentModificationDate ?? Date())
    }

    /// Moves a finished render in, replacing the period's last one.
    func keep(_ staged: URL, for period: RecapPlan.Period) throws -> Saved {
        guard var directory else { throw CocoaError(.fileNoSuchFile) }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        let destination = directory.appendingPathComponent(Self.fileName(for: period))
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staged, to: destination)
        if case .year(let year) = period { removeYears(except: year) }
        return saved(for: period) ?? Saved(url: destination, madeAt: Date())
    }

    /// Only one year is ever offered (`RecapPlan.reviewYear`), so an older
    /// year's video is out of reach once the next unwraps: it goes, keeping
    /// `year` and the twelve-month one Diagnostics makes.
    func removeYears(except year: Int) {
        guard let directory else { return }
        let keep: Set = [Self.fileName(for: .year(year)), Self.fileName(for: .lastTwelveMonths)]
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !keep.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Bytes the kept videos take.
    func size() -> Int {
        guard let directory else { return 0 }
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// They show the history: erased whenever it is. Stamps when, so a run
    /// started before it — paused, or still drawing — isn't kept either.
    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        FileManager.default.createFile(atPath: clearedMarker(for: directory).path, contents: Data())
    }

    /// Whether the kept recaps were cleared after `start`: a render begun then
    /// may show what's gone, so it's gathered again rather than resumed or kept.
    func cleared(since start: Date) -> Bool {
        guard let directory,
              let at = try? clearedMarker(for: directory).resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { return false }
        return at >= start
    }

    /// Beside the folder, not in it: it outlives the folder's removal.
    private func clearedMarker(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".cleared")
    }

    /// Renders in progress stage here (`RecapView`); a run the app was killed
    /// in leaves its folder behind, so launch clears them.
    static func stagingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recap-\(UUID().uuidString)", isDirectory: true)
    }

    static func clearStaging() {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: fileManager.temporaryDirectory,
                                                            includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("recap-") {
            try? fileManager.removeItem(at: entry)
        }
    }
}
