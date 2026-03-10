import SwiftUI
import UIKit

struct Theme {
    // MARK: - Accent colours (P3 via Asset Catalog, sRGB fallback)

    static let accent = Color("PrereadAccent")
    static let purple = Color("PrereadPurple")
    static let teal = Color("PrereadTeal")
    static let success = Color("PrereadSuccess")

    // MARK: - Neutral colours (adaptive light/dark)

    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .black
            : .white
    })

    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 17/255, green: 17/255, blue: 24/255, alpha: 1)     // #111118
            : UIColor(red: 242/255, green: 242/255, blue: 247/255, alpha: 1)  // #F2F2F7
    })

    static let surfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 28/255, green: 28/255, blue: 40/255, alpha: 1)     // #1C1C28
            : UIColor(red: 232/255, green: 232/255, blue: 237/255, alpha: 1)  // #E8E8ED
    })

    static let textPrimary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 240/255, green: 240/255, blue: 255/255, alpha: 1)  // #F0F0FF
            : UIColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)     // #1A1A1A
    })

    static let textSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 136/255, green: 136/255, blue: 153/255, alpha: 1)  // #888899
            : UIColor(red: 107/255, green: 107/255, blue: 128/255, alpha: 1)  // #6B6B80
    })

    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 232/255, green: 160/255, blue: 32/255, alpha: 1)   // #E8A020
            : UIColor(red: 204/255, green: 136/255, blue: 0/255, alpha: 1)    // #CC8800
    })

    static let danger = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 248/255, green: 113/255, blue: 113/255, alpha: 1)  // #F87171
            : UIColor(red: 220/255, green: 38/255, blue: 38/255, alpha: 1)    // #DC2626
    })

    // MARK: - Borders (adaptive)

    static let border = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.07)
    })

    static let borderProminent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.22)
            : UIColor.black.withAlphaComponent(0.2)
    })

    // MARK: - Gradients

    static let accentGradient = LinearGradient(
        colors: [Color("PrereadAccent"), Color("PrereadPurple")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Avatar gradients

    /// Six deterministic gradient pairs for letter-avatars and storage bar.
    static let avatarGradients: [(Color, Color)] = [
        (Color(hex: "6B6BF0"), Color(hex: "A855F7")),
        (Color(hex: "22D3EE"), Color(hex: "6B6BF0")),
        (Color(hex: "34D399"), Color(hex: "22D3EE")),
        (Color(hex: "E8A020"), Color(hex: "F87171")),
        (Color(hex: "A855F7"), Color(hex: "F87171")),
        (Color(hex: "5B5BDE"), Color(hex: "34D399")),
    ]

    /// Returns the raw color pair for a given source title.
    static func avatarGradientColors(for title: String) -> (Color, Color) {
        let hash = title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % avatarGradients.count
        return avatarGradients[index]
    }

    /// Returns a consistent gradient for a given source title.
    static func avatarGradient(for title: String) -> LinearGradient {
        // Use a stable hash so the same title always picks the same pair.
        // String.hashValue is randomised per launch; use a deterministic hash.
        let hash = title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let index = abs(hash) % avatarGradients.count
        let pair = avatarGradients[index]
        return LinearGradient(
            colors: [pair.0, pair.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Reduce Motion

    /// Whether the user has enabled Reduce Motion in system settings.
    static var reduceMotion: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// A spring animation that falls back to a linear 0.2s fade when Reduce Motion is on.
    static func gentleAnimation(response: Double = 0.35, dampingFraction: Double = 0.8) -> Animation {
        reduceMotion
            ? .linear(duration: 0.2)
            : .spring(response: response, dampingFraction: dampingFraction)
    }

    // MARK: - Dynamic Type scaled font

    /// The custom font family name. Change this to swap the app-wide typeface.
    private static let fontFamily = "Inter Tight"

    /// Returns a SwiftUI Font using Inter Tight that scales with Dynamic Type settings.
    /// Falls back to the system font if the custom font isn't available.
    static func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default, relativeTo style: Font.TextStyle = .body) -> Font {
        let uiWeight: UIFont.Weight = switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }

        let textStyle = style.uiTextStyle
        let metrics = UIFontMetrics(forTextStyle: textStyle)

        // Try custom font via descriptor with weight trait
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: fontFamily,
            .traits: [UIFontDescriptor.TraitKey.weight: uiWeight]
        ])
        let uiFont = UIFont(descriptor: descriptor, size: size)

        // Verify we actually got Inter Tight, not a fallback
        if uiFont.familyName == "Inter Tight" {
            let scaledSize = metrics.scaledValue(for: size)
            return Font.custom(uiFont.fontName, size: scaledSize, relativeTo: style)
        }

        // Fallback to system font
        let scaledSize = metrics.scaledValue(for: size)
        return .system(size: scaledSize, weight: weight, design: design)
    }
}

extension Font.TextStyle {
    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
}
