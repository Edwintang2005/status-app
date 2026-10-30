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
                        // What the app is, before the rules — the gate itself is unchanged.
                        intro
                    }
                    Text(readOnly ? "Terms of Use" : "The full terms")
                        .font(Theme.rounded(readOnly ? 24 : 18, .semibold))
                    ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(Theme.rounded(15, .semibold))
                            Text(section.body)
                                .font(Theme.rounded(15))
                                .foregroundStyle(Theme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("These terms supplement Apple's standard Licensed Application End User License Agreement, which also applies.")
                        .font(Theme.rounded(13))
                        .foregroundStyle(Theme.mutedText)
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

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("💛")
                .font(.system(size: 44))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(AppConfig.appName)
                    .font(Theme.rounded(32, .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("A private status app for two people.")
                    .font(Theme.rounded(17))
                    .foregroundStyle(Theme.mutedText)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("What you send goes only to your partner, through iCloud.", systemImage: "lock.fill")
                Label("Report or block anything, anytime.", systemImage: "flag.fill")
                Label("We respond to reports within 24 hours.", systemImage: "clock.fill")
            }
            .font(Theme.rounded(15, .medium))
            .labelStyle(TermsBulletStyle())
            .card(padding: 18)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private struct Section {
        let title: LocalizedStringKey
        let body: LocalizedStringKey
    }

    private static let sections: [Section] = [
        Section(title: "What Red String is",
                body: "A private status app for two people who choose to pair with each other. Everything you send — statuses, nudges, photos, drawings and voice memos — goes only to your partner, through iCloud, in the shared space of whoever sent the invite. You are responsible for what you send."),
        Section(title: "No tolerance for objectionable content or abuse",
                body: "Don't send anything that is threatening, harassing, hateful, sexually explicit without consent, violent, illegal, or that involves a minor in any sexual way. Don't use Red String to abuse, stalk or pressure anyone. There is no tolerance for objectionable content or abusive behaviour: reported content is removed from your iPhone at once, and Block ends the link with the person who sent it."),
        Section(title: "Reporting",
                body: "Any status, photo, drawing or voice memo your partner sends can be reported from inside the app. Reporting removes it from your iPhone immediately and opens an email to us with the details, ready for you to send. A word filter, on by default, hides strong language from your partner's messages; you can turn it off in Settings."),
        Section(title: "Blocking",
                body: "Settings → Block ends the link, removes everything your partner sent from your iPhone instantly, refuses any future invite from them, and opens an email so you can tell us."),
        Section(title: "What we do",
                body: "We respond to every report within 24 hours. Red String has no server, so we can't see or delete anything in iCloud ourselves: reporting removes the content from your iPhone straight away, and Block ends the link and refuses that person's invites for good. Your words are end-to-end encrypted, so we only see what you include in your email."),
        Section(title: "Contact",
                body: "Questions, reports and appeals: \(AppConfig.supportEmail)."),
    ]
}

#if DEBUG
#Preview("Terms") {
    TermsView()
        .environment(AppModel.previewModel())
        .tint(Theme.accent)
}
#endif

/// A crimson glyph beside wrapping text, aligned to its first line.
private struct TermsBulletStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.icon
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
