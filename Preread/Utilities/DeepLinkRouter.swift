import SwiftUI

/// Handles `preread://` deep links for source and article navigation.
///
/// Supported URLs:
/// - `preread://source/{uuid}` — opens that source's article list
/// - `preread://article/{uuid}` — opens the article in the reader
/// - `preread://saved` — navigates to the Saved Articles view
/// - `preread://add?url={encoded-url}` — opens Add Source sheet with URL pre-filled
/// - No ID / invalid ID — stays on current screen (silent failure)
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var pendingSourceID: UUID?
    @Published var pendingArticleID: UUID?
    @Published var pendingSavedNavigation = false
    @Published var pendingAddURL: String?

    /// Parses a `preread://` URL and sets the appropriate pending navigation.
    func handle(_ url: URL) {
        guard url.scheme == "preread" else { return }

        switch url.host {
        case "source":
            guard let id = extractUUID(from: url) else { return }
            pendingSourceID = id

        case "article":
            guard let id = extractUUID(from: url) else { return }
            pendingArticleID = id

        case "saved":
            pendingSavedNavigation = true

        case "add":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  !urlParam.isEmpty else { return }
            pendingAddURL = urlParam

        default:
            // Unknown host or no host — stay on current screen
            break
        }
    }

    // MARK: - Private

    private func extractUUID(from url: URL) -> UUID? {
        guard let idString = url.pathComponents.last,
              let uuid = UUID(uuidString: idString) else { return nil }
        return uuid
    }
}
