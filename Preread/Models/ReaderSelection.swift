import Foundation

struct ReaderSelection: Identifiable {
    let id = UUID()
    let article: Article
    let source: Source
}
