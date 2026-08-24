import SwiftUI
import UIKit

/// `UIActivityViewController`, for handing the memories archive to whatever the
/// user wants to keep it in — Files, AirDrop, Mail.
///
/// Not `ShareLink`: this is presented as the *result* of an action rather than
/// being a button the user pressed, and `ShareLink` can only be the button.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
