import Foundation
import CryptoKit

// MARK: - Feed model (used for both master list input and output)

struct DiscoverFeedOutput: Codable {
    let id: String
    let name: String
    let feedURL: String
    let siteURL: String?
    let description: String
    let category: String
    let country: String?
    let tags: [String]
}

// MARK: - GitHub API model

struct GitHubFile: Codable {
    let name: String
    let download_url: String?
}

// MARK: - Configuration

let gitHubAPIBase = "https://api.github.com/repos/plenaryapp/awesome-rss-feeds/contents"
let skipValidation = CommandLine.arguments.contains("--skip-validation")
let skipQuality = CommandLine.arguments.contains("--skip-quality")
let verbose = CommandLine.arguments.contains("--verbose")

// MARK: - Helpers

func deterministicID(from feedURL: String) -> String {
    let hash = SHA256.hash(data: Data(feedURL.utf8))
    let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    let i = hex.index(hex.startIndex, offsetBy: 8)
    let j = hex.index(i, offsetBy: 4)
    let k = hex.index(j, offsetBy: 4)
    let l = hex.index(k, offsetBy: 4)
    return "\(hex[hex.startIndex..<i])-\(hex[i..<j])-\(hex[j..<k])-\(hex[k..<l])-\(hex[l..<hex.endIndex])"
}

/// Extracts the category name from an OPML filename like "Android Development.opml" -> "Android Development"
func categoryFromFilename(_ filename: String) -> String {
    filename.replacingOccurrences(of: ".opml", with: "")
}

/// Shortens verbose feed titles by extracting the brand name.
func simplifyName(_ name: String, feedURL: String) -> String {
    let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return raw }

    // Normalize separators that appear without spaces (e.g. "Title| Subtitle" -> "Title | Subtitle")
    let separatorChars: [Character] = ["|", "\u{2013}", "\u{2014}", "\u{00B7}", "\u{2022}", "\u{00BB}"]
    var normalized = raw
    for sep in separatorChars {
        normalized = normalized.replacingOccurrences(
            of: String(sep),
            with: " \(sep) "
        )
    }
    // Clean up any double spaces from normalization
    while normalized.contains("  ") {
        normalized = normalized.replacingOccurrences(of: "  ", with: " ")
    }
    normalized = normalized.trimmingCharacters(in: .whitespaces)

    let punct = CharacterSet.punctuationCharacters
    let words = normalized.split(separator: " ").map(String.init)
    func cleaned(_ w: String) -> String { w.trimmingCharacters(in: punct).lowercased() }
    let separators: Set<String> = ["-", "\u{2013}", "\u{2014}", "|", ">", ":", "\u{00B7}", "\u{2022}", "\u{00BB}"]

    // Extract domain label from feed URL (e.g. "design-milk" from "design-milk.com")
    let domainLabel: String
    if let url = URL(string: feedURL), let host = url.host {
        domainLabel = host
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "feeds.", with: "")
            .components(separatedBy: ".").first ?? ""
    } else {
        domainLabel = ""
    }

    // Domain label without hyphens for concatenated matching (e.g. "designmilk")
    let domainLabelNoHyphens = domainLabel.replacingOccurrences(of: "-", with: "")

    // For any title with a separator, pick the side that contains the brand name.
    let genericTerms: Set<String> = [
        "blog", "blogs", "news", "page array", "rss feed", "rss", "feed",
        "podcast", "home", "latest news", "blog feed", "top stories",
    ]
    if let sepIndex = words.firstIndex(where: { separators.contains($0) }), sepIndex > 0 {
        let before = words[..<sepIndex]
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }
        let after = words[words.index(after: sepIndex)...]
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }

        let beforeJoined = before.joined(separator: " ")
        let afterJoined = after.joined(separator: " ")

        // If one side is a generic term, use the other side
        if !after.isEmpty && genericTerms.contains(beforeJoined.lowercased()) {
            return afterJoined
        }
        if !before.isEmpty && genericTerms.contains(afterJoined.lowercased()) {
            return beforeJoined
        }

        // Check if one side matches the domain -- prefer that side as the brand name
        if !domainLabel.isEmpty {
            let beforeConcat = before.map { $0.lowercased() }.joined()
            let afterConcat = after.map { $0.lowercased() }.joined()
            if afterConcat == domainLabel || afterConcat == domainLabelNoHyphens {
                return afterJoined
            }
            if beforeConcat == domainLabel || beforeConcat == domainLabelNoHyphens {
                return beforeJoined
            }
        }
    }

    // Short titles without separators are fine as-is
    let wordCount = words.count
    guard wordCount > 5 else { return normalized }

    guard !domainLabel.isEmpty else { return normalized }

    // Direct single-word match (e.g. "Engadget" in "Engadget | Technology News & Reviews")
    if let match = words.first(where: { cleaned($0) == domainLabel || cleaned($0) == domainLabelNoHyphens }) {
        return match.trimmingCharacters(in: punct)
    }

    // Concatenated words match (e.g. "The Verge" -> "theverge")
    for start in words.indices {
        var concat = ""
        for end in start..<words.count {
            concat += cleaned(words[end])
            if concat == domainLabel || concat == domainLabelNoHyphens {
                return words[start...end]
                    .map { $0.trimmingCharacters(in: punct) }
                    .joined(separator: " ")
            }
            if concat.count >= domainLabel.count { break }
        }
    }

    // Fallback: take words before the first separator
    if let sepIndex = words.firstIndex(where: { separators.contains($0) }), sepIndex > 0 {
        let before = words[..<sepIndex]
            .map { $0.trimmingCharacters(in: punct) }
            .filter { !$0.isEmpty }
        if !before.isEmpty && before.count <= 4 {
            return before.joined(separator: " ")
        }
    }

    // Last resort: take up to 3 words
    let realWords = words
        .filter { !separators.contains($0) }
        .map { $0.trimmingCharacters(in: punct) }
        .filter { !$0.isEmpty }
    if realWords.count > 3 {
        return realWords.prefix(3).joined(separator: " ")
    }
    return realWords.joined(separator: " ")
}

/// Fetches the list of files in a GitHub directory.
func fetchGitHubFileList(path: String, session: URLSession) async throws -> [GitHubFile] {
    let urlString = "\(gitHubAPIBase)/\(path)"
    guard let url = URL(string: urlString) else { return [] }

    var request = URLRequest(url: url)
    request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
    let (data, _) = try await session.data(for: request)
    return try JSONDecoder().decode([GitHubFile].self, from: data)
}

/// Normalizes a feed URL for comparison (lowercase, strip trailing slash, strip scheme).
func normalizeFeedURL(_ urlString: String) -> String {
    var normalized = urlString.lowercased()
    if normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
    // Strip scheme for comparison
    normalized = normalized
        .replacingOccurrences(of: "https://", with: "")
        .replacingOccurrences(of: "http://", with: "")
    return normalized
}

/// Upgrades http:// to https:// (iOS ATS blocks plain HTTP).
func upgradeToHTTPS(_ urlString: String) -> String {
    if urlString.lowercased().hasPrefix("http://") {
        return "https://" + urlString.dropFirst("http://".count)
    }
    return urlString
}

// MARK: - Date formatting for reports

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

// MARK: - Shared session factory

/// User-Agent string matching the main app's FeedService — a full Safari UA.
/// Truncated or generic UAs get blocked by Cloudflare and similar WAFs.
let sharedUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

func makeSession(timeout: TimeInterval = 15) -> URLSession {
    URLSession(configuration: {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpMaximumConnectionsPerHost = 5
        config.httpAdditionalHeaders = ["User-Agent": sharedUserAgent]
        // Disable URL cache — we never re-read responses, and the default
        // in-memory cache grows large enough to OOM when validating 500+ feeds.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }())
}

// MARK: - Category file loading

/// Converts a category name to its filesystem slug (e.g. "Business & Economy" -> "business-economy").
func slugifyCategory(_ name: String) -> String {
    var s = name.lowercased()
    s = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
        .map(String.init).joined()
    s = s.split(separator: " ").joined(separator: "-")
    while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
    return s
}

/// Loads all feeds from the categories/ directory by reading every .json file.
func loadAllFeeds(from scriptDir: URL) throws -> [DiscoverFeedOutput] {
    try loadFeedsByCategory(from: scriptDir).flatMap(\.feeds)
}

/// Loads feeds grouped by category file, preserving per-file grouping.
func loadFeedsByCategory(from scriptDir: URL) throws -> [(category: String, feeds: [DiscoverFeedOutput])] {
    let categoriesDir = scriptDir.appendingPathComponent("categories")
    let fm = FileManager.default

    guard fm.fileExists(atPath: categoriesDir.path) else {
        fatalError("categories/ directory not found at \(categoriesDir.path)")
    }

    let files = try fm.contentsOfDirectory(at: categoriesDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var result: [(category: String, feeds: [DiscoverFeedOutput])] = []
    for file in files {
        let data = try Data(contentsOf: file)
        let feeds = try JSONDecoder().decode([DiscoverFeedOutput].self, from: data)
        let categoryName = file.deletingPathExtension().lastPathComponent
        result.append((category: categoryName, feeds: feeds))
    }

    return result
}

/// Writes feeds back to the categories/ directory, one file per category.
func writeAllFeeds(_ feeds: [DiscoverFeedOutput], to scriptDir: URL) throws {
    let categoriesDir = scriptDir.appendingPathComponent("categories")
    try FileManager.default.createDirectory(at: categoriesDir, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    let grouped = Dictionary(grouping: feeds, by: \.category)

    // Remove category files for categories with no remaining feeds
    let fm = FileManager.default
    let existingFiles = try fm.contentsOfDirectory(at: categoriesDir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    let activeFilenames = Set(grouped.keys.map { slugifyCategory($0) + ".json" })
    for file in existingFiles {
        if !activeFilenames.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
        }
    }

    for (category, categoryFeeds) in grouped.sorted(by: { $0.key < $1.key }) {
        let sorted = categoryFeeds.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let filename = slugifyCategory(category) + ".json"
        let fileURL = categoriesDir.appendingPathComponent(filename)
        var data = try encoder.encode(sorted)

        // Fix formatting to match original style:
        // - Remove space before colon: "key" : "value" -> "key": "value"
        // - Compact empty arrays: "tags" : [\n\n    ] -> "tags": []
        if var json = String(data: data, encoding: .utf8) {
            // Fix key-value separator spacing
            json = json.replacingOccurrences(
                of: "\" : ",
                with: "\": "
            )
            // Compact empty arrays
            json = json.replacingOccurrences(
                of: "\\[\\s*\\]",
                with: "[]",
                options: .regularExpression
            )
            data = Data(json.utf8)
        }

        try data.write(to: fileURL)
    }
}

// MARK: - Audit Mode

/// Reads feeds from the categories/ directory, validates each feed, removes broken/stale/thin entries,
/// writes the clean result to the app bundle, and prints a report of what was removed.
func runAudit() async throws {
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let feedsByCategory = try loadFeedsByCategory(from: scriptDir)
    let totalFeeds = feedsByCategory.reduce(0) { $0 + $1.feeds.count }
    print("📥 Loaded \(totalFeeds) feeds from \(feedsByCategory.count) category files")

    // Track removals for the report
    var deadFeeds: [(name: String, feedURL: String, category: String)] = []
    var staleFeeds: [(name: String, feedURL: String, category: String, lastDate: Date)] = []
    var thinFeeds: [(name: String, feedURL: String, category: String, words: Int, images: Int)] = []

    // 1. Validate feeds (unless --skip-validation)
    struct ValidatedFeed {
        let feed: DiscoverFeedOutput
        let siteURL: String?        // Updated siteURL from feed XML (if found)
        let newestItemDate: Date?
        let articleURLs: [String]
    }
    var validatedFeeds: [ValidatedFeed] = []

    if skipValidation {
        print("Skipping validation (--skip-validation)")
        let allFeeds = feedsByCategory.flatMap(\.feeds)
        validatedFeeds = allFeeds.map {
            ValidatedFeed(feed: $0, siteURL: $0.siteURL, newestItemDate: nil, articleURLs: [])
        }
    } else {
        print("Validating \(totalFeeds) feeds across \(feedsByCategory.count) categories...")
        var validCount = 0
        var invalidCount = 0
        var processedTotal = 0

        // Process each category independently with its own URLSession.
        // This prevents connection pool exhaustion that causes false failures
        // when all 500+ feeds share a single session.
        for (categorySlug, categoryFeeds) in feedsByCategory {
            guard !categoryFeeds.isEmpty else { continue }

            let session = makeSession()
            let categoryDisplay = categoryFeeds.first?.category ?? categorySlug
            print("  [\(categoryDisplay)] \(categoryFeeds.count) feeds...")

            let batchSize = 10
            for batchStart in stride(from: 0, to: categoryFeeds.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, categoryFeeds.count)
                let batch = Array(categoryFeeds[batchStart..<batchEnd])

                let results = await withTaskGroup(
                    of: (DiscoverFeedOutput, FeedValidator.ValidationResult).self
                ) { group in
                    for feed in batch {
                        group.addTask {
                            let result = await FeedValidator.validate(
                                feedURL: feed.feedURL, session: session,
                                checkATSRedirects: true
                            )
                            return (feed, result)
                        }
                    }
                    var collected: [(DiscoverFeedOutput, FeedValidator.ValidationResult)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }

                for (feed, result) in results {
                    if result.isValid {
                        validatedFeeds.append(ValidatedFeed(
                            feed: feed,
                            siteURL: feed.siteURL ?? result.siteURL,
                            newestItemDate: result.newestItemDate,
                            articleURLs: result.articleURLs
                        ))
                        validCount += 1
                        if verbose {
                            let dateStr = result.newestItemDate.map { dateFormatter.string(from: $0) } ?? "no date"
                            print("    \u{2713} \(feed.name) (\(feed.feedURL)) — newest: \(dateStr)")
                        }
                    } else {
                        deadFeeds.append((name: feed.name, feedURL: feed.feedURL, category: feed.category))
                        invalidCount += 1
                        let issue = result.issue?.description ?? "unknown"
                        if verbose {
                            print("    \u{2717} \(feed.name) (\(feed.feedURL)) — \(issue)")
                        }
                    }
                }
            }

            processedTotal += categoryFeeds.count
            print("    \(processedTotal)/\(totalFeeds) done (\(validCount) valid, \(invalidCount) dead)")

        }

        // Retry failed feeds with a fresh session after a cooldown.
        // Late-alphabet categories often fail due to accumulated network state;
        // retrying with a clean session recovers most of them.
        if !deadFeeds.isEmpty {
            print("Retrying \(deadFeeds.count) failed feeds...")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s cooldown
            let retrySession = makeSession()
            var stillDead: [(name: String, feedURL: String, category: String)] = []

            for dead in deadFeeds {
                let result = await FeedValidator.validate(
                    feedURL: dead.feedURL, session: retrySession,
                    checkATSRedirects: true
                )
                if result.isValid {
                    // Find the original feed object from feedsByCategory
                    let originalFeed = feedsByCategory.flatMap(\.feeds)
                        .first(where: { $0.feedURL == dead.feedURL })!
                    validatedFeeds.append(ValidatedFeed(
                        feed: originalFeed,
                        siteURL: originalFeed.siteURL ?? result.siteURL,
                        newestItemDate: result.newestItemDate,
                        articleURLs: result.articleURLs
                    ))
                    validCount += 1
                    invalidCount -= 1
                    print("  \u{2713} \(dead.name) — recovered on retry")
                } else {
                    stillDead.append(dead)
                    let issue = result.issue?.description ?? "unknown"
                    print("  \u{2717} \(dead.name) — still failing: \(issue)")
                }
            }

            deadFeeds = stillDead
            print("After retry: \(validCount) valid, \(invalidCount) dead")
        }

        print("Validation: \(validCount) valid, \(invalidCount) dead")
    }

    // 2. Quality checks (unless --skip-quality or --skip-validation)
    if !skipQuality && !skipValidation {
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!

        // 2a. Staleness check
        validatedFeeds.removeAll { vf in
            if let newestDate = vf.newestItemDate, newestDate < sixMonthsAgo {
                staleFeeds.append((
                    name: vf.feed.name,
                    feedURL: vf.feed.feedURL,
                    category: vf.feed.category,
                    lastDate: newestDate
                ))
                return true
            }
            return false
        }
        if !staleFeeds.isEmpty {
            print("Stale feeds removed: \(staleFeeds.count)")
            for stale in staleFeeds.sorted(by: { $0.lastDate < $1.lastDate }) {
                print("   - \(stale.name) (\(stale.category)) — last article: \(dateFormatter.string(from: stale.lastDate))")
            }
        }

        // 2b. Content quality check — process per-category to avoid connection exhaustion
        let feedsToCheck = validatedFeeds.filter { !$0.articleURLs.isEmpty }

        if !feedsToCheck.isEmpty {
            print("Checking content quality for \(feedsToCheck.count) feeds...")

            let groupedByCategory = Dictionary(grouping: feedsToCheck, by: \.feed.category)
            var thinFeedURLs = Set<String>()
            var qualityProcessed = 0

            for (category, categoryFeeds) in groupedByCategory.sorted(by: { $0.key < $1.key }) {
                let qualitySession = makeSession(timeout: 10)

                let qualityBatchSize = 5
                for batchStart in stride(from: 0, to: categoryFeeds.count, by: qualityBatchSize) {
                    let batchEnd = min(batchStart + qualityBatchSize, categoryFeeds.count)
                    let batch = Array(categoryFeeds[batchStart..<batchEnd])

                    let results = await withTaskGroup(
                        of: ContentQualityChecker.QualityResult.self
                    ) { group in
                        for vf in batch {
                            group.addTask {
                                await ContentQualityChecker.check(
                                    feedURL: vf.feed.feedURL,
                                    articleURLs: vf.articleURLs,
                                    session: qualitySession
                                )
                            }
                        }
                        var collected: [ContentQualityChecker.QualityResult] = []
                        for await result in group {
                            collected.append(result)
                        }
                        return collected
                    }

                    for result in results {
                        if !result.isAcceptable {
                            thinFeedURLs.insert(result.feedURL)
                            if let vf = feedsToCheck.first(where: { $0.feed.feedURL == result.feedURL }) {
                                thinFeeds.append((
                                    name: vf.feed.name,
                                    feedURL: vf.feed.feedURL,
                                    category: vf.feed.category,
                                    words: result.medianWordCount,
                                    images: result.medianImageCount
                                ))
                            }
                        }
                        if verbose {
                            print("   \(result.isAcceptable ? "\u{2713}" : "\u{2717}") \(result.feedURL) — \(result.reason)")
                        }
                    }

                    qualityProcessed += batch.count
                }

                print("  Quality: \(qualityProcessed)/\(feedsToCheck.count) [\(category)]")
            }

            if !thinFeedURLs.isEmpty {
                print("Thin content feeds (kept, warning only): \(thinFeeds.count)")
                for thin in thinFeeds.sorted(by: { $0.words < $1.words }) {
                    print("   ⚠ \(thin.name) (\(thin.category)) — median: \(thin.words) words, \(thin.images) images")
                }
            }
        }
    } else if skipQuality {
        print("Skipping quality checks (--skip-quality)")
    }

    // 3. Build output — master list already has clean names/IDs, just upgrade URLs to HTTPS
    var outputFeeds: [DiscoverFeedOutput] = validatedFeeds.map { vf in
        let finalFeedURL = upgradeToHTTPS(vf.feed.feedURL)
        let finalSiteURL = (vf.siteURL ?? vf.feed.siteURL).map { upgradeToHTTPS($0) }

        return DiscoverFeedOutput(
            id: vf.feed.id,
            name: vf.feed.name,
            feedURL: finalFeedURL,
            siteURL: finalSiteURL,
            description: vf.feed.description,
            category: vf.feed.category,
            country: vf.feed.country,
            tags: vf.feed.tags
        )
    }
    outputFeeds.sort {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    // 4. Write JSON output
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(outputFeeds)

    let projectRoot = scriptDir
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let outputPath = projectRoot
        .appendingPathComponent("Preread")
        .appendingPathComponent("Resources")
        .appendingPathComponent("discover_feeds.json")

    try FileManager.default.createDirectory(
        at: outputPath.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try jsonData.write(to: outputPath)

    let sizeKB = jsonData.count / 1024
    print("")
    print("Done! Wrote \(outputFeeds.count) feeds (\(sizeKB)KB)")
    print("   Output: \(outputPath.path)")

    // 5. Report
    let totalRemoved = deadFeeds.count + staleFeeds.count + thinFeeds.count
    if totalRemoved > 0 {
        print("")
        print("Removed \(totalRemoved) feeds from output:")
        if !deadFeeds.isEmpty {
            print("   Dead (unreachable/invalid): \(deadFeeds.count)")
            for dead in deadFeeds {
                print("      - \(dead.name) [\(dead.category)] \(dead.feedURL)")
            }
        }
        if !staleFeeds.isEmpty {
            print("   Stale (>6 months): \(staleFeeds.count)")
            for stale in staleFeeds.sorted(by: { $0.lastDate < $1.lastDate }) {
                print("      - \(stale.name) [\(stale.category)] last: \(dateFormatter.string(from: stale.lastDate)) \(stale.feedURL)")
            }
        }
        if !thinFeeds.isEmpty {
            print("   Thin content: \(thinFeeds.count)")
            for thin in thinFeeds.sorted(by: { $0.words < $1.words }) {
                print("      - \(thin.name) [\(thin.category)] median: \(thin.words)w/\(thin.images)img \(thin.feedURL)")
            }
        }
        print("")
        print("These feeds were excluded from the app output but remain in their category files.")
        print("Remove them from categories/ if they should be permanently excluded.")
    }

    let categoryCounts = Dictionary(grouping: outputFeeds, by: \.category)
        .mapValues(\.count)
        .sorted { $0.value > $1.value }

    print("")
    print("Categories:")
    for (category, count) in categoryCounts {
        print("   \(category): \(count)")
    }
}

// MARK: - Discover Mode

/// Fetches feeds from upstream OPML sources, deduplicates against the master list,
/// and prints new candidates for manual review.
func runDiscover() async throws {
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let session = makeSession()
    let parser = OPMLParser()
    var allRawFeeds: [OPMLParser.RawFeed] = []

    // 1. Fetch recommended category OPML file list from GitHub API
    print("Fetching recommended category file list...")
    let recommendedFiles = try await fetchGitHubFileList(
        path: "recommended/with_category", session: session
    )
    let recommendedOPMLs = recommendedFiles.filter { $0.name.hasSuffix(".opml") }
    print("   Found \(recommendedOPMLs.count) category OPMLs")

    for file in recommendedOPMLs {
        guard let downloadURL = file.download_url,
              let url = URL(string: downloadURL) else { continue }

        let categoryName = categoryFromFilename(file.name)
        do {
            let (data, _) = try await session.data(from: url)
            let feeds = parser.parse(data: data, category: categoryName)
            allRawFeeds.append(contentsOf: feeds)
            if verbose {
                print("  \u{2713} \(categoryName): \(feeds.count) feeds")
            }
        } catch {
            print("  \u{2717} Failed to fetch \(categoryName): \(error.localizedDescription)")
        }
    }

    // 2. Fetch country OPML file list from GitHub API
    print("Fetching country file list...")
    let countryFiles = try await fetchGitHubFileList(
        path: "countries/with_category", session: session
    )
    let countryOPMLs = countryFiles.filter { $0.name.hasSuffix(".opml") }
    print("   Found \(countryOPMLs.count) country OPMLs")

    for file in countryOPMLs {
        guard let downloadURL = file.download_url,
              let url = URL(string: downloadURL) else { continue }

        let countryName = categoryFromFilename(file.name)
        do {
            let (data, _) = try await session.data(from: url)
            let feeds = parser.parse(data: data, country: countryName)
            allRawFeeds.append(contentsOf: feeds)
            if verbose {
                print("  \u{2713} \(countryName): \(feeds.count) feeds")
            }
        } catch {
            print("  \u{2717} Failed to fetch \(countryName): \(error.localizedDescription)")
        }
    }

    print("Total raw feeds from OPML: \(allRawFeeds.count)")

    // 3. Deduplicate by feed URL
    var seenURLs = Set<String>()
    var uniqueFeeds: [OPMLParser.RawFeed] = []
    for feed in allRawFeeds {
        let normalized = normalizeFeedURL(feed.feedURL)
        if seenURLs.insert(normalized).inserted {
            uniqueFeeds.append(feed)
        }
    }
    print("After URL dedup: \(uniqueFeeds.count) unique feeds")

    // 4. Site-level dedup (same domain + simplified name)
    var seenDomainName = Set<String>()
    let beforeSiteDedup = uniqueFeeds.count
    uniqueFeeds.removeAll { feed in
        guard let host = URL(string: feed.feedURL)?.host?.lowercased() else { return false }
        let domain = host.replacingOccurrences(of: "www.", with: "")
        let simplified = simplifyName(feed.name, feedURL: feed.feedURL).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(domain)|\(simplified)"
        return !seenDomainName.insert(key).inserted
    }
    if beforeSiteDedup != uniqueFeeds.count {
        print("After site dedup: \(uniqueFeeds.count) feeds (\(beforeSiteDedup - uniqueFeeds.count) same-site duplicates removed)")
    }

    // 5. Filter out feeds already in master list
    var masterNormalizedURLs = Set<String>()
    if let masterFeeds = try? loadAllFeeds(from: scriptDir) {
        masterNormalizedURLs = Set(masterFeeds.map { normalizeFeedURL($0.feedURL) })
        print("Master list has \(masterFeeds.count) feeds (from categories/)")
    }

    let beforeMasterFilter = uniqueFeeds.count
    uniqueFeeds.removeAll { feed in
        masterNormalizedURLs.contains(normalizeFeedURL(feed.feedURL))
    }
    print("After filtering master list entries: \(uniqueFeeds.count) candidates (\(beforeMasterFilter - uniqueFeeds.count) already in master)")

    // 6. Optionally validate candidates
    if !skipValidation && !uniqueFeeds.isEmpty {
        print("Validating \(uniqueFeeds.count) candidates...")
        var validCandidates: [OPMLParser.RawFeed] = []
        var invalidCount = 0

        let batchSize = 10
        for batchStart in stride(from: 0, to: uniqueFeeds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, uniqueFeeds.count)
            let batch = Array(uniqueFeeds[batchStart..<batchEnd])

            let results = await withTaskGroup(
                of: (OPMLParser.RawFeed, FeedValidator.ValidationResult).self
            ) { group in
                for feed in batch {
                    group.addTask {
                        let result = await FeedValidator.validate(
                            feedURL: feed.feedURL, session: session
                        )
                        return (feed, result)
                    }
                }
                var collected: [(OPMLParser.RawFeed, FeedValidator.ValidationResult)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }

            for (feed, result) in results {
                if result.isValid {
                    validCandidates.append(feed)
                } else {
                    invalidCount += 1
                }
            }

            let progress = min(batchEnd, uniqueFeeds.count)
            print("  Progress: \(progress)/\(uniqueFeeds.count)")
        }

        print("Validation: \(validCandidates.count) valid, \(invalidCount) dead")
        uniqueFeeds = validCandidates
    }

    // 7. Print candidates
    if uniqueFeeds.isEmpty {
        print("")
        print("No new candidates found.")
    } else {
        // Group by category
        let grouped = Dictionary(grouping: uniqueFeeds, by: \.category)
            .sorted { $0.key < $1.key }

        print("")
        print("\(uniqueFeeds.count) new candidates found:")
        print("")
        for (category, feeds) in grouped {
            print("[\(category)] (\(feeds.count) feeds)")
            for feed in feeds.sorted(by: { $0.name < $1.name }) {
                let simplified = simplifyName(feed.name, feedURL: feed.feedURL)
                print("   \(simplified)")
                print("      feedURL: \(feed.feedURL)")
                if let siteURL = feed.siteURL {
                    print("      siteURL: \(siteURL)")
                }
                if !feed.description.isEmpty {
                    print("      \(feed.description)")
                }
            }
            print("")
        }

        print("To add candidates, create entries in the appropriate categories/<category>.json file:")
        print("  { \"id\": \"<generated>\", \"name\": \"...\", \"feedURL\": \"...\", \"siteURL\": \"...\", \"description\": \"...\", \"category\": \"...\", \"country\": null, \"tags\": [] }")
    }
}

// MARK: - Verify Mode

/// Loads all feeds from category files, validates each one with ATS-aware checks,
/// attempts autodiscovery for broken feeds, updates category files with fixed URLs,
/// and removes feeds that can't be fixed.
func runVerify() async throws {
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    var allFeeds = try loadAllFeeds(from: scriptDir)
    let categoryFileCount = try FileManager.default.contentsOfDirectory(
        at: scriptDir.appendingPathComponent("categories"),
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.count
    print("Loaded \(allFeeds.count) feeds from \(categoryFileCount) category files")

    let session = makeSession()

    // Track results
    var okCount = 0
    var fixedFeeds: [(name: String, category: String, oldURL: String, newURL: String)] = []
    var removedFeeds: [(name: String, category: String, feedURL: String, reason: String)] = []

    // Validate all feeds with ATS-aware redirect checking
    print("Verifying feeds (ATS-aware)...")

    struct FeedCheckResult {
        let feed: DiscoverFeedOutput
        let validation: FeedValidator.ValidationResult
    }

    var failedFeeds: [FeedCheckResult] = []

    let batchSize = 10
    for batchStart in stride(from: 0, to: allFeeds.count, by: batchSize) {
        let batchEnd = min(batchStart + batchSize, allFeeds.count)
        let batch = Array(allFeeds[batchStart..<batchEnd])

        let results = await withTaskGroup(of: FeedCheckResult.self) { group in
            for feed in batch {
                group.addTask {
                    let result = await FeedValidator.validate(
                        feedURL: feed.feedURL, session: session,
                        checkATSRedirects: true
                    )
                    return FeedCheckResult(feed: feed, validation: result)
                }
            }
            var collected: [FeedCheckResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for result in results {
            if result.validation.isValid {
                okCount += 1
                if verbose {
                    print("  \u{2713} \(result.feed.name)")
                }
            } else {
                failedFeeds.append(result)
                let issue = result.validation.issue?.description ?? "unknown"
                print("  \u{2717} \(result.feed.name) [\(result.feed.category)] — \(issue)")
            }
        }

        let progress = min(batchEnd, allFeeds.count)
        print("  Progress: \(progress)/\(allFeeds.count) (\(okCount) ok, \(failedFeeds.count) failed)")
    }

    if failedFeeds.isEmpty {
        print("\nAll \(allFeeds.count) feeds are valid!")
        return
    }

    // Retry failed feeds once before declaring them broken (handles intermittent timeouts)
    print("\nRetrying \(failedFeeds.count) failed feeds...")
    var confirmedFailed: [FeedCheckResult] = []
    for failed in failedFeeds {
        let retry = await FeedValidator.validate(
            feedURL: failed.feed.feedURL, session: session, checkATSRedirects: true
        )
        if retry.isValid {
            okCount += 1
            print("  \u{2713} \(failed.feed.name) — passed on retry")
        } else {
            confirmedFailed.append(failed)
            print("  \u{2717} \(failed.feed.name) — still failing")
        }
    }

    if confirmedFailed.isEmpty {
        print("\nAll feeds passed after retry!")
        return
    }

    // Attempt autodiscovery for confirmed-failed feeds
    print("\nAttempting autodiscovery for \(confirmedFailed.count) failed feeds...")

    for (i, failed) in confirmedFailed.enumerated() {
        let feed = failed.feed
        print("  [\(i + 1)/\(confirmedFailed.count)] \(feed.name) (\(feed.category))...")

        if let newURL = await FeedValidator.discoverFeed(
            siteURL: feed.siteURL, feedURL: feed.feedURL, session: session
        ) {
            // Skip if autodiscovery found the same URL we already have
            if normalizeFeedURL(newURL) == normalizeFeedURL(feed.feedURL) {
                let reason = failed.validation.issue?.description ?? "unknown"
                removedFeeds.append((
                    name: feed.name,
                    category: feed.category,
                    feedURL: feed.feedURL,
                    reason: reason
                ))
                print("    \u{2717} Autodiscovery returned same URL — removing")
                allFeeds.removeAll { $0.id == feed.id }
                continue
            }

            // Keep the original siteURL if it exists — the validator's siteURL comes from
            // the feed XML's <link> tag which is sometimes wrong (e.g. pointing back to the
            // feed URL instead of the homepage). Only use the validator's siteURL as a fallback.
            let newResult = await FeedValidator.validate(
                feedURL: newURL, session: session, checkATSRedirects: true
            )
            let newSiteURL = feed.siteURL ?? newResult.siteURL

            fixedFeeds.append((
                name: feed.name,
                category: feed.category,
                oldURL: feed.feedURL,
                newURL: newURL
            ))
            print("    \u{2713} Found: \(newURL)")

            // Update the feed in the allFeeds array
            if let idx = allFeeds.firstIndex(where: { $0.id == feed.id }) {
                allFeeds[idx] = DiscoverFeedOutput(
                    id: feed.id,
                    name: feed.name,
                    feedURL: newURL,
                    siteURL: newSiteURL,
                    description: feed.description,
                    category: feed.category,
                    country: feed.country,
                    tags: feed.tags
                )
            }
        } else {
            let reason = failed.validation.issue?.description ?? "unknown"
            removedFeeds.append((
                name: feed.name,
                category: feed.category,
                feedURL: feed.feedURL,
                reason: reason
            ))
            print("    \u{2717} No valid feed found — removing")

            // Remove the feed
            allFeeds.removeAll { $0.id == feed.id }
        }
    }

    // Write updated category files
    if !fixedFeeds.isEmpty || !removedFeeds.isEmpty {
        try writeAllFeeds(allFeeds, to: scriptDir)
        print("\nCategory files updated.")
    }

    // Summary
    print("\n--- Verification Summary ---")
    print("Total feeds checked: \(okCount + failedFeeds.count)")
    print("OK: \(okCount)")

    if !fixedFeeds.isEmpty {
        print("\nFixed (\(fixedFeeds.count)):")
        for fix in fixedFeeds.sorted(by: { $0.category < $1.category }) {
            print("  \(fix.name) [\(fix.category)]")
            print("    old: \(fix.oldURL)")
            print("    new: \(fix.newURL)")
        }
    }

    if !removedFeeds.isEmpty {
        print("\nRemoved (\(removedFeeds.count)):")
        for removed in removedFeeds.sorted(by: { $0.category < $1.category }) {
            print("  \(removed.name) [\(removed.category)] — \(removed.reason)")
            print("    \(removed.feedURL)")
        }
    }
}

// MARK: - Test Mode

/// Tests a single URL end-to-end: feed validation, discovery, staleness, and content quality.
/// Replicates the app's discovery flow so you can diagnose why a URL fails in the app.
func runTest(url inputURL: String) async throws {
    let session = makeSession()

    // Normalize: prepend https:// if no scheme
    var urlString = inputURL
    if !urlString.lowercased().hasPrefix("http://") && !urlString.lowercased().hasPrefix("https://") {
        urlString = "https://" + urlString
    }
    // Upgrade http to https (matches app behaviour)
    urlString = upgradeToHTTPS(urlString)

    print("Testing: \(urlString)")
    print("")

    // Step 1: Is the URL itself a feed?
    print("1. Checking if URL is a feed...")
    let directResult = await FeedValidator.validate(feedURL: urlString, session: session, checkATSRedirects: true)
    var feedURL: String?
    var validationResult: FeedValidator.ValidationResult?

    if directResult.isValid {
        print("   \u{2713} URL is a valid feed")
        feedURL = urlString
        validationResult = directResult
    } else {
        let issue = directResult.issue?.description ?? "not a feed"
        print("   \u{2717} Not a feed (\(issue))")

        // Step 2: Discover from the site
        print("")
        print("2. Discovering feed from site...")

        // 2a: HTML <link> discovery
        print("   Checking <link rel=\"alternate\"> tags...")
        if let discovered = await FeedValidator.discoverFeed(siteURL: urlString, feedURL: urlString, session: session) {
            let discoveredResult = await FeedValidator.validate(feedURL: discovered, session: session, checkATSRedirects: true)
            if discoveredResult.isValid {
                print("   \u{2713} Discovered feed: \(discovered)")
                feedURL = discovered
                validationResult = discoveredResult
            } else {
                let issue = discoveredResult.issue?.description ?? "invalid"
                print("   \u{2717} Discovered \(discovered) but it failed validation: \(issue)")
            }
        } else {
            print("   \u{2717} No feed found via discovery (link tags, common paths, feeds subdomain)")
        }
    }

    guard let feedURL, let validationResult else {
        print("")
        print("RESULT: FAIL — no valid feed found")
        exit(1)
    }

    // Step 3: Feed info
    print("")
    print("3. Feed details")
    if let siteURL = validationResult.siteURL {
        print("   Site URL:  \(siteURL)")
    }
    print("   Feed URL:  \(feedURL)")

    if let newestDate = validationResult.newestItemDate {
        let dateStr = dateFormatter.string(from: newestDate)
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        let isStale = newestDate < sixMonthsAgo
        print("   Newest article: \(dateStr)\(isStale ? " \u{26A0}\u{FE0F} STALE (>6 months)" : "")")
    } else {
        print("   Newest article: unknown (no dates in feed)")
    }
    print("   Articles in feed: \(validationResult.articleURLs.count)")

    // Step 4: Content quality
    var qualityFailed = false
    if !validationResult.articleURLs.isEmpty {
        print("")
        print("4. Content quality (sampling up to 5 articles)...")
        let qualityResult = await ContentQualityChecker.check(
            feedURL: feedURL,
            articleURLs: validationResult.articleURLs,
            session: session
        )
        print("   Median words:  \(qualityResult.medianWordCount)")
        print("   Median images: \(qualityResult.medianImageCount)")
        print("   Sampled:       \(qualityResult.sampledArticles) articles")
        print("   Quality:       \(qualityResult.isAcceptable ? "\u{2713} acceptable" : "\u{2717} thin (\(qualityResult.reason))")")
        qualityFailed = !qualityResult.isAcceptable
    }

    // Step 5: Check staleness
    var isStaleFeed = false
    if let newestDate = validationResult.newestItemDate {
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date())!
        isStaleFeed = newestDate < sixMonthsAgo
    }

    // Step 6: Check if it's in the directory
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if let existingFeeds = try? loadAllFeeds(from: scriptDir) {
        let normalizedFeed = normalizeFeedURL(feedURL)
        if let match = existingFeeds.first(where: { normalizeFeedURL($0.feedURL) == normalizedFeed }) {
            print("")
            print("6. Directory: \u{2713} Already in directory as \"\(match.name)\" [\(match.category)]")
        } else {
            print("")
            print("6. Directory: not in directory")
        }
    }

    print("")
    if isStaleFeed {
        print("RESULT: FAIL — feed is stale (>6 months)")
    } else if qualityFailed {
        print("RESULT: WARN — thin or paywalled content (will still be included in directory)")
    } else {
        print("RESULT: PASS")
    }
}

// MARK: - Entry point

do {
    if CommandLine.arguments.contains("test"),
       let testIndex = CommandLine.arguments.firstIndex(of: "test"),
       testIndex + 1 < CommandLine.arguments.count {
        let url = CommandLine.arguments[testIndex + 1]
        try await runTest(url: url)
    } else if CommandLine.arguments.contains("discover") {
        try await runDiscover()
    } else if CommandLine.arguments.contains("verify") {
        try await runVerify()
    } else {
        try await runAudit()
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
