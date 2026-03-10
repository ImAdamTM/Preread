import Foundation
import Network

/// Lightweight wrapper around NWPathMonitor for one-shot connectivity checks.
/// No long-lived monitor — just reads the current path on demand.
enum NetworkMonitor {
    /// Returns `true` when the device is on WiFi (or Ethernet/wired).
    static var isOnWiFi: Bool {
        let monitor = NWPathMonitor()
        let path = monitor.currentPath
        return path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
    }

    /// Returns `true` when the user has enabled "WiFi only" **and** the device
    /// is currently on a non-WiFi connection.  Callers can use this to skip
    /// automatic network work without affecting user-initiated actions.
    static var shouldSkipForWiFiOnly: Bool {
        let wifiOnly = UserDefaults.standard.bool(forKey: "wifiOnly")
        guard wifiOnly else { return false }
        return !isOnWiFi
    }
}
