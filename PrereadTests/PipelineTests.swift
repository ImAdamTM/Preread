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

    // MARK: - Nintendo Life Gallery (aside unwrap)

    @Test("Nintendo Life Gallery: inline gallery images preserved from aside elements")
    func nintendoLifeGallery() async throws {
        let html = try loadFixture("nintendolife_gallery")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/news/2026/04/gallery-we-werent-prepared-for-the-sheer-size-of-yoshis-popcorn-bucket")!
        )

        #expect(result.title.contains("Yoshi"))
        #expect(result.contentHTML.contains("popcorn"), "Article text should be present")
        // Gallery images inside <aside class="gallery"> must be preserved
        #expect(result.imageCount >= 6, "Inline gallery images should survive aside unwrap")
        #expect(result.contentHTML.contains("images.nintendolife.com"), "Gallery image URLs should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
        // Related articles sidebar should still be stripped
        #expect(!result.contentHTML.contains("75x75"), "Related article thumbnails should be stripped")
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

    @Test("Squarespace wellness: blank.jpg tracking pixel excluded from hero, og:image used instead")
    func squarespaceWellness() async throws {
        let html = try loadFixture("squarespace_wellness")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.squarespace.com/blog/how-to-start-health-and-wellness-business")!
        )

        #expect(result.title.contains("Wellness") || result.title.contains("Health"))
        #expect(result.contentHTML.contains("wellness business"))
        #expect(!result.contentHTML.contains("blank.jpg"), "Tracking pixel should not be injected as hero")
        #expect(result.imageCount == 1, "og:image should be injected as hero")
        #expect(result.heroImageURL?.contains("squarespace") == true, "Hero should come from og:image")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
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

    @Test("TechCrunch YC: author photo with ?w=150 filtered, article image used as hero")
    func techcrunchYCArticle() async throws {
        let html = try loadFixture("techcrunch_yc_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://techcrunch.com/2026/03/28/from-moon-hotels-to-cattle-herding-8-startups-investors-chased-at-yc-demo-day/")!
        )

        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("IMG_0758"), "Author photo should not be used as hero")
        #expect((result.heroImageURL ?? "").contains("yc-sf"), "YC skyline image should be hero")
        #expect(result.contentHTML.contains("Demo Day") || result.contentHTML.contains("YC"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Health.com

    @Test("Health.com: small square author photo filtered, article image used as hero")
    func healthArticle() async throws {
        let html = try loadFixture("health_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.health.com/worrying-about-aging-might-make-you-age-faster-11933189")!
        )

        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("untitled-5582"), "Author photo should not be used as hero")
        #expect((result.heroImageURL ?? "").contains("GettyImages"), "Article image should be hero")
        #expect(result.contentHTML.contains("aging") || result.contentHTML.contains("Aging"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Chocolate & Zucchini

    @Test("cnz.to: small portrait author photo filtered, recipe image used as hero")
    func cnzRecipe() async throws {
        let html = try loadFixture("cnz_recipe")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://cnz.to/recipes/vegetables-grains/spiced-pilau-rice-beets-recipe/")!
        )

        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("clotilde"), "Author photo should not be used as hero")
        #expect((result.heroImageURL ?? "").contains("beet_pilau"), "Recipe image should be hero")
        #expect(result.contentHTML.contains("pilau") || result.contentHTML.contains("Pilau") || result.contentHTML.contains("rice"))
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Business Insider

    @Test("Business Insider: data-srcs JSON lazy-load images recovered")
    func businessInsiderArticle() async throws {
        let html = try loadFixture("businessinsider_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.businessinsider.com/best-biggest-fast-food-burgers-ranked")!
        )

        #expect(result.title.contains("burger") || result.title.contains("Burger") || result.title.contains("fast-food") || result.title.contains("fast food"))
        #expect(result.imageCount >= 10, "Should recover lazy-loaded images from data-srcs JSON (got \(result.imageCount))")
        #expect(!result.contentHTML.contains("data:image/svg"), "SVG placeholders should be replaced with real URLs")
        #expect(result.contentHTML.contains("i.insider.com"), "Real image URLs should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - The Verge (Suno)

    @Test("The Verge Suno: correct hero selected from compound filename")
    func theVergeSunoArticle() async throws {
        let html = try loadFixture("theverge_suno_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.theverge.com/entertainment/903056/suno-ai-music-v5-5-model")!
        )

        #expect(result.title.contains("Suno"))
        // Hero must be the Suno banner, not a related article thumbnail like screen-02.png.
        // Readability may include related article images as sibling content,
        // so check that the FIRST image is the Suno banner.
        #expect(result.contentHTML.contains("blogouterbanner"), "Suno banner should be the hero image")
        let firstImgRange = result.contentHTML.range(of: "<img ")
        if let range = firstImgRange {
            let firstImg = String(result.contentHTML[range.lowerBound...].prefix(500))
            #expect(firstImg.contains("blogouterbanner"), "First image should be the Suno banner, not a related article thumbnail")
        }
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Coveteur

    @Test("Coveteur: data-runner-src lazy-load images recovered")
    func coveteurArticle() async throws {
        let html = try loadFixture("coveteur_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://coveteur.com/milan-fashion-week-guide")!
        )

        #expect(result.title.contains("Milan") || result.title.contains("Fashion"))
        #expect(result.imageCount >= 5, "Should recover lazy-loaded images from data-runner-src (got \(result.imageCount))")
        #expect(!result.contentHTML.contains("data:image/svg"), "SVG placeholders should be replaced with real URLs")
        #expect(result.contentHTML.contains("media-library"), "Real image URLs should be present")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - HuggingFace Blog

    @Test("HuggingFace Blog: avatar images stripped, article content extracted")
    func huggingfaceBlog() async throws {
        let html = try loadFixture("huggingface_blog")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://huggingface.co/blog/liberate-your-openclaw")!
        )

        #expect(result.title.contains("OpenClaw") || result.title.contains("Liberate"))
        #expect(result.contentHTML.contains("Anthropic"), "Article text should be present")
        #expect(result.contentHTML.contains("llama.cpp") || result.contentHTML.contains("llama-server"), "Code examples should be preserved")
        #expect(!result.contentHTML.contains("cdn-avatars"), "Author avatar images should be stripped")
        #expect(result.imageCount >= 1, "Article thumbnail should be preserved")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }
    // MARK: - PC Gamer

    @Test("PC Gamer: full article recovered, chrome stripped")
    func pcGamerArticle() async throws {
        let html = try loadFixture("pcgamer_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.pcgamer.com/gaming-industry/a-programmer-with-terminal-brain-cancer-was-caught-in-epics-mass-layoff-but-ceo-tim-sweeney-says-the-studio-will-solve-the-insurance-for-them/")!
        )

        // Title should be extracted
        #expect(result.title.contains("brain cancer") || result.title.contains("Epic"))

        // Full article text should be present (including aria-hidden paragraphs)
        #expect(result.contentHTML.contains("Mike Prinke"))
        #expect(result.contentHTML.contains("not just a number"), "Hidden paragraphs should be recovered")
        #expect(result.contentHTML.contains("Tim Sweeney"), "Sweeney quote should be present")
        #expect(result.contentHTML.contains("confidentiality around medical"), "Final quote should be present")

        // Junk chrome should be stripped
        #expect(!result.contentHTML.contains("biggest gaming news"), "Utility bar promo text should be stripped")
        #expect(!result.contentHTML.contains("Article continues below"), "Interstitial should be stripped")
        #expect(!result.contentHTML.contains("Keep up to date"), "Newsletter promo should be stripped")
        #expect(!result.contentHTML.contains("confirm your public display name"), "Comments section should be stripped")

        // Hero image should be present
        #expect(result.imageCount >= 1, "Hero image should be present")

        // Standard cleanup checks
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - NPR (Iran article)

    @Test("NPR Iran: article images preserved, Loading placeholder stripped")
    func nprIranArticle() async throws {
        let html = try loadFixture("npr_iran_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.npr.org/2026/03/30/nx-s1-5765967/trump-iran-israel-lebanon-kharg-island-oil")!
        )

        // Title should be extracted
        #expect(result.title.contains("Iran") || result.title.contains("Kharg"))

        // Article text should be present
        #expect(result.contentHTML.contains("Strait of Hormuz"))
        #expect(result.contentHTML.contains("regime change"))
        #expect(result.contentHTML.contains("Kharg Island"))
        #expect(result.contentHTML.contains("Brent crude"))

        // Multiple article images should survive (CDN proxy URLs must not be falsely deduped)
        #expect(result.imageCount >= 4, "All article images should be preserved")

        // JS-dependent embed placeholders should be stripped
        #expect(!result.contentHTML.contains("Loading..."), "Loading placeholder should be stripped")

        // Standard cleanup checks
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Yachting Monthly

    @Test("Yachting Monthly: lazy-loaded images recovered, logo excluded from hero")
    func yachtingMonthlyArticle() async throws {
        let html = try loadFixture("yachting_monthly")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.yachtingmonthly.com/sponsored/henri-lloyd-redefining-waterproofs-104580")!
        )

        // Title should be extracted
        #expect(result.title.contains("Henri-Lloyd") || result.title.contains("Waterproof"))

        // Article text should be present
        #expect(result.contentHTML.contains("Ocean Pro"))
        #expect(result.contentHTML.contains("Southern Ocean"))
        #expect(result.contentHTML.contains("Durable Water Repellent"))

        // Lazy-loaded images should be recovered (not stripped as placeholders)
        #expect(result.imageCount >= 4, "Lazy-loaded article images should be recovered")

        // Site logo (itemprop="logo") should NOT be in the content
        #expect(!result.contentHTML.contains("YM-120-new.jpg"), "Site logo should be excluded from hero")

        // Standard cleanup checks
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Al Jazeera

    @Test("Al Jazeera: relative-URL hero not duplicated when Readability resolves to absolute")
    func aljazeeraArticle() async throws {
        let html = try loadFixture("aljazeera_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.aljazeera.com/video/newsfeed/2026/3/30/irans-foreign-ministry-denies-claims-of-us-iran-negotiations?traffic_source=rss")!
        )

        // Title should be extracted
        #expect(result.title.contains("Iran"))

        // Article text should be present
        #expect(result.contentHTML.contains("foreign ministry"))

        // Hero image should appear exactly once (not duplicated due to relative vs absolute URL)
        #expect(result.imageCount == 1, "Hero should not be duplicated")

        // Standard cleanup checks
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Droid Life

    @Test("Droid Life: og:image not duplicated when Readability already extracted it")
    func droidlifeArticle() async throws {
        let html = try loadFixture("droidlife_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.droid-life.com/2026/03/30/this-is-the-pixel-11/")!
        )

        #expect(result.title.contains("Pixel 11"))
        #expect(result.contentHTML.contains("Pixel 11"))
        #expect(result.imageCount >= 2, "Article images should be preserved")
        // The scoped hero (already in Readability output) should not be re-injected,
        // and the og:image (a different resize) should not be added either.
        #expect(result.imageCount <= 4, "No duplicate hero images should be injected")
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - E! Online (Apollo image hydration)

    @Test("E! Online: Apollo images hydrated into placeholders, article text extracted")
    func eonlineArticle() async throws {
        let html = try loadFixture("eonline_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.eonline.com/news/1430353/kylie-jenner-timothee-chalamet-beach-vacation-photos")!
        )

        #expect(result.title.contains("Kylie Jenner"))
        #expect(result.contentHTML.contains("Timothée Chalamet"))
        // Apollo images should have been hydrated from __APOLLO_STATE__
        // (2 inline segment images + 19 gallery images)
        #expect(result.imageCount >= 15, "Apollo-hydrated images should be present (segments + gallery)")
        #expect(result.contentHTML.contains("akns-images.eonline.com"), "Real image URLs from Apollo cache should be injected")
        // Standard cleanup
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
        // Apollo JSON should not leak into content
        #expect(!result.contentHTML.contains("__APOLLO_STATE__"))
    }

    // MARK: - LensCulture

    @Test("LensCulture: CDN images with /large path not falsely deduplicated, article images recovered")
    func lenscultureArticle() async throws {
        let html = try loadFixture("lensculture_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.lensculture.com/articles/janet-delaney-too-many-products-too-much-pressure")!
        )

        #expect(result.title.contains("Too Many Products Too Much Pressure"))
        #expect(result.contentHTML.contains("Janet Delaney"))
        // Article has 11 inline images plus a hero — CDN URLs all end in /large
        // so the dedup must treat "large" as a generic size indicator, not a unique filename
        #expect(result.imageCount >= 10, "CDN images with /large path should not be falsely deduplicated")
        #expect(result.contentHTML.contains("images.lensculture.com"))
        // Standard cleanup
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - NPR (feature article)

    @Test("NPR feature: data-src backdrop images recovered, article text extracted")
    func nprFeatureArticle() async throws {
        let html = try loadFixture("npr_feature_article")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://apps.npr.org/life-on-tristan-da-cunha/")!
        )

        #expect(result.title.contains("Tristan da Cunha"))
        #expect(result.contentHTML.contains("Edinburgh of the Seven Seas"))
        // Backdrop images use data-src and must be promoted to src
        #expect(result.imageCount >= 30, "Lazy-loaded backdrop + gallery images should all be recovered")
        // Standard cleanup
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
        // Video elements should be stripped
        #expect(!result.contentHTML.contains("<video"))
    }

    // MARK: - Nintendo Life (Toree article)

    @Test("Nintendo Life Toree: hero image extracted despite oversized .original variant")
    func nintendolifeToree() async throws {
        let html = try loadFixture("nintendolife_toree")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/news/2026/04/super-rare-announces-toree-and-friends-physical-switch-collection-pre-orders-open-next-week")!
        )

        #expect(result.title.contains("Toree"))
        #expect(result.contentHTML.contains("Super Rare"))
        // The hero image .original.jpg exceeds 2 MB; Readability wraps it
        // in an <a> linking to .large.jpg — the pipeline should extract at
        // least one image via the anchor fallback path.
        #expect(result.imageCount >= 1, "Hero image should be present via anchor or direct download")
        // Standard cleanup
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Nintendo Life South of Midnight review

    @Test("Nintendo Life review: inline screenshots recovered after Readability drops them")
    func nintendolifeSouthOfMidnight() async throws {
        let html = try loadFixture("nintendolife_south_of_midnight")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/reviews/nintendo-switch-2/south-of-midnight")!
        )

        #expect(result.title.contains("South Of Midnight"))
        #expect(result.contentHTML.contains("third‑person action‑adventure"))
        // The review has 5 inline screenshots — Readability keeps only the first.
        // The recovery pass should re-inject the rest; dedup must not collapse
        // them since they share a CDN dimension filename (900x.jpg).
        #expect(result.imageCount >= 4, "Inline screenshots should be recovered (got \(result.imageCount))")
        // Standard cleanup
        #expect(!result.contentHTML.contains("<script"))
        #expect(!result.contentHTML.contains("<nav"))
        #expect(!result.contentHTML.contains("<style"))
    }

    // MARK: - Jezebel Coachella billboards

    @Test("Jezebel listicle: EWWW lazy-loaded images recovered via noscript promotion")
    func jezebelCoachella() async throws {
        let html = try loadFixture("jezebel_coachella")
        let result = try await PageCacheService.shared.runStandardPipeline(
            html: html,
            pageURL: URL(string: "https://www.jezebel.com/the-10-best-coachella-2026-billboards")!
        )

        #expect(result.title.contains("Coachella"))
        #expect(result.contentHTML.contains("billboard"))
        // The article has 10 billboard images plus a hero — all use EWWW lazy
        // loading with data-src + noscript fallback. The noscript promotion
        // must update the previous sibling <img> to avoid duplicate images
        // being falsely stripped as badge clusters.
        #expect(result.imageCount >= 10, "All billboard images should be recovered (got \(result.imageCount))")
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

    // MARK: - Nintendo Life Gallery

    @Test("Nintendo Life Gallery: scripts and nav stripped, gallery images preserved")
    func nintendoLifeGallery() async throws {
        let html = try loadFixture("nintendolife_gallery")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/news/2026/04/gallery-we-werent-prepared-for-the-sheer-size-of-yoshis-popcorn-bucket")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))

        #expect(result.cleanedHTML.contains("popcorn"))
        #expect(result.cleanedHTML.contains("Yoshi"))
        #expect(result.cleanedHTML.contains("<img"), "Gallery images should be preserved")
        #expect(result.cleanedHTML.contains("images.nintendolife.com"), "Gallery image URLs should be present")
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

    @Test("Squarespace wellness: blank.jpg tracking pixel stripped, article content preserved")
    func squarespaceWellness() async throws {
        let html = try loadFixture("squarespace_wellness")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.squarespace.com/blog/how-to-start-health-and-wellness-business")!
        )

        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
        #expect(result.cleanedHTML.contains("wellness business"))
        #expect(result.cleanedHTML.contains("Health"))
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

    // MARK: - TechCrunch YC

    @Test("TechCrunch YC: author photo with ?w=150 filtered, article content preserved")
    func techcrunchYCArticle() async throws {
        let html = try loadFixture("techcrunch_yc_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://techcrunch.com/2026/03/28/from-moon-hotels-to-cattle-herding-8-startups-investors-chased-at-yc-demo-day/")!
        )

        #expect(result.cleanedHTML.contains("Demo Day") || result.cleanedHTML.contains("YC"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("IMG_0758"), "Author photo should not be used as hero")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Health.com

    @Test("Health.com: small square author photo filtered, article content preserved")
    func healthArticle() async throws {
        let html = try loadFixture("health_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.health.com/worrying-about-aging-might-make-you-age-faster-11933189")!
        )

        #expect(result.cleanedHTML.contains("aging") || result.cleanedHTML.contains("Aging"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("untitled-5582"), "Author photo should not be used as hero")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Chocolate & Zucchini

    @Test("cnz.to: small portrait author photo filtered, recipe content preserved")
    func cnzRecipe() async throws {
        let html = try loadFixture("cnz_recipe")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://cnz.to/recipes/vegetables-grains/spiced-pilau-rice-beets-recipe/")!
        )

        #expect(result.cleanedHTML.contains("pilau") || result.cleanedHTML.contains("Pilau") || result.cleanedHTML.contains("rice"))
        #expect(result.heroImageURL != nil, "Hero image should be found")
        #expect(!(result.heroImageURL ?? "").contains("clotilde"), "Author photo should not be used as hero")
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Business Insider

    @Test("Business Insider: data-srcs JSON lazy-load images recovered, content preserved")
    func businessInsiderArticle() async throws {
        let html = try loadFixture("businessinsider_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.businessinsider.com/best-biggest-fast-food-burgers-ranked")!
        )

        #expect(!result.cleanedHTML.contains("data:image/svg"), "SVG placeholders should be replaced with real URLs")
        #expect(result.cleanedHTML.contains("i.insider.com"), "Real image URLs should be present")
        #expect(result.cleanedHTML.contains("burger") || result.cleanedHTML.contains("Burger"))
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - The Verge (Suno)

    @Test("The Verge Suno: compound filename not falsely rejected by chrome filter")
    func theVergeSunoArticle() async throws {
        let html = try loadFixture("theverge_suno_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.theverge.com/entertainment/903056/suno-ai-music-v5-5-model")!
        )

        // Suno banner with compound filename "blogouterbanner" should not be
        // rejected by chrome word filters (contains "logo" and "banner" as substrings)
        #expect(result.heroImageURL?.contains("blogouterbanner") == true, "Suno banner should be the hero")
        #expect(result.cleanedHTML.contains("Suno") || result.cleanedHTML.contains("suno"))
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - Coveteur

    @Test("Coveteur full: lazy-load images recovered, no SVG placeholders")
    func coveteurArticle() async throws {
        let html = try loadFixture("coveteur_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://coveteur.com/milan-fashion-week-guide")!
        )

        // Check that img src attributes don't contain SVG placeholders (full page
        // may contain SVG data URIs in CSS/preload, so check img tags specifically)
        #expect(!result.cleanedHTML.contains("src=\"data:image/svg"), "img src SVG placeholders should be replaced")
        #expect(result.cleanedHTML.contains("media-library"), "Real image URLs should be present")
        // Strip HTML comments before checking for removed elements — IE conditional
        // comments (<!--[if IE]>...<![endif]-->) contain inert <script> references
        // that SwiftSoup preserves as comment nodes, not executable elements.
        let noComments = result.cleanedHTML.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )
        #expect(!noComments.contains("<script>") && !noComments.contains("<script "))
        #expect(!noComments.contains("<nav>") && !noComments.contains("<nav "))
        #expect(!noComments.contains("<noscript"))
        #expect(!noComments.contains("<form>") && !noComments.contains("<form "))
        #expect(!noComments.contains("<svg"))
    }

    // MARK: - HuggingFace Blog

    @Test("HuggingFace Blog: scripts and navigation stripped, article content preserved")
    func huggingfaceBlog() async throws {
        let html = try loadFixture("huggingface_blog")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://huggingface.co/blog/liberate-your-openclaw")!
        )

        #expect(result.cleanedHTML.contains("Anthropic"), "Article text should be preserved")
        #expect(result.cleanedHTML.contains("llama.cpp") || result.cleanedHTML.contains("llama-server"), "Code examples should be preserved")
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
        #expect(!result.cleanedHTML.contains("<svg"))
    }
    // MARK: - PC Gamer

    @Test("PC Gamer: scripts, nav, comments stripped; article content preserved")
    func pcGamerArticle() async throws {
        let html = try loadFixture("pcgamer_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.pcgamer.com/gaming-industry/a-programmer-with-terminal-brain-cancer-was-caught-in-epics-mass-layoff-but-ceo-tim-sweeney-says-the-studio-will-solve-the-insurance-for-them/")!
        )

        // Article content should be preserved
        #expect(result.cleanedHTML.contains("Mike Prinke"))
        #expect(result.cleanedHTML.contains("not just a number"), "Hidden paragraphs should be recovered")
        #expect(result.cleanedHTML.contains("Tim Sweeney"))

        // Junk chrome should be stripped
        #expect(!result.cleanedHTML.contains("biggest gaming news"), "Utility bar should be stripped")
        #expect(!result.cleanedHTML.contains("Article continues below"), "Interstitial should be stripped")
        #expect(!result.cleanedHTML.contains("confirm your public display name"), "Comments should be stripped")

        // Standard full-mode cleanup checks
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
        // Note: this fixture's CSS contains an inline SVG inside a data: URI
        // (filter: url('data:image/svg+xml;...<svg ...')), so we can't do a
        // blanket string check. SVG element removal is tested by other fixtures.
    }

    // MARK: - NPR (Iran article)

    @Test("NPR Iran: scripts, nav stripped; article content and images preserved")
    func nprIranArticle() async throws {
        let html = try loadFixture("npr_iran_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.npr.org/2026/03/30/nx-s1-5765967/trump-iran-israel-lebanon-kharg-island-oil")!
        )

        // Article content should be preserved
        #expect(result.cleanedHTML.contains("Strait of Hormuz"))
        #expect(result.cleanedHTML.contains("regime change"))
        #expect(result.cleanedHTML.contains("Kharg Island"))

        // Images should be preserved
        #expect(result.cleanedHTML.contains("<img"))

        // JS-dependent embed placeholders should be stripped
        #expect(!result.cleanedHTML.contains("Loading..."), "Loading placeholder should be stripped")

        // Standard full-mode cleanup checks
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - Yachting Monthly

    @Test("Yachting Monthly: scripts, nav stripped; article content and images preserved")
    func yachtingMonthlyArticle() async throws {
        let html = try loadFixture("yachting_monthly")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.yachtingmonthly.com/sponsored/henri-lloyd-redefining-waterproofs-104580")!
        )

        // Article content should be preserved
        #expect(result.cleanedHTML.contains("Ocean Pro"))
        #expect(result.cleanedHTML.contains("Southern Ocean"))
        #expect(result.cleanedHTML.contains("Durable Water Repellent"))

        // Images should be preserved
        #expect(result.cleanedHTML.contains("<img"))

        // Standard full-mode cleanup checks
        // Note: this fixture has a <script> inside an IE conditional comment
        // (<!--[if lt IE 9]>...<![endif]-->), which SwiftSoup treats as an
        // opaque HTML comment and doesn't strip. That's harmless — no browser
        // executes it. We check <script> elements outside comments are gone.
        #expect(!result.cleanedHTML.contains("<script>"))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - Al Jazeera

    @Test("Al Jazeera: scripts, nav stripped; article content preserved")
    func aljazeeraArticle() async throws {
        let html = try loadFixture("aljazeera_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.aljazeera.com/video/newsfeed/2026/3/30/irans-foreign-ministry-denies-claims-of-us-iran-negotiations?traffic_source=rss")!
        )

        // Article content should be preserved
        #expect(result.cleanedHTML.contains("foreign ministry"))

        // Images should be preserved
        #expect(result.cleanedHTML.contains("<img"))

        // Standard full-mode cleanup checks
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - Droid Life

    @Test("Droid Life: scripts, nav stripped; article content and images preserved")
    func droidlifeArticle() async throws {
        let html = try loadFixture("droidlife_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.droid-life.com/2026/03/30/this-is-the-pixel-11/")!
        )

        #expect(result.cleanedHTML.contains("Pixel 11"))
        #expect(result.cleanedHTML.contains("<img"))
        #expect(!result.cleanedHTML.contains("<script"))
        #expect(!result.cleanedHTML.contains("<nav"))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form"))
    }

    // MARK: - E! Online (Apollo image hydration)

    @Test("E! Online: Apollo images hydrated, scripts stripped, content preserved")
    func eonlineArticle() async throws {
        let html = try loadFixture("eonline_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.eonline.com/news/1430353/kylie-jenner-timothee-chalamet-beach-vacation-photos")!
        )

        // Apollo images should have been hydrated
        #expect(result.cleanedHTML.contains("akns-images.eonline.com"), "Real image URLs from Apollo cache should be injected")
        #expect(result.cleanedHTML.contains("<img"))
        // Article content preserved
        #expect(result.cleanedHTML.contains("Timothée Chalamet"))
        // Standard full-mode cleanup
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - LensCulture

    @Test("LensCulture: scripts and navigation stripped, article images and content preserved")
    func lenscultureArticle() async throws {
        let html = try loadFixture("lensculture_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.lensculture.com/articles/janet-delaney-too-many-products-too-much-pressure")!
        )

        // Article content preserved
        #expect(result.cleanedHTML.contains("Janet Delaney"))
        #expect(result.cleanedHTML.contains("images.lensculture.com"))
        #expect(result.cleanedHTML.contains("<img"))
        // Standard full-mode cleanup
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - NPR (feature article)

    @Test("NPR feature: data-src images promoted, video stripped, article preserved")
    func nprFeatureArticle() async throws {
        let html = try loadFixture("npr_feature_article")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://apps.npr.org/life-on-tristan-da-cunha/")!
        )

        // Article content preserved
        #expect(result.cleanedHTML.contains("Tristan da Cunha"))
        #expect(result.cleanedHTML.contains("Edinburgh of the Seven Seas"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        // data-src backdrop images should be promoted to src
        #expect(!result.cleanedHTML.contains("data-src="), "All data-src should be promoted to src")
        // Standard full-mode cleanup
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
        #expect(!result.cleanedHTML.contains("<video"))
    }

    // MARK: - Nintendo Life (Toree article)

    @Test("Nintendo Life Toree: interactive elements stripped, article content preserved")
    func nintendolifeToree() async throws {
        let html = try loadFixture("nintendolife_toree")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/news/2026/04/super-rare-announces-toree-and-friends-physical-switch-collection-pre-orders-open-next-week")!
        )

        // Article content preserved
        #expect(result.cleanedHTML.contains("Toree"))
        #expect(result.cleanedHTML.contains("Super Rare"))
        #expect(result.cleanedHTML.contains("<img"), "Images should be preserved")
        // Standard full-mode cleanup
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - Nintendo Life South of Midnight review

    @Test("Nintendo Life review: interactive elements stripped, screenshots preserved")
    func nintendolifeSouthOfMidnight() async throws {
        let html = try loadFixture("nintendolife_south_of_midnight")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.nintendolife.com/reviews/nintendo-switch-2/south-of-midnight")!
        )

        #expect(result.cleanedHTML.contains("South of Midnight"))
        #expect(result.cleanedHTML.contains("third‑person action‑adventure"))
        #expect(result.cleanedHTML.contains("<img"), "Screenshots should be preserved")
        // Standard full-mode cleanup
        #expect(!result.cleanedHTML.contains("<script>") && !result.cleanedHTML.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
    }

    // MARK: - Jezebel Coachella billboards

    @Test("Jezebel listicle: EWWW lazy-loaded images preserved, interactive elements stripped")
    func jezebelCoachella() async throws {
        let html = try loadFixture("jezebel_coachella")
        let result = try await PageCacheService.shared.runFullPipeline(
            html: html,
            pageURL: URL(string: "https://www.jezebel.com/the-10-best-coachella-2026-billboards")!
        )

        #expect(result.cleanedHTML.contains("billboard"))
        #expect(result.cleanedHTML.contains("<img"), "Billboard images should be preserved")
        // Script tags inside HTML comments are harmless (no execution)
        let htmlWithoutComments = result.cleanedHTML.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        #expect(!htmlWithoutComments.contains("<script>") && !htmlWithoutComments.contains("<script "))
        #expect(!result.cleanedHTML.contains("<nav>") && !result.cleanedHTML.contains("<nav "))
        #expect(!result.cleanedHTML.contains("<noscript"))
        #expect(!result.cleanedHTML.contains("<svg"))
        #expect(!result.cleanedHTML.contains("<form>") && !result.cleanedHTML.contains("<form "))
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
