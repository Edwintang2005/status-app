import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What this device's iCloud actually looks like, in plain rows.
///
/// Exists because the two failures that cost the most time to find were both
/// invisible from the UI: a build talking to the Development database while
/// the other phone was on Production, and a device that believed it was paired
/// to a zone it had never actually joined. Both are obvious the moment you can
/// see the environment and the shared-zone list side by side.
struct DiagnosticsView: View {
    @State private var diagnostics: CloudDiagnostics?
    @State private var copied = false

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

                list("Push subscriptions", diagnostics.subscriptions,
                     empty: "None registered yet.")

                if !diagnostics.problems.isEmpty {
                    Section("Problems") {
                        ForEach(diagnostics.problems, id: \.self) { problem in
                            Text(problem)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.warm)
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
        .task { diagnostics = await CloudSync.shared.diagnostics() }
        .refreshable { diagnostics = await CloudSync.shared.diagnostics() }
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

    /// The line that would have ended this whole hunt on day one.
    private func environmentFooter(_ environment: CloudEnvironment) -> String {
        switch environment {
        case .development:
            return "Installed from Xcode, so this app uses the Development "
                + "database. It cannot see or pair with a copy installed from "
                + "TestFlight — they are separate databases with separate data."
        case .production:
            return "Installed from TestFlight or the App Store, so this app "
                + "uses the Production database. Both of you must be on this "
                + "side to pair."
        case .unknown:
            return "Couldn't tell which iCloud database this build uses."
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
