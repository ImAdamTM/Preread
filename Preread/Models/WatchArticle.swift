import Foundation

/// Lightweight article model for Watch Connectivity transfer.
/// Shared between the main app (serialization) and watch app/widget (deserialization).
/// No images — watch accessory widgets are text-only / monochrome.
struct WatchArticle: Codable, Identifiable {
    let id: UUID
    let title: String
    let sourceName: String
    let publishedAt: Date?
}
