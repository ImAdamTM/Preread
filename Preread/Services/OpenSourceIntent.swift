import AppIntents
import GRDB
import UIKit

// MARK: - Source entity for Shortcuts

struct SourceEntity: AppEntity {
    static var defaultQuery = SourceEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Source"

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        let faviconPath = ContainerPaths.sourcesBaseURL
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("favicon.png")
        let image: DisplayRepresentation.Image? = {
            guard let data = try? Data(contentsOf: faviconPath), !data.isEmpty else { return nil }
            return DisplayRepresentation.Image(data: data)
        }()
        return DisplayRepresentation(title: "\(title)", image: image)
    }
}

struct SourceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SourceEntity] {
        let sources = try await DatabaseManager.shared.dbPool.read { db in
            try Source.fetchAll(db)
        }
        return sources
            .filter { identifiers.contains($0.id.uuidString) }
            .map { SourceEntity(id: $0.id.uuidString, title: $0.title) }
    }

    func suggestedEntities() async throws -> [SourceEntity] {
        let sources = try await DatabaseManager.shared.dbPool.read { db in
            try Source.order(Column("sortOrder")).fetchAll(db)
        }
        return sources.map { SourceEntity(id: $0.id.uuidString, title: $0.title) }
    }
}

// MARK: - Open source intent

struct OpenSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Source"
    static var description: IntentDescription = "Opens a source in Preread"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Source")
    var source: SourceEntity

    func perform() async throws -> some IntentResult {
        let sourceID = source.id
        await MainActor.run {
            guard let url = URL(string: "preread://source/\(sourceID)") else { return }
            UIApplication.shared.open(url)
        }
        return .result()
    }
}

// MARK: - App shortcuts provider

struct PrereadShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSourceIntent(),
            phrases: [
                "Open \(\.$source) in \(.applicationName)",
                "Read \(\.$source) in \(.applicationName)"
            ],
            shortTitle: "Open Source",
            systemImageName: "square.stack.3d.down.right.fill"
        )
    }
}
