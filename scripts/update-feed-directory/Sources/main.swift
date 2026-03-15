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

func makeSession(timeout: TimeInterval = 15) -> URLSession {
    URLSession(configuration: {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = 5
        return config
    }())
}

// MARK: - Audit Mode

/// Reads the master feed list, validates each feed, removes broken/stale/thin entries,
/// writes the clean result to the app bundle, and prints a report of what was removed.
func runAudit() async throws {
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let masterURL = scriptDir.appendingPathComponent("master_feeds.json")
    let masterData = try Data(contentsOf: masterURL)
    let masterFeeds = try JSONDecoder().decode([DiscoverFeedOutput].self, from: masterData)
    print("📥 Loaded \(masterFeeds.count) feeds from master list")

    let session = makeSession()

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
        validatedFeeds = masterFeeds.map {
            ValidatedFeed(feed: $0, siteURL: $0.siteURL, newestItemDate: nil, articleURLs: [])
        }
    } else {
        print("Validating \(masterFeeds.count) feeds...")
        var validCount = 0
        var invalidCount = 0

        let batchSize = 10
        for batchStart in stride(from: 0, to: masterFeeds.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, masterFeeds.count)
            let batch = Array(masterFeeds[batchStart..<batchEnd])

            let results = await withTaskGroup(
                of: (DiscoverFeedOutput, FeedValidator.ValidationResult).self
            ) { group in
                for feed in batch {
                    group.addTask {
                        let result = await FeedValidator.validate(
                            feedURL: feed.feedURL, session: session
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
                        siteURL: result.siteURL ?? feed.siteURL,
                        newestItemDate: result.newestItemDate,
                        articleURLs: result.articleURLs
                    ))
                    validCount += 1
                    if verbose {
                        let dateStr = result.newestItemDate.map { dateFormatter.string(from: $0) } ?? "no date"
                        print("  \u{2713} \(feed.name) (\(feed.feedURL)) — newest: \(dateStr)")
                    }
                } else {
                    deadFeeds.append((name: feed.name, feedURL: feed.feedURL, category: feed.category))
                    invalidCount += 1
                    if verbose {
                        print("  \u{2717} \(feed.name) (\(feed.feedURL))")
                    }
                }
            }

            let progress = min(batchEnd, masterFeeds.count)
            print("  Progress: \(progress)/\(masterFeeds.count) (\(validCount) valid, \(invalidCount) dead)")
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

        // 2b. Content quality check
        let feedsToCheck = validatedFeeds.filter { !$0.articleURLs.isEmpty }

        if !feedsToCheck.isEmpty {
            print("Checking content quality for \(feedsToCheck.count) feeds...")

            let qualitySession = makeSession(timeout: 10)
            var thinFeedURLs = Set<String>()

            let qualityBatchSize = 5
            for batchStart in stride(from: 0, to: feedsToCheck.count, by: qualityBatchSize) {
                let batchEnd = min(batchStart + qualityBatchSize, feedsToCheck.count)
                let batch = Array(feedsToCheck[batchStart..<batchEnd])

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

                let progress = min(batchEnd, feedsToCheck.count)
                print("  Quality progress: \(progress)/\(feedsToCheck.count)")
            }

            if !thinFeedURLs.isEmpty {
                validatedFeeds.removeAll { thinFeedURLs.contains($0.feed.feedURL) }
                print("Thin content feeds removed: \(thinFeeds.count)")
                for thin in thinFeeds.sorted(by: { $0.words < $1.words }) {
                    print("   - \(thin.name) (\(thin.category)) — median: \(thin.words) words, \(thin.images) images")
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
        print("These feeds were excluded from the app output but remain in master_feeds.json.")
        print("Remove them from master_feeds.json if they should be permanently excluded.")
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
    let masterURL = scriptDir.appendingPathComponent("master_feeds.json")
    var masterNormalizedURLs = Set<String>()
    if let data = try? Data(contentsOf: masterURL),
       let masterFeeds = try? JSONDecoder().decode([DiscoverFeedOutput].self, from: data) {
        masterNormalizedURLs = Set(masterFeeds.map { normalizeFeedURL($0.feedURL) })
        print("Master list has \(masterFeeds.count) feeds")
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

        print("To add candidates to the master list, create entries in master_feeds.json with the format:")
        print("  { \"id\": \"<generated>\", \"name\": \"...\", \"feedURL\": \"...\", \"siteURL\": \"...\", \"description\": \"...\", \"category\": \"...\", \"country\": null, \"tags\": [] }")
    }
}

// MARK: - Entry point

do {
    if CommandLine.arguments.contains("discover") {
        try await runDiscover()
    } else {
        try await runAudit()
    }
} catch {
    print("Error: \(error)")
    exit(1)
}
