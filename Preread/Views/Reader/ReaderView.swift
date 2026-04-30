import SwiftUI
import SafariServices
import GRDB

struct ReaderView: View {
    let source: Source
    @State private var currentArticle: Article

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var detailCoordinator = ArticleDetailCoordinator.shared
    @EnvironmentObject private var toastManager: ToastManager
    @AppStorage("readerTextSize") private var textSize: Double = 18
    @AppStorage("readerFontFamily") private var fontFamily: String = "-apple-system"
    @State private var webViewVisible = false
    @State private var safariURL: URL?
    @State private var showSafari = false
    @State private var showLinkConfirmation = false
    @State private var tappedLinkURL: URL?
    @State private var showTextSize = false
    @State private var showFontPicker = false
    @State private var showArticleDrawer = false
    @State private var cachedPage: CachedPage?
    @State private var isLoadingCachedPage = true
    @State private var isRetrying = false
    @State private var navFaviconImage: UIImage?
    @State private var lightboxImageURL: URL?
    @State private var lightboxChromeVisible = true
    @State private var isSaved: Bool

    init(article: Article, source: Source) {
        self.source = source
        _currentArticle = State(initialValue: article)
        _isSaved = State(initialValue: article.isSaved)
    }

    /// Display name for the toolbar — prefers the original source name when the article
    /// has been detached from its original source (e.g. source was deleted).
    private var displaySourceName: String {
        if source.isHidden, let original = currentArticle.originalSourceName, !original.isEmpty {
            return original
        }
        return source.title
    }

    /// Whether the reader chrome (toolbar, bottom bar) should be visible.
    /// Hides when the lightbox is open and the user zooms or taps to hide.
    private var showReaderChrome: Bool {
        lightboxImageURL == nil || lightboxChromeVisible
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
        return ContainerPaths.articlesBaseURL
            .appendingPathComponent(currentArticle.id.uuidString, isDirectory: true)
            .appendingPathComponent("index.html")
    }



    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Group {
                if isLoadingCachedPage {
                    EmptyView()
                } else if let cachedPage, htmlFileExists {
                    readerContent(cachedPage: cachedPage)
                } else {
                    missingContentView
                }
            }
            .ignoresSafeArea(edges: .top)
            .alert(
                "Open External Link",
                isPresented: $showLinkConfirmation,
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
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if !detailCoordinator.isSplitView {
                    Button {
                        if lightboxImageURL != nil {
                            withAnimation(.easeOut(duration: 0.25)) {
                                lightboxImageURL = nil
                                lightboxChromeVisible = true
                            }
                        } else {
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "chevron.left")
                                .font(Theme.scaledFont(size: 16, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            readerSourceFavicon
                                .padding(.trailing, 4)
                        }
                    }
                } else {
                    readerSourceFavicon
                        .padding(.trailing, 4)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Share
                    ShareLink(item: URL(string: currentArticle.articleURL) ?? URL(string: "https://preread.app")!,
                              subject: Text(currentArticle.title)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(Theme.scaledFont(size: 17))
                            .foregroundColor(Theme.textPrimary)
                    }

                    // Save / Unsave
                    Button {
                        Task { await toggleSave() }
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(Theme.scaledFont(size: 17))
                            .foregroundColor(isSaved ? Theme.accent : Theme.textPrimary)
                    }

                    // Text size (long press for font picker)
                    Button {
                        showTextSize.toggle()
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(Theme.scaledFont(size: 17))
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
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !detailCoordinator.isSplitView {
                HStack {
                    // Close
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 48, height: 48)
                    }
                    .glassCloseButton()

                    Spacer()

                    // Article drawer
                    Button {
                        showArticleDrawer = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 48, height: 48)
                    }
                    .glassCloseButton()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .opacity(showReaderChrome ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: showReaderChrome)
                .allowsHitTesting(showReaderChrome)
            }
        }
        .task {
            await loadCachedPage()
            isLoadingCachedPage = false
            await markAsRead()
        }
        .sheet(isPresented: $showSafari) {
            if let url = safariURL {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showArticleDrawer) {
            ArticleDrawerView(
                currentArticleID: currentArticle.id,
                sourceID: currentArticle.sourceID,
                sourceName: displaySourceName,
                isSavedContext: currentArticle.isSaved && currentArticle.sourceID == Source.savedPagesID,
                onSelectArticle: { switchToArticle($0) }
            )
        }
    }

    // MARK: - Reader content

    private func readerContent(cachedPage: CachedPage) -> some View {
        let isReaderMode = cachedPage.cacheLevelUsed != .full

        let htmlURL = articleHTMLURL
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
                useTransparentBackground: isReaderMode,
                heroImageURL: heroImageURL,
                onScrollDown: { },
                onScrollUp: { },
                onLinkTapped: { url in
                    tappedLinkURL = url
                    showLinkConfirmation = true
                },
                onImageTapped: isReaderMode ? { url in
                    lightboxChromeVisible = true
                    lightboxImageURL = url
                } : nil
            )
        }
        .overlay {
            if let lightboxURL = lightboxImageURL {
                ImageLightboxView(imageURL: lightboxURL, onDismiss: {
                    lightboxImageURL = nil
                    lightboxChromeVisible = true
                }, chromeVisible: $lightboxChromeVisible)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .opacity(webViewVisible ? 1 : 0)
        .animation(.easeIn(duration: 0.2), value: webViewVisible)
        .onAppear {
            // Migrate legacy font choice
            if fontFamily == "Inter Tight" {
                fontFamily = "-apple-system"
            }
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
        let articleDir = ContainerPaths.articlesBaseURL.appendingPathComponent(currentArticle.id.uuidString, isDirectory: true)

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
        let faviconPath = ContainerPaths.sourcesBaseURL.appendingPathComponent("\(source.id.uuidString)/favicon.png")
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
                .background(Theme.faviconBackground, in: RoundedRectangle(cornerRadius: 5))
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
                       let iconURLString = currentArticle.originalSourceIconURL,
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
                    .font(Theme.scaledFont(size: 40, weight: .light))
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

                if let url = URL(string: currentArticle.articleURL) {
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
                try CachedPage.fetchOne(db, key: currentArticle.id)
            }
        } catch {
            cachedPage = nil
        }
    }

    private func retryCache() async {
        isRetrying = true
        do {
            // Manually saved pages remember the cache level chosen at save time.
            // Feed articles use the source's current level.
            let cacheLevel: CacheLevel
            if currentArticle.sourceID == Source.savedPagesID,
               let existing = try? await DatabaseManager.shared.dbPool.read({ db in
                   try CachedPage.fetchOne(db, key: currentArticle.id)
               }) {
                cacheLevel = existing.cacheLevelUsed
            } else {
                let source = try? await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: currentArticle.sourceID)
                }
                cacheLevel = source?.effectiveCacheLevel ?? .standard
            }

            // Clear stale conditional headers so we get a fresh response
            var mutable = currentArticle
            mutable.etag = nil
            mutable.lastModified = nil
            let snapshot = mutable
            try await DatabaseManager.shared.dbPool.write { db in
                try snapshot.update(db)
            }

            try await PageCacheService.shared.cacheArticle(snapshot, cacheLevel: cacheLevel)
            await loadCachedPage()

            // If we now have content, the view will automatically show it
        } catch {
            // Stay on the missing content view
        }
        isRetrying = false
    }

    private func markAsRead() async {
        guard !currentArticle.isRead else { return }
        var mutable = currentArticle
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

        HapticManager.articleCached()
        ToastManager.shared.snack(
            newSaved ? "Saved" : "Unsaved",
            icon: newSaved ? "bookmark.fill" : "bookmark.slash"
        )

        if !newSaved && currentArticle.sourceID == Source.savedPagesID {
            // Saved-pages articles have no feed source — delete entirely
            let articleID = currentArticle.id
            try? await PageCacheService.shared.deleteCachedArticle(articleID)
            _ = try? await DatabaseManager.shared.dbPool.write { db in
                try Article.deleteOne(db, key: articleID)
            }
            FetchCoordinator.shared.savedArticlesVersion += 1
            dismiss()
            return
        }

        var mutable = currentArticle
        mutable.isSaved = newSaved
        mutable.savedAt = newSaved ? Date() : nil
        if newSaved {
            mutable.originalSourceName = source.title
            mutable.originalSourceIconURL = source.iconURL
        } else {
            mutable.originalSourceName = nil
            mutable.originalSourceIconURL = nil
        }

        let toSave = mutable
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try toSave.update(db)
            }
            FetchCoordinator.shared.savedArticlesVersion += 1
        } catch {
            isSaved = !newSaved
        }
    }

    private func switchToArticle(_ article: Article) {
        showArticleDrawer = false
        currentArticle = article
        isSaved = article.isSaved
        cachedPage = nil
        isLoadingCachedPage = true
        webViewVisible = false
        navFaviconImage = nil
        lightboxImageURL = nil
        Task {
            await loadCachedPage()
            isLoadingCachedPage = false
            await markAsRead()
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
