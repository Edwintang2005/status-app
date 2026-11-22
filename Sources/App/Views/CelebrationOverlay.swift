import SwiftUI

/// Where the partner card's emoji is on screen, so a celebration's hero can fly
/// home into it. `PartnerCard` writes it; the overlay reads it once, leaving.
@MainActor @Observable final class CelebrationTarget {
    var frame: CGRect = .zero
}

/// Shown on first open after a celebration status arrives — see
/// `Snapshot.pendingCelebration` and `AppModel.celebrationPlayed()`. One shell
/// for every `CelebrationStyle`, staged in the beats `CelebrationBeats` sets:
/// backdrop, hero (with the haptic as it lands), words, footer.
struct CelebrationOverlay: View {
    let payload: StatusPayload
    let partnerName: String
    let onDismiss: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(CelebrationTarget.self) private var target: CelebrationTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    // The beats, in order.
    @State private var staged = false
    @State private var bloomed = false
    @State private var heroIn = false
    @State private var wordsIn = false
    @State private var footerIn = false
    @State private var breathing = false
    /// The candles are out, or the surprise scratched open.
    @State private var opened = false
    @State private var candles: [CandleState] = [.unlit, .unlit, .unlit]
    @State private var squash = false
    @State private var shine = false
    @State private var heartbeat = 0
    // Each particle layer is inserted when it starts, and counts from then.
    @State private var confetti: [ConfettiPiece] = []
    @State private var hearts: [HeartPiece] = []
    @State private var fireworks: FireworkShow?
    @State private var snow: [SnowFlake] = []
    // Frames in the screen's space: the overlay fills it from the origin.
    @State private var screen: CGSize = .zero
    /// Where the particles come from: the hero, the cake, the card.
    @State private var heroFrame: CGRect = .zero
    /// What the particles keep clear of.
    @State private var wordsFrame: CGRect = .zero
    /// What flies home on leaving.
    @State private var flyFrame: CGRect = .zero
    @State private var leaving = false
    @State private var flying = false
    @State private var flyOffset: CGSize = .zero
    @State private var flyScale: CGFloat = 1
    @State private var confirmingReport = false

    private var style: CelebrationStyle { payload.celebration ?? .confetti }
    /// Birthday and reveal ask for a gesture before the words.
    private var interactive: Bool { style == .birthday || style == .reveal }
    private var isNight: Bool { style == .fireworks || style == .snow }

    /// Their status as it may be shown; this fills the screen (invariant 20).
    private var shown: ModeratedStatus {
        payload.moderation(reportedAt: model.hiddenPartnerStatusAt, filterEnabled: model.contentFilterEnabled)
    }

    /// Their words, or the style's own line if they sent none — or the words
    /// can't be shown.
    private var headline: String {
        let message = shown.message
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !message.isPlaceholder else { return style.defaultHeadline }
        return trimmed
    }

    /// The quieter lines. Not `Theme.mutedText`: over this backdrop's pink centre
    /// that measured 4.3:1, short of AA; in either appearance this is well clear.
    private static let quietText = Color.primary.opacity(0.72)

    private var accessibilityText: String {
        switch style {
        case .birthday where !opened:
            String(localized: "\(partnerName) sent you a birthday cake. Make a wish, then blow out the candles.")
        case .reveal where !opened:
            String(localized: "\(partnerName) has a surprise for you.")
        default:
            String(localized: "\(headline). From \(partnerName).")
        }
    }

    var body: some View {
        ZStack {
            backdrop
            particles
                .allowsHitTesting(false)
                .opacity(leaving ? 0 : 1)
            content
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        // Night skies carry white text whatever the phone's appearance — and
        // drop the status bar, whose dark clock would vanish into them.
        .environment(\.colorScheme, isNight ? .dark : colorScheme)
        .statusBarHidden(isNight)
        // Whole screen dismisses once there's nothing left to do on it;
        // nothing underneath is tappable by accident.
        .contentShape(Rectangle())
        .onTapGesture { if wordsIn { finish() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isModal)
        .accessibilityActions {
            if interactive, !opened {
                Button(style == .birthday ? "Blow out the candles" : "Reveal", action: blowOutAll)
            }
        }
        .accessibilityAction(named: "Dismiss") { finish() }
        .accessibilityAction(named: "Send a heart back") {
            Task {
                await model.sendNudge()
                finish()
            }
        }
        // Guideline 1.2: their words fill the screen, so they can be reported from here.
        .accessibilityAction(named: "Report…") { confirmingReport = true }
        .reportStatusDialog(isPresented: $confirmingReport) {
            model.reportPartnerStatus()
            finish(flies: false)
        }
        // Staged once the launch or resume zoom is over, not under it.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active, !staged else { return }
            try? await Task.sleep(for: .seconds(CelebrationBeats.stageDelay))
            if !Task.isCancelled { staged = true }
        }
        .task(id: staged) {
            if staged { await play() }
        }
        .task(id: fireworks == nil) {
            guard let fireworks else { return }
            await tickFireworks(fireworks)
        }
    }

    // MARK: - Layers

    /// Material, not opaque: the home screen faintly showing through makes this
    /// read as landing *on* the app, not another screen. Night styles darken it.
    private var backdrop: some View {
        let glows = style.glows
        let glow = bloomed ? (breathing ? 1 - CelebrationBeats.breathDepth : 1) : 0
        return ZStack {
            Rectangle().fill(.regularMaterial)
            if isNight {
                LinearGradient(colors: style == .snow
                                   ? [Color(red: 0.06, green: 0.12, blue: 0.26), Color(red: 0.16, green: 0.22, blue: 0.38)]
                                   : [Color(red: 0.04, green: 0.04, blue: 0.13), Color(red: 0.14, green: 0.07, blue: 0.24)],
                               startPoint: .top, endPoint: .bottom)
                    .opacity(0.9)
            }
            RadialGradient(colors: [glows.0.opacity(0.55), .clear],
                           center: .center, startRadius: 0, endRadius: 420)
                .scaleEffect(bloomed || reduceMotion ? 1 : 0.2)
                .opacity(glow)
            RadialGradient(colors: [glows.1.opacity(0.40), .clear],
                           center: UnitPoint(x: 0.5, y: 0.72), startRadius: 0, endRadius: 360)
                .scaleEffect(bloomed || reduceMotion ? 1 : 0.2)
                .opacity(glow)
        }
        .opacity(leaving ? 0 : 1)
    }

    @ViewBuilder
    private var particles: some View {
        if reduceMotion {
            // Still pieces instead of none: it still reads as a celebration.
            if bloomed, !interactive || opened {
                StillScatter(style: style, zone: wordsFrame).transition(.opacity)
            }
        } else {
            ZStack {
                if let fireworks { FireworksLayer(show: fireworks, zone: wordsFrame) }
                if !snow.isEmpty { SnowLayer(flakes: snow, zone: wordsFrame) }
                if !hearts.isEmpty { HeartBloomLayer(pieces: hearts, zone: wordsFrame) }
                if !confetti.isEmpty {
                    if style == .trophy {
                        ConfettiLayer(pieces: confetti, palette: CelebrationPalette.trophy,
                                      glyphs: CelebrationPalette.trophyGlyphs,
                                      edge: CelebrationPalette.amberEdge, zone: wordsFrame)
                    } else {
                        ConfettiLayer(pieces: confetti, zone: wordsFrame)
                    }
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch style {
            case .birthday:
                birthday
            case .reveal:
                revealCard
            default:
                hero.padding(.bottom, 26)
                words
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 64)
    }

    /// The emoji (or the fireworks' drawn burst) that lands, and flies home.
    private var hero: some View {
        Group {
            if style == .fireworks {
                BurstMark()
            } else {
                Text(shown.emoji).font(.system(size: 84))
            }
        }
        .keyframeAnimator(initialValue: 1.0, trigger: heartbeat) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            // Lub, dub.
            KeyframeTrack {
                CubicKeyframe(1.18, duration: 0.12)
                CubicKeyframe(1.0, duration: 0.14)
                CubicKeyframe(1.1, duration: 0.12)
                CubicKeyframe(1.0, duration: 0.22)
            }
        }
        .overlay { if style == .trophy { trophyShine } }
        .scaleEffect(x: squash ? 1.12 : 1, y: squash ? 0.88 : 1, anchor: .bottom)
        .modifier(HeroEntrance(style: style, arrived: heroIn, staged: staged, still: reduceMotion,
                               fallFrom: screen.height))
        .modifier(FlightHome(offset: flyOffset, scale: flyScale, fades: leaving && !flying))
        // Outermost: where it rests, not every frame of how it moves.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            heroFrame = $0
            flyFrame = $0
        }
    }

    /// One band of light across the trophy, a beat after it lands.
    private var trophyShine: some View {
        ZStack {
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 30, height: 140)
                .rotationEffect(.degrees(20))
                .offset(x: shine ? 70 : -70)
                .opacity(shine ? 1 : 0.0001)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mask { Text(shown.emoji).font(.system(size: 84)) }
        .allowsHitTesting(false)
    }

    private var words: some View {
        VStack(spacing: 18) {
            // Sized to fit rather than truncated — anniversary messages run long.
            Text(headline)
                .font(Theme.rounded(style == .birthday ? 38 : 44, .bold))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.45)
                .foregroundStyle(.primary)
                .shadow(color: style.glows.0.opacity(0.35), radius: 18)
                .padding(.horizontal, 34)
            from
        }
        .modifier(Reserved(shown: wordsIn && !leaving, transition: rise(by: 8, blur: 6)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { wordsFrame = $0 }
    }

    /// Words rise a few points into place, sharpening as they come; Reduce Motion fades.
    private func rise(by distance: CGFloat, blur: CGFloat) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .modifier(active: Rising(offset: distance, blur: blur, opacity: 0),
                                                identity: Rising(offset: 0, blur: 0, opacity: 1)),
                           removal: .opacity)
    }

    private var from: some View {
        Text("from \(partnerName)")
            .font(Theme.rounded(17, .medium))
            .foregroundStyle(Self.quietText)
    }

    /// The prompt and the words share one slot, so the cake never moves.
    private var birthday: some View {
        VStack(spacing: 28) {
            BirthdayCake(candles: candles, flickers: !reduceMotion, onBlow: blow)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { heroFrame = $0 }
                .scaleEffect(heroIn || reduceMotion ? 1 : 0.85)
                .opacity(heroIn && !leaving ? 1 : 0)
            ZStack {
                prompt("Make a wish, then tap the candles to blow them out")
                    .modifier(Reserved(shown: heroIn && !opened))
                words
            }
        }
    }

    /// Their news under foil until scratched (or "Just show me"). The title
    /// and the emoji share a slot, so the card never moves under the finger.
    private var revealCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Text("Guess what…")
                    .font(Theme.rounded(34, .bold))
                    .multilineTextAlignment(.center)
                    .modifier(Reserved(shown: !opened && !leaving))
                Text(shown.emoji)
                    .font(.system(size: 64))
                    .scaleEffect(opened || reduceMotion ? 1 : 0.4)
                    .opacity(opened ? 1 : 0)
                    .modifier(FlightHome(offset: flyOffset, scale: flyScale, fades: leaving && !flying))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flyFrame = $0 }
            }
            ScratchCard(text: headline, opened: opened, onOpen: open)
                .frame(maxWidth: 340)
                .frame(height: 190)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    heroFrame = $0
                    wordsFrame = $0
                }
                .padding(.horizontal, 28)
                .opacity(leaving ? 0 : 1)
                // Its falling foil passes over the lines below.
                .zIndex(1)
            ZStack(alignment: .top) {
                VStack(spacing: 16) {
                    prompt("Scratch the card to see what \(partnerName) has to tell you")
                    Button("Just show me") { open() }
                        .font(Theme.rounded(15, .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .modifier(Reserved(shown: !opened))
                from
                    .modifier(Reserved(shown: wordsIn && !leaving, transition: rise(by: 8, blur: 6)))
            }
        }
        .modifier(Reserved(shown: heroIn, transition: reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity)))
    }

    private func prompt(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Theme.rounded(16, .medium))
            .foregroundStyle(Self.quietText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var footer: some View {
        // Both states share one slot, so nothing above shifts when it changes.
        ZStack {
            VStack(spacing: 12) {
                // The natural answer to their moment: the heart, then out.
                HeartBackButton(bursts: false, afterSending: { finish() })
                    .padding(.horizontal, 44)
                Text("Tap anywhere to close")
                    .font(Theme.rounded(13))
                    .foregroundStyle(Self.quietText)
            }
            .modifier(Reserved(shown: footerIn && !leaving, transition: rise(by: 6, blur: 0)))
            if interactive {
                Button("Not now") { finish(flies: false) }
                    .font(Theme.rounded(15, .medium))
                    .foregroundStyle(Self.quietText)
                    .frame(minWidth: 44, minHeight: 44)
                    .modifier(Reserved(shown: heroIn && !opened && !leaving))
            }
        }

        Button("Report...") { confirmingReport = true }
            .font(Theme.rounded(13, .medium))
            .foregroundStyle(Self.quietText)
            .frame(minWidth: 44, minHeight: 44)
            .modifier(Reserved(shown: bloomed && !leaving))
    }

    // MARK: - The beats

    /// False once the overlay is going: the rest of the sequence is skipped.
    private func pause(_ seconds: Double) async -> Bool {
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
        return !Task.isCancelled && !leaving
    }

    private func play() async {
        withAnimation(reduceMotion ? .easeIn(duration: 0.4) : .smooth(duration: 0.5)) { bloomed = true }
        if reduceMotion { return await playStill() }

        // Skies fill from the start: rockets climb, snow is already falling.
        if style == .fireworks {
            var rng = SystemRandomNumberGenerator()
            fireworks = FireworkShow.plan(palette: CelebrationPalette.fireworks.count, using: &rng)
        }
        if style == .snow { snow = SnowFlake.fall() }

        guard await pause(CelebrationBeats.heroStarts) else { return }
        withAnimation(style == .trophy ? .easeIn(duration: CelebrationBeats.travel(.trophy)) : Theme.Motion.pop) {
            heroIn = true
        }
        guard await pause(CelebrationBeats.travel(style)) else { return }
        await land()
    }

    /// The hero has arrived: the haptic, the particles, then the words.
    private func land() async {
        var rng = SystemRandomNumberGenerator()
        switch style {
        case .confetti:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            confetti = ConfettiPiece.cannons(in: screen, palette: CelebrationPalette.confetti.count,
                                             glyphs: CelebrationPalette.confettiGlyphs.count, using: &rng)
        case .trophy:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(.easeOut(duration: 0.08)) { squash = true }
            confetti = ConfettiPiece.burst(from: CGPoint(x: heroFrame.midX, y: heroFrame.maxY - 8), in: screen,
                                           palette: CelebrationPalette.trophy.count,
                                           glyphs: CelebrationPalette.trophyGlyphs.count, using: &rng)
            guard await pause(0.08) else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.45)) { squash = false }
        case .hearts:
            await beatTwice()
        case .fireworks:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .snow:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .birthday:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            await lightCandles()
            return
        case .reveal:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        await revealWords(after: CelebrationBeats.words(afterImpact: 0))
        if style == .trophy, await pause(0.45) {
            withAnimation(.easeInOut(duration: 0.7)) { shine = true }
        }
        await breatheLater()
    }

    /// Two lub-dubs, felt as well as seen; the hearts bloom between them.
    private func beatTwice() async {
        var elapsed = 0.0
        for (index, beat) in CelebrationBeats.heartbeats.enumerated() {
            guard await pause(beat.at - elapsed) else { return }
            elapsed = beat.at
            UIImpactFeedbackGenerator(style: beat.heavy ? .heavy : .light).impactOccurred()
            if beat.heavy { heartbeat += 1 }
            if index == 1 { hearts = HeartPiece.bloom(around: CGPoint(x: heroFrame.midX, y: heroFrame.midY)) }
        }
    }

    private func lightCandles() async {
        for index in candles.indices {
            guard await pause(0.15), !opened else { return }
            if candles[index] == .unlit {
                withAnimation(Theme.Motion.pop) { candles[index] = .lit }
            }
        }
    }

    private func revealWords(after delay: Double) async {
        guard await pause(delay) else { return }
        withAnimation(Theme.Motion.settle) { wordsIn = true }
        guard await pause(CelebrationBeats.footer(afterWords: 0)) else { return }
        withAnimation(Theme.Motion.settle) { footerIn = true }
    }

    /// Once the particles are spent, the glow breathes slowly; nothing else moves.
    private func breatheLater() async {
        guard await pause(CelebrationBeats.particleBudget) else { return }
        withAnimation(.easeInOut(duration: CelebrationBeats.breathPeriod / 2).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    /// Reduce Motion: everything fades in where it rests.
    private func playStill() async {
        withAnimation(.easeIn(duration: 0.4)) {
            heroIn = true
            candles = candles.map { _ in .lit }
        }
        guard !interactive else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeIn(duration: 0.4)) { wordsIn = true }
        guard await pause(0.4) else { return }
        withAnimation(.easeIn(duration: 0.4)) { footerIn = true }
    }

    /// A light tick as each rocket bursts, a few at most.
    private func tickFireworks(_ show: FireworkShow) async {
        let start = Date()
        for at in show.hapticTimes {
            guard await pause(at - Date().timeIntervalSince(start)) else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Opening

    private func blow(_ index: Int, lean: Double) {
        guard candles.indices.contains(index), candles[index] == .lit else { return }
        withAnimation(.easeOut(duration: 0.3)) { candles[index] = .out(lean: lean) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !candles.contains(.lit), !candles.contains(.unlit) {
            Task {
                // A breath for the smoke before the party.
                try? await Task.sleep(for: .seconds(0.6))
                open()
            }
        }
    }

    /// VoiceOver's action: one breath for every candle, or the foil in one go.
    private func blowOutAll() {
        guard style == .birthday else { return open() }
        withAnimation(.easeOut(duration: 0.3)) { candles = candles.map { _ in .out(lean: 1) } }
        open()
    }

    private func open() {
        guard !opened, !leaving else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? .easeIn(duration: 0.3) : Theme.Motion.pop) { opened = true }
        AccessibilityNotification.Announcement(String(localized: "\(headline). From \(partnerName).")).post()
        if !reduceMotion {
            var rng = SystemRandomNumberGenerator()
            confetti = style == .birthday
                ? ConfettiPiece.burst(from: CGPoint(x: heroFrame.midX, y: heroFrame.minY + 60), in: screen,
                                      palette: CelebrationPalette.confetti.count,
                                      glyphs: CelebrationPalette.confettiGlyphs.count, using: &rng)
                : ConfettiPiece.rim(of: heroFrame, in: screen, palette: CelebrationPalette.confetti.count,
                                    glyphs: CelebrationPalette.confettiGlyphs.count, using: &rng)
        }
        Task {
            await revealWords(after: reduceMotion ? 0 : 0.2)
            if !reduceMotion { await breatheLater() }
        }
    }

    /// The hero flies into the partner card's emoji while the rest fades; the
    /// cake, a report and Reduce Motion just fade.
    private func finish(flies: Bool = true) {
        guard !leaving else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        let destination = target?.frame ?? .zero
        let canFly = flies && !reduceMotion && style != .birthday && (style != .reveal || opened)
            && !destination.isEmpty && !flyFrame.isEmpty
        if canFly {
            flying = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                flyOffset = CGSize(width: destination.midX - flyFrame.midX, height: destination.midY - flyFrame.midY)
                flyScale = destination.height / max(flyFrame.height, 1)
            }
        }
        withAnimation(Theme.Motion.exit) { leaving = true }
        Task {
            try? await Task.sleep(for: .seconds(canFly ? 0.5 : 0.22))
            onDismiss()
        }
    }
}

/// The hero's entrance: the trophy falls from above the screen, the rest pop.
/// Under Reduce Motion it only fades.
private struct HeroEntrance: ViewModifier {
    let style: CelebrationStyle
    let arrived: Bool
    let staged: Bool
    let still: Bool
    let fallFrom: CGFloat

    func body(content: Content) -> some View {
        if style == .trophy && !still {
            content
                .offset(y: arrived ? 0 : -max(fallFrom, 600))
                .opacity(staged ? 1 : 0)
        } else {
            content
                .scaleEffect(arrived || still ? 1 : 0.4)
                .rotationEffect(.degrees(arrived || still ? 0 : -18))
                .opacity(arrived ? 1 : 0)
        }
    }
}

/// Carries the hero to the partner card's emoji.
private struct FlightHome: ViewModifier {
    let offset: CGSize
    let scale: CGFloat
    let fades: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .opacity(fades ? 0 : 1)
    }
}

/// Holds its place while hidden, so nothing around it moves when it arrives,
/// and isn't there at all until then: an invisible label is still audited and read.
private struct Reserved: ViewModifier {
    let shown: Bool
    var transition: AnyTransition = .opacity

    func body(content: Content) -> some View {
        ZStack {
            if shown {
                content.transition(transition)
            } else {
                content.hidden()
            }
        }
    }
}

private struct Rising: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: offset).blur(radius: blur).opacity(opacity)
    }
}

private extension CelebrationStyle {
    /// The backdrop's two glows.
    var glows: (Color, Color) {
        switch self {
        case .confetti: (Theme.warm, Theme.accent)
        case .hearts: (Theme.accentBright, Theme.accent)
        case .trophy: (Color(red: 1.0, green: 0.80, blue: 0.35), Theme.warm)
        case .birthday: (Color(red: 1.0, green: 0.70, blue: 0.80), Theme.warm)
        case .reveal: (Theme.mint, Theme.accent)
        case .fireworks: (Color(red: 0.55, green: 0.35, blue: 0.95), Theme.accentBright)
        // Deep blues: a bright glow washed out the muted "from" line.
        case .snow: (Color(red: 0.32, green: 0.48, blue: 0.80), Color(red: 0.22, green: 0.32, blue: 0.58))
        }
    }
}

#if DEBUG
#Preview("Celebrations") {
    TabView {
        ForEach(CelebrationStyle.allCases, id: \.self) { style in
            ZStack {
                Theme.Background()
                CelebrationOverlay(payload: StatusPayload(emoji: "🎉",
                                                          message: style == .reveal ? "we got the flat!" : "",
                                                          displayName: "Sam",
                                                          updatedAt: Date(),
                                                          nudgeCount: 0,
                                                          lastNudgeAt: nil,
                                                          isCelebration: true,
                                                          celebrationStyle: style),
                                   partnerName: "Sam") {}
                    .environment(AppModel.previewModel())
            }
            .tabItem { Text(style.rawValue) }
        }
    }
}
#endif
