import Foundation
import os

/// What each process last did, for Diagnostics: per device, never pairing state.
extension SharedStore {
    /// How the notification service's last push went, for Diagnostics: a banner
    /// left in CloudKit's words is otherwise invisible. Per device.
    struct BannerPass: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case worded
            /// Fetched, but the plan kept CloudKit's words (held unreadable, one batch of many).
            case unworded
            case failed
            /// iOS's deadline came before the words.
            case timedOut
        }

        var at: Date
        var outcome: Outcome
        var seconds: Double
        var detail: String?

        var summary: String {
            let took = seconds.formatted(.number.precision(.fractionLength(1)))
            let what = switch outcome {
            case .worded: String(localized: "worded in \(took) s")
            case .unworded: String(localized: "left generic after \(took) s")
            case .failed: String(localized: "fetch failed after \(took) s")
            case .timedOut: String(localized: "timed out after \(took) s")
            }
            let line = [what, detail].compactMap { $0 }.joined(separator: " — ")
            return "\(line) (\(at.formatted(date: .abbreviated, time: .shortened)))"
        }
    }

    /// The widget's last timeline, for Diagnostics: whether WidgetKit still
    /// calls it, and whether its own check reached iCloud.
    struct WidgetRun: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case fetched
            /// The app or another kind had just fetched; drawn from the store.
            case skipped
            /// iCloud refused or had no route (`WidgetReloadPolicy.waitsQuietly`).
            case unreachable
            case failed
            case unpaired
        }

        /// One attempt to reach iCloud.
        struct Fetch: Codable, Equatable, Sendable {
            var at: Date
            var outcome: Outcome
            var detail: String?
        }

        var at: Date
        var outcome: Outcome
        var detail: String?
        var nextReload: Date
        /// The last run that tried iCloud — kept through the runs that didn't
        /// (opening the app redraws without fetching), so an outage stays visible.
        var lastFetch: Fetch?

        /// This run, carrying the previous one's attempt when it made none.
        static func recorded(after previous: WidgetRun?, at: Date, outcome: Outcome,
                             detail: String?, nextReload: Date) -> WidgetRun {
            let fetched = [.fetched, .unreachable, .failed].contains(outcome)
            return WidgetRun(at: at, outcome: outcome, detail: detail, nextReload: nextReload,
                             lastFetch: fetched ? Fetch(at: at, outcome: outcome, detail: detail) : previous?.lastFetch)
        }

        var summary: String {
            let next = nextReload.formatted(date: .omitted, time: .shortened)
            var line = "\(Self.words(outcome, detail)) (\(at.formatted(date: .abbreviated, time: .shortened))), next \(next)"
            if let lastFetch, lastFetch.at != at {
                line += " · last fetch: \(Self.words(lastFetch.outcome, lastFetch.detail)) "
                    + "(\(lastFetch.at.formatted(date: .abbreviated, time: .shortened)))"
            }
            return line
        }

        private static func words(_ outcome: Outcome, _ detail: String?) -> String {
            let what = switch outcome {
            case .fetched: String(localized: "fetched")
            case .skipped: String(localized: "drawn from this iPhone's copy")
            case .unreachable: String(localized: "couldn't reach iCloud")
            case .failed: String(localized: "fetch failed")
            case .unpaired: String(localized: "not linked")
            }
            return [what, detail].compactMap { $0 }.joined(separator: " — ")
        }
    }

    var lastWidgetRun: WidgetRun? {
        get { self[Key.lastWidgetRun] }
        set { self[Key.lastWidgetRun] = newValue }
    }

    var lastBannerPass: BannerPass? {
        get { self[Key.lastBannerPass] }
        set { self[Key.lastBannerPass] = newValue }
    }

    #if DEBUG
    /// What one process last saw of delivered banners, and how its last rewrite
    /// went — the device probes behind `BannerUpkeep` (Diagnostics). DEBUG only.
    struct BannerProbe: Codable, Equatable, Sendable {
        var at: Date
        var listed: Int
        var rewrite: String?
    }

    /// One key per process, so no process writes over another's.
    func bannerProbe(for process: String) -> BannerProbe? {
        decode(BannerProbe.self, forKey: "bannerProbe.\(process)")
    }

    func setBannerProbe(_ probe: BannerProbe, for process: String) {
        encodeOptional(probe, forKey: "bannerProbe.\(process)")
    }

    static let processName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "?"
    #endif

    /// Sheets that opened blank, measured at the time, newest first, for
    /// Diagnostics (`LayoutGlitch`). Per device, written only by the app.
    var layoutGlitches: [LayoutGlitch] {
        get { decode(LossyArray<LayoutGlitch>.self, forKey: Key.layoutGlitches.name)?.elements ?? [] }
        set { self[Key.layoutGlitches] = newValue.isEmpty ? nil : newValue }
    }

    /// The share sheet's last openings, newest first (`ShareLaunch`). Written only by the sheet.
    var shareLaunches: [ShareLaunch] {
        get { decode(LossyArray<ShareLaunch>.self, forKey: Key.shareLaunches.name)?.elements ?? [] }
        set { self[Key.shareLaunches] = newValue.isEmpty ? nil : newValue }
    }

    /// MetricKit's crash and hang reports, newest first, for Diagnostics. Per
    /// device, written only by the app; a bad entry costs only itself.
    var crashReports: [CrashReport] {
        get { decode(LossyArray<CrashReport>.self, forKey: Key.crashReports.name)?.elements ?? [] }
        set { self[Key.crashReports] = newValue.isEmpty ? nil : newValue }
    }
}
