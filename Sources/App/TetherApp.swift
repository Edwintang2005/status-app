import CloudKit
import SwiftUI

@main
struct TetherApp: App {
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
                    guard phase == .active else { return }
                    Task { await model.refresh() }
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
