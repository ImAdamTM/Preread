import SwiftUI
import GRDB

struct SourceCardView: View {
    let source: Source
    let articleCount: Int
    let refreshState: SourceRefreshState
    let onTap: () -> Void
    let onRefresh: () -> Void
    let onEditName: () -> Void
    let onRemove: () -> Void

    @State private var isPressed = false
    @State private var showUpdated = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Favicon / letter avatar
                faviconView

                // Text content
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.title)
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    secondaryLine
                }

                Spacer(minLength: 4)

                // Right side: count pill + cache ring
                HStack(spacing: 8) {
                    if articleCount > 0 {
                        countPill
                    }
                    cacheRing
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 88)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .scaleEffect(isPressed && !Theme.reduceMotion ? 0.97 : 1.0)
        .animation(Theme.gentleAnimation(response: 0.28, dampingFraction: 0.75), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !Theme.reduceMotion { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .contextMenu {
            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Button {
                onEditName()
            } label: {
                Label("Edit name", systemImage: "pencil")
            }

            Button {
                addToShortcuts()
            } label: {
                Label("Add to Shortcuts", systemImage: "square.on.square")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Remove \(source.title)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove source and articles", role: .destructive) {
                onRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all saved articles from this source.")
        }
        .onChange(of: refreshState) { oldValue, newValue in
            if oldValue == .refreshing && newValue == .completed {
                showUpdated = true
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    showUpdated = false
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Favicon

    @ViewBuilder
    private var faviconView: some View {
        if let iconURL = source.iconURL, let url = URL(string: iconURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                default:
                    letterAvatar
                }
            }
            .frame(width: 40, height: 40)
        } else {
            letterAvatar
        }
    }

    private var letterAvatar: some View {
        let letter = String(source.title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.avatarGradient(for: source.title))
                .frame(width: 40, height: 40)
            Text(letter)
                .font(Theme.scaledFont(size: 18, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Secondary line

    @ViewBuilder
    private var secondaryLine: some View {
        switch refreshState {
        case .refreshing:
            HStack(spacing: 4) {
                Text("Refreshing...")
                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                    .foregroundColor(Theme.accent)
            }

        case .failed:
            Text("Couldn't refresh · Tap to try again")
                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                .foregroundColor(Theme.danger)

        case .completed where showUpdated:
            Text("Updated just now")
                .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                .foregroundColor(Theme.success)

        default:
            // idle or completed (after fade)
            HStack(spacing: 0) {
                Text("\(articleCount) article\(articleCount == 1 ? "" : "s")")
                    .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                    .foregroundColor(Theme.textSecondary)

                if let lastFetched = source.lastFetchedAt {
                    Text(" · ")
                        .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                        .foregroundColor(Theme.textSecondary)
                    Text(RelativeTimeFormatter.string(from: lastFetched))
                        .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: - Count pill

    private var countPill: some View {
        Text("\(articleCount)")
            .font(Theme.scaledFont(size: 11, weight: .semibold, relativeTo: .caption2))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accentGradient)
            .clipShape(Capsule())
    }

    // MARK: - Cache ring / refresh icon

    private var cacheRing: some View {
        let isRefreshing = refreshState == .refreshing
        return ZStack {
            // Refresh icon — visible when idle
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .opacity(isRefreshing ? 0 : 1)
                .scaleEffect(isRefreshing ? 0.5 : 1)

            // Spinning ring — visible when refreshing
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRefreshing)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
                ZStack {
                    Circle()
                        .stroke(Theme.borderProminent, lineWidth: 2.5)
                        .frame(width: 28, height: 28)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(
                                colors: [Theme.accent.opacity(0.6), Theme.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(angle))
                }
            }
            .opacity(isRefreshing ? 1 : 0)
            .scaleEffect(isRefreshing ? 1 : 0.5)
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
    }

    // MARK: - Shortcuts

    private func addToShortcuts() {
        if let url = URL(string: "shortcuts://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Accessibility

    private var cardAccessibilityLabel: String {
        var parts: [String] = [source.title]

        parts.append("\(articleCount) article\(articleCount == 1 ? "" : "s")")

        switch refreshState {
        case .refreshing: parts.append("Refreshing")
        case .failed: parts.append("Refresh failed")
        case .completed: parts.append("Updated")
        case .idle: break
        }

        if let lastFetched = source.lastFetchedAt {
            parts.append("last fetched \(RelativeTimeFormatter.string(from: lastFetched))")
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Card border

    @ViewBuilder
    private var cardBorder: some View {
        if refreshState == .refreshing {
            // Active card: gradient border + outer glow
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.accentGradient, lineWidth: 2)
                .shadow(color: Theme.accent.opacity(0.15), radius: 8)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}
