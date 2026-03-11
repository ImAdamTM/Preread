import SwiftUI

/// Manages the article currently shown in the iPad detail column.
/// On compact size class (iPhone), this object is unused — sheets handle presentation.
@MainActor
final class ArticleDetailCoordinator: ObservableObject {
    static let shared = ArticleDetailCoordinator()

    /// Whether the app is running in split-view mode (iPad).
    /// Set by ContentView when it detects a regular size class.
    @Published var isSplitView = false

    /// The article + source currently shown in the detail pane.
    /// Setting this to nil shows the empty placeholder.
    @Published var selection: ReaderSelection?

    /// Clears the detail pane (e.g. when user taps the close button in detail mode).
    func clearSelection() {
        selection = nil
    }
}
