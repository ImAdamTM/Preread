import UIKit

enum ShortcutIconGenerator {

    /// Generates a 180x180 Home Screen shortcut icon for a source.
    /// - Parameters:
    ///   - favicon: Optional favicon image for the source.
    ///   - title: Source title (used for letter avatar fallback).
    /// - Returns: A 180x180 UIImage suitable for UIApplicationShortcutIcon.
    static func generate(favicon: UIImage?, title: String) -> UIImage {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { ctx in
            let context = ctx.cgContext

            // Background: #0D0D1A
            UIColor(red: 13/255, green: 13/255, blue: 26/255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Favicon centred ~108pt, rounded 20pt mask
            let faviconSize: CGFloat = 108
            let faviconRect = CGRect(
                x: (size.width - faviconSize) / 2,
                y: (size.height - faviconSize) / 2 - 8, // slight upward offset for badge room
                width: faviconSize,
                height: faviconSize
            )

            let faviconPath = UIBezierPath(roundedRect: faviconRect, cornerRadius: 20)

            if let favicon {
                context.saveGState()
                faviconPath.addClip()
                favicon.draw(in: faviconRect)
                context.restoreGState()
            } else {
                // Letter avatar fallback
                drawLetterAvatar(in: faviconRect, title: title, context: context)
            }

            // Preread badge: bottom-right
            drawBadge(in: context, size: size)
        }
    }

    // MARK: - Letter avatar

    private static func drawLetterAvatar(in rect: CGRect, title: String, context: CGContext) {
        // Gradient background using deterministic colours
        let hash = title.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let gradientPairs: [(UIColor, UIColor)] = [
            (UIColor(red: 91/255, green: 91/255, blue: 222/255, alpha: 1),
             UIColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 1)),
            (UIColor(red: 34/255, green: 211/255, blue: 238/255, alpha: 1),
             UIColor(red: 91/255, green: 91/255, blue: 222/255, alpha: 1)),
            (UIColor(red: 52/255, green: 211/255, blue: 153/255, alpha: 1),
             UIColor(red: 34/255, green: 211/255, blue: 238/255, alpha: 1)),
            (UIColor(red: 232/255, green: 160/255, blue: 32/255, alpha: 1),
             UIColor(red: 248/255, green: 113/255, blue: 113/255, alpha: 1)),
            (UIColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 1),
             UIColor(red: 248/255, green: 113/255, blue: 113/255, alpha: 1)),
            (UIColor(red: 91/255, green: 91/255, blue: 222/255, alpha: 1),
             UIColor(red: 52/255, green: 211/255, blue: 153/255, alpha: 1)),
        ]
        let index = abs(hash) % gradientPairs.count
        let pair = gradientPairs[index]

        // Draw gradient in rounded rect
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 20)
        context.saveGState()
        path.addClip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [pair.0.cgColor, pair.1.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: rect.origin,
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }
        context.restoreGState()

        // Draw letter
        let letter = String(title.prefix(1)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let attrString = NSAttributedString(string: letter, attributes: attrs)
        let letterSize = attrString.size()
        let letterRect = CGRect(
            x: rect.midX - letterSize.width / 2,
            y: rect.midY - letterSize.height / 2,
            width: letterSize.width,
            height: letterSize.height
        )
        attrString.draw(in: letterRect)
    }

    // MARK: - Badge

    private static func drawBadge(in context: CGContext, size: CGSize) {
        let badgeCenter = CGPoint(x: 144, y: 144)
        let badgeRadius: CGFloat = 22 // 44pt circle

        // Outer gradient ring (2pt)
        let ringRect = CGRect(
            x: badgeCenter.x - badgeRadius,
            y: badgeCenter.y - badgeRadius,
            width: badgeRadius * 2,
            height: badgeRadius * 2
        )

        context.saveGState()
        let ringPath = UIBezierPath(ovalIn: ringRect)
        ringPath.addClip()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let accent = UIColor(red: 91/255, green: 91/255, blue: 222/255, alpha: 1)
        let purple = UIColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [accent.cgColor, purple.cgColor] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: ringRect.origin,
                end: CGPoint(x: ringRect.maxX, y: ringRect.maxY),
                options: []
            )
        }
        context.restoreGState()

        // Inner circle: #1E1E2E
        let innerRadius = badgeRadius - 2
        let innerRect = CGRect(
            x: badgeCenter.x - innerRadius,
            y: badgeCenter.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        UIColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 1).setFill()
        context.fillEllipse(in: innerRect)

        // Logomark: SF Symbol rendered as image ~22pt
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        if let symbol = UIImage(systemName: "square.stack.3d.down.right.fill", withConfiguration: config) {
            let symbolSize = symbol.size
            let symbolRect = CGRect(
                x: badgeCenter.x - symbolSize.width / 2,
                y: badgeCenter.y - symbolSize.height / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )

            // Tint the symbol with accent colour
            context.saveGState()
            accent.setFill()
            symbol.withTintColor(accent, renderingMode: .alwaysOriginal).draw(in: symbolRect)
            context.restoreGState()
        }
    }
}
