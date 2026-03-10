import SwiftUI
import GRDB

enum NavigationTarget: Hashable {
    case source(UUID)
    case saved
}

private struct ReaderSelection: Identifiable {
    let id = UUID()
    let article: Article
    let source: Source
}

struct SourcesListView: View {
    @ObservedObject private var coordinator = FetchCoordinator.shared
    @EnvironmentObject private var toastManager: ToastManager
    @EnvironmentObject private var deepLinkRouter: DeepLinkRouter

    @State private var sources: [Source] = []
    @State private var hasSavedArticles: Bool = false
    @State private var showAddSource = false
    @State private var addSourceInitialURL: String?
    @State private var highlightedSourceID: UUID?
    @State private var navigationPath = NavigationPath()
    @State private var renamingSource: Source?
    @State private var renameText = ""
    
    @State private var scrollToSourceID: UUID?
    @State private var readerSelection: ReaderSelection?
    @Environment(\.colorScheme) private var systemColorScheme
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
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                        }

                        Button {
                            Task { await coordinator.refreshAllSources() }
                        } label: {
                            navRefreshButton
                        }
                        .disabled(coordinator.isFetching)

                        NavigationLink {
                            SettingsView()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 17))
                                .foregroundColor(Theme.textPrimary)
                        }
                    }
                }
            }
            .task {
                await loadSources()
            }
            .onChange(of: navigationPath) { _, path in
                // Refresh counts when navigating back (e.g. after reading articles)
                if path.isEmpty {
                    Task { await loadSources() }
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
                .toastOverlay()
                .presentationDragIndicator(.hidden)
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
                    }
                case .saved:
                    SavedArticlesView()
                }
            }
            .onChange(of: deepLinkRouter.pendingSourceID) { _, sourceID in
                guard let sourceID else { return }
                navigationPath = NavigationPath()
                navigationPath.append(NavigationTarget.source(sourceID))
                deepLinkRouter.pendingSourceID = nil
            }
            .onChange(of: deepLinkRouter.pendingArticleID) { _, articleID in
                guard let articleID else { return }
                Task {
                    // Look up the article's sourceID for back-stack navigation
                    guard let article = try? await DatabaseManager.shared.dbPool.read({ db in
                        try Article.fetchOne(db, key: articleID)
                    }) else {
                        // Invalid article ID — fail silently
                        deepLinkRouter.pendingArticleID = nil
                        return
                    }
                    navigationPath = NavigationPath()
                    navigationPath.append(NavigationTarget.source(article.sourceID))
                    // pendingArticleID stays set — ArticleListView picks it up
                }
            }
            .onChange(of: deepLinkRouter.pendingSavedNavigation) { _, shouldNavigate in
                guard shouldNavigate else { return }
                navigationPath = NavigationPath()
                navigationPath.append(NavigationTarget.saved)
                deepLinkRouter.pendingSavedNavigation = false
            }
            .onChange(of: deepLinkRouter.pendingAddURL) { _, urlString in
                guard let urlString else { return }
                navigationPath = NavigationPath()
                addSourceInitialURL = urlString
                deepLinkRouter.pendingAddURL = nil

                if showAddSource {
                    showAddSource = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showAddSource = true
                    }
                } else {
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
                    Text("Your Prereads")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(Theme.textPrimary)
                        .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                ForEach(sources) { source in
                    let state = coordinator.sourceStatuses[source.id] ?? .idle

                    SourceSectionView(
                        source: source,
                        refreshState: state,
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
                            openArticleInReader(article)
                        }
                    )
                    .id(source.id)
                }

                if hasSavedArticles {
                    SavedSectionView(
                        onViewAll: {
                            navigationPath.append(NavigationTarget.saved)
                        },
                        onOpenArticle: { article in
                            openArticleInReader(article)
                        }
                    )
                }

                if !sources.isEmpty {
                    Button {
                        showAddSource = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 24))
                            Text("Add a new source")
                                .font(Theme.scaledFont(size: 15))
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: scrollToSourceID) { _, sourceID in
                guard let sourceID else { return }
                withAnimation(Theme.gentleAnimation()) {
                    proxy.scrollTo(sourceID, anchor: .top)
                }
                scrollToSourceID = nil
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 80))
                .foregroundStyle(Theme.accentGradient)
                .symbolEffect(.pulse, options: .repeating, isActive: !Theme.reduceMotion)

            Text("Your library is empty")
                .font(Theme.scaledFont(size: 22, weight: .bold, relativeTo: .title2))
                .foregroundColor(Theme.textPrimary)

            Text("Add a site to get started...")
                .font(Theme.scaledFont(size: 15, relativeTo: .subheadline))
                .foregroundColor(Theme.textSecondary)

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
                .font(.system(size: 15, weight: .medium))
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
        Image(systemName: "square.stack.3d.down.right.fill")
            .font(.system(size: 20))
            .foregroundStyle(Theme.accentGradient)
    }

    // MARK: - Reader

    private func openArticleInReader(_ article: Article) {
        Task {
            guard let source = try? await DatabaseManager.shared.dbPool.read({ db in
                try Source.fetchOne(db, key: article.sourceID)
            }) else { return }
            readerSelection = ReaderSelection(article: article, source: source)
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
        } catch {
            // Silently fail — sources will remain as last loaded
        }
    }

    // MARK: - Remove source

    private func removeSource(_ source: Source) async {
        HapticManager.deleteConfirm()

        do {
            try await Source.deleteWithCleanup(source)

            withAnimation(Theme.gentleAnimation()) {
                sources.removeAll { $0.id == source.id }
            }

            // Refresh saved status in case removing the source affected saved articles
            let savedExists = try await DatabaseManager.shared.dbPool.read { db in
                try Article.filter(Column("isSaved") == true).fetchCount(db) > 0
            }
            hasSavedArticles = savedExists
        } catch {
            toastManager.show("Couldn't remove source", type: .error)
        }
    }

    // MARK: - Rename source

    private func renameSource(_ source: Source, to newName: String) async {
        var updated = source
        updated.title = newName
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                try updated.update(db)
            }
            await loadSources()
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
