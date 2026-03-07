import SwiftUI

struct HomeScreenSection: View {
    let sources: [Source]

    var body: some View {
        if !sources.isEmpty {
            ForEach(sources) { source in
                HomeScreenShortcutRow(source: source)
            }
        } else {
            Text("Add a source to create Home Screen shortcuts.")
                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                .foregroundColor(Theme.textSecondary)
        }
    }
}

// MARK: - Individual shortcut row

private struct HomeScreenShortcutRow: View {
    let source: Source

    @State private var iconImage: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            // Icon preview
            iconPreview
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("\(source.title) — Preread shortcut")

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title)
                    .font(Theme.scaledFont(size: 15, weight: .medium, relativeTo: .subheadline))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Text("Opens this source in Preread")
                    .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                shareToHomeScreen()
            } label: {
                Text("Add")
                    .font(Theme.scaledFont(size: 13, weight: .semibold, relativeTo: .footnote))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Theme.accentGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .task {
            await generateIcon()
        }
    }

    // MARK: - Icon preview

    @ViewBuilder
    private var iconPreview: some View {
        if let iconImage {
            Image(uiImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surfaceRaised)
                .overlay(
                    ProgressView()
                        .tint(Theme.textSecondary)
                )
        }
    }

    // MARK: - Actions

    private func generateIcon() async {
        // Load favicon if available
        var favicon: UIImage?
        if let iconURLString = source.iconURL,
           let url = URL(string: iconURLString) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                favicon = UIImage(data: data)
            } catch {
                // Fallback to letter avatar
            }
        }

        let image = ShortcutIconGenerator.generate(favicon: favicon, title: source.title)
        iconImage = image
    }

    private func shareToHomeScreen() {
        let deepLink = URL(string: "preread://source/\(source.id.uuidString)")!
        let activityVC = UIActivityViewController(
            activityItems: [deepLink],
            applicationActivities: nil
        )

        // Present from the key window's root view controller
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.keyWindow?.rootViewController else { return }

        // Find the topmost presented view controller
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // iPad popover anchor
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        }

        topVC.present(activityVC, animated: true)
    }
}
