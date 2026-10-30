import AVFoundation
import AVKit
import SwiftUI

/// The moment camera: timer, flash, lens buttons, tap to focus, pinch to zoom,
/// and the hardware shutters (volume buttons, AirPods, Camera Control). Shows
/// the 4:3 frame that's sent. Nothing in this body reads `model.zoom`: a pinch
/// would re-render it, and the preview with it, every frame.
struct CameraView: View {
    var onCapture: (CameraShot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = CameraModel()
    @State private var focusPoint: CGPoint?

    static var isAvailable: Bool { CameraEngine.isAvailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .denied:
                notice("Camera access is off",
                       detail: "Turn it on in Settings to take a photo here.",
                       opensSettings: true)
            case .failed:
                notice("The camera couldn't start", detail: "Close this and try again.")
            case .starting, .running:
                camera
            }
        }
        .statusBarHidden()
        .task {
            model.onCapture = { shot in
                onCapture(shot)
                dismiss()
            }
            await model.start()
        }
        .onDisappear { model.stop() }
        .sensoryFeedback(.impact(weight: .light), trigger: model.countdown) { _, new in new != nil }
        // A dark shot is in: the phone can move.
        .sensoryFeedback(.impact(weight: .light), trigger: model.isHoldingStill) { old, new in old && !new }
        .animation(.easeOut(duration: 0.2), value: model.isLowLight)
    }

    // MARK: - Camera

    private var camera: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 8)
            viewfinder
            Spacer(minLength: 8)
            LensRow(model: model)
                .frame(height: 44)
                .opacity(model.controlsFullscreen ? 0 : 1)
            shutterRow
                .padding(.vertical, 16)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            iconButton("xmark", label: "Close") { dismiss() }
            Spacer()
            Group {
                if model.supportsBothCameras {
                    iconButton("pip", label: "Both cameras",
                               value: model.isDual ? String(localized: "On") : String(localized: "Off"),
                               tint: model.isDual ? Theme.warm : .white) {
                        model.toggleBothCameras()
                    }
                    .disabled(model.countdown != nil || model.isCapturing || model.state != .running)
                }
                if model.flashModes.count > 1 {
                    iconButton(flashSymbol, label: "Flash", value: flashValue,
                               tint: model.flash == .on ? Theme.warm : .white) {
                        model.cycleFlash()
                    }
                }
                iconButton("timer", label: "Timer", value: timerValue,
                           tint: model.timer == .off ? .white : Theme.warm,
                           badge: model.timer == .off ? nil : model.timer.title) {
                    model.cycleTimer()
                }
                .disabled(model.countdown != nil)
            }
            .opacity(model.controlsFullscreen ? 0 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var viewfinder: some View {
        Group {
            if model.isDual {
                DualCameraPreview(model: model) { point in focusPoint = point }
            } else {
                CameraPreview(model: model) { point in focusPoint = point }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay { focusRing }
        .overlay { countdownOverlay }
        .overlay(alignment: .bottom) { statusLine }
        .overlay(alignment: .top) { DebugFormatLabel(model: model) }
        .overlay(alignment: .topLeading) { lowLightBadge }
        .overlay { shutterBlink }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Viewfinder")
        .accessibilityValue(statusText.map { Text($0) } ?? Text(model.isLowLight ? "Low light" : ""))
        .accessibilityActions {
            if model.isDual {
                Button("Move the small picture") { model.moveDualInset(to: model.dualCorner.next) }
            }
        }
    }

    private var statusText: LocalizedStringKey? {
        if model.isInterrupted { "Camera unavailable" }
        else if model.isHoldingStill { "Hold still…" }
        else if model.captureFailed { "Couldn't take the photo. Try again." }
        else if model.dualNotice == .tooWarm { "Back to one camera: the iPhone is warm" }
        else if model.dualNotice == .unavailable { "Both cameras couldn't start" }
        else { nil }
    }

    /// Like the system camera's moon: the shot will take a moment.
    @ViewBuilder
    private var lowLightBadge: some View {
        if model.isLowLight {
            Image(systemName: "moon.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Theme.warm, in: Circle())
                .padding(10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Black for a beat as the sensor fires, like the system camera.
    private var shutterBlink: some View {
        Color.black
            .keyframeAnimator(initialValue: 0.0, trigger: model.shutterCount) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(1, duration: 0.02)
                CubicKeyframe(0, duration: 0.25)
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var focusRing: some View {
        if let focusPoint {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.warm, lineWidth: 1.5)
                .frame(width: 72, height: 72)
                .position(focusPoint)
                .allowsHitTesting(false)
                .transition(.opacity)
                .task(id: focusPoint) {
                    try? await Task.sleep(for: .seconds(1.2))
                    withAnimation { self.focusPoint = nil }
                }
        }
    }

    @ViewBuilder
    private var countdownOverlay: some View {
        if let countdown = model.countdown {
            Text(countdown, format: .number)
                .font(Theme.rounded(96, .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12)
                .contentTransition(.numericText(countsDown: true))
                .animation(.smooth, value: countdown)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let text = statusText {
            Text(text)
                .font(Theme.rounded(14, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 14)
        }
    }

    private var shutterRow: some View {
        HStack {
            Color.clear.frame(width: 52, height: 52)
            Spacer()
            shutterButton
            Spacer()
            iconButton("arrow.triangle.2.circlepath", label: model.isDual ? "Swap cameras" : "Switch camera",
                       size: 52) {
                model.flip()
            }
            .disabled(model.countdown != nil || model.isCapturing || model.state != .running)
        }
        .padding(.horizontal, 32)
    }

    private var shutterButton: some View {
        Button { model.shutter() } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                if model.countdown != nil {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.accent)
                        .frame(width: 28, height: 28)
                } else {
                    Circle().fill(.white).padding(8)
                        .opacity(model.isCapturing ? 0.5 : 1)
                    if model.isCapturing {
                        ProgressView().tint(.black)
                    }
                }
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.countdown == nil && !model.canShoot)
        .accessibilityLabel(model.countdown == nil ? "Take photo" : "Cancel timer")
        .accessibilityIdentifier("camera.shutter")
    }

    // MARK: - Pieces

    private var flashSymbol: String {
        switch model.flash {
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }

    private var flashValue: String {
        switch model.flash {
        case .auto: String(localized: "Auto")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        }
    }

    private var timerValue: String {
        switch model.timer {
        case .off: String(localized: "Off")
        case .three: String(localized: "3 seconds")
        case .ten: String(localized: "10 seconds")
        }
    }

    private func iconButton(_ symbol: String,
                            label: LocalizedStringKey,
                            value: String? = nil,
                            tint: Color = .white,
                            badge: String? = nil,
                            size: CGFloat = 44,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                if let badge {
                    Text(badge).font(Theme.rounded(13, .semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, badge == nil ? 0 : 8)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
    }

    private func notice(_ title: LocalizedStringKey,
                        detail: LocalizedStringKey,
                        opensSettings: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.rounded(20, .semibold))
            Text(detail)
                .font(Theme.rounded(15))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if opensSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
            }
            Button("Close") { dismiss() }
                .font(Theme.rounded(16, .medium))
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

/// The lens buttons, or the front camera's expand button. Its own view: it
/// reads `zoom`, which a pinch changes every frame.
private struct LensRow: View {
    let model: CameraModel

    var body: some View {
        if model.lenses?.selfieNarrowZoom != nil {
            // The system camera's expand button; turning the phone also sets it.
            Button { model.toggleSelfieWidth() } label: {
                Image(systemName: model.isSelfieWide
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.isSelfieWide ? Theme.warm : .white)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wide selfie")
            .accessibilityAddTraits(model.isSelfieWide ? .isSelected : [])
        } else if let lenses = model.lenses, lenses.presets.count > 1 {
            let active = lenses.activePreset(for: model.zoom)
            HStack(spacing: 10) {
                ForEach(lenses.presets, id: \.self) { preset in
                    let isActive = preset == active
                    let shown = isActive ? lenses.displayed(model.zoom) : lenses.displayed(preset)
                    Button { model.selectLens(preset) } label: {
                        Text(CameraLensPlan.label(shown))
                            .font(Theme.rounded(isActive ? 13 : 11, .semibold))
                            .foregroundStyle(isActive ? Theme.warm : .white)
                            .frame(minWidth: 38, minHeight: 38)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom \(CameraLensPlan.label(lenses.displayed(preset)))")
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }
}

/// Debug only: what the camera is really running, to compare with the system camera.
private struct DebugFormatLabel: View {
    let model: CameraModel

    var body: some View {
        #if DEBUG
        Text(verbatim: "\(model.formatSummary) · zoom \(String(format: "%.2f", model.zoom))"
             + " · \(model.tilt)")
            .font(.caption2.monospaced())
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.5))
            .padding(.top, 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }
}

/// The live preview, with the gestures and hardware shutter that need UIKit.
private struct CameraPreview: UIViewRepresentable {
    let model: CameraModel
    var onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = model.session
        view.previewLayer.videoGravity = .resizeAspectFill
        let coordinator = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator,
                                                         action: #selector(Coordinator.tapped)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: coordinator,
                                                           action: #selector(Coordinator.pinched)))
        // Volume buttons, an AirPods stem press and the Camera Control's click.
        // The system only sends these while the session runs.
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak model] event in
                guard event.phase == .ended else { return }
                MainActor.assumeIsolated { model?.shutter() }
            }
            view.addInteraction(interaction)
            coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.parent = self
        // A disabled interaction gives the buttons back their system behaviour.
        if #available(iOS 17.2, *),
           let interaction = context.coordinator.interaction as? AVCaptureEventInteraction {
            interaction.isEnabled = model.state == .running
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CameraPreview
        /// `AVCaptureEventInteraction` (iOS 17.2).
        var interaction: AnyObject?

        init(parent: CameraPreview) { self.parent = parent }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewView else { return }
            let point = gesture.location(in: view)
            parent.model.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
            parent.onFocus(point)
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed: parent.model.pinchChanged(gesture.scale)
            default: parent.model.pinchEnded()
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The app is portrait-only.
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

/// Both cameras' previews: the main one filling the frame, the other inset
/// where the shot will put it (`DualShotLayout`). Tap the inset to swap, drag
/// it to a corner; elsewhere, tap to focus and pinch to zoom.
private struct DualCameraPreview: UIViewRepresentable {
    let model: CameraModel
    var onFocus: (CGPoint) -> Void

    func makeUIView(context: Context) -> DualPreviewView {
        let view = DualPreviewView()
        if let previews = model.dualPreviews {
            view.attach(back: previews.back, front: previews.front)
        }
        let coordinator = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator,
                                                         action: #selector(Coordinator.tapped)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: coordinator,
                                                           action: #selector(Coordinator.pinched)))
        let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.dragged))
        drag.delegate = coordinator
        view.addGestureRecognizer(drag)
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak model] event in
                guard event.phase == .ended else { return }
                MainActor.assumeIsolated { model?.shutter() }
            }
            view.addInteraction(interaction)
            coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: DualPreviewView, context: Context) {
        context.coordinator.parent = self
        view.mainIsBack = model.dualMainIsBack
        view.corner = model.dualCorner
        if #available(iOS 17.2, *),
           let interaction = context.coordinator.interaction as? AVCaptureEventInteraction {
            interaction.isEnabled = model.state == .running
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DualCameraPreview
        /// `AVCaptureEventInteraction` (iOS 17.2).
        var interaction: AnyObject?

        init(parent: DualCameraPreview) { self.parent = parent }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? DualPreviewView else { return }
            let point = gesture.location(in: view)
            if view.insetFrame.contains(point) {
                parent.model.swapDualCameras()
            } else if let main = view.mainLayer {
                parent.model.focus(at: main.captureDevicePointConverted(fromLayerPoint: point))
                parent.onFocus(point)
            }
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed: parent.model.pinchChanged(gesture.scale)
            default: parent.model.pinchEnded()
            }
        }

        @objc func dragged(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? DualPreviewView else { return }
            switch gesture.state {
            case .began, .changed:
                view.dragOffset = gesture.translation(in: view)
            default:
                let center = CGPoint(x: view.insetFrame.midX, y: view.insetFrame.midY)
                view.dragOffset = .zero
                parent.model.moveDualInset(to: .nearest(to: center, in: view.bounds.size))
            }
        }

        /// Only a drag that starts on the inset moves it.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let view = gesture.view as? DualPreviewView else { return false }
            return view.insetFrame.contains(gesture.location(in: view))
        }
    }

    final class DualPreviewView: UIView {
        private var back: AVCaptureVideoPreviewLayer?
        private var front: AVCaptureVideoPreviewLayer?
        /// Clips the inset's preview to the rounded, bordered frame the shot draws.
        private let insetHost = CALayer()

        var mainIsBack = true { didSet { if mainIsBack != oldValue { restack() } } }
        var corner: DualShotLayout.Corner = .topLeading { didSet { if corner != oldValue { setNeedsLayout() } } }
        var dragOffset: CGPoint = .zero { didSet { setNeedsLayout() } }
        private(set) var insetFrame: CGRect = .zero

        var mainLayer: AVCaptureVideoPreviewLayer? { mainIsBack ? back : front }
        private var insetLayer: AVCaptureVideoPreviewLayer? { mainIsBack ? front : back }

        func attach(back: AVCaptureVideoPreviewLayer, front: AVCaptureVideoPreviewLayer) {
            self.back = back
            self.front = front
            insetHost.masksToBounds = true
            insetHost.borderColor = UIColor.white.cgColor
            restack()
        }

        private func restack() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            [back, front].forEach { $0?.removeFromSuperlayer() }
            insetHost.removeFromSuperlayer()
            if let mainLayer { layer.addSublayer(mainLayer) }
            layer.addSublayer(insetHost)
            if let insetLayer { insetHost.addSublayer(insetLayer) }
            CATransaction.commit()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = DualShotLayout.insetRect(main: bounds.size, inset: CGSize(width: 3, height: 4), corner: corner)
            insetFrame = inset.offsetBy(dx: dragOffset.x, dy: dragOffset.y)
            CATransaction.begin()
            // Snapping to a corner glides; following a finger doesn't lag.
            CATransaction.setDisableActions(dragOffset != .zero)
            CATransaction.setAnimationDuration(0.25)
            mainLayer?.frame = bounds
            insetHost.frame = insetFrame
            insetHost.cornerRadius = DualShotLayout.cornerRadius(inset: insetFrame.size)
            insetHost.borderWidth = DualShotLayout.borderWidth(main: bounds.size)
            insetLayer?.frame = insetHost.bounds
            CATransaction.commit()
        }
    }
}
