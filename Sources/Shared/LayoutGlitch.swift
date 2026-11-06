import CoreGraphics
import Foundation

/// A sheet that opened with its toolbar but an empty body — the status picker,
/// intermittently, on a phone — measured at the time, for Diagnostics: the
/// cause isn't known, and the simulator never shows it.
struct LayoutGlitch: Codable, Equatable, Sendable {
    var at: Date
    var sheet: String
    /// The space the sheet's body was given, and its safe area.
    var container: String
    var insets: String
    /// What the scrolling content measured, or "never laid out".
    var content: String
    /// Whether rebuilding the body once brought it back; `nil` until checked.
    var healed: Bool?

    var summary: String {
        let outcome = switch healed {
        case true?: "rebuilt, fixed"
        case false?: "rebuilt, still blank"
        case nil: "not rebuilt"
        }
        return "\(sheet): content \(content) in \(container), insets \(insets) — \(outcome) "
            + "(\(at.formatted(date: .abbreviated, time: .shortened)))"
    }

    /// Nothing laid out, laid out with no width or height, or laid out wholly
    /// outside what the sheet shows. `content` is in the scroll view's space.
    static func isBlank(_ content: CGRect?, visible: CGSize?) -> Bool {
        guard let content else { return true }
        if content.width < 1 || content.height < 1 { return true }
        guard let visible, visible.width >= 1, visible.height >= 1 else { return false }
        return !CGRect(origin: .zero, size: visible).intersects(content)
    }

    static func describe(_ size: CGSize?) -> String {
        guard let size else { return "never laid out" }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "never laid out" }
        return "\(describe(rect.size)) at \(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
    }

    /// Newest first, at most `limit`.
    static func recording(_ glitch: LayoutGlitch, in list: [LayoutGlitch], limit: Int) -> [LayoutGlitch] {
        Array(([glitch] + list.filter { $0.at != glitch.at || $0.sheet != glitch.sheet }).prefix(limit))
    }
}
