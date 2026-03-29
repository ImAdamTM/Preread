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
            pageURL: URL(string: "https://arstechnica.com/science/2026/03/getting-formal-about-quantum-mechanics-lack-of-causality/")!
        )

        #expect(result.title.contains("Causality"))
        #expect(result.contentHTML.contains("quantum"))
        #expect(result.imageCount >= 1, "Hero image should be present")

        // The key check: Ars Technica puts two <img> siblings inside one <a> —
        // a small thumbnail (with -WxH suffix) and the full-size image (no suffix).
        // After deduplication, only the largest variant should remain.
        let contentDoc = try SwiftSoup.parseBodyFragment(result.contentHTML, "https://arstechnica.com")
        let heroImages = try contentDoc.select("img").array().filter { img in
            let src = (try? img.attr("src")) ?? ""
            return src.contains("ligo-laser")
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

    // MARK: - IGN

    @Test("IGN: placeholder images recovered from parent anchors, article content extracted")
    func ignArticle() async throws {
        let html = try loadFixture("ign_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.ign.com/articles/resident-evils-big-nintendo-swing-and-a-miss")!
        )

        #expect(result.title.contains("Resident Evil"))
        #expect(result.contentHTML.contains("Game Boy Color"))
        #expect(result.contentHTML.contains("GameCube"))
        // IGN uses data:image/gif placeholder src with real URLs on parent <a> tags.
        // The pipeline should recover these placeholder images.
        #expect(result.imageCount >= 3, "Placeholder images should be recovered from parent anchor hrefs")
        #expect(result.contentHTML.contains("ignimgs.com"), "Recovered image URLs should point to IGN's CDN")
        #expect(!result.contentHTML.contains("data:image/gif"), "Placeholder data URIs should be replaced")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
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

    // MARK: - Daily Mail (factbox)

    @Test("Daily Mail factbox: article body and embedded statement both extracted")
    func dailymailFactbox() async throws {
        let html = try loadFixture("dailymail_factbox")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.dailymail.co.uk/tvshowbiz/article-15677151/Cruz-Beckham-sings-song-breaking-mamas-heart-takes-aim-Brooklyn-brutal-lyrics.html")!
        )

        #expect(result.title.contains("Cruz Beckham"))
        // Main article body should be extracted
        #expect(result.contentHTML.contains("Loneliest Boy"), "Song title should appear in extracted content")
        #expect(result.contentHTML.contains("The Breakers"), "Band name should appear in extracted content")
        // Brooklyn's embedded statement (inside a factbox/custom element) should also be extracted
        #expect(result.contentHTML.contains("I do not want to reconcile with my family"),
                "Brooklyn's statement from the factbox should be included")
        #expect(result.imageCount >= 3, "Article photos should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Squarespace blog

    @Test("Squarespace: og:image used as hero for text-only article, no navigation images")
    func squarespaceBlog() async throws {
        let html = try loadFixture("squarespace_blog")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.squarespace.com/blog/how-to-start-a-tutoring-business")!
        )

        #expect(result.title.contains("Tutoring"))
        #expect(result.contentHTML.contains("personalized instruction"))
        // No <img> heroes in the body, but og:image provides a hero
        #expect(result.imageCount == 1, "og:image should be injected as hero")
        #expect(result.heroImageURL?.contains("squarespace") == true, "Hero should come from og:image")
        #expect(result.heroImageURL?.hasPrefix("https://") == true, "og:image http URL should be upgraded to https")
        #expect(!result.contentHTML.contains("site-navigation"), "Navigation images must not leak into content")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }

    // MARK: - NPR

    @Test("NPR: picture elements unwrapped, caption toggles stripped, images preserved")
    func nprArticle() async throws {
        let html = try loadFixture("npr_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.npr.org/2026/03/27/nx-s1-5763475/iran-war-talks-rubio-markets-g7")!
        )

        #expect(result.title.contains("Rubio"))
        #expect(result.imageCount >= 1, "Images from <picture> elements should survive")
        #expect(result.contentHTML.contains("G7"))
        #expect(!result.contentHTML.contains("hide caption"), "Caption toggle text should be stripped")
        #expect(!result.contentHTML.contains("toggle caption"), "Caption toggle text should be stripped")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - CNBC

    @Test("CNBC: og:image used as hero when no <img> hero found, author thumbnail filtered")
    func cnbcArticle() async throws {
        let html = try loadFixture("cnbc_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnbc.com/2026/03/26/inifiniti-qx65-suv-nissan.html")!
        )

        #expect(result.title.contains("Infiniti") || result.title.contains("SUV"))
        #expect(result.imageCount >= 1, "og:image should be injected as hero")
        #expect(result.heroImageURL != nil, "og:image should provide heroImageURL")
        // The og:image should be the CNBC article image, not the author thumbnail
        #expect(result.heroImageURL?.contains("cnbcfm.com") == true, "Hero should be from og:image")
        #expect(!result.contentHTML.contains("w=60&h=60"), "Author thumbnail should not be hero")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - CNBC Special Report

    @Test("CNBC Special Report: banner header filtered, article image used as hero")
    func cnbcSpecialReport() async throws {
        let html = try loadFixture("cnbc_special_report")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnbc.com/2026/03/27/iran-war-wipes-out-100-billion-from-luxury-stocks.html")!
        )

        #expect(result.title.contains("luxury") || result.title.contains("billion"))
        #expect(result.imageCount >= 1, "Article image should be present")
        // The HEADER_BKGD banner should be filtered by chromeWords
        #expect(!result.contentHTML.contains("HEADER_BKGD"), "Banner background should be filtered")
        #expect(!result.contentHTML.contains("HEADER_LOGO"), "Banner logo should be filtered")
        #expect(result.heroImageURL?.contains("cnbcfm.com") == true, "Hero should be the article image")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
    }

    // MARK: - HackerNoon (Next.js __NEXT_DATA__)

    @Test("HackerNoon: article extracted from __NEXT_DATA__ JSON")
    func hackernoonArticle() async throws {
        let html = try loadFixture("hackernoon_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://hackernoon.com/backward-compatibility-in-go-what-to-know")!
        )

        #expect(result.title.contains("Backward Compatibility"))
        #expect(result.contentHTML.contains("Go 1.21"))
        #expect(result.contentHTML.contains("GODEBUG"))
        #expect(result.wordCount > 100, "Article should have substantial content")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Mashable

    @Test("Mashable: author headshot not used as hero, article image injected")
    func mashableArticle() async throws {
        let html = try loadFixture("mashable_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://mashable.com/article/march-28-best-amazon-spring-sale-pokemon-tcg-perfect-order-booster-deal")!
        )

        #expect(result.imageCount >= 1, "Article image should be present")
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("/authors/"), "Author headshot should not be used as hero")
        #expect(result.contentHTML.contains("Pokémon") || result.contentHTML.contains("Pokemon"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Sky & Telescope

    @Test("Sky & Telescope: comment icon not used as hero, article images preserved")
    func skyTelescopeArticle() async throws {
        let html = try loadFixture("skytelescope_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://skyandtelescope.org/astronomy-news/comet-break-up-caught-in-action/")!
        )

        #expect(result.title.contains("Comet"))
        #expect(result.contentHTML.contains("Hubble"))
        #expect(result.contentHTML.contains("ATLAS"))
        #expect(result.imageCount >= 2, "Article images should be preserved")
        #expect(!result.contentHTML.contains("comment.png"), "Comment icon should not be in article content")
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("comment"), "Comment icon should not be used as hero")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - CNET

    @Test("CNET: duplicate author headshots removed, article content preserved")
    func cnetArticle() async throws {
        let html = try loadFixture("cnet_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnet.com/tech/gaming/todays-nyt-connections-sports-edition-hints-and-answers-for-march-29-552/")!
        )

        #expect(result.title.contains("Connections"))
        #expect(result.imageCount == 2, "Should have exactly 2 images (hero + article photo), not duplicate headshots")
        #expect(!result.contentHTML.contains("Headshot of"), "Author headshots should be stripped")
        #expect(result.contentHTML.contains("Connections: Sports Edition"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - TechCrunch

    @Test("TechCrunch: headshot filtered from hero, article image used instead")
    func techcrunchArticle() async throws {
        let html = try loadFixture("techcrunch_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://techcrunch.com/2026/03/28/what-will-power-the-grid-in-2035-the-race-is-wide-open/")!
        )

        #expect(result.title.contains("grid") || result.title.contains("power"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("headshot"), "Author headshot should not be used as hero")
        #expect((result.heroImageURL ?? "").contains("electrical-grid"), "Real article image should be hero")
        #expect(result.contentHTML.contains("fusion") || result.contentHTML.contains("Fusion"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
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
            pageURL: URL(string: "https://arstechnica.com/science/2026/03/getting-formal-about-quantum-mechanics-lack-of-causality/")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("quantum"))
        #expect(result.cleanedHTML.contains("causal order"))
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

    // MARK: - IGN

    @Test("IGN: placeholder images recovered, interactive elements stripped")
    func ignArticle() async throws {
        let html = try loadFixture("ign_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.ign.com/articles/resident-evils-big-nintendo-swing-and-a-miss")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Resident Evil"))
        #expect(result.cleanedHTML.contains("Game Boy Color"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        // Placeholder images should be recovered with real URLs
        #expect(result.cleanedHTML.contains("ignimgs.com"), "Recovered image URLs should point to IGN's CDN")
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

    // MARK: - Daily Mail (factbox)

    @Test("Daily Mail factbox: interactive elements stripped, article and statement preserved")
    func dailymailFactbox() async throws {
        let html = try loadFixture("dailymail_factbox")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.dailymail.co.uk/tvshowbiz/article-15677151/Cruz-Beckham-sings-song-breaking-mamas-heart-takes-aim-Brooklyn-brutal-lyrics.html")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<form"))
        #expect(!result.cleanedHTML.contains("<button"))

        // Article content should be preserved
        #expect(result.cleanedHTML.contains("Cruz Beckham"))
        #expect(result.cleanedHTML.contains("Loneliest Boy"))
        // Brooklyn's statement should also be preserved
        #expect(result.cleanedHTML.contains("I do not want to reconcile with my family"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - Squarespace blog

    @Test("Squarespace: navigation and header stripped, article content preserved")
    func squarespaceBlog() async throws {
        let html = try loadFixture("squarespace_blog")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.squarespace.com/blog/how-to-start-a-tutoring-business")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
        // Article content should be preserved
        #expect(result.cleanedHTML.contains("personalized instruction"))
        #expect(result.cleanedHTML.contains("Tutoring"))
    }

    // MARK: - NPR

    @Test("NPR: picture elements unwrapped, caption toggles stripped, images preserved")
    func nprArticle() async throws {
        let html = try loadFixture("npr_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.npr.org/2026/03/27/nx-s1-5763475/iran-war-talks-rubio-markets-g7")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Caption toggle text should be stripped
        #expect(!result.cleanedHTML.contains("hide caption"), "Caption toggle text should be stripped")
        #expect(!result.cleanedHTML.contains("toggle caption"), "Caption toggle text should be stripped")

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Rubio"))
        #expect(result.cleanedHTML.contains("G7"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
    }

    // MARK: - CNBC

    @Test("CNBC: og:image used as hero fallback, interactive elements stripped")
    func cnbcArticle() async throws {
        let html = try loadFixture("cnbc_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnbc.com/2026/03/26/inifiniti-qx65-suv-nissan.html")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // og:image should be picked up as hero for thumbnail backfill
        #expect(result.heroImageURL != nil, "og:image should provide heroImageURL")
        #expect(result.heroImageURL?.contains("cnbcfm.com") == true, "Hero should be from og:image")

        // Content should be preserved
        #expect(result.cleanedHTML.contains("Infiniti") || result.cleanedHTML.contains("Nissan"))
    }

    // MARK: - CNBC Special Report

    @Test("CNBC Special Report: banner header filtered, interactive elements stripped")
    func cnbcSpecialReport() async throws {
        let html = try loadFixture("cnbc_special_report")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnbc.com/2026/03/27/iran-war-wipes-out-100-billion-from-luxury-stocks.html")!
        )

        // Interactive elements should be stripped
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        // Hero should be the article image, not the banner
        #expect(result.heroImageURL != nil, "Article image should be used as hero")
        #expect(result.heroImageURL?.contains("HEADER_BKGD") != true, "Banner should not be hero")

        // Content should be preserved
        #expect(result.cleanedHTML.contains("luxury") || result.cleanedHTML.contains("billion"))
    }

    // MARK: - HackerNoon (Next.js __NEXT_DATA__)

    @Test("HackerNoon: article content injected from __NEXT_DATA__ JSON")
    func hackernoonArticle() async throws {
        let html = try loadFixture("hackernoon_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://hackernoon.com/backward-compatibility-in-go-what-to-know")!
        )

        #expect(result.cleanedHTML.contains("Go 1.21"))
        #expect(result.cleanedHTML.contains("GODEBUG"))
        #expect(result.wordCount > 100, "Article should have substantial content")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Mashable

    @Test("Mashable: author headshot filtered from hero, article content preserved")
    func mashableArticle() async throws {
        let html = try loadFixture("mashable_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://mashable.com/article/march-28-best-amazon-spring-sale-pokemon-tcg-perfect-order-booster-deal")!
        )

        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("/authors/"), "Author headshot should not be used as hero")
        #expect(result.cleanedHTML.contains("Pokémon") || result.cleanedHTML.contains("Pokemon"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Sky & Telescope

    @Test("Sky & Telescope: comment icon filtered from hero, article content preserved")
    func skyTelescopeArticle() async throws {
        let html = try loadFixture("skytelescope_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://skyandtelescope.org/astronomy-news/comet-break-up-caught-in-action/")!
        )

        #expect(result.cleanedHTML.contains("Comet"))
        #expect(result.cleanedHTML.contains("Hubble"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("comment"), "Comment icon should not be used as hero")
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - CNET

    @Test("CNET: scripts and navigation stripped, article content preserved")
    func cnetArticle() async throws {
        let html = try loadFixture("cnet_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.cnet.com/tech/gaming/todays-nyt-connections-sports-edition-hints-and-answers-for-march-29-552/")!
        )

        #expect(result.cleanedHTML.contains("Connections: Sports Edition"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - TechCrunch

    @Test("TechCrunch: headshot filtered from hero, article content preserved")
    func techcrunchArticle() async throws {
        let html = try loadFixture("techcrunch_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://techcrunch.com/2026/03/28/what-will-power-the-grid-in-2035-the-race-is-wide-open/")!
        )

        #expect(result.cleanedHTML.contains("fusion") || result.cleanedHTML.contains("Fusion"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("headshot"), "Author headshot should not be used as hero")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }
}

// MARK: - RSS content fallback pipeline tests

@Suite("RSS content fallback pipeline")
struct RSSFallbackPipelineTests {

    @Test("Strips scripts and interactive elements from RSS HTML")
    func stripsUnsafeElements() async throws {
        let rssHTML = """
        <p>Article text here with <strong>bold</strong> content that is long enough to pass validation.</p>
        <script>alert('xss')</script>
        <button>Subscribe</button>
        <nav><a href="/">Home</a></nav>
        <form><input type="text" /></form>
        <p>More article text with important information about the topic being discussed.</p>
        """
        let result = try await PageCacheService.shared.cleanRSSContent(
            html: rssHTML,
            baseURL: URL(string: "https://example.com/article")!
        )
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<button"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<form"))
        #expect(!result.contentHTML.contains("<input"))
        #expect(result.contentHTML.contains("Article text here"))
        #expect(result.contentHTML.contains("More article text"))
        #expect(result.wordCount > 0)
    }

    @Test("Preserves images and extracts hero image URL")
    func preservesImages() async throws {
        let rssHTML = """
        <p>Article intro paragraph with enough text to pass validation easily without issues.</p>
        <img src="https://example.com/hero.jpg" />
        <p>More article content after the image with sufficient length to be meaningful.</p>
        """
        let result = try await PageCacheService.shared.cleanRSSContent(
            html: rssHTML,
            baseURL: URL(string: "https://example.com/article")!
        )
        #expect(result.imageCount >= 1)
        #expect(result.heroImageURL == "https://example.com/hero.jpg")
    }

    @Test("Rejects content that is too short")
    func rejectsShortContent() async throws {
        let rssHTML = "<p>Short</p>"
        do {
            _ = try await PageCacheService.shared.cleanRSSContent(
                html: rssHTML,
                baseURL: URL(string: "https://example.com/article")!
            )
            Issue.record("Should have thrown for short content")
        } catch {
            // Expected — RSS content was too short
        }
    }

    @Test("Preserves text formatting: bold, italic, links, lists")
    func preservesFormatting() async throws {
        let rssHTML = """
        <p>This is a <strong>bold</strong> and <em>italic</em> test with a <a href="https://example.com">link</a>.</p>
        <ul><li>First item in the list</li><li>Second item in the list</li></ul>
        <blockquote>A notable quote from the article source material.</blockquote>
        """
        let result = try await PageCacheService.shared.cleanRSSContent(
            html: rssHTML,
            baseURL: URL(string: "https://example.com/article")!
        )
        #expect(result.contentHTML.contains("<strong>bold</strong>"))
        #expect(result.contentHTML.contains("<em>italic</em>"))
        #expect(result.contentHTML.contains("<a"))
        #expect(result.contentHTML.contains("<li>"))
        #expect(result.contentHTML.contains("<blockquote>"))
    }

    @Test("Adds paragraph breaks to flat text without block-level HTML")
    func addsParagraphBreaks() async throws {
        // Flat text with no <p>, <br>, or other block elements — like Crunchyroll's RSS
        let flatHTML = "First sentence here. Second sentence follows closely. Third one wraps up the intro. Fourth starts a new topic entirely. Fifth provides more details on it. Sixth is the final thought. Source: Official website"
        let result = try await PageCacheService.shared.cleanRSSContent(
            html: flatHTML,
            baseURL: URL(string: "https://example.com/article")!
        )
        // Should contain <p> tags (paragraph structure was added)
        #expect(result.contentHTML.contains("<p>"))
        // Should have multiple paragraphs (not one giant block)
        let pCount = result.contentHTML.components(separatedBy: "<p>").count - 1
        #expect(pCount >= 2, "Should split flat text into multiple paragraphs, got \(pCount)")
    }

    @Test("Preserves existing paragraph structure without modification")
    func preservesExistingParagraphs() async throws {
        let structuredHTML = "<p>First paragraph with enough content to pass the minimum length threshold for this test.</p><p>Second paragraph also with sufficient content to meet the requirements.</p>"
        let result = try await PageCacheService.shared.cleanRSSContent(
            html: structuredHTML,
            baseURL: URL(string: "https://example.com/article")!
        )
        // Should NOT double-wrap in <p> tags
        #expect(!result.contentHTML.contains("<p><p>"))
        // Should still have the original paragraphs
        #expect(result.contentHTML.contains("First paragraph"))
        #expect(result.contentHTML.contains("Second paragraph"))
    }
}
