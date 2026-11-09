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
        return saved(for: period) ?? Saved(url: destination, madeAt: Date())
    }

    /// They show the history: erased whenever it is.
    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
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
