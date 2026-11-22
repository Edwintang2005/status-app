import SwiftUI
import UIKit

/// The photo the gallery is showing, whole (UI-9).
struct ViewedPhoto: Identifiable {
    let id: String
    let image: UIImage
    /// What VoiceOver reads for the picture.
    let summary: String
    /// Only the thumbnail is here: the full size is still on its way, or offline.
    let isPreview: Bool
}

/// The whole photo, full screen: pinch or double-tap to zoom, drag to pan, and
/// Done or a swipe down to close. Its own screen, so panning never fights the
/// gallery's page swipe.
struct PhotoViewer: View {
    let photo: ViewedPhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// The full size, if it reached this phone after the gallery handed over a thumbnail.
    @State private var full: UIImage?
    /// How far a swipe down has gone, `0...1`: the backdrop fades with it.
    @State private var pull: CGFloat = 0
    /// A single tap hides Done for an unobstructed look.
    @State private var chromeHidden = false

    var body: some View {
        ZoomableImage(image: full ?? photo.image,
                      onPull: { pull = $0 },
                      onDismiss: { dismiss() },
                      // VoiceOver's double-tap arrives as a tap: it mustn't hide the way out.
                      onTap: { if !voiceOver { chromeHidden.toggle() } })
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel(photo.summary)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("viewer.photo")
            .background(Color.black.opacity(1 - pull * 0.7).ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                if !chromeHidden {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("viewer.done")
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(16)
                        .opacity(1 - pull)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if photo.isPreview, full == nil, !chromeHidden {
                    Label("A smaller copy — the full size isn't on this iPhone yet", systemImage: "photo.badge.arrow.down")
                        .font(Theme.rounded(13, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .opacity(1 - pull)
                }
            }
            .animation(.easeOut(duration: 0.2), value: chromeHidden)
            .statusBarHidden(chromeHidden)
            .accessibilityAction(.escape) { dismiss() }
            // Light text on the black backdrop, the status bar's included.
            .preferredColorScheme(.dark)
            .presentationBackground(.clear)
            .task {
                guard photo.isPreview else { return }
                let id = photo.id
                full = await Task.detached(priority: .userInitiated) { MomentStore.shared.image(for: id) }.value
            }
    }
}

/// `UIScrollView` zooming: it pans, bounces and zooms about the fingers the way
/// Photos does, which SwiftUI's own gestures can't match.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onPull: (CGFloat) -> Void
    var onDismiss: () -> Void
    var onTap: () -> Void

    func makeUIView(context: Context) -> ZoomingScrollView {
        ZoomingScrollView(image: image)
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        view.onPull = onPull
        view.onDismiss = onDismiss
        view.onTap = onTap
        view.show(image)
    }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var laidOutFor: CGSize = .zero
    private var dismissing = false
    var onPull: (CGFloat) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onTap: () -> Void = {}

    /// How far down a drag must pull, at rest, to close.
    private static let dismissDistance: CGFloat = 120

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        laidOutFor = .zero
        setNeedsLayout()
    }

    private var atFit: Bool { zoomScale <= minimumZoomScale + 0.001 }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A rotation or the first layout: start again at the whole photo.
        if bounds.size != laidOutFor, bounds.width > 0, bounds.height > 0 {
            laidOutFor = bounds.size
            fitToBounds()
        }
    }

    private func fitToBounds() {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        // Limits first: the old ones would clamp the reset, leaving the view transformed.
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        // Four times the whole photo, and never less than its own pixels.
        maximumZoomScale = max(fit * 4, 1)
        zoomScale = fit
        centre()
    }

    /// A photo smaller than the screen sits in its middle, not its corner.
    private func centre() {
        let horizontal = max(0, (bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (bounds.height - imageView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        // At the whole photo, a vertical drag is the swipe to close.
        alwaysBounceVertical = atFit
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
    }

    private var pulledDown: CGFloat { max(0, -(contentOffset.y + contentInset.top)) }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard atFit, !dismissing else { return }
        onPull(min(1, pulledDown / (Self.dismissDistance * 2)))
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Velocity is points per millisecond; negative is a downward flick.
        guard atFit, pulledDown > Self.dismissDistance || (pulledDown > 24 && velocity.y < -1.2) else { return }
        dismissing = true
        // The backdrop goes with it rather than freezing mid-fade.
        onPull(1)
        onDismiss()
    }

    @objc private func tapped() {
        onTap()
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard atFit else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
