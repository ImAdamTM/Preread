import SwiftUI
import GRDB
import WidgetKit

enum NavigationTarget: Hashable {
    case source(UUID)
    case saved
}

struct SourcesListView: View {
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var toastManager: ToastManager
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var sources: [Source] = []
    @State private var hasSavedArticles: Bool = false
    @State private var showAddSource = false
    @State private var showSettings = false
    @State private var addSourceInitialURL: String?
    @State private var highlightedSourceID: UUID?
    @State private var navigationPath = NavigationPath()
    /// Tracks the source ID currently at the top of the navigation stack,
    /// so deep links can skip redundant pop-and-push when already viewing the target.
    @State private var currentSourceID: UUID?
    @State private var renamingSource: Source?
    @State private var renameText = ""
    
    @Namespace private var namespace
    @State private var scrollToSourceID: UUID?
    @State private var readerSelection: ReaderSelection?
    @State private var transitionSourceID: String?
    @State private var accentGradientImage: UIImage?
    @State private var totalArticleCount: Int = 0
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var detailCoordinator = ArticleDetailCoordinator.shared
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private var preferredScheme: ColorScheme {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Theme.background.ignoresSafeArea()

                if sources.isEmpty && !hasSavedArticles {
                    emptyState
                } else {
                    sourcesList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    logomark
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            showAddSource = true
                        } label: {
                            Image(systemName: "plus")
                                .font(Theme.scaledFont(size: 17, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                        }

                        Button {
                            Task { await coordinator.refreshAllSources() }
                        } label: {
                            navRefreshButton
                        }
                        .disabled(coordinator.isFetching)

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(Theme.scaledFont(size: 17))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                }
            }
            .task {
                await loadSources()
                // On cold launch via deep link, the pending ID may already
                // be set before this view appears. Consume it immediately
                // so we navigate without flashing the home screen.
                if let sourceID = deepLinkRouter.pendingSourceID {
                    deepLinkRouter.pendingSourceID = nil
                    navigateToSource(sourceID)
                }
            }
            .onChange(of: navigationPath) { _, path in
                // Refresh counts when navigating back (e.g. after reading articles)
                if path.isEmpty {
                    Task { await loadSources() }
                    // Kick off any stale-source refreshes that were deferred
                    // while the user was viewing a specific feed.
                    Task { await coordinator.refreshDeferredStaleSources() }
                }
            }
            .refreshable {
                HapticManager.pullToRefresh()
                // Run in an unstructured Task so SwiftUI's pull-to-refresh
                // lifecycle doesn't cancel the refresh when the spinner dismisses.
                await Task {
                    await coordinator.refreshAllSources()
                }.value
                await loadSources()
            }
            .onChange(of: coordinator.isFetching) { _, isFetching in
                if !isFetching {
                    Task { await loadSources() }
                    checkForFailures()
                }
            }
            .onChange(of: coordinator.sourceStatuses) { _, statuses in
                let hasCompleted = statuses.values.contains { $0 == .completed }

                if hasCompleted {
                    Task { await loadSources() }
                }
            }
            .onChange(of: coordinator.savedArticlesVersion) { _, _ in
                Task { await loadSources() }
            }
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet(
                    initialURL: addSourceInitialURL,
                    onSourceAdded: { addedSourceID in
                        Task {
                            await loadSources()
                            // Brief delay lets the List layout settle after
                            // inserting the new section, so scrollTo lands
                            // with the header fully visible.
                            try? await Task.sleep(for: .milliseconds(200))
                            scrollToSourceID = addedSourceID
                            highlightedSourceID = addedSourceID
                            try? await Task.sleep(for: .seconds(1))
                            highlightedSourceID = nil
                        }
                    },
                    onSavedArticle: {
                        Task {
                            await loadSources()
                            navigationPath.append(NavigationTarget.saved)
                        }
                    }
                )
                .onDisappear {
                    addSourceInitialURL = nil
                }
            }
            .sheet(item: $readerSelection) { selection in
                NavigationStack {
                    ReaderView(article: selection.article, source: selection.source)
                }
                .navigationTransition(.zoom(sourceID: transitionSourceID ?? "\(selection.source.id)-\(selection.article.id)", in: namespace))
                .toastOverlay()
                .presentationDragIndicator(.hidden)
                .preferredColorScheme(preferredScheme)
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                Task { await loadSources() }
            }) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
                .preferredColorScheme(preferredScheme)
            }
            .alert("Edit name", isPresented: Binding(
                get: { renamingSource != nil },
                set: { if !$0 { renamingSource = nil } }
            )) {
                TextField("Source name", text: $renameText)
                Button("Save") {
                    guard let source = renamingSource,
                          !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    Task { await renameSource(source, to: renameText.trimmingCharacters(in: .whitespaces)) }
                    renamingSource = nil
                }
                Button("Cancel", role: .cancel) { renamingSource = nil }
            }
            .navigationDestination(for: NavigationTarget.self) { target in
                switch target {
                case .source(let sourceID):
                    if let source = sources.first(where: { $0.id == sourceID }) {
                        ArticleListView(source: source)
                            .onAppear { currentSourceID = sourceID }
                            .onDisappear { currentSourceID = nil }
                    }
                case .saved:
                    SavedArticlesView()
                }
            }
            .onChange(of: deepLinkRouter.pendingSourceID) { _, sourceID in
                guard let sourceID else { return }
                deepLinkRouter.pendingSourceID = nil
                navigateToSource(sourceID)
            }
            .onChange(of: deepLinkRouter.pendingArticleID) { _, articleID in
                guard let articleID else { return }
                deepLinkRouter.pendingArticleID = nil
                dismissAndNavigate {
                    Task {
                        guard let article = try? await DatabaseManager.shared.dbPool.read({ db in
                            try Article.fetchOne(db, key: articleID)
                        }) else {
                            toastManager.show("This article is no longer available", type: .error)
                            // Refresh widgets to clear stale entries
                            WidgetCenter.shared.reloadAllTimelines()
                            return
                        }
                        transitionSourceID = nil
                        openArticleInReader(article)
                    }
                }
            }
            .onChange(of: deepLinkRouter.pendingSavedNavigation) { _, shouldNavigate in
                guard shouldNavigate else { return }
                deepLinkRouter.pendingSavedNavigation = false
                dismissAndNavigate {
                    navigationPath.append(NavigationTarget.saved)
                }
            }
            .onChange(of: deepLinkRouter.pendingAddURL) { _, urlString in
                guard let urlString else { return }
                deepLinkRouter.pendingAddURL = nil
                addSourceInitialURL = urlString
                dismissAndNavigate {
                    showAddSource = true
                }
            }
        }
    }

    // MARK: - Sources list

    private var sourcesList: some View {
        ScrollViewReader { proxy in
            List {
                if !sources.isEmpty {
                    homeHeroRow
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .zIndex(-1)

                    LatestCarouselView(
                        transitionNamespace: namespace,
                        onOpenArticle: { article in
                            transitionSourceID = "latest-carousel-\(article.id)"
                            openArticleInReader(article)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                ForEach(sources) { source in
                    let state = coordinator.sourceStatuses[source.id] ?? .idle

                    SourceSectionView(
                        source: source,
                        refreshState: state,
                        transitionNamespace: namespace,
                        onViewAll: {
                            navigationPath.append(NavigationTarget.source(source.id))
                        },
                        onRefresh: {
                            Task {
                                await coordinator.refreshSingleSource(source)
                                await loadSources()
                            }
                        },
                        onEditName: {
                            renameText = source.title
                            renamingSource = source
                        },
                        onRemove: {
                            Task { await removeSource(source) }
                        },
                        onOpenArticle: { article in
                            transitionSourceID = "\(source.id)-\(article.id)"
                            openArticleInReader(article)
                        }
                    )
                    .id(source.id)
                }

                if hasSavedArticles {
                    SavedSectionView(
                        transitionNamespace: namespace,
                        onViewAll: {
                            navigationPath.append(NavigationTarget.saved)
                        },
                        onOpenArticle: { article in
                            transitionSourceID = "saved-section-\(article.id)"
                            openArticleInReader(article)
                        }
                    )
                }

                if !sources.isEmpty {
                    Button {
                        showAddSource = true
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Theme.accentGradient)
                                    .frame(width: 36, height: 36)
                                Image(systemName: "plus")
                                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text("Add a new source")
                                .font(Theme.scaledFont(size: 15))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(20)
            .scrollContentBackground(.hidden)
            .onChange(of: scrollToSourceID) { _, sourceID in
                guard let sourceID else { return }
                withAnimation(Theme.gentleAnimation()) {
                    // Anchor slightly above .top so the section header clears
                    // the previous section's sticky header and sits fully visible.
                    proxy.scrollTo(sourceID, anchor: UnitPoint(x: 0.5, y: -0.05))
                }
                scrollToSourceID = nil
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            LinearGradient(
                colors: [Color("PrereadAccent"), Color("PrereadPurple")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .mask(
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            )
            .frame(height: 72)
            .offset(x: 5)

            VStack(spacing: 6) {
                Text("Your library is empty")
                    .font(Theme.scaledFont(size: 22, weight: .semibold, relativeTo: .title2))
                    .foregroundColor(Theme.textPrimary)

                Text("Discover and follow your favourite sites")
                    .font(Theme.scaledFont(size: 15, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)
            }

            Button {
                showAddSource = true
            } label: {
                Text("Add your first source")
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.accentGradient)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Nav refresh button

    private var navRefreshButton: some View {
        let isRefreshing = coordinator.isFetching
        return ZStack {
            Image(systemName: "arrow.clockwise")
                .font(Theme.scaledFont(size: 15, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .opacity(isRefreshing ? 0 : 1)
                .scaleEffect(isRefreshing ? 0.5 : 1)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRefreshing)) { context in
                let angle = context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.2) / 1.2 * 360
                ZStack {
                    Circle()
                        .stroke(Theme.borderProminent, lineWidth: 2)
                        .frame(width: 20, height: 20)

                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(
                            AngularGradient(
                                colors: [Theme.accent.opacity(0.6), Theme.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(angle))
                }
            }
            .opacity(isRefreshing ? 1 : 0)
            .scaleEffect(isRefreshing ? 1 : 0.5)
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
    }

    // MARK: - Logomark

    private var logomark: some View {
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 21)
            .padding(.leading, 3)
    }

    // MARK: - Home hero

    private var homeHeroRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preread for you")
                .font(Theme.scaledFont(size: 32, weight: .regular))
                .foregroundColor(Theme.textPrimary)

            Text(totalArticleCount > 0 ? "\(totalArticleCount) articles ready" : " ")
                .font(Theme.scaledFont(size: 13, relativeTo: .caption))
                .foregroundColor(Theme.textSecondary)
                .opacity(totalArticleCount > 0 ? 1 : 0)
                .padding(.top, -4)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            blurredAccentBackground
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
                .visualEffect { content, proxy in
                    content.offset(y: -max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY))
                }
        }
    }

    private var blurredAccentBackground: some View {
        ZStack {
            if let img = accentGradientImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .clipped()
            } else {
                Color.clear
                    .task {
                        accentGradientImage = Self.makeAccentGradientImage()
                    }
            }
        }
        .opacity(0.3)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.4),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private static func makeAccentGradientImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cgColors = [UIColor(Theme.teal).cgColor, UIColor(Theme.purple).cgColor]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors as CFArray, locations: [0, 1]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: - Deep link navigation

    /// Navigates to a source, skipping the pop-and-push cycle when
    /// the user is already viewing that source.
    private func navigateToSource(_ sourceID: UUID) {
        // Already viewing this feed — nothing to do.
        if currentSourceID == sourceID && !showAddSource && readerSelection == nil {
            return
        }
        dismissAndNavigate {
            navigationPath.append(NavigationTarget.source(sourceID))
        }
    }

    /// Dismisses any open sheets and pops the nav stack to root,
    /// then runs the provided navigation action after a brief delay
    /// so that dismissals complete before the new navigation begins.
    private func dismissAndNavigate(then navigate: @escaping () -> Void) {
        let needsDismissal = !navigationPath.isEmpty || showAddSource || showSettings || readerSelection != nil

        // Pop to root and close any open sheets
        navigationPath = NavigationPath()
        showAddSource = false
        showSettings = false
        readerSelection = nil

        if needsDismissal {
            // Small delay to let sheet/navigation dismissals animate out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                navigate()
            }
        } else {
            navigate()
        }
    }

    // MARK: - Reader

    private func openArticleInReader(_ article: Article) {
        Task {
            guard let source = try? await DatabaseManager.shared.dbPool.read({ db in
                try Source.fetchOne(db, key: article.sourceID)
            }) else { return }
            let selection = ReaderSelection(article: article, source: source)
            if detailCoordinator.isSplitView {
                detailCoordinator.selection = selection
            } else {
                readerSelection = selection
            }
        }
    }

    // MARK: - Data loading

    private func loadSources() async {
        do {
            let loadedSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
            }
            sources = loadedSources

            let savedExists = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("isSaved") == true)
                    .fetchCount(db) > 0
            }
            hasSavedArticles = savedExists

            let articleCount = try await DatabaseManager.shared.dbPool.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*)
                    FROM article
                    WHERE sourceID != ?
                      AND fetchStatus IN ('cached', 'partial')
                """, arguments: [Source.savedPagesID])
            }
            totalArticleCount = articleCount ?? 0
        } catch {
            // Silently fail — sources will remain as last loaded
        }
    }

    // MARK: - Remove source

    private func removeSource(_ source: Source) async {
        HapticManager.deleteConfirm()

        // Tell the coordinator to stop updating status for this source.
        // Without this, an in-flight fetch completing mid-deletion triggers
        // loadSources() which can temporarily resurrect the source.
        coordinator.cancelSource(source.id)

        // Remove from the local array first so the SourceSectionView's
        // observation is torn down before the DB cascade-delete fires.
        // This prevents a race where the observation sees 0 articles
        // mid-animation, leaving a stuck header.
        withAnimation(Theme.gentleAnimation()) {
            sources.removeAll { $0.id == source.id }
        }

        do {
            try await Source.deleteWithCleanup(source)

            // Refresh saved status in case removing the source affected saved articles
            let savedExists = try await DatabaseManager.shared.dbPool.read { db in
                try Article.filter(Column("isSaved") == true).fetchCount(db) > 0
            }
            hasSavedArticles = savedExists
        } catch {
            // DB cleanup failed — the source is already removed from the UI.
            // Reload from DB to reconcile state.
            await loadSources()
            toastManager.show("Couldn't remove source", type: .error)
        }
    }

    // MARK: - Rename source

    private func renameSource(_ source: Source, to newName: String) async {
        var updated = source
        updated.title = newName
        let snapshot = updated
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try snapshot.update(db)
            }
            await loadSources()
            // Refresh widgets so they pick up the new source name
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            toastManager.show("Couldn't rename source", type: .error)
        }
    }

    // MARK: - Sort order

    private func saveSortOrder() async {
        let orderedSources = sources
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                for (index, var source) in orderedSources.enumerated() {
                    source.sortOrder = index
                    try source.update(db)
                }
            }
        } catch {
            // Sort order save failed silently
        }
    }

    // MARK: - Failure handling

    private func checkForFailures() {
        let failedCount = coordinator.sourceStatuses.values.filter { $0 == .failed }.count
        let totalCount = coordinator.sourceStatuses.count

        if failedCount == totalCount && totalCount > 0 {
            toastManager.showOffline()
        }
    }
}

#Preview {
    SourcesListView()
        .environmentObject(ToastManager.shared)
        .environmentObject(DeepLinkRouter())
}
