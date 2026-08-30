import SwiftUI

/// One place for colour, type and elevation, defined in code (no asset-catalog
/// palette to sync). The palette is the app icon's: rope crimson, fox orange, fish steel blue, icon cream.
enum Theme {
    /// Rope crimson.
    static let accent = Color(red: 0.78, green: 0.27, blue: 0.32)
    /// The crimson lifted for text on dark backgrounds, where the accent reads as disabled.
    static let accentBright = Color(red: 0.95, green: 0.45, blue: 0.50)
    /// Fox orange.
    static let warm = Color(red: 0.92, green: 0.53, blue: 0.25)
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

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.rounded(16, .medium))
            .foregroundStyle(colorScheme == .dark ? Theme.accentBright : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.20 : 0.12),
                        in: Capsule())
    }
}
