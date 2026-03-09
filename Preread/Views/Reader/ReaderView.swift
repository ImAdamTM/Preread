import SwiftUI
import SafariServices
import GRDB

struct ReaderView: View {
    let article: Article
    let source: Source

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var toastManager: ToastManager
    @AppStorage("readerTextSize") private var textSize: Double = 18
    @AppStorage("readerFontFamily") private var fontFamily: String = "Inter Tight"
    @State private var webViewVisible = false
    @State private var safariURL: URL?
    @State private var showSafari = false
    @State private var showLinkConfirmation = false
    @State private var tappedLinkURL: URL?
    @State private var showTextSize = false
    @State private var showFontPicker = false
    @State private var cachedPage: CachedPage?
    @State private var isLoadingCachedPage = true
    @State private var isRetrying = false
    @State private var navFaviconImage: UIImage?
    @State private var lightboxImageURL: URL?
    @State private var isSaved: Bool

    init(article: Article, source: Source) {
        self.article = article
        self.source = source
        _isSaved = State(initialValue: article.isSaved)
    }

    /// Display name for the toolbar — prefers the original source name when the article
    /// has been detached from its original source (e.g. source was deleted).
    private var displaySourceName: String {
        if source.isHidden, let original = article.originalSourceName, !original.isEmpty {
            return original
        }
        return source.title
    }

    private var useDarkAppearance: Bool {
        colorScheme == .dark
    }

    /// Checks the dynamic path (not the stored DB path) so it survives
    /// container path changes in the simulator.
    private var htmlFileExists: Bool {
        let url = articleHTMLURL
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var articleHTMLURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("preread/articles", isDirectory: true)
            .appendingPathComponent(article.id.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")
    }

    private var articleDarkHTMLURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("preread/articles", isDirectory: true)
            .appendingPathComponent(article.id.uuidString, isDirectory: true)
            .appendingPathComponent("index-dark.html")
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if isLoadingCachedPage {
                EmptyView()
            } else if let cachedPage, htmlFileExists {
                readerContent(cachedPage: cachedPage)
            } else {
                missingContentView
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    readerSourceFavicon
                    Text(displaySourceName)
                        .font(Theme.scaledFont(size: 17, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Text size (long press for font picker)
                    Button {
                        showTextSize.toggle()
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 17))
                            .foregroundColor(Theme.textPrimary)
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

                    // Share
                    ShareLink(item: URL(string: article.articleURL) ?? URL(string: "https://preread.app")!,
                              subject: Text(article.title)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundColor(Theme.textPrimary)
                    }

                    // Save / Unsave
                    Button {
                        Task { await toggleSave() }
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 17))
                            .foregroundColor(isSaved ? Theme.accent : Theme.textPrimary)
                    }
                }
            }
        }
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
           FileManager.default.fileExists(atPath: articleDarkHTMLURL.path) {
            htmlURL = articleDarkHTMLURL
            usePreDarkened = true
        } else {
            htmlURL = articleHTMLURL
            usePreDarkened = false
        }
        let articleDir = htmlURL.deletingLastPathComponent()

        return ZStack {
            CachedWebView(
                htmlFileURL: htmlURL,
                articleDirectory: articleDir,
                isDarkMode: isReaderMode ? false : useDarkAppearance,
                isReaderMode: isReaderMode,
                useLightMode: isReaderMode && !useDarkAppearance,
                textSize: CGFloat(textSize),
                fontFamily: fontFamily,
                useTransparentBackground: true,
                heroImageURL: heroImageURL,
                onScrollDown: { },
                onScrollUp: { },
                onLinkTapped: { url in
                    tappedLinkURL = url
                    showLinkConfirmation = true
                },
                onImageTapped: isReaderMode ? { url in
                    lightboxImageURL = url
                } : nil
            )
        }
        .overlay {
            if let lightboxURL = lightboxImageURL {
                ImageLightboxView(imageURL: lightboxURL) {
                    lightboxImageURL = nil
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .opacity(webViewVisible ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: webViewVisible)
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

    // MARK: - Hero image URL

    private var heroImageURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let articleDir = appSupport.appendingPathComponent("preread/articles/\(article.id.uuidString)", isDirectory: true)

        // Try the regular-size downsampled thumbnail (600px)
        let thumbnailPath = articleDir.appendingPathComponent("thumbnail.jpg")
        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return thumbnailPath
        }

        // Legacy: articles cached before downsampling was added may have other extensions
        for ext in ["jpeg", "png", "webp", "gif", "avif"] {
            let path = articleDir.appendingPathComponent("thumbnail.\(ext)")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        // Fall back to source's cached favicon
        let faviconPath = appSupport.appendingPathComponent("preread/sources/\(source.id.uuidString)/favicon.png")
        if FileManager.default.fileExists(atPath: faviconPath.path) {
            return faviconPath
        }

        return nil
    }

    // MARK: - Source favicon for toolbar

    @ViewBuilder
    private var readerSourceFavicon: some View {
        if let favicon = navFaviconImage {
            Image(uiImage: favicon)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            readerSmallLetterAvatar
                .task {
                    // Try the source's cached favicon first
                    let sourceID = source.id
                    if let cached = await Task.detached(priority: .utility, operation: {
                        await PageCacheService.shared.cachedFavicon(for: sourceID)
                    }).value {
                        navFaviconImage = cached
                        return
                    }

                    // For detached articles, try loading from the original icon URL
                    if source.isHidden,
                       let iconURLString = article.originalSourceIconURL,
                       let iconURL = URL(string: iconURLString) {
                        if let (data, _) = try? await URLSession.shared.data(from: iconURL),
                           let image = UIImage(data: data) {
                            navFaviconImage = image
                        }
                    }
                }
        }
    }

    private var readerSmallLetterAvatar: some View {
        let name = displaySourceName
        let letter = String(name.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.avatarGradient(for: name))
                .frame(width: 24, height: 24)
            Text(letter)
                .font(Theme.scaledFont(size: 12, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Missing content fallback

    private var missingContentView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(Theme.textSecondary)

                Text("Content unavailable")
                    .font(Theme.scaledFont(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

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

    private func toggleSave() async {
        let newSaved = !isSaved
        isSaved = newSaved

        var mutable = article
        mutable.isSaved = newSaved
        mutable.savedAt = newSaved ? Date() : nil
        if newSaved {
            mutable.originalSourceName = source.title
            mutable.originalSourceIconURL = source.iconURL
        } else {
            mutable.originalSourceName = nil
            mutable.originalSourceIconURL = nil
        }

        HapticManager.articleCached()
        ToastManager.shared.snack(
            newSaved ? "Saved" : "Unsaved",
            icon: newSaved ? "bookmark.fill" : "bookmark.slash"
        )

        let toSave = mutable
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try toSave.update(db)
            }
        } catch {
            isSaved = !newSaved
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
