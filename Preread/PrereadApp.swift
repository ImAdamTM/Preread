import SwiftUI

// MARK: - App entry point

@main
struct PrereadApp: App {
    // 1. Background task registration via AppDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var deepLinkRouter = DeepLinkRouter()
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
                // 3. Deep link handling
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    // MARK: - Startup sequence

    private func startupSequence() async {
        // Run integrity checker (orphan detection)
        await IntegrityChecker.run()

        // Schedule background tasks
        let bgEnabled = UserDefaults.standard.bool(forKey: "backgroundRefreshEnabled")
        // Default to true if key hasn't been set yet
        if bgEnabled || !UserDefaults.standard.contains(key: "backgroundRefreshEnabled") {
            BackgroundTaskManager.scheduleRefresh()
            BackgroundTaskManager.scheduleProcessing()
        }

        // Trigger .onOpen refreshes for sources configured as such
        await triggerOnOpenRefreshes()
    }

    /// Refreshes sources whose fetchFrequency is .onOpen.
    private func triggerOnOpenRefreshes() async {
        await FetchCoordinator.shared.refreshOnOpenSources()
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
