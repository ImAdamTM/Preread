import Foundation
import CryptoKit

// MARK: - Output model

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

// MARK: - Custom feed model

struct CustomFeed: Codable {
    let name: String
    let feedURL: String
    let siteURL: String?
    let description: String
    let category: String
    let country: String?
}

// MARK: - Exclusions model

struct FeedExclusions: Codable {
    let excludedDomains: [String]
    let excludedFeedURLs: [String]
}

// MARK: - Configuration

let gitHubAPIBase = "https://api.github.com/repos/plenaryapp/awesome-rss-feeds/contents"
let skipValidation = CommandLine.arguments.contains("--skip-validation")
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

/// Extracts the category name from an OPML filename like "Android Development.opml" → "Android Development"
func categoryFromFilename(_ filename: String) -> String {
    filename.replacingOccurrences(of: ".opml", with: "")
}

/// Shortens verbose feed titles by extracting the brand name.
func simplifyName(_ name: String, feedURL: String) -> String {
    let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return raw }

    // Normalize separators that appear without spaces (e.g. "Title| Subtitle" → "Title | Subtitle")
    let separatorChars: [Character] = ["|", "–", "—", "·", "•", "»"]
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
    let separators: Set<String> = ["-", "–", "—", "|", ">", ":", "·", "•", "»"]

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

        // Check if one side matches the domain — prefer that side as the brand name
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

    // Concatenated words match (e.g. "The Verge" → "theverge")
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

// MARK: - Main

func run() async throws {
    let scriptDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let session = URLSession(configuration: {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 5
        return config
    }())

    let parser = OPMLParser()
    var allRawFeeds: [OPMLParser.RawFeed] = []

    // 1. Fetch recommended category OPML file list from GitHub API
    print("📥 Fetching recommended category file list...")
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
                print("  ✓ \(categoryName): \(feeds.count) feeds")
            }
        } catch {
            print("  ✗ Failed to fetch \(categoryName): \(error.localizedDescription)")
        }
    }

    // 2. Fetch country OPML file list from GitHub API
    print("📥 Fetching country file list...")
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
                print("  ✓ \(countryName): \(feeds.count) feeds")
            }
        } catch {
            print("  ✗ Failed to fetch \(countryName): \(error.localizedDescription)")
        }
    }

    // 3. Load custom feeds
    let customFeedsURL = scriptDir.appendingPathComponent("custom_feeds.json")
    if let data = try? Data(contentsOf: customFeedsURL),
       let customFeeds = try? JSONDecoder().decode([CustomFeed].self, from: data) {
        print("📥 Loaded \(customFeeds.count) custom feeds")
        for cf in customFeeds {
            allRawFeeds.append(OPMLParser.RawFeed(
                name: cf.name,
                feedURL: cf.feedURL,
                description: cf.description,
                category: cf.category,
                country: cf.country,
                siteURL: cf.siteURL
            ))
        }
    }

    print("📊 Total raw feeds parsed: \(allRawFeeds.count)")

    // 4. Deduplicate by feed URL (keep first occurrence)
    var seenURLs = Set<String>()
    var uniqueFeeds: [OPMLParser.RawFeed] = []
    for feed in allRawFeeds {
        var normalized = feed.feedURL.lowercased()
        if normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        if seenURLs.insert(normalized).inserted {
            uniqueFeeds.append(feed)
        }
    }
    print("📊 After dedup: \(uniqueFeeds.count) unique feeds")

    // 3b. Apply exclusions
    let exclusionsURL = scriptDir.appendingPathComponent("feed_exclusions.json")
    var excludedDomains: Set<String> = []
    var excludedFeedURLs: Set<String> = []
    if let data = try? Data(contentsOf: exclusionsURL),
       let exclusions = try? JSONDecoder().decode(FeedExclusions.self, from: data) {
        excludedDomains = Set(exclusions.excludedDomains.map { $0.lowercased() })
        excludedFeedURLs = Set(exclusions.excludedFeedURLs.flatMap { raw -> [String] in
            var url = raw.lowercased()
            if url.hasSuffix("/") { url = String(url.dropLast()) }
            // Include both http and https variants
            if url.hasPrefix("https://") {
                return [url, "http://" + url.dropFirst("https://".count)]
            } else if url.hasPrefix("http://") {
                return [url, "https://" + url.dropFirst("http://".count)]
            }
            return [url]
        })
        print("🚫 Loaded exclusions: \(excludedDomains.count) domains, \(excludedFeedURLs.count) URLs")
    }

    let beforeExclusion = uniqueFeeds.count
    uniqueFeeds.removeAll { feed in
        var urlLower = feed.feedURL.lowercased()
        if urlLower.hasSuffix("/") { urlLower = String(urlLower.dropLast()) }
        if excludedFeedURLs.contains(urlLower) { return true }
        if excludedFeedURLs.contains(urlLower + "/") { return true }
        if let host = URL(string: feed.feedURL)?.host?.lowercased() {
            return excludedDomains.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        }
        return false
    }
    if beforeExclusion != uniqueFeeds.count {
        print("🚫 Excluded \(beforeExclusion - uniqueFeeds.count) feeds → \(uniqueFeeds.count) remaining")
    }

    // 4. Validate feeds (unless --skip-validation)
    var validatedFeeds: [(OPMLParser.RawFeed, String?)] = []

    if skipValidation {
        print("⏭️  Skipping validation (--skip-validation)")
        validatedFeeds = uniqueFeeds.map { ($0, $0.siteURL) }
    } else {
        print("🔍 Validating feeds (this may take a few minutes)...")
        var validCount = 0
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
                    validatedFeeds.append((feed, result.siteURL ?? feed.siteURL))
                    validCount += 1
                    if verbose {
                        print("  ✓ \(feed.name) (\(feed.feedURL))")
                    }
                } else {
                    invalidCount += 1
                    if verbose {
                        print("  ✗ \(feed.name) (\(feed.feedURL))")
                    }
                }
            }

            let progress = min(batchEnd, uniqueFeeds.count)
            print("  Progress: \(progress)/\(uniqueFeeds.count) (\(validCount) valid, \(invalidCount) dead)")
        }

        print("✅ Validation: \(validCount) valid, \(invalidCount) dead")
    }

    // 5. Load tag overrides
    let tagOverridesURL = scriptDir.appendingPathComponent("tag_overrides.json")
    var tagOverrides: [String: [String]] = [:]
    if let data = try? Data(contentsOf: tagOverridesURL),
       let parsed = try? JSONDecoder().decode([String: [String]].self, from: data) {
        tagOverrides = parsed
        print("🏷️  Loaded \(parsed.count) tag overrides")
    } else {
        print("🏷️  No tag overrides found (or empty)")
    }

    // 6. Build output
    var outputFeeds: [DiscoverFeedOutput] = []
    for (feed, siteURL) in validatedFeeds {
        let tags = tagOverrides[feed.feedURL] ?? []

        // Upgrade http:// to https:// (iOS ATS blocks plain HTTP)
        let finalFeedURL: String
        if feed.feedURL.lowercased().hasPrefix("http://") {
            finalFeedURL = "https://" + feed.feedURL.dropFirst("http://".count)
        } else {
            finalFeedURL = feed.feedURL
        }

        // CDN / feed-hosting domains that don't represent the actual publisher's site.
        // A siteURL pointing here won't have a favicon or meaningful homepage.
        let cdnDomains: Set<String> = [
            "feeds.feedburner.com", "feeds2.feedburner.com", "feedburner.com",
            "feedproxy.google.com", "feeds.feedblitz.com", "rss.nytimes.com",
            "feeds.megaphone.fm", "feeds.simplecast.com", "feeds.transistor.fm",
            "feeds.fireside.fm", "feeds.acast.com", "anchor.fm",
            "rss.art19.com", "feeds.soundcloud.com",
        ]

        // Also treat any host starting with these prefixes as a CDN-like domain
        // (e.g. feeds.bbci.co.uk, rss.sciam.com, feeds.skynews.com)
        func isCDNHost(_ host: String) -> Bool {
            if cdnDomains.contains(host) { return true }
            let feedPrefixes = ["feeds.", "feeds2.", "rss.", "feed."]
            return feedPrefixes.contains(where: { host.hasPrefix($0) })
        }

        let finalSiteURL: String?
        if let siteURL, !siteURL.isEmpty,
           let siteHost = URL(string: siteURL)?.host?.lowercased(),
           !isCDNHost(siteHost) {
            if siteURL.lowercased().hasPrefix("http://") {
                finalSiteURL = "https://" + siteURL.dropFirst("http://".count)
            } else {
                finalSiteURL = siteURL
            }
        } else if let url = URL(string: feed.feedURL), let host = url.host,
                  !isCDNHost(host.lowercased()) {
            finalSiteURL = "https://\(host)"
        } else {
            finalSiteURL = nil
        }

        // Fall back to domain name if OPML had no title, then simplify verbose titles
        let genericNames: Set<String> = [
            "blog feed", "rss feed", "feed", "blog", "news", "home", "rss",
        ]
        let feedName: String
        if feed.name.isEmpty || genericNames.contains(feed.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)),
           let url = URL(string: feed.feedURL), let host = url.host {
            feedName = host
                .replacingOccurrences(of: "www.", with: "")
                .replacingOccurrences(of: "feeds.", with: "")
        } else {
            feedName = simplifyName(feed.name, feedURL: finalFeedURL)
        }

        outputFeeds.append(DiscoverFeedOutput(
            id: deterministicID(from: finalFeedURL),
            name: feedName,
            feedURL: finalFeedURL,
            siteURL: finalSiteURL,
            description: feed.description,
            category: feed.category,
            country: feed.country,
            tags: tags
        ))
    }
    outputFeeds.sort {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }

    // 7. Write JSON output
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
    print("🎉 Done! Generated \(outputFeeds.count) feeds (\(sizeKB)KB)")
    print("   Output: \(outputPath.path)")

    let categoryCounts = Dictionary(grouping: outputFeeds, by: \.category)
        .mapValues(\.count)
        .sorted { $0.value > $1.value }

    print("")
    print("📊 Categories:")
    for (category, count) in categoryCounts {
        print("   \(category): \(count)")
    }
}

// Run
do {
    try await run()
} catch {
    print("❌ Error: \(error)")
    exit(1)
}
