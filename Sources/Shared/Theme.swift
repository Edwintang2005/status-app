import SwiftUI

/// One place for colour, type and elevation, so nothing in the app has to
/// invent its own look. Everything is defined in code and derived from a
/// single accent hue — there is no palette to keep in sync in the asset catalog.
enum Theme {
    static let accent = Color(red: 0.44, green: 0.38, blue: 0.92)
    static let warm = Color(red: 0.96, green: 0.44, blue: 0.56)
    static let mint = Color(red: 0.30, green: 0.80, blue: 0.70)

    /// A quiet full-bleed backdrop. Deliberately low contrast: the status card
    /// should be the only thing competing for attention.
    struct Background: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            ZStack {
                (colorScheme == .dark ? Color.black : Color(white: 0.94))
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

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Square

/// A square box whose contents cannot change its size.
///
/// `Image.resizable().scaledToFill()` reports the size it needs in order to
/// fill, which for a tall photo is far bigger than the space offered. As a
/// plain child that drags its parent out with it, and a later
/// `.aspectRatio(1, contentMode: .fit)` can't pull it back — the frame is
/// already wrong by the time it applies. Sizing from `Color.clear` (no
/// intrinsic size) and hanging the content in an `overlay` fixes the direction
/// of that negotiation: the box decides, the content fits.
///
/// Callers still supply their own clip shape.
struct SquareFill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { content }
    }
}

// MARK: - Card

private struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 20

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
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
    func card(padding: CGFloat = 20) -> some View {
        modifier(CardModifier(padding: padding))
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
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.20 : 0.12),
                        in: Capsule())
    }
}
