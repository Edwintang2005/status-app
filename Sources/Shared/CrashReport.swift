import Foundation

/// One crash, hang or resource report MetricKit delivered about this app or its
/// extensions, kept on this phone for Diagnostics — there's no server to send
/// it to. Read from `MXDiagnosticPayload.jsonRepresentation()`, so the tests
/// reach it without MetricKit.
struct CrashReport: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case crash, hang, cpu, diskWrites, launch
    }

    var kind: Kind
    /// The end of the period MetricKit reported (whole seconds).
    var at: Date
    var appVersion: String?
    var build: String?
    /// The bundle's last component when it isn't the app (`NotificationService`, …).
    var process: String?
    var detail: String?

    var summary: String {
        let what = switch kind {
        case .crash: String(localized: "Crash")
        case .hang: String(localized: "Hang")
        case .cpu: String(localized: "Too much CPU")
        case .diskWrites: String(localized: "Too many disk writes")
        case .launch: String(localized: "Slow launch")
        }
        var head = what
        if let process { head += " · \(process)" }
        if let appVersion { head += " · \(appVersion)" + (build.map { " (\($0))" } ?? "") }
        let line = [head, detail].compactMap { $0 }.joined(separator: " — ")
        return "\(line) (\(at.formatted(date: .abbreviated, time: .shortened)))"
    }

    /// Every diagnostic in one payload; anything missing or malformed is skipped,
    /// never thrown — Apple's format gains keys over time.
    static func parse(_ json: Data, receivedAt: Date, appBundleID: String) -> [CrashReport] {
        guard let payload = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
        let at = (payload["timeStampEnd"] as? String).flatMap(date(from:)) ?? receivedAt
        let sections: [(key: String, kind: Kind)] = [
            ("crashDiagnostics", .crash), ("hangDiagnostics", .hang),
            ("cpuExceptionDiagnostics", .cpu), ("diskWriteExceptionDiagnostics", .diskWrites),
            ("appLaunchDiagnostics", .launch),
        ]
        return sections.flatMap { section -> [CrashReport] in
            let entries = payload[section.key] as? [[String: Any]] ?? []
            return entries.map { entry in
                let meta = entry["diagnosticMetaData"] as? [String: Any] ?? [:]
                let bundle = meta["bundleIdentifier"] as? String
                return CrashReport(kind: section.kind,
                                   at: at.wholeSeconds,
                                   appVersion: meta["appVersion"] as? String,
                                   build: meta["appBuildVersion"] as? String,
                                   process: bundle.flatMap { $0 == appBundleID ? nil : $0.components(separatedBy: ".").last },
                                   detail: detail(section.kind, meta: meta, tree: entry["callStackTree"]))
            }
        }
    }

    /// Newest first, the same report never twice, at most `limit`.
    static func merged(_ new: [CrashReport], into old: [CrashReport], limit: Int) -> [CrashReport] {
        var seen = Set<String>()
        return (new + old)
            .sorted { $0.at > $1.at }
            .filter { seen.insert("\($0.kind.rawValue)|\($0.at.timeIntervalSince1970)|\($0.detail ?? "")").inserted }
            .prefix(limit)
            .map { $0 }
    }

    private static func detail(_ kind: Kind, meta: [String: Any], tree: Any?) -> String? {
        var parts: [String] = []
        switch kind {
        case .crash:
            if let type = number(meta["exceptionType"]) { parts.append(exceptionName(type)) }
            if let signal = number(meta["signal"]) { parts.append(signalName(signal)) }
            if let reason = meta["terminationReason"] as? String, !reason.isEmpty {
                parts.append(String(reason.prefix(120)))
            }
            if let frame = topFrame(tree) { parts.append(String(localized: "in \(frame)")) }
        case .hang:
            if let duration = meta["hangDuration"] as? String { parts.append(duration) }
            if let frame = topFrame(tree) { parts.append(String(localized: "in \(frame)")) }
        case .cpu:
            if let time = meta["totalCPUTime"] as? String { parts.append(time) }
        case .diskWrites:
            if let writes = meta["writesCaused"] as? String { parts.append(writes) }
        case .launch:
            if let duration = meta["launchDuration"] as? String { parts.append(duration) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The innermost frame of the thread the report blames: which binary, and where.
    private static func topFrame(_ tree: Any?) -> String? {
        guard let stacks = (tree as? [String: Any])?["callStacks"] as? [[String: Any]] else { return nil }
        let blamed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard let frame = (blamed?["callStackRootFrames"] as? [[String: Any]])?.first,
              let binary = frame["binaryName"] as? String else { return nil }
        guard let offset = number(frame["offsetIntoBinaryTextSegment"]) else { return binary }
        return "\(binary) +\(offset)"
    }

    private static func number(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "exception \(type)"
        }
    }

    private static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        default: "signal \(signal)"
        }
    }

    /// MetricKit's stamps look like "2026-11-05 09:41:00 +0000"; some omit the zone.
    private static func date(from text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
