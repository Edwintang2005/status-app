import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Plain rows of what this device's iCloud actually looks like. The costly
/// failures (Dev-vs-Prod database mismatch, a pairing to a zone never actually
/// joined) are invisible from the normal UI.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    @State private var diagnostics: CloudDiagnostics?
    @State private var resyncing = false
    /// Outcome line for the history re-check, shown under its button.
    @State private var resyncResult: String?
    @State private var copied = false
    @State private var securing = false
    /// Outcome line for the manual promote-and-close, shown under its button.
    @State private var secureResult: String?
    /// Outcome line for the DEBUG public-joiner sweep.
    @State private var sweepResult: String?
    /// Bytes the kept recap videos take; `nil` until measured.
    @State private var recapBytes: Int?
    /// The last "Time a load and save" result.
    @State private var historyTiming: String?

    var body: some View {
        Form {
            if let diagnostics {
                Section {
                    LabeledContent("Environment", value: diagnostics.environment.label)
                    LabeledContent("Account", value: diagnostics.accountStatus)
                    LabeledContent("Pairing", value: diagnostics.pairing)
                    LabeledContent("Last notification", value: diagnostics.lastNotification)
                    LabeledContent("Widget", value: diagnostics.widget)
                } header: {
                    Text("This device")
                } footer: {
                    Group {
                        Text(environmentFooter(diagnostics.environment))
                    }
                    // The system footer grey is ~3.6:1 on the cream backdrop; this is AA.
                    .foregroundStyle(Theme.mutedText)
                }

                Section("Container") {
                    Text(diagnostics.containerID)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }

                list("Your own zones", diagnostics.privateZones,
                     empty: "None. As the owner of a link you'd have CoupleZone here.")

                list("Zones shared with you", diagnostics.sharedZones,
                     empty: "None. If you joined someone's link, their zone would be here — an empty list means the join never completed.")

                Section {
                    if let permission = diagnostics.sharePublicPermission {
                        LabeledContent("Invite link", value: permission)
                    }
                    if diagnostics.shareParticipants.isEmpty {
                        Text("No share found — either this device isn't paired, or the shared zone is gone.")
                            .font(.footnote)
                            .foregroundStyle(Theme.mutedText)
                    } else {
                        ForEach(diagnostics.shareParticipants, id: \.self) { participant in
                            Text(participant)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Share participants")
                } footer: {
                    Group {
                        Text("Once paired, both people should be listed as accepted with the link closed. A partner shown as \u{201C}public\u{201D} while the link is open hasn't been locked in yet — closing the link removes public participants, so the button below closes it and re-adds them as private — they then tap the link once to confirm.")
                    }
                    .foregroundStyle(Theme.mutedText)
                }

                if SharedStore.shared.pairing?.role == .owner {
                    #if DEBUG
                    Section {
                        Button {
                            Task { await sweepNow() }
                        } label: {
                            Label("Sweep public joiners", systemImage: "person.badge.minus")
                        }
                        .disabled(securing)
                        if let sweepResult {
                            Text(sweepResult)
                                .font(.footnote)
                                .foregroundStyle(Theme.mutedText)
                        }
                    } footer: {
                        Group {
                            Text("Ejects anyone who came in through the open link, then reopens it. Named participants and records are untouched.")
                        }
                        .foregroundStyle(Theme.mutedText)
                    }
                    #endif

                    Section {
                        Button {
                            Task { await secureNow() }
                        } label: {
                            if securing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Securing…")
                                }
                            } else {
                                Label("Promote partner & close invite",
                                      systemImage: "lock")
                            }
                        }
                        .disabled(securing)
                        if let secureResult {
                            Text(secureResult)
                                .font(.footnote)
                                .foregroundStyle(Theme.mutedText)
                        }
                    } footer: {
                        Group {
                            Text("Tries to make your partner a private participant and close the link to anyone new. Caution: if the promotion fails, CloudKit can drop them from the share entirely — their app then unlinks and they must rejoin with the invite link (history comes back, but not their local read/seen state). Only use it with your partner on standby.")
                        }
                        .foregroundStyle(Theme.mutedText)
                    }
                }

                if model.isPaired {
                    Section {
                        Button {
                            Task { await resyncNow() }
                        } label: {
                            if resyncing {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text("Checking…")
                                }
                            } else {
                                Label("Re-check sent moments", systemImage: "arrow.triangle.2.circlepath.icloud")
                            }
                        }
                        .disabled(resyncing)
                        if let resyncResult {
                            Text(resyncResult)
                                .font(.footnote)
                                .foregroundStyle(Theme.mutedText)
                        }
                    } footer: {
                        Group {
                            Text("Fetches the whole shared history again and compares it with what this phone believes it sent. Anything marked sent that iCloud never received is sent again — a photo saved during patchy signal can look delivered here without ever having left the phone.")
                        }
                        .foregroundStyle(Theme.mutedText)
                    }
                }

                list("Push subscriptions", diagnostics.subscriptions,
                     empty: "None registered yet.")

                #if DEBUG
                Section {
                    ForEach(Self.probeProcesses, id: \.name) { process in
                        LabeledContent(process.label, value: Self.probeLine(process.name))
                    }
                } header: {
                    Text("Notification probes")
                } footer: {
                    Group {
                        Text("Each process that tidies banners records how many it could list and whether its last rewrite replaced the banner in place. To run them: lock this phone, have your partner set a status, then unlock and let the widget refresh or long-press the banner. Expanded banner: long-press a banner while locked, unlock with it open, and check it stays open as its words change.")
                    }
                    .foregroundStyle(Theme.mutedText)
                }
                #endif

                if !diagnostics.layoutGlitches.isEmpty {
                    list("Blank sheets", diagnostics.layoutGlitches, empty: "")
                }

                list("Crashes and hangs", diagnostics.crashReports,
                     empty: "None yet. iOS hands these over about once a day, and a crash usually on the next launch; they stay on this phone.")

                list("Share sheet launches", diagnostics.shareLaunches,
                     empty: "Not opened yet. Each time \(AppConfig.appName) is picked in a share sheet, its start, when it was on screen and how it ended are kept here; \"never on screen\" is one that flashed and closed.")

                if !diagnostics.problems.isEmpty {
                    Section("Problems") {
                        ForEach(diagnostics.problems, id: \.self) { problem in
                            Text(problem)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.warmText)
                        }
                    }
                }

                Section {
                    Button {
                        copy(diagnostics.report + Self.probeReport)
                    } label: {
                        Label(copied ? "Copied" : "Copy report",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            } else {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Reading iCloud…")
                            .foregroundStyle(Theme.mutedText)
                    }
                }
            }

            Section {
                NavigationLink("Make a recap of the last 12 months") {
                    RecapView(period: .lastTwelveMonths)
                }
                Button(model.recapCardPreview ? "Recap card is on Home" : "Show the recap card on Home") {
                    model.recapCardPreview = true
                }
                .tint(.primary)
                .disabled(model.recapCardPreview)
                Button {
                    RecapStore.shared.removeAll()
                    RecapStore.clearStaging()
                    recapBytes = RecapStore.shared.size()
                } label: {
                    LabeledContent("Delete saved recap videos",
                                   value: (recapBytes ?? 0).formatted(.byteCount(style: .file)))
                }
                .tint(.primary)
                .disabled((recapBytes ?? 0) == 0)
                .onAppear { recapBytes = RecapStore.shared.size() }
            } header: {
                Text("Year in review")
            } footer: {
                Group {
                    Text("The year's recap unwraps at midday on 25 December — a notification, and a Home card until 31 January — and stays in Settings after that. These make one now, from whatever falls in the last 12 months. Each year's video is kept until the next year's unwraps; deleting them only means the next look makes them again.")
                }
                .foregroundStyle(Theme.mutedText)
            }

            #if DEBUG
            historyTest
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Background())
        .navigationTitle("iCloud diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    #if DEBUG
    private func sweepNow() async {
        securing = true
        defer { securing = false }
        sweepResult = await model.sweepPublicJoiners()
        await reload()
    }
    #endif

    /// The explicit trigger behind the button; the passive attempt in `reload()`
    /// stays quiet, this one always reports back.
    private func secureNow() async {
        securing = true
        defer { securing = false }
        let problem = await model.secureInviteFromDiagnostics()
        secureResult = problem
            ?? String(localized: "Done — the link is closed. If your partner shows as \u{201C}invited\u{201D} or \u{201C}pending\u{201D} above, they confirm by tapping the invite link once.")
        await reload()
    }

    private func resyncNow() async {
        resyncing = true
        defer { resyncing = false }
        guard let found = await model.resyncHistory() else {
            resyncResult = String(localized: "Couldn't fetch the history from iCloud. Try again on a better connection.")
            await reload()
            return
        }
        let stillPending = model.pendingUploadCount
        if found == 0 {
            resyncResult = String(localized: "Everything this phone sent is in iCloud.")
        } else if stillPending == 0, model.isUploading {
            resyncResult = String(localized: "\(found) moment(s) were missing from iCloud and are being sent now.")
        } else if stillPending == 0 {
            resyncResult = String(localized: "\(found) moment(s) were missing from iCloud and have now been sent.")
        } else {
            resyncResult = String(localized: "\(found) moment(s) were missing from iCloud; \(stillPending) still waiting — the home screen retries them.")
        }
        await reload()
    }

    /// Strictly read-only. The promote-and-close can evict a link-joined
    /// partner from the share when it fails, so it only ever runs from the
    /// explicit button above — never as a side effect of looking.
    private func reload() async {
        diagnostics = await CloudSync.shared.diagnostics()
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String], empty: String) -> some View {
        Section {
            if items.isEmpty {
                Text(empty)
                    .font(.footnote)
                    .foregroundStyle(Theme.mutedText)
            } else {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(title)
        }
    }

    private func environmentFooter(_ environment: CloudEnvironment) -> String {
        switch environment {
        case .development:
            return String(localized: "Installed from Xcode, so this app uses the Development database. It cannot see or pair with a copy installed from TestFlight — they are separate databases with separate data. A second device on the same iCloud account writes the same records as this one, not the partner's.")
        case .production:
            return String(localized: "Installed from TestFlight or the App Store, so this app uses the Production database. Both of you must be on this side to pair. A second device on the same iCloud account writes the same records as this one, not the partner's.")
        case .unknown:
            return String(localized: "Couldn't tell which iCloud database this build uses.")
        }
    }

    #if DEBUG
    /// Fills this phone's history toward its cap with local placeholders, so a
    /// long history's speed and the notification service's memory can be tried.
    @ViewBuilder
    private var historyTest: some View {
        let padded = model.history.lazy.filter { MomentIndex.isPadding($0.id) }.count
        Section {
            LabeledContent("Moments on this phone",
                           value: padded == 0 ? "\(model.history.count)" : "\(model.history.count) (\(padded) padding)")
            LabeledContent("History refill", value: Self.refillState)
            Button {
                historyTiming = "Timing…"
                Task {
                    let result = await Task.detached(priority: .userInitiated) { MomentIndex.shared.measure() }.value
                    historyTiming = result.map {
                        "\($0.count) moments · \($0.bytes.formatted(.byteCount(style: .file))) · "
                            + "load \(Int($0.decode * 1000)) ms · save \(Int($0.encode * 1000)) ms"
                    } ?? "Couldn't read the history."
                }
            } label: {
                Text("Time a load and save")
            }
            .tint(.primary)
            if let historyTiming {
                Text(historyTiming)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.mutedText)
            }
            Button("Pad history to \(AppConfig.momentHistoryLimit.formatted())") { model.padHistory() }
                .tint(.primary)
                .disabled(model.history.count >= AppConfig.momentHistoryLimit)
            Button("Remove padding", role: .destructive) { model.removePadding() }
                .disabled(padded == 0)
        } header: {
            Text("History (test)")
        } footer: {
            Group {
                Text("Padding adds placeholder moments to this iPhone's history only — nothing is sent to iCloud or your partner. They're dated before 2020 and already seen, so no recap, notification or widget shows them; their library tiles show Retry, as they have no pictures. Remove them before archiving memories. With the history padded, have your partner send something while Xcode is attached to the notification service to see its memory.")
            }
            .foregroundStyle(Theme.mutedText)
        }
    }

    private static var refillState: String {
        switch SharedStore.shared.historyCoverage {
        case nil: return "not checked yet"
        case HistoryCoverage.owed: return "under way"
        case let limit?: return limit >= AppConfig.momentHistoryLimit ? "complete" : "filled to \(limit)"
        }
    }

    private static let probeProcesses: [(name: String, label: String)] = [
        ("RedStringNotificationService", "Notification service"),
        ("RedStringWidgetExtension", "Widget"),
        ("RedStringNotificationContent", "Expanded banner"),
        ("RedString", "App"),
    ]

    private static func probeLine(_ process: String) -> String {
        guard let probe = SharedStore.shared.bannerProbe(for: process) else { return "not run yet" }
        return "listed \(probe.listed) · \(probe.rewrite ?? "no rewrite yet") "
            + "(\(probe.at.formatted(date: .omitted, time: .shortened)))"
    }

    private static var probeReport: String {
        "\nNotification probes: " + probeProcesses.map { "\($0.label): \(probeLine($0.name))" }.joined(separator: " | ")
    }
    #else
    private static let probeReport = ""
    #endif

    private func copy(_ text: String) {
        Clipboard.copy(text: text, localOnly: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

#if DEBUG
#Preview("Diagnostics") {
    NavigationStack {
        DiagnosticsView()
    }
    .tint(Theme.accent)
}
#endif
