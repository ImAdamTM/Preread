import AppIntents

struct OpenSourceIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Source"
    static var description: IntentDescription = "Opens a source in Preread"
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Source ID")
    var sourceID: String

    func perform() async throws -> some IntentResult {
        // Deep link handling is done via URL — this intent opens the app
        // and the URL handler in PrereadApp takes care of navigation.
        return .result()
    }
}
