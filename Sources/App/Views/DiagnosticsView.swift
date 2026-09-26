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

    var body: some View {
        Form {
            if let diagnostics {
                Section {
                    LabeledContent("Environment", value: diagnostics.environment.label)
                    LabeledContent("Account", value: diagnostics.accountStatus)
                    LabeledContent("Pairing", value: diagnostics.pairing)
                } header: {
                    Text("This device")
                } footer: {
                    Text(environmentFooter(diagnostics.environment))
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
                            .foregroundStyle(.secondary)
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
                    Text("Once paired, both people should be listed as accepted "
                         + "with the link closed. A partner shown as \u{201C}public\u{201D} "
                         + "while the link is open hasn't been locked in yet — closing "
                         + "the link removes public participants, so the button below "
                         + "closes it and re-adds them as private — they then tap the "
                         + "link once to confirm.")
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
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Ejects anyone who came in through the open link, "
                             + "then reopens it. Named participants and records "
                             + "are untouched.")
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
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Tries to make your partner a private participant "
                             + "and close the link to anyone new. Caution: if "
                             + "the promotion fails, CloudKit can drop them from "
                             + "the share entirely — their app then unlinks and "
                             + "they must rejoin with the invite link (history "
                             + "comes back, but not their local read/seen state). "
                             + "Only use it with your partner on standby.")
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
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Fetches the whole shared history again and compares it with what this "
                             + "phone believes it sent. Anything marked sent that iCloud never "
                             + "received is sent again — a photo saved during patchy signal can "
                             + "look delivered here without ever having left the phone.")
                    }
                }

                list("Push subscriptions", diagnostics.subscriptions,
                     empty: "None registered yet.")

                if !diagnostics.problems.isEmpty {
                    Section("Problems") {
                        ForEach(diagnostics.problems, id: \.self) { problem in
                            Text(problem)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.warmDeep)
                        }
                    }
                }

                Section {
                    Button {
                        copy(diagnostics.report)
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
        sweepResult = await CloudSync.shared.sweepPublicJoiners()
        await reload()
    }
    #endif

    /// The explicit trigger behind the button; the passive attempt in `reload()`
    /// stays quiet, this one always reports back.
    private func secureNow() async {
        securing = true
        defer { securing = false }
        let problem = await CloudSync.shared.secureInviteIfPartnerJoined()
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
                    .foregroundStyle(.secondary)
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

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
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
