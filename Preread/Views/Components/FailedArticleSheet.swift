import SwiftUI
import GRDB

struct FailedArticleSheet: View {
    let article: Article
    let onRetry: () -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    private var is404: Bool {
        article.lastHTTPStatus == 404
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    Spacer().frame(height: 24)

                    if is404 {
                        notFoundContent
                    } else {
                        genericContent
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .presentationDetents([.fraction(0.45)])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Generic failure

    private var genericContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.warning)

            Text("Couldn't save this article")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("Preread tried to fetch this page but something went wrong.")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                onRetry()
                dismiss()
            } label: {
                Text("Try again")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Show details disclosure
            DisclosureGroup("Show details", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("URL", value: article.articleURL)
                    if let status = article.lastHTTPStatus {
                        detailRow("HTTP Status", value: "\(status)")
                    }
                    detailRow("Status", value: article.fetchStatus.rawValue)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 14))
            .foregroundColor(Theme.textSecondary)
        }
    }

    // MARK: - 404 content

    private var notFoundContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.danger)
                .symbolRenderingMode(.palette)

            Text("This page is gone")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("The link in this feed no longer exists...")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(role: .destructive) {
                onRemove()
                dismiss()
            } label: {
                Text("Remove from list")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                dismiss()
            } label: {
                Text("Keep it anyway")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.teal)
            }
        }
    }

    // MARK: - Detail row

    private func detailRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
        }
    }
}
