import Testing
import Foundation
import SwiftSoup
@testable import Preread

// MARK: - Helpers

/// Loads a raw HTML fixture from the Fixtures directory on disk.
private func loadFixture(_ name: String) throws -> String {
    let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    let fileURL = fixturesDir.appendingPathComponent("\(name).html")
    return try String(contentsOf: fileURL, encoding: .utf8)
}

// MARK: - Standard-mode tests

@Suite("Standard pipeline extraction")
struct StandardPipelineTests {

    // MARK: - BBC Sport

    @Test("BBC Sport: hero image re-injected, article text extracted")
    func bbcSport() async throws {
        let html = try loadFixture("bbc_sport")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.bbc.com/sport/football/articles/example")!
        )

        #expect(result.imageCount >= 1, "Hero image should be present")
        #expect(result.title.contains("Liverpool"))
        #expect(result.title.contains("Grok"))
        #expect(result.contentHTML.contains("sickening"))
        #expect(result.wordCount > 0, "Word count should be positive")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - GitHub README

    @Test("GitHub README: badges stripped, screenshots preserved")
    func githubReadme() async throws {
        let html = try loadFixture("github_readme")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://github.com/bostrot/wsl2-distro-manager")!
        )

        #expect(!result.contentHTML.contains("shields.io"), "Badge images should be stripped")
        #expect(result.contentHTML.lowercased().contains("screenshot"), "Content screenshots should survive")
        #expect(result.imageCount >= 2, "Screenshot images should be preserved")
        #expect(result.contentHTML.contains("WSL"))
        #expect(!result.contentHTML.contains("<script"))
    }

    // MARK: - Gizmodo

    @Test("Gizmodo: hero image re-injected, article content extracted")
    func gizmodoArticle() async throws {
        let html = try loadFixture("gizmodo_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://gizmodo.com/example")!
        )

        #expect(result.imageCount >= 1, "Hero image should be re-injected")
        #expect(result.title.contains("AI"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }

    // MARK: - The Verge

    @Test("The Verge: content extracted, no scripts or nav")
    func theVergeArticle() async throws {
        let html = try loadFixture("theverge_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.theverge.com/example")!
        )

        #expect(result.title.contains("Sony"))
        #expect(result.contentHTML.contains("PlayStation"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Cell Journal

    @Test("Cell journal: tables preserved, scientific content extracted")
    func cellJournal() async throws {
        let html = try loadFixture("cell_journal")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.cell.com/neuron/fulltext/example")!
        )

        #expect(result.contentHTML.contains("<table"), "Tables should be preserved")
        #expect(result.title.contains("neurons"))
        #expect(result.contentHTML.contains("DishBrain"))
        #expect(result.imageCount >= 5, "Scientific figures should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }

    // MARK: - Daily Mail

    @Test("Daily Mail: logo not injected as hero, sidebar thumbnails excluded, article images preserved")
    func dailymailArticle() async throws {
        let html = try loadFixture("dailymail_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.dailymail.co.uk/tvshowbiz/article-15627191/Rihanna-home-targeted-shooting-woman-arrested.html")!
        )

        #expect(result.title.contains("Rihanna"))
        #expect(result.contentHTML.contains("Beverly Hills"))
        #expect(!result.contentHTML.contains("DailyMail_Main.png"), "Site logo should not be injected as hero image")
        #expect(!result.contentHTML.contains("sitelogos"), "No site logo images should appear in content")
        #expect(!result.contentHTML.contains("106972263-0-image"), "Sidebar puff thumbnails should not be injected")
        #expect(!result.contentHTML.contains("106975501-0-image"), "Sidebar puff thumbnails should not be injected")
        #expect(result.imageCount >= 5, "Article photos should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Ars Technica

    @Test("Ars Technica: duplicate hero images deduplicated, article content extracted")
    func arstechnicaArticle() async throws {
        let html = try loadFixture("arstechnica_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://arstechnica.com/tech-policy/2026/03/binance-sues-wsj-over-report-sparking-government-probes-into-exchange/")!
        )

        #expect(result.title.contains("Binance"))
        #expect(result.contentHTML.contains("Wall Street Journal"))
        #expect(result.imageCount >= 1, "Hero image should be present")

        // The key check: Ars Technica puts two <img> siblings with different
        // dimension suffixes (e.g. -640x426 vs -1024x648) inside one <a>.
        // After deduplication, only the largest variant should remain.
        let contentDoc = try SwiftSoup.parseBodyFragment(result.contentHTML, "https://arstechnica.com")
        let heroImages = try contentDoc.select("img").array().filter { img in
            let src = (try? img.attr("src")) ?? ""
            return src.contains("GettyImages-2263087121")
        }
        #expect(heroImages.count == 1, "Duplicate hero images should be deduplicated to one")

        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Nintendo

    @Test("Nintendo: flag icon not used as hero, article image injected")
    func nintendoArticle() async throws {
        let html = try loadFixture("nintendo_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendo.com/us/whatsnew/mobile-news-wonder-flowers-arrive-for-a-super-mario-run-special-event/")!
        )

        #expect(result.title.contains("Super Mario Run"))
        #expect(result.contentHTML.contains("Wonder Flower"))
        #expect(!result.contentHTML.contains("FlagUsa"), "Flag icon should not be injected as hero image")
        #expect(result.contentHTML.contains("Super_Mario_Run_Wonder"), "Article hero image should be present")
        #expect(result.heroImageURL?.contains("Super_Mario_Run_Wonder") == true, "Hero URL should be the article image, not the flag")
        #expect(result.imageCount >= 1, "Article image should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Nintendo Life

    @Test("Nintendo Life: comment section stripped, article content extracted")
    func nintendoLifeArticle() async throws {
        let html = try loadFixture("nintendolife-boost-mode")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/features/community-which-switch-1-games-benefit-most-from-switch-2s-new-boost-mode")!
        )

        #expect(result.title.contains("Switch"))
        #expect(result.title.contains("Boost Mode"))
        // Article content should be extracted, not the comments section
        #expect(result.contentHTML.contains("Handheld Boost Mode"), "Article body should be present")
        #expect(!result.contentHTML.contains("avatar.jpg"), "User comment avatars should not be present")
        #expect(!result.contentHTML.contains("data-author"), "Comment metadata should not be present")
        #expect(result.imageCount >= 1, "Video thumbnail or article image should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - GQ

    @Test("GQ: Cloudinary srcset URLs with commas parsed correctly, images extracted")
    func gqArticle() async throws {
        let html = try loadFixture("gq_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.gq.com/story/best-golf-clothing-brands")!
        )

        #expect(result.title.contains("Golf"))
        #expect(result.contentHTML.contains("Polo"))
        // GQ uses Cloudinary URLs with commas in the path (e.g. w_640,c_limit).
        // The srcset parser must handle these without splitting the URL at the comma.
        #expect(result.imageCount >= 10, "Product images from Cloudinary srcset should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - TMZ

    @Test("TMZ: hero bar promo images skipped, correct article image used")
    func tmzArticle() async throws {
        let html = try loadFixture("tmz_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.tmz.com/2026/03/19/jessi-draper-jordan-ngatikaura-files-divorce/")!
        )

        #expect(result.title.contains("Ngatikaura"))
        #expect(result.contentHTML.contains("divorce"))
        #expect(result.imageCount >= 2, "Article images should be preserved")
        // The hero bar contains thumbnails for other articles (e.g. Taylor Frankie Paul).
        // These should NOT be re-injected as the hero image.
        #expect(!result.contentHTML.contains("49e7759df340449dac6c9472319fe480"),
                "Hero bar promo thumbnail from different article should not be injected")
        // The correct article image should be present
        #expect(result.contentHTML.contains("364fd81b76d04acc88216bf49fd45b4c"),
                "Actual article hero image should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }

    // MARK: - Perez Hilton

    @Test("Perez Hilton: theme decoration image not injected as hero, article image preserved")
    func perezHiltonArticle() async throws {
        let html = try loadFixture("perezhilton_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://perezhilton.com/taylor-frankie-paul-dropped-by-meta-facebook-instagram-after-the-bachelorette-domestic-violence/")!
        )

        #expect(result.title.contains("Taylor Frankie Paul"))
        #expect(result.contentHTML.contains("domestic violence"))
        // The site theme decoration (St. Patrick's Day background) should NOT be the hero
        #expect(!result.contentHTML.contains("feature-st-patrick"),
                "Theme decoration image should not be injected as hero")
        // The actual article image should be present
        #expect(result.contentHTML.contains("taylor-frankie-paul-dropped-by-meta-the-bachelorette"),
                "Actual article hero image should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }
}

// MARK: - Full-mode tests

@Suite("Full pipeline extraction")
struct FullPipelineTests {

    // MARK: - BBC Sport

    @Test("BBC Sport: scripts and navigation stripped, article content preserved")
    func bbcSport() async throws {
        let html = try loadFixture("bbc_sport")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.bbc.com/sport/football/articles/example")!
        )

        // Interactive and structural elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Liverpool"))
        #expect(result.cleanedHTML.contains("sickening"))
        #expect(result.cleanedHTML.contains("Grok"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        #expect(result.wordCount > 0, "Word count should be positive")
    }

    // MARK: - GitHub README

    @Test("GitHub README: interactive elements stripped, README content preserved")
    func githubReadme() async throws {
        let html = try loadFixture("github_readme")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://github.com/bostrot/wsl2-distro-manager")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("WSL"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        #expect(result.cleanedHTML.contains("<table"), "Tables should be preserved")
        #expect(result.cleanedHTML.contains("stylesheet"), "CSS should be preserved in full mode")
    }

    // MARK: - Gizmodo

    @Test("Gizmodo: interactive elements stripped, article content preserved")
    func gizmodoArticle() async throws {
        let html = try loadFixture("gizmodo_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://gizmodo.com/example")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("AI"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        #expect(result.cleanedHTML.contains("stylesheet"), "CSS should be preserved in full mode")
    }

    // MARK: - The Verge

    @Test("The Verge: interactive elements stripped, content and styles preserved")
    func theVergeArticle() async throws {
        let html = try loadFixture("theverge_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.theverge.com/games/891085/sony-dynamic-pricing-playstation-games")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<button"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
        #expect(!result.cleanedHTML.contains("<dialog"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("aria-hidden=\"true\""))

        // Content and page structure should be preserved
        #expect(result.cleanedHTML.contains("Sony"))
        #expect(result.cleanedHTML.contains("PlayStation"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        #expect(result.cleanedHTML.contains("stylesheet"), "CSS should be preserved in full mode")
    }

    // MARK: - Cell Journal

    @Test("Cell journal: tables and scientific content preserved, navigation stripped")
    func cellJournal() async throws {
        let html = try loadFixture("cell_journal")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.cell.com/neuron/fulltext/example")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<svg"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("<table"), "Tables should be preserved")
        #expect(result.cleanedHTML.contains("DishBrain"))
        #expect(result.cleanedHTML.contains("neurons"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        #expect(result.cleanedHTML.contains("stylesheet"), "CSS should be preserved in full mode")
    }

    // MARK: - Daily Mail

    @Test("Daily Mail: interactive elements stripped, article content preserved")
    func dailymailArticle() async throws {
        let html = try loadFixture("dailymail_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.dailymail.co.uk/tvshowbiz/article-15627191/Rihanna-home-targeted-shooting-woman-arrested.html")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<form"))
        #expect(!result.cleanedHTML.contains("<button"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Rihanna"))
        #expect(result.cleanedHTML.contains("Beverly Hills"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - Ars Technica

    @Test("Ars Technica: interactive elements stripped, article content preserved")
    func arstechnicaArticle() async throws {
        let html = try loadFixture("arstechnica_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://arstechnica.com/tech-policy/2026/03/binance-sues-wsj-over-report-sparking-government-probes-into-exchange/")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Binance"))
        #expect(result.cleanedHTML.contains("Wall Street Journal"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - Nintendo

    @Test("Nintendo: interactive elements stripped, article content preserved")
    func nintendoArticle() async throws {
        let html = try loadFixture("nintendo_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendo.com/us/whatsnew/mobile-news-wonder-flowers-arrive-for-a-super-mario-run-special-event/")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Super Mario Run"))
        #expect(result.cleanedHTML.contains("Wonder Flower"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - Nintendo Life

    @Test("Nintendo Life: comment section stripped, article content preserved")
    func nintendoLifeArticle() async throws {
        let html = try loadFixture("nintendolife-boost-mode")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/features/community-which-switch-1-games-benefit-most-from-switch-2s-new-boost-mode")!
        )

        // Interactive and comment elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
        #expect(!result.cleanedHTML.contains("data-author"), "Comment metadata should not be present")

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Handheld Boost Mode"))
        #expect(result.cleanedHTML.contains("Switch 2"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - GQ

    @Test("GQ: interactive elements stripped, article content preserved")
    func gqArticle() async throws {
        let html = try loadFixture("gq_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.gq.com/story/best-golf-clothing-brands")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Golf"))
        #expect(result.cleanedHTML.contains("Polo"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - TMZ

    @Test("TMZ: hero bar promo images skipped in thumbnail selection")
    func tmzArticle() async throws {
        let html = try loadFixture("tmz_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.tmz.com/2026/03/19/jessi-draper-jordan-ngatikaura-files-divorce/")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("divorce"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")

        // Hero image should be the article's own image, not a hero bar promo
        if let hero = result.heroImageURL {
            #expect(!hero.contains("49e7759df340449dac6c9472319fe480"),
                    "Hero bar promo thumbnail should not be selected as hero image")
        }
    }

    // MARK: - Perez Hilton

    @Test("Perez Hilton: theme decoration stripped, article content preserved")
    func perezHiltonArticle() async throws {
        let html = try loadFixture("perezhilton_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://perezhilton.com/taylor-frankie-paul-dropped-by-meta-facebook-instagram-after-the-bachelorette-domestic-violence/")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("domestic violence"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")

        // Theme decoration should not be the hero image
        if let hero = result.heroImageURL {
            #expect(!hero.contains("feature-st-patrick"),
                    "Theme decoration image should not be selected as hero image")
        }
    }
}
