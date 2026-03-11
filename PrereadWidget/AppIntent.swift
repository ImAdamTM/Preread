import WidgetKit
import AppIntents
import GRDB

// MARK: - Widget configuration intent

struct SelectSourceIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Source"
    static var description: IntentDescription = "Choose which source to show articles from."

    @Parameter(title: "Source")
    var source: WidgetSourceEntity?
}

// MARK: - Source entity for widget configuration picker

struct WidgetSourceEntity: AppEntity {
    static var defaultQuery = WidgetSourceEntityQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Source"

    var id: String  // UUID string
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct WidgetSourceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetSourceEntity] {
        guard let provider = WidgetDataProvider() else { return [] }
        let sources = provider.fetchSources()
        return sources
            .filter { identifiers.contains($0.id.uuidString) }
            .map { WidgetSourceEntity(id: $0.id.uuidString, title: $0.title) }
    }

    func suggestedEntities() async throws -> [WidgetSourceEntity] {
        guard let provider = WidgetDataProvider() else { return [] }
        return provider.fetchSources()
            .map { WidgetSourceEntity(id: $0.id.uuidString, title: $0.title) }
    }

    func defaultResult() async -> WidgetSourceEntity? {
        nil  // nil means "All Sources"
    }
}
