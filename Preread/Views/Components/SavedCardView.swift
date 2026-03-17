import SwiftUI

struct SavedCardView: View {
    let articleCount: Int
    let unreadCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Bookmark icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [Theme.teal, Theme.teal.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                    Image(systemName: "bookmark.fill")
                        .font(Theme.scaledFont(size: 18, weight: .medium))
                        .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved")
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    Text("\(articleCount) article\(articleCount == 1 ? "" : "s")")
                        .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer(minLength: 4)

                // Unread pill
                Text("\(unreadCount)")
                    .font(Theme.scaledFont(size: 11, weight: .semibold, relativeTo: .caption2))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(unreadCount > 0 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textSecondary.opacity(0.4)))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .frame(height: 88)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Saved, \(articleCount) article\(articleCount == 1 ? "" : "s")\(unreadCount > 0 ? ", \(unreadCount) unread" : "")")
        .accessibilityAddTraits(.isButton)
        .padding(.horizontal, 16)
    }
}
