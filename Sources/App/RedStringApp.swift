import CloudKit
import SwiftUI

@main
struct RedStringApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Before the model reads the store — see `DemoSeeder`.
        DemoSeeder.seedIfRequested()
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Every banner's content is now on screen — clear the backlog.
                        NotificationManager.clearDelivered()
                        Task { await model.refresh() }
                    case .inactive:
                        // Fires as Notification Centre is pulled down over the open
                        // app — see `clearDelivered` for why this proxies "shade opened".
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
                // iCloud account switch while running: re-check readiness without a relaunch.
                .onReceive(NotificationCenter.default
                    .publisher(for: .CKAccountChanged)
                    .receive(on: DispatchQueue.main)) { _ in
                    Task { await model.refresh() }
                }
                .onOpenURL { url in
                    // Widget tap opens the composer — only when paired, so the latched
                    // flag can't pop the composer over a first-run home screen.
                    if url.host == "compose", model.isPaired { model.pendingComposer = true }
                }
        }
    }
}
