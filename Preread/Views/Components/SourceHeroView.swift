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
    let onSettingsTapped: () -> Void
    let onRefreshTapped: () -> Void
    var onTitlePositionChange: ((CGFloat) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            heroFavicon
                .padding(.bottom, 10)

            // Source title — its Y position drives the nav bar title fade
            Text(source.title)
                .font(Theme.scaledFont(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .modifier(HeroTitleScrollTracker { minY in
                    onTitlePositionChange?(minY)
                })

            Spacer().frame(height: 20)

            heroActionButtons

            Spacer().frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(alignment: .bottom) {
            blurredBackground
                .frame(height: 280)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Blurred background

    private var blurredBackground: some View {
        ZStack {
            if let iconURL = source.iconURL, let url = URL(string: iconURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 40)
                            .clipped()
                    default:
                        gradientFallbackBackground
                    }
                }
            } else {
                gradientFallbackBackground
            }
        }
        .clipped()
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

    private var gradientFallbackBackground: some View {
        Rectangle()
            .fill(Theme.avatarGradient(for: source.title))
            .blur(radius: 30)
    }

    // MARK: - Hero favicon (large)

    @ViewBuilder
    private var heroFavicon: some View {
        if let iconURL = source.iconURL, let url = URL(string: iconURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                default:
                    heroLetterAvatar
                }
            }
            .frame(width: 52, height: 52)
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

    // MARK: - Action buttons

    private var heroActionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onSettingsTapped) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                    Text("Settings")
                        .font(Theme.scaledFont(size: 13, weight: .medium, relativeTo: .footnote))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.surfaceRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }

            Button(action: onRefreshTapped) {
                HStack(spacing: 6) {
                    heroRefreshIcon
                    Text("Refresh")
                        .font(Theme.scaledFont(size: 13, weight: .medium, relativeTo: .footnote))
                }
                .foregroundColor(isRefreshing ? Theme.teal : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.surfaceRaised)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(isRefreshing ? Theme.teal.opacity(0.3) : Theme.border, lineWidth: 1)
                )
            }
            .disabled(isRefreshing)
        }
    }

    @ViewBuilder
    private var heroRefreshIcon: some View {
        if isRefreshing {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
                ZStack {
                    Circle()
                        .stroke(Theme.borderProminent, lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(
                                colors: [Theme.teal, Theme.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(angle))
                }
                .frame(width: 14, height: 14)
            }
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
        }
    }
}
