import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var confirmingUnpair = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("You") {
                        TextField("Your name", text: $model.myDisplayName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    LabeledContent("Them") {
                        TextField(model.snapshot.theirs?.displayName ?? "Partner",
                                  text: $model.partnerNickname)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                } header: {
                    Text("Names")
                } footer: {
                    Text("The nickname you set for them is yours alone — it shows on your widget and never syncs to their phone.")
                }

                Section("Notifications") {
                    LabeledContent("Nudges") {
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

                if model.role == .owner {
                    Section {
                        Button("Close the invite link") {
                            Task { await model.lockPairing() }
                        }
                    } footer: {
                        Text("Stops anyone else joining with a link you've already sent. Do this once your partner is paired.")
                    }
                }

                Section {
                    Button("Unpair", role: .destructive) { confirmingUnpair = true }
                } footer: {
                    Text(model.role == .owner
                         ? "Deletes the shared zone from your iCloud. Both widgets go blank."
                         : "Leaves the shared zone. Your partner keeps their copy.")
                }

                Section {
                    LabeledContent("Version",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } footer: {
                    Text("Statuses are stored in your own iCloud with the text fields end-to-end encrypted. Nothing is sent anywhere else.")
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
            .confirmationDialog("Unpair from \(model.partnerName)?",
                                isPresented: $confirmingUnpair,
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    Task {
                        await model.unpair()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
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
