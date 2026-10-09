import AVFoundation
import AVKit
import SwiftUI

/// The moment camera: timer, flash, lens buttons, tap to focus, pinch to zoom,
/// and the hardware shutters (volume buttons, AirPods, Camera Control).
/// `UIImagePickerController` offered none of the first three. Shows the 4:3
/// frame that's sent.
struct CameraView: View {
    var onCapture: (UIImage) -> Void

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
            model.onCapture = { image in
                onCapture(image)
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
            lensRow
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
        CameraPreview(model: model) { point in
            focusPoint = point
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay { focusRing }
        .overlay { countdownOverlay }
        .overlay(alignment: .bottom) { statusLine }
        .overlay(alignment: .top) { debugFormat }
        .overlay(alignment: .topLeading) { lowLightBadge }
        .overlay { shutterBlink }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Viewfinder")
        .accessibilityValue(statusText.map { Text($0) } ?? Text(model.isLowLight ? "Low light" : ""))
    }

    /// Debug only: what the camera is really running, to compare with the system camera.
    @ViewBuilder
    private var debugFormat: some View {
        #if DEBUG
        Text(verbatim: "\(model.formatSummary) · zoom \(String(format: "%.2f", model.zoom))"
             + (model.isLandscape ? " · sideways" : " · upright"))
            .font(.caption2.monospaced())
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.5))
            .padding(.top, 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }

    private var statusText: LocalizedStringKey? {
        if model.isInterrupted { "Camera unavailable" }
        else if model.isHoldingStill { "Hold still…" }
        else if model.captureFailed { "Couldn't take the photo. Try again." }
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

    @ViewBuilder
    private var lensRow: some View {
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

    private var shutterRow: some View {
        HStack {
            Color.clear.frame(width: 52, height: 52)
            Spacer()
            shutterButton
            Spacer()
            iconButton("arrow.triangle.2.circlepath", label: "Switch camera", size: 52) {
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
