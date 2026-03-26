import WidgetKit
import AppIntents
import GRDB

// MARK: - Widget configuration intent

struct SelectSourceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Source"
    static var description: IntentDescription = "Choose which source to show articles from."

    @Parameter(title: "Source")
    var source: WidgetSourceEntity
}

// MARK: - Source entity for widget configuration picker

struct WidgetSourceEntity: AppEntity {
    static var defaultQuery = WidgetSourceEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Source"

    /// Sentinel entity representing "all sources" (no filter).
    static let allSourcesID = "all"
    static let allSources = WidgetSourceEntity(id: allSourcesID, title: "All Sources")

    var id: String  // UUID string or "all"
    var title: String

    var isAllSources: Bool { id == Self.allSourcesID }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct WidgetSourceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
        guard let provider = WidgetDataProvider() else {
            // Still return "All Sources" if requested even without DB
            return identifiers.contains(WidgetSourceEntity.allSourcesID)
                ? [.allSources] : []
        }
        var results: [WidgetSourceEntity] = []
        if identifiers.contains(WidgetSourceEntity.allSourcesID) {
            results.append(.allSources)
        }
        let sources = provider.fetchSources()
        results += sources
            .filter { identifiers.contains($0.id.uuidString) }
            .map { WidgetSourceEntity(id: $0.id.uuidString, title: $0.title) }
        return results
    }

    func suggestedEntities() async throws -> [WidgetSourceEntity] {
        guard let provider = WidgetDataProvider() else { return [.allSources] }
        var results: [WidgetSourceEntity] = [.allSources]
        results += provider.fetchSources()
            .map { WidgetSourceEntity(id: $0.id.uuidString, title: $0.title) }
        return results
    }

    func defaultResult() async -> WidgetSourceEntity? {
        .allSources
    }
}
