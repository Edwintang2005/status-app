import SwiftUI

/// The terms every user agrees to before pairing (App Review guideline 1.2:
/// user-generated content). Also readable later from Settings.
struct TermsView: View {
    /// Settings shows the same text without the agree button.
    var readOnly = false

    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if !readOnly { Theme.Background() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !readOnly {
                        Text("Before you start")
                            .font(Theme.rounded(30, .bold))
                            .padding(.top, 24)
                    }
                    Text("Terms of Use")
                        .font(Theme.rounded(readOnly ? 24 : 18, .semibold))
                    ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(Theme.rounded(15, .semibold))
                            Text(section.body)
                                .font(Theme.rounded(15))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("These terms supplement Apple's standard Licensed Application End User License Agreement, which also applies.")
                        .font(Theme.rounded(13))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, readOnly ? 24 : 120)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(readOnly ? "Terms of Use" : "")
        .safeAreaInset(edge: .bottom) {
            if !readOnly {
                Button {
                    model.acceptTerms()
                } label: {
                    Text("I agree")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
            }
        }
    }

    private struct Section {
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private static let sections: [Section] = [
        Section(title: "What Red String is",
                body: "A private status app for two people who choose to pair with each other. Everything you send — statuses, nudges, photos, drawings and voice memos — goes only to your partner, through your own iCloud. You are responsible for what you send."),
        Section(title: "No tolerance for objectionable content or abuse",
                body: "Don't send anything that is threatening, harassing, hateful, sexually explicit without consent, violent, illegal, or that involves a minor in any sexual way. Don't use Red String to abuse, stalk or pressure anyone. There is no tolerance for objectionable content or abusive behaviour: content is removed and the person who sent it is ejected."),
        Section(title: "Reporting",
                body: "Any status, photo, drawing or voice memo your partner sends can be reported from inside the app. Reporting removes it from your iPhone immediately and sends the details to us. A word filter, on by default, hides strong language from your partner's messages; you can turn it off in Settings."),
        Section(title: "Blocking",
                body: "Settings → Block ends the link, removes everything your partner sent from your iPhone instantly, refuses any future invite from them, and notifies us."),
        Section(title: "What we do",
                body: "We act on every report within 24 hours: the reported content is removed and, where the report is upheld, the person who sent it is ejected from the shared space and barred from pairing with the reporter again. Because messages are end-to-end encrypted in your iCloud, we can only see what you include in a report."),
        Section(title: "Contact",
                body: "Questions, reports and appeals: edwintang2005@gmail.com."),
    ]
}

#if DEBUG
#Preview("Terms") {
    TermsView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif
