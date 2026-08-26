import CloudKit
import SwiftUI

@main
struct RedStringApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Opening the app means every banner's content is now
                        // on screen — clear the backlog so Notification
                        // Centre doesn't hoard a day of statuses.
                        NotificationManager.clearDelivered()
                        Task { await model.refresh() }
                    case .inactive:
                        // Fires as Notification Centre is pulled down over
                        // the open app — see `clearDelivered` for why this is
                        // the closest thing to "the user opened the shade".
                        NotificationManager.clearDelivered()
                    default:
                        break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pairingDidChange)) { _ in
                    Task { await model.reloadFromStore() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pairingDidFail)) { note in
                    model.errorMessage = note.object as? String
                }
                .onReceive(NotificationCenter.default.publisher(for: .inviteDidArrive)) { note in
                    guard let metadata = note.object as? CKShare.Metadata else { return }
                    _ = InviteInbox.shared.take()
                    model.receiveInvite(metadata)
                }
                .onOpenURL { url in
                    // Tapping the photo widget jumps straight to the composer.
                    if url.host == "compose" { model.pendingComposer = true }
                }
        }
    }
}
