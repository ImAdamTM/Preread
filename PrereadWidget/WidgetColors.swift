import SwiftUI

// MARK: - Color hex extension (standalone for widget target)

extension Color {
    init(hex: String) {
        let sanitised = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: sanitised).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Avatar gradient colors

/// Standalone avatar gradient colors for the widget target.
/// Mirrors Theme.avatarGradients from the main app.
func avatarGradientColors(for title: String) -> [Color] {
    let pairs: [(Color, Color)] = [
        (Color(hex: "6B6BF0"), Color(hex: "A855F7")),
        (Color(hex: "22D3EE"), Color(hex: "6B6BF0")),
        (Color(hex: "34D399"), Color(hex: "22D3EE")),
        (Color(hex: "E8A020"), Color(hex: "F87171")),
        (Color(hex: "A855F7"), Color(hex: "F87171")),
        (Color(hex: "5B5BDE"), Color(hex: "34D399")),
    ]
    let hash = title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
    let index = abs(hash) % pairs.count
    return [pairs[index].0, pairs[index].1]
}
