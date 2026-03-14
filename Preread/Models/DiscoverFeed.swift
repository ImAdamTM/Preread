import Foundation

/// A feed entry from the bundled discover directory.
/// In-memory only — not stored in the database.
struct DiscoverFeed: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let feedURL: String
    let siteURL: String?
    let description: String
    let category: String
    let country: String?
    let tags: [String]
}
