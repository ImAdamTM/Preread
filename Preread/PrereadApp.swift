import AppIntents
import SwiftUI

// MARK: - App entry point

@main
struct PrereadApp: App {
    // 1. Background task registration via AppDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private var preferredScheme: ColorScheme? {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(preferredScheme)
                .tint(Theme.accent)
                // 6. Environment objects
                .environmentObject(ToastManager.shared)
                .environmentObject(deepLinkRouter)
                // 7. Toast overlay on root
                .toastOverlay()
                // 2. Startup tasks
                .task {
                    await startupSequence()
                }
                // 3. Refresh stale sources when returning to foreground
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            // Reset any articles left at .fetching by a
                            // cancelled background task or interrupted cache
                            await IntegrityChecker.resetStaleFetchingArticles()
                            await FetchCoordinator.shared.refreshStaleAutoSources()
                        }
                    } else if phase == .background {
                        // Re-schedule background tasks every time the app
                        // enters the background so iOS always has a fresh
                        // request. Without this, tasks only get scheduled at
                        // app launch or when a previous task fires — if iOS
                        // never runs the first one, they're never re-queued.
                        let bgEnabled = UserDefaults.standard.bool(forKey: "backgroundRefreshEnabled")
                        if bgEnabled || !UserDefaults.standard.contains(key: "backgroundRefreshEnabled") {
                            BackgroundTaskManager.scheduleRefresh()
                            BackgroundTaskManager.scheduleProcessing()
                        }
                    }
                }
                // 4. Deep link handling
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    // MARK: - Startup sequence

    private func startupSequence() async {
        // Activate Watch Connectivity session
        WatchConnectivityManager.shared.activate()

        // Run integrity checker (orphan detection)
        await IntegrityChecker.run()

        // Signal views to reload with corrected article statuses
        await MainActor.run {
            FetchCoordinator.shared.startupComplete = true
        }

        // Schedule background tasks
        let bgEnabled = UserDefaults.standard.bool(forKey: "backgroundRefreshEnabled")
        // Default to true if key hasn't been set yet
        if bgEnabled || !UserDefaults.standard.contains(key: "backgroundRefreshEnabled") {
            BackgroundTaskManager.scheduleRefresh()
            BackgroundTaskManager.scheduleProcessing()
        }

        // Register App Shortcuts parameters so the Shortcuts app
        // knows which sources are available for the "Open Source" shortcut.
        PrereadShortcutsProvider.updateAppShortcutParameters()

        // Backfill cached favicons for any sources missing them
        await backfillFavicons()

        // Trigger .onOpen refreshes for sources configured as such
        await triggerOnOpenRefreshes()

        // Refresh .automatic sources if they've gone stale (safety net for
        // missed background tasks — no-op if background ran recently)
        await FetchCoordinator.shared.refreshStaleAutoSources()
    }

    /// Refreshes sources whose fetchFrequency is .onOpen.
    private func triggerOnOpenRefreshes() async {
        await FetchCoordinator.shared.refreshOnOpenSources()
    }

    // MARK: - Favicon backfill

    /// Downloads and caches favicons for any sources that don't have one on disk yet.
    private func backfillFavicons() async {
        // Generate the gradient bookmark icon for Saved Pages
        await PageCacheService.shared.generateSavedPagesFavicon()

        do {
            let sources = try await DatabaseManager.shared.dbPool.read { db in
                try Source.fetchAll(db)
            }
            for source in sources {
                guard let iconURL = source.iconURL else { continue }
                // Skip if already cached
                let existing = await PageCacheService.shared.cachedFavicon(for: source.id)
                guard existing == nil else { continue }
                await PageCacheService.shared.cacheFavicon(for: source.id, from: iconURL)
            }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Deep links

    private func handleDeepLink(_ url: URL) {
        deepLinkRouter.handle(url)
    }
}

// MARK: - UserDefaults helper

extension UserDefaults {
    func contains(key: String) -> Bool {
        object(forKey: key) != nil
    }
}
