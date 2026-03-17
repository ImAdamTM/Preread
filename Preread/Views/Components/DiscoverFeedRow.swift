import SwiftUI

/// A row displaying a discover feed entry with favicon, name, description, and action indicator.
struct DiscoverFeedRow: View {
    let feed: DiscoverFeed
    let isSubscribed: Bool
    var favicon: UIImage?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                faviconView

                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.name)
                        .font(Theme.scaledFont(size: 15, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    if !feed.description.isEmpty {
                        Text(feed.description)
                            .font(Theme.scaledFont(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }

                    // Category pill
                    Text(feed.category)
                        .font(Theme.scaledFont(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceRaised)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 4)

                if isSubscribed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Theme.scaledFont(size: 18))
                        .foregroundStyle(Theme.accentGradient)
                } else {
                    Image(systemName: "plus.circle")
                        .font(Theme.scaledFont(size: 18))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubscribed)
        .opacity(isSubscribed ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var faviconView: some View {
        if let favicon {
            Image(uiImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 34 * 0.24))
        } else {
            let letter = String(feed.name.prefix(1)).uppercased()
            ZStack {
                RoundedRectangle(cornerRadius: 34 * 0.24)
                    .fill(Theme.avatarGradient(for: feed.name))
                    .frame(width: 34, height: 34)
                Text(letter)
                    .font(Theme.scaledFont(size: 34 * 0.45, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}
