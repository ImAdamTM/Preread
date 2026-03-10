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
        VStack(spacing: 0) {
            Spacer()

            heroFavicon
                .padding(.bottom, 10)

            // Source title — its Y position drives the nav bar title fade
            Text(source.title)
                .font(Theme.scaledFont(size: 18, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: UIScreen.main.bounds.width * 0.6)
                .modifier(HeroTitleScrollTracker { minY in
                    onTitlePositionChange?(minY)
                })

            // Last updated label
            lastUpdatedLabel
                .padding(.top, 6)

            Spacer().frame(height: 16)

            heroActionButtons

            Spacer().frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(alignment: .bottom) {
            blurredBackground
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .task(id: source.iconURL) {
            let sourceID = source.id
            let cached = await Task.detached(priority: .utility, operation: {
                await PageCacheService.shared.cachedFavicon(for: sourceID)
            }).value
            iconImage = cached
        }
    }

    // MARK: - Blurred background

    private var blurredBackground: some View {
        ZStack {
            if let iconImage {
                Image(uiImage: iconImage)
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

    @ViewBuilder
    private var heroFavicon: some View {
        if let iconImage {
            Image(uiImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        } else {
            heroLetterAvatar
        }
    }

    private var heroLetterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 52, height: 52)
            Text(letter)
                .font(Theme.scaledFont(size: 24, weight: .bold))
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
        .font(Theme.scaledFont(size: 12, relativeTo: .caption))
        .foregroundColor(Theme.textSecondary)
    }

    // MARK: - Action buttons

    private var heroActionButtons: some View {
        HStack(spacing: 32) {
            circleButton(
                icon: isRefreshing ? nil : "arrow.clockwise",
                label: "Refresh",
                isActive: isRefreshing,
                action: onRefreshTapped
            )
            
            circleButton(
                icon: "slider.horizontal.3",
                label: "Settings",
                action: onSettingsTapped
            )
            .disabled(isRefreshing)
        }
    }

    private func circleButton(
        icon: String?,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(.regularMaterial)
                        .frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isActive ? Theme.accent : .primary)
                    } else if isActive {
                        heroRefreshSpinner
                    }
                }

                Text(label)
                    .font(Theme.scaledFont(size: 11, relativeTo: .caption))
                    .foregroundStyle(isActive ? Theme.accent : Color.primary)
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
