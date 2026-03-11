import SwiftUI

// MARK: - Scroll tracking preference key

/// Callback-based scroll tracking for the hero title position.
/// Rounds to the nearest 2pt to avoid excessive state updates during scroll.
struct HeroTitleScrollTracker: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { geo in
                let raw = geo.frame(in: .global).minY
                return (raw / 2).rounded() * 2
            } action: { newValue in
                onChange(newValue)
            }
    }
}

// MARK: - Source hero view

struct SourceHeroView: View {
    let source: Source
    let isRefreshing: Bool
    let articleCount: Int
    let onSettingsTapped: () -> Void
    let onRefreshTapped: () -> Void
    var onTitlePositionChange: ((CGFloat) -> Void)?

    @State private var iconImage: UIImage?
    @State private var fallbackGradientImage: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: favicon + title + metadata
            HStack(alignment: .top, spacing: 12) {
                heroFavicon

                VStack(alignment: .leading, spacing: -2) {
                    // Source title — its Y position drives the nav bar title fade
                    Text(source.title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .modifier(HeroTitleScrollTracker { minY in
                            onTitlePositionChange?(minY)
                        })

                    lastUpdatedLabel
                }
            }

            Spacer()

            // Right: action buttons
            heroActionButtons
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(alignment: .top) {
            blurredBackground
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .task(id: source.iconURL) {
            let sourceID = source.id
            // Check shared favicon cache first (populated by SourceSectionView)
            if let cached = ThumbnailCache.shared.favicon(for: sourceID) {
                iconImage = cached
                return
            }
            let loaded = await Task.detached(priority: .utility, operation: {
                await PageCacheService.shared.cachedFavicon(for: sourceID)
            }).value
            if let loaded {
                iconImage = loaded
                ThumbnailCache.shared.setFavicon(loaded, for: sourceID)
            }
        }
    }

    // MARK: - Blurred background

    private var blurredBackground: some View {
        ZStack {
            if let favicon = resolvedFavicon {
                Image(uiImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .clipped()
            } else {
                gradientFallbackBackground
            }
        }
        .opacity(0.3)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.4),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var gradientFallbackBackground: some View {
        if let img = fallbackGradientImage {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 40)
                .clipped()
        } else {
            Color.clear
                .task {
                    fallbackGradientImage = Self.makeGradientImage(for: source.title)
                }
        }
    }

    private static func makeGradientImage(for title: String) -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        let colors = Theme.avatarGradientColors(for: title)
        return renderer.image { ctx in
            let cgColors = [UIColor(colors.0).cgColor, UIColor(colors.1).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors as CFArray, locations: [0, 1]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: - Hero favicon (large)

    /// Resolved favicon: prefer @State (async-loaded), then synchronous LRU cache hit.
    private var resolvedFavicon: UIImage? {
        iconImage ?? ThumbnailCache.shared.favicon(for: source.id)
    }

    @ViewBuilder
    private var heroFavicon: some View {
        if let favicon = resolvedFavicon {
            Image(uiImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        } else {
            heroLetterAvatar
        }
    }

    private var heroLetterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 38, height: 38)
            Text(letter)
                .font(Theme.scaledFont(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    // MARK: - Last updated label

    private var lastUpdatedLabel: some View {
        Group {
            if let lastFetched = source.lastFetchedAt {
                Text("\(articleCount) article\(articleCount == 1 ? "" : "s") · Updated \(RelativeTimeFormatter.string(from: lastFetched))")
            } else {
                Text("Not yet synced")
            }
        }
        .font(Theme.scaledFont(size: 13, relativeTo: .caption))
        .foregroundColor(Theme.textPrimary.opacity(0.6))
    }

    // MARK: - Action buttons

    private var heroActionButtons: some View {
        HStack(spacing: 12) {
            circleButton(
                icon: isRefreshing ? nil : "arrow.clockwise",
                isActive: isRefreshing,
                action: onRefreshTapped
            )
            
            circleButton(
                icon: "slider.horizontal.3",
                action: onSettingsTapped
            )
            .disabled(isRefreshing)
        }
    }

    private func circleButton(
        icon: String?,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isActive ? Theme.accent : .primary)
                } else if isActive {
                    heroRefreshSpinner
                }
            }
        }
    }

    private var heroRefreshSpinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
            ZStack {
                Circle()
                    .stroke(Theme.borderProminent, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent.opacity(0.6), Theme.accent],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 18, height: 18)
        }
    }
}
