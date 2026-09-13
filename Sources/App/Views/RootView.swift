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
        // The one question asked of the owner: after creating the link (once the
        // link sheet is out of the way), and again whenever the partner asks for
        // the date. The sheet can't be swiped away; "Not now" is the way out.
        .sheet(isPresented: Binding(
            get: { (model.anniversaryPromptPending || model.anniversaryRequestPending)
                    && model.canEditAnniversary && model.presentedInvite == nil },
            set: { if !$0 { model.dismissAnniversaryPrompt(); model.dismissAnniversaryRequest() } })) {
            AnniversaryEditorView(mode: .prompt)
                .environment(model)
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

/// Errors raised while a sheet is up can't present from `RootView` (SwiftUI
/// allows one presentation per view), so every sheet hosts the same alert.
private struct ModelErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model: AppModel?

    func body(content: Content) -> some View {
        content.alert("Something went wrong",
                      isPresented: Binding(get: { model?.errorMessage != nil },
                                           set: { if !$0 { model?.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model?.errorMessage = nil }
        } message: {
            Text(model?.errorMessage ?? "")
        }
    }
}

extension View {
    /// Hosts the model's error alert on a sheet's root view — see `ModelErrorAlert`.
    func presentsModelErrors() -> some View {
        modifier(ModelErrorAlert())
    }
}
