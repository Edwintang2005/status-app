import Foundation
import MetricKit

/// Files MetricKit's diagnostics — the app's crashes and hangs and its
/// extensions' — as `CrashReport`s for Diagnostics. No server: they stay here.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = CrashReporter()

    /// MetricKit holds subscribers weakly; `shared` keeps this one alive.
    func start() {
        MXMetricManager.shared.add(self)
        // Reports delivered while no build of ours was listening.
        file(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    /// Arrives on a background queue: turned into plain values before the hop.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        file(payloads)
    }

    private func file(_ payloads: [MXDiagnosticPayload]) {
        let now = Date()
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let reports = payloads.flatMap {
            CrashReport.parse($0.jsonRepresentation(), receivedAt: now, appBundleID: bundleID)
        }
        guard !reports.isEmpty else { return }
        Task { @MainActor in
            let store = SharedStore.shared
            store.crashReports = CrashReport.merged(reports, into: store.crashReports,
                                                    limit: AppConfig.crashReportLimit)
        }
    }
}
