import SwiftUI
import SafariServices
import GRDB

struct ReaderView: View {
    let article: Article
    let namespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var toastManager: ToastManager
    @AppStorage("readerTextSize") private var textSize: Double = 18
    @AppStorage("readerFontFamily") private var fontFamily: String = "system-ui"
    @State private var webViewVisible = false
    @State private var scrollProgress: CGFloat = 0
    @State private var safariURL: URL?
    @State private var showSafari = false
    @State private var showLinkConfirmation = false
    @State private var tappedLinkURL: URL?
    @State private var showTextSize = false
    @State private var showFontPicker = false
    @State private var cachedPage: CachedPage?
    @State private var isLoadingCachedPage = true
    @State private var retryDarkMode = false
    @State private var isRetrying = false

    private var useDarkAppearance: Bool {
        colorScheme == .dark
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoadingCachedPage {
                // Brief loading while DB lookup completes
                EmptyView()
            } else if let cachedPage, FileManager.default.fileExists(atPath: cachedPage.htmlPath) {
                readerContent(cachedPage: cachedPage)
            } else {
                // No cached content available — show fallback
                missingContentView
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .task {
            await loadCachedPage()
            isLoadingCachedPage = false
            await markAsRead()
        }
        .confirmationDialog(
            "Open External Link",
            isPresented: $showLinkConfirmation,
            titleVisibility: .visible,
            presenting: tappedLinkURL
        ) { url in
            Button("Open in Safari") {
                safariURL = url
                showSafari = true
            }
            Button("Copy Link") {
                UIPasteboard.general.url = url
                toastManager.show("Link copied", type: .success, duration: 2)
            }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
        .sheet(isPresented: $showSafari) {
            if let url = safariURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Reader content

    private func readerContent(cachedPage: CachedPage) -> some View {
        let isReaderMode = cachedPage.cacheLevelUsed != .full

        // For full-page caches in dark mode, use the pre-darkened variant if available
        let usePreDarkened: Bool
        let htmlURL: URL
        if useDarkAppearance,
           !isReaderMode,
           let darkPath = cachedPage.darkHtmlPath,
           FileManager.default.fileExists(atPath: darkPath) {
            htmlURL = URL(fileURLWithPath: darkPath)
            usePreDarkened = true
        } else {
            htmlURL = URL(fileURLWithPath: cachedPage.htmlPath)
            usePreDarkened = false
        }
        let articleDir = htmlURL.deletingLastPathComponent()

        return ZStack(alignment: .top) {
            // Progress bar at top
            GeometryReader { geo in
                Theme.accentGradient
                    .frame(width: geo.size.width * scrollProgress, height: 2)
                    .clipShape(Capsule())
                    .shadow(color: Theme.accent.opacity(0.4), radius: 4, y: 1)
            }
            .frame(height: 2)
            .zIndex(2)

            VStack(spacing: 0) {
                // Title bar
                titleBar
                    .zIndex(1)

                // Web view
                CachedWebView(
                    htmlFileURL: htmlURL,
                    articleDirectory: articleDir,
                    isDarkMode: isReaderMode ? false : useDarkAppearance,
                    isReaderMode: isReaderMode,
                    useLightMode: isReaderMode && !useDarkAppearance,
                    skipDarkReader: usePreDarkened,
                    textSize: CGFloat(textSize),
                    fontFamily: fontFamily,
                    retryDarkMode: $retryDarkMode,
                    onScrollDown: { },
                    onScrollUp: { },
                    onLinkTapped: { url in
                        tappedLinkURL = url
                        showLinkConfirmation = true
                    },
                    onDarkReaderReady: { }
                )
                .opacity(webViewVisible ? 1 : 0)
                .animation(.easeIn(duration: 0.2), value: webViewVisible)
            }
        }
        .onAppear {
            if Theme.reduceMotion {
                webViewVisible = true
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    webViewVisible = true
                }
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Theme.surfaceRaised)
                    .clipShape(Circle())
            }

            Text(article.title)
                .font(Theme.scaledFont(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .matchedGeometryEffect(id: article.id.uuidString + "-title", in: namespace)

            Spacer()

            // Text size
            Button {
                showTextSize.toggle()
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 36, height: 36)
            }
            .popover(isPresented: $showTextSize) {
                TextSizePopover(textSize: Binding(
                    get: { CGFloat(textSize) },
                    set: { textSize = Double($0) }
                ), onChanged: { _ in })
                    .presentationCompactAdaptation(.popover)
            }
            .onLongPressGesture {
                HapticManager.fontSelected()
                showFontPicker = true
            }
            .popover(isPresented: $showFontPicker) {
                FontPickerPopover(selectedFont: $fontFamily, onChanged: { _ in })
                    .presentationCompactAdaptation(.popover)
            }

            // Retry dark mode (debug — full-page dark mode only)
            if useDarkAppearance, cachedPage?.cacheLevelUsed == .full {
                Button {
                    retryDarkMode = true
                } label: {
                    Image(systemName: "moon.circle")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
            }

            // Share
            ShareLink(item: URL(string: article.articleURL) ?? URL(string: "https://preread.app")!,
                      subject: Text(article.title)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.background)
    }

    // MARK: - Missing content fallback

    private var missingContentView: some View {
        VStack(spacing: 0) {
            // Title bar with back button
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(Theme.surfaceRaised)
                        .clipShape(Circle())
                }

                Text(article.title)
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.background)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Theme.textSecondary)

                Text("Content unavailable")
                    .font(Theme.scaledFont(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Text("This article couldn't be saved. The site may block automated access.")
                    .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await retryCache() }
                } label: {
                    if isRetrying {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 20, height: 20)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Theme.accentGradient)
                            .clipShape(Capsule())
                    } else {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(Theme.scaledFont(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Theme.accentGradient)
                            .clipShape(Capsule())
                    }
                }
                .disabled(isRetrying)
                .padding(.top, 8)

                if let url = URL(string: article.articleURL) {
                    Button {
                        safariURL = url
                        showSafari = true
                    } label: {
                        Label("Open in Safari", systemImage: "safari")
                            .font(Theme.scaledFont(size: 15, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    // MARK: - Data

    private func loadCachedPage() async {
        do {
            cachedPage = try await DatabaseManager.shared.dbPool.read { db in
                try CachedPage.fetchOne(db, key: article.id)
            }
        } catch {
            cachedPage = nil
        }
    }

    private func retryCache() async {
        isRetrying = true
        do {
            // Look up the source's cache level
            let source = try await DatabaseManager.shared.dbPool.read { db in
                try Source.fetchOne(db, key: article.sourceID)
            }
            let cacheLevel = source?.effectiveCacheLevel ?? .standard

            // Clear stale conditional headers so we get a fresh response
            var mutable = article
            mutable.etag = nil
            mutable.lastModified = nil
            try await DatabaseManager.shared.dbPool.write { db in
                try mutable.update(db)
            }

            try await PageCacheService.shared.cacheArticle(mutable, cacheLevel: cacheLevel)
            await loadCachedPage()

            // If we now have content, the view will automatically show it
        } catch {
            // Stay on the missing content view
        }
        isRetrying = false
    }

    private func markAsRead() async {
        guard !article.isRead else { return }
        var mutable = article
        mutable.isRead = true
        let toSave = mutable
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try toSave.update(db)
            }
        } catch {
            // Non-critical
        }
    }
}

// MARK: - SFSafariViewController wrapper

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
