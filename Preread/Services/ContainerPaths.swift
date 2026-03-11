import Foundation

enum ContainerPaths {
    static let appGroupID = "group.com.ahartwig.preread"

    /// The shared app-group container root.
    static var sharedContainerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            // Fallback for previews / unit tests where the group isn't provisioned.
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        }
        return url
    }

    /// Root directory for all Preread data in the shared container.
    static var prereadRoot: URL {
        sharedContainerURL.appendingPathComponent("preread", isDirectory: true)
    }

    static var databasePath: String {
        prereadRoot.appendingPathComponent("preread.db").path
    }

    static var articlesBaseURL: URL {
        prereadRoot.appendingPathComponent("articles", isDirectory: true)
    }

    static var sourcesBaseURL: URL {
        prereadRoot.appendingPathComponent("sources", isDirectory: true)
    }

    static var sharedAssetsURL: URL {
        prereadRoot.appendingPathComponent("shared_assets", isDirectory: true)
    }

    /// Legacy path (pre-app-group) for migration detection.
    static var legacyPrereadRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("preread", isDirectory: true)
    }

    /// One-time migration: moves entire preread/ dir from app sandbox to shared container.
    /// Must be called before DatabaseManager opens the database.
    static func migrateToAppGroupIfNeeded() {
        let fm = FileManager.default
        let marker = prereadRoot.appendingPathComponent(".migrated")

        // Skip if already migrated
        guard !fm.fileExists(atPath: marker.path) else { return }

        let legacyDB = legacyPrereadRoot.appendingPathComponent("preread.db")

        guard fm.fileExists(atPath: legacyDB.path) else {
            // Fresh install — no migration needed, just ensure the directory exists
            try? fm.createDirectory(at: prereadRoot, withIntermediateDirectories: true)
            try? Data().write(to: marker)
            return
        }

        // Ensure the shared container directory exists
        try? fm.createDirectory(at: sharedContainerURL, withIntermediateDirectories: true)

        // Move the entire preread/ directory tree to the shared container
        if !fm.fileExists(atPath: prereadRoot.path) {
            do {
                try fm.moveItem(at: legacyPrereadRoot, to: prereadRoot)
            } catch {
                print("[ContainerPaths] Migration failed: \(error)")
                // If move failed, the DB stays in the old location.
                // DatabaseManager will still open from prereadRoot, so we need
                // to at least ensure the directory exists.
                try? fm.createDirectory(at: prereadRoot, withIntermediateDirectories: true)
                return
            }
        }

        // Write the migration marker
        try? Data().write(to: marker)
    }
}
