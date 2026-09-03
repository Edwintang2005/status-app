import Foundation
import XCTest

/// Helpers shared by the store tests: throwaway files and suites, fixed dates.
enum Fixtures {
    /// A whole-second date, like every persisted one (see CLAUDE.md invariant 14).
    static let t0 = Date(timeIntervalSince1970: 1_756_720_000)

    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: t0.timeIntervalSince1970 + seconds)
    }

    static func status(_ emoji: String = "🥰",
                       _ message: String = "missing you",
                       at: Date = t0,
                       nudges: Int = 0,
                       celebration: Bool = false) -> StatusPayload {
        StatusPayload(emoji: emoji,
                      message: message,
                      displayName: "Sam",
                      updatedAt: at,
                      nudgeCount: nudges,
                      lastNudgeAt: nil,
                      isCelebration: celebration)
    }

    static func moment(_ id: String,
                       kind: Moment.Kind = .photo,
                       at: Date = t0,
                       fromMe: Bool = false,
                       seen: Bool? = nil,
                       uploaded: Bool = true) -> Moment {
        Moment(id: id,
               kind: kind,
               caption: "",
               senderName: fromMe ? "Me" : "Sam",
               sentAt: at,
               fromMe: fromMe,
               seen: seen,
               uploaded: uploaded)
    }
}

extension XCTestCase {
    /// A file path nothing else touches, removed (with any `.corrupt` sidecar) on teardown.
    func temporaryFile(_ name: String = "store.json") -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedStringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }

    /// An isolated defaults suite, wiped on teardown — never the real group container.
    func temporaryDefaults() -> UserDefaults {
        let name = "RedStringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.shared.decode(type, from: Data(json.utf8))
    }
}
