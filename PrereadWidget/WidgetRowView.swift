import SwiftUI

/// Compact article row for the large widget's list section.
struct WidgetRowView: View {
    let article: WidgetArticle

    var body: some View {
        HStack(spacing: 10) {
            // Small thumbnail
            if let thumb = article.thumbnailImage {
                Image(uiImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)

                Text(article.sourceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
