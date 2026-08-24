import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack {
            Theme.Background()
            // One gate before anything else: we can't show a status, send a
            // nudge or accept an invite without knowing what to call this
            // person. An invite outranks first-run, because the link is a
            // stronger statement of intent than an empty name field.
            if model.pendingInvite != nil {
                WelcomeView(mode: .joining(ownerName: model.pendingInviteOwnerName))
            } else if !model.hasName {
                WelcomeView(mode: .firstRun)
            } else if model.isPaired {
                HomeView()
            } else {
                PairingView()
            }

            // Layered over the whole app rather than presented from HomeView:
            // an anniversary greeting shouldn't have to wait behind whatever
            // screen you happened to leave open.
            if let celebration = model.pendingCelebration {
                CelebrationOverlay(payload: celebration,
                                   partnerName: model.partnerName) {
                    model.celebrationPlayed()
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.smooth(duration: 0.4), value: model.isPaired)
        .animation(.smooth(duration: 0.4), value: model.hasName)
        .animation(.smooth(duration: 0.35), value: model.pendingCelebration)
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
