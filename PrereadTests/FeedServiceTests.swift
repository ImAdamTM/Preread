import Testing
import Foundation
@testable import Preread

struct FeedServiceTests {
    let service = FeedService.shared

    // MARK: - Discovery from real websites

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_theVerge() async throws {
        let feed = try await service.discoverFeed(from: URL(string: "https://www.theverge.com")!)
        assertValidFeed(feed)
    }

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_arsTechnica() async throws {
        let feed = try await service.discoverFeed(from: URL(string: "https://arstechnica.com")!)
        assertValidFeed(feed)
    }

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_kottke() async throws {
        let feed = try await service.discoverFeed(from: URL(string: "https://kottke.org")!)
        assertValidFeed(feed)
    }

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_platformer() async throws {
        let feed = try await service.discoverFeed(from: URL(string: "https://www.platformer.news")!)
        assertValidFeed(feed)
    }

    // MARK: - No feed found

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_google_throwsNoFeedFound() async {
        await #expect(throws: FeedError.self) {
            try await service.discoverFeed(from: URL(string: "https://google.com")!)
        }
    }

    // MARK: - Direct RSS parsing

    @Test(.timeLimit(.minutes(1)))
    func parseFeed_rss() async throws {
        // RSS feed
        let feed = try await service.parseFeed(from: URL(string: "https://www.theverge.com/rss/index.xml")!)
        #expect(!feed.title.isEmpty)
        #expect(!feed.items.isEmpty)
        for item in feed.items {
            #expect(!item.title.isEmpty)
            #expect(item.url.scheme == "http" || item.url.scheme == "https")
        }
    }

    // MARK: - Direct Atom parsing

    @Test(.timeLimit(.minutes(1)))
    func parseFeed_atom() async throws {
        // kottke.org serves Atom
        let feed = try await service.parseFeed(from: URL(string: "https://feeds.kottke.org/main")!)
        #expect(!feed.title.isEmpty)
        #expect(!feed.items.isEmpty)
        for item in feed.items {
            #expect(!item.title.isEmpty)
            #expect(item.url.scheme == "http" || item.url.scheme == "https")
        }
    }

    // MARK: - Redirect following

    @Test(.timeLimit(.minutes(1)))
    func discoverFeed_followsRedirects() async throws {
        // theverge.com (no www) redirects to www.theverge.com
        let feed = try await service.discoverFeed(from: URL(string: "https://theverge.com")!)
        assertValidFeed(feed)
    }

    // MARK: - Helper

    private func assertValidFeed(_ feed: DiscoveredFeed) {
        #expect(feed.feedURL.scheme == "http" || feed.feedURL.scheme == "https")
        #expect(!feed.title.isEmpty)
        #expect(!feed.items.isEmpty)
        for item in feed.items {
            #expect(!item.title.isEmpty)
            #expect(item.url.scheme == "http" || item.url.scheme == "https")
        }
    }
}
