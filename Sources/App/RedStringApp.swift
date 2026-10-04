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
        let model = AppModel()
        _model = State(initialValue: model)
        MainActor.assumeIsolated { AppModel.current = model }
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
                        // Only here: `.inactive` also fires for Control Centre, an
                        // incoming call and every app switch, and swept banners the
                        // user had not read.
                        NotificationManager.clearDelivered()
                        Task { await model.refresh() }
                    default:
                        break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .pairingDidChange)) { _ in
                    Task { await model.reloadFromStore() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .snapshotDidChange)) { _ in
                    model.reloadLocally()
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
                    Task { await model.accountDidChange() }
                }
                .onOpenURL { url in
                    // Only when paired, so a latched route can't pop a sheet over
                    // a first-run screen. `moment/<id>` is the photo widget's tap.
                    guard model.isPaired else { return }
                    switch url.host {
                    case "compose":
                        model.pendingRoute = .compose
                    case "moment":
                        let id = url.lastPathComponent
                        model.pendingRoute = id.isEmpty || id == "/" ? .newMoments : .moment(id)
                    default:
                        break
                    }
                }
        }
    }
}
