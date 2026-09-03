import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        ZStack {
            Theme.Background()
            // Terms first, even over a tapped invite: nothing user-generated
            // is shown or sent before they're agreed to (guideline 1.2).
            if !model.termsAccepted {
                TermsView()
            } else if model.pendingInvite != nil {
                // An invite outranks first-run: the link is a stronger statement
                // of intent than an empty name field.
                WelcomeView(mode: .joining(ownerName: model.pendingInviteOwnerName))
            } else if !model.hasName {
                WelcomeView(mode: .firstRun)
            } else if model.isPaired {
                HomeView()
            } else {
                PairingView()
            }

            // Layered over the whole app so a celebration doesn't wait behind
            // whichever screen is open.
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
        .animation(.smooth(duration: 0.4), value: model.termsAccepted)
        .animation(.smooth(duration: 0.4), value: model.hasName)
        .animation(.smooth(duration: 0.35), value: model.pendingCelebration)
        // Presented from the root: creating the invite replaces PairingView,
        // which would tear down anything it presented itself.
        .sheet(item: $model.presentedInvite) { invite in
            InviteLinkSheet(url: invite.url, partnerName: model.partnerName)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Report copied",
               isPresented: Binding(get: { model.noticeMessage != nil },
                                    set: { if !$0 { model.noticeMessage = nil } })) {
            Button("OK", role: .cancel) { model.noticeMessage = nil }
        } message: {
            Text(model.noticeMessage ?? "")
        }
    }
}
