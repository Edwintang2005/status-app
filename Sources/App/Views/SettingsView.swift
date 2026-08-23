import SwiftUI
import UserNotifications

/// Which demo sheet is showing. Declared unconditionally so the `.sheet`
/// modifier below doesn't need to appear and disappear between build
/// configurations; in CloudKit builds nothing ever sets it.
enum DemoSheet: String, Identifiable {
    case status
    case moment

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmingUnpair = false
    /// Owned here, not by the Section. A `.sheet` attached to a `Section`
    /// inside a `Form` dismisses the enclosing sheet instead of presenting.
    @State private var demoSheet: DemoSheet?

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Your name") {
                        TextField("Your name", text: $model.myDisplayName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                } footer: {
                    Text("This is the name \(model.partnerName) sees on your status, your nudges and anything you send. Their name is theirs to set.")
                }

                Section("Notifications") {
                    LabeledContent("Nudges and photos") {
                        Text(notificationLabel)
                            .foregroundStyle(.secondary)
                    }
                    if notificationStatus == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }

                #if TETHER_LOCAL_MODE
                Section {
                    LabeledContent("Their name") {
                        TextField("Partner", text: $model.demoPartnerName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    Button("Set their status…") { demoSheet = .status }
                    Button("Make them nudge you") {
                        Task { await model.simulatePartnerNudge() }
                    }
                    Button("Send yourself a photo or doodle…") { demoSheet = .moment }
                } header: {
                    Text("Demo controls")
                } footer: {
                    Text("Drive the other side of the conversation, including the name they'd have set for themselves. Everything here behaves exactly as a real update would — widgets and notifications included.")
                }
                #else
                if model.role == .owner {
                    Section {
                        Button("Close the invite link") {
                            Task { await model.lockPairing() }
                        }
                    } footer: {
                        Text("Stops anyone else joining with a link you've already sent. Do this once your partner is paired.")
                    }
                }
                #endif

                Section {
                    Button(model.isLocalDemo ? "Reset demo" : "Unpair", role: .destructive) {
                        confirmingUnpair = true
                    }
                } footer: {
                    Text(unpairFooter)
                }

                Section {
                    LabeledContent("Version",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } footer: {
                    Text(model.isLocalDemo
                         ? "Demo build. Nothing is sent anywhere — every \"partner\" action comes from the controls above."
                         : "Statuses are stored in your own iCloud with the text end-to-end encrypted. Photos and drawings are CloudKit assets, which are encrypted by default.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Background())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { notificationStatus = await NotificationManager.authorizationStatus() }
            .confirmationDialog(model.isLocalDemo
                                ? "Reset the demo?"
                                : "Unpair from \(model.partnerName)?",
                                isPresented: $confirmingUnpair,
                                titleVisibility: .visible) {
                Button(model.isLocalDemo ? "Reset" : "Unpair", role: .destructive) {
                    Task {
                        await model.unpair()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $demoSheet) { sheet in
                demoSheetContent(sheet)
            }
        }
    }

    @ViewBuilder
    private func demoSheetContent(_ sheet: DemoSheet) -> some View {
        #if TETHER_LOCAL_MODE
        switch sheet {
        case .status:
            MoodPickerView(title: "\(model.partnerName)'s status",
                           initialEmoji: model.snapshot.theirs?.emoji ?? "",
                           initialMessage: model.snapshot.theirs?.message ?? "") { emoji, message in
                Task { await model.simulatePartnerStatus(emoji: emoji, message: message) }
            }
        case .moment:
            MomentComposerView(title: "Send as \(model.partnerName)",
                               sendLabel: "Receive") { image, kind, caption in
                Task { await model.simulatePartnerMoment(image: image, kind: kind, caption: caption) }
            }
            .environment(model)
        }
        #else
        EmptyView()
        #endif
    }

    private var unpairFooter: String {
        if model.isLocalDemo {
            return "Clears the demo partner and all local photos."
        }
        return model.role == .owner
            ? "Deletes the shared zone from your iCloud. Both widgets go blank."
            : "Leaves the shared zone. Your partner keeps their copy."
    }

    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Not set"
        }
    }
}

#if DEBUG
#Preview("Settings") {
    SettingsView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
