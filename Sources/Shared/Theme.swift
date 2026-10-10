import SwiftUI
import UIKit

/// One place for colour, type and elevation, defined in code (no asset-catalog
/// palette to sync). The palette is the app icon's: rope crimson, fox orange, fish steel blue, icon cream.
enum Theme {
    /// Rope crimson.
    static let accent = Color(red: 0.78, green: 0.27, blue: 0.32)
    /// The crimson lifted for text on dark backgrounds, where the accent reads as disabled.
    static let accentBright = Color(red: 0.95, green: 0.45, blue: 0.50)
    /// Crimson *text*, adaptive. Light: `accent` itself is 4.25:1 on cream and
    /// under 3:1 on its own tint over the backdrop's crimson corner; this shade is
    /// 7.7 on cream, about 6.6 on the send row's tint, 4.47 at the very corner.
    /// Dark: `accentBright`.
    static let accentText = adaptive(light: Color(red: 0.55, green: 0.14, blue: 0.20), dark: accentBright)
    /// Fox orange.
    static let warm = Color(red: 0.92, green: 0.53, blue: 0.25)
    /// The orange for surfaces that carry white text, or for orange text on the
    /// cream ground — `warm` itself sits near 2.3:1 there, short of AA (4.5:1).
    /// 4.9:1 on cream, 5.5:1 under white text.
    static let warmDeep = Color(red: 0.66, green: 0.31, blue: 0.08)
    /// Orange *text*, adaptive: `warmDeep` on light grounds, `warm` on dark,
    /// where the deep shade is under 4:1 on black.
    static let warmText = adaptive(light: warmDeep, dark: warm)
    /// Small informational text — captions, timestamps, "Seen …": 5.5:1 on
    /// cream, where `.secondary` is 3.3:1 and `.tertiary` 1.7:1. Use it, not
    /// `.secondary`, for any small text.
    static let mutedText = adaptive(light: Color(red: 0.42, green: 0.37, blue: 0.36), dark: Color(white: 0.72))

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
    /// Fish steel blue.
    static let mint = Color(red: 0.44, green: 0.66, blue: 0.86)

    /// A quiet full-bleed backdrop. Deliberately low contrast: the status card
    /// should be the only thing competing for attention.
    struct Background: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ZStack {
                // Light mode sits on the icon's cream; dark keeps black.
                (colorScheme == .dark
                    ? Color.black
                    : Color(red: 0.973, green: 0.945, blue: 0.894))
                    .ignoresSafeArea()
                RadialGradient(
                    colors: [accent.opacity(colorScheme == .dark ? 0.34 : 0.40), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 620
                )
                .ignoresSafeArea()
                RadialGradient(
                    colors: [warm.opacity(colorScheme == .dark ? 0.26 : 0.32), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 560
                )
                .ignoresSafeArea()
                RadialGradient(
                    colors: [mint.opacity(colorScheme == .dark ? 0.14 : 0.20), .clear],
                    center: UnitPoint(x: 0.95, y: 0.18),
                    startRadius: 0,
                    endRadius: 320
                )
                .ignoresSafeArea()
            }
        }
    }

    /// Follows Dynamic Type like the system text styles, capped so fixed-height
    /// tiles and single-line rows still fit at the accessibility sizes.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let scaled = min(UIFontMetrics.default.scaledValue(for: size), size * 1.35)
        return .system(size: scaled, weight: weight, design: .rounded)
    }
}

// MARK: - Square

/// A square box whose contents cannot change its size: `Color.clear` (no intrinsic
/// size) decides the frame and the overlaid content fits — a `scaledToFill` child
/// would otherwise drag the frame out. Callers supply their own clip shape.
struct SquareFill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
    }
}

// MARK: - Card

extension Theme {
    /// The card's outline — also for overlays that trace a card.
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 26, style: .continuous) }
}

private struct CardSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                // Material alone almost vanishes against the tinted backdrop,
                // so lift it with an opaque wash first.
                shape.fill(colorScheme == .dark
                           ? Color.white.opacity(0.07)
                           : Color.white.opacity(0.72))
                shape.fill(.ultraThinMaterial)
            }
            .overlay(
                shape.strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.55),
                                   lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 20, y: 10)
    }
}

extension View {
    /// Padded, full width, on the standard card.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity)
            .card(shape: Theme.cardShape)
    }

    /// The card's surface on any shape, sized by the content; clip first when
    /// the content bleeds to the edge.
    func card<S: InsettableShape>(shape: S) -> some View {
        modifier(CardSurface(shape: shape))
    }

    /// The small uppercase label over a value ("SINCE", a name on a card).
    /// `color` stays overridable: section heads over the backdrop's crimson
    /// corner need `.primary` for contrast.
    func eyebrow(size: CGFloat = 11, color: Color = Theme.mutedText) -> some View {
        font(Theme.rounded(size, .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(17, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 1),
                        in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(16, .medium))
            .foregroundStyle(Theme.accentText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.20 : 0.12),
                        in: Capsule())
    }
}

// MARK: - Scroll edge

// The bar backing, drawn by hand on iOS 26: the system's hard edge stops flush
// with the bar's buttons, and its soft one let the title draw over the content
// beneath it. Solid past the top of the content, then a short fade; it fades
// in as the content scrolls under. Overlays only, so nothing resizes a scroll
// view (invariant 21).
extension View {
    /// On the scroll view.
    @ViewBuilder
    func topBarBacking() -> some View {
        if #available(iOS 26, *) {
            modifier(TopBarBacking())
        } else {
            self
        }
    }

    /// On a stack with a header pinned above its scroll view: the backing then
    /// reaches up over the header, which needs `.zIndex(1)` to stay above it.
    func topBarBackingCeiling() -> some View {
        modifier(TopBarBackingCeiling())
    }
}

private struct TopBarCeilingKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    /// The global y of the top of the stack's screen area, bar included.
    var topBarCeiling: CGFloat? {
        get { self[TopBarCeilingKey.self] }
        set { self[TopBarCeilingKey.self] = newValue }
    }
}

private struct TopBarBackingCeiling: ViewModifier {
    @State private var ceiling: CGFloat?

    func body(content: Content) -> some View {
        content
            .environment(\.topBarCeiling, ceiling)
            .background {
                Color.clear
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { ceiling = $0 }
                    .ignoresSafeArea(edges: .top)
            }
    }
}

@available(iOS 26, *)
private struct TopBarBacking: ViewModifier {
    /// Solid this far past the content's top, so nothing sits on the cut; then the fade.
    private static let margin: CGFloat = 8
    private static let fade: CGFloat = 20
    /// Scroll distance over which the backing fades in.
    private static let reveal: CGFloat = 40

    private struct Scroll: Equatable {
        /// What the scroll view insets for a bar it runs under.
        var inset: CGFloat = 0
        /// 0 at rest, 1 once content is `reveal` under; clamped, so a longer scroll stops updating it.
        var opacity: CGFloat = 0
    }
    @State private var scroll = Scroll()
    @State private var minY: CGFloat = 0
    @Environment(\.topBarCeiling) private var ceiling

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Scroll.self) {
                Scroll(inset: $0.contentInsets.top,
                       opacity: min(max(($0.contentOffset.y + $0.contentInsets.top) / Self.reveal, 0), 1))
            } action: { _, now in
                scroll = now
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { minY = $0 }
            .overlay(alignment: .top) {
                // Without a ceiling the scroll view already runs under the bar.
                let above = ceiling.map { max(minY - $0, 0) } ?? 0
                let solid = above + scroll.inset + Self.margin
                let total = solid + Self.fade
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: total)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: solid / total),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .offset(y: -above)
                    .opacity(scroll.opacity)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
