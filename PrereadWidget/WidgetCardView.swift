import SwiftUI

/// Full-bleed article card matching the main app's carousel card design.
struct WidgetCardView: View {
    let article: WidgetArticle
    let compact: Bool  // true for systemSmall

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                // Background: thumbnail or gradient fallback
                if let thumbnail = article.thumbnailImage {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: avatarGradientColors(for: article.sourceName),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                // Gradient overlay for text legibility
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.3), location: 0),
                        .init(color: .black.opacity(0), location: 0.25),
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.6), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Source name pill
                VStack {
                    if !article.sourceName.isEmpty {
                        HStack {
                            sourcePill
                            Spacer()
                        }
                        .padding(.top, compact ? 8 : 10)
                        .padding(.leading, compact ? 8 : 10)
                    }
                    Spacer()
                }

                // Title + relative time
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preread for you")
                        .font(.system(size: compact ? 9 : 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                    Text(article.title)
                        .font(.system(size: compact ? 14 : 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(compact ? 2 : 3)
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)

                    if let published = article.publishedAt {
                        Text(RelativeTimeFormatter.string(from: published))
                            .font(.system(size: compact ? 10 : 11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.bottom, compact ? 8 : 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(ContainerRelativeShape())
    }

    private var sourcePill: some View {
        HStack(spacing: 4) {
            if let favicon = article.faviconImage {
                Image(uiImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(article.sourceName)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
