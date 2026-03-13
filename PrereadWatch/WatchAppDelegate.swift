import WatchKit
import WatchConnectivity
import WidgetKit

/// Handles Watch Connectivity session on the watch side.
/// Receives article data from the paired iPhone and stores it in the shared app group.
class WatchAppDelegate: NSObject, WKApplicationDelegate, WCSessionDelegate {

    func applicationDidFinishLaunching() {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            // Check for any existing context that arrived before activation
            processApplicationContext(session.receivedApplicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        processApplicationContext(applicationContext)
    }

    // MARK: - Private

    private func processApplicationContext(_ context: [String: Any]) {
        guard let data = context["articles"] as? Data,
              let articles = try? JSONDecoder().decode([WatchArticle].self, from: data) else {
            return
        }

        WatchDataStore.saveArticles(articles)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
