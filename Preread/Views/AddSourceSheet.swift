import SwiftUI
import SwiftSoup
import GRDB

struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when a source is successfully added, passing the new source ID.
    var onSourceAdded: ((UUID) -> Void)?

    // MARK: - State

    @State private var urlText = ""
    @State private var sheetState: SheetState = .input
    @State private var detectedFeed: DiscoveredFeed?
    @State private var editableName = ""
    @State private var selectedFrequency: FetchFrequency = .automatic
    @State private var selectedCacheLevel: CacheLevel = .standard
    @State private var existingSourceName: String?
    @State private var existingSourceID: UUID?
    @State private var cyclingTextIndex = 0
    @State private var cyclingTimer: Timer?
    @State private var shakeOffset: CGFloat = 0
    @State private var checkmarkScale: CGFloat = 0

    @FocusState private var isURLFieldFocused: Bool

    private enum SheetState {
        case input
        case detecting
        case feedFound
        case notFound
        case alreadySubscribed
    }

    private let cyclingTexts = [
        "Checking for a feed...",
        "Fetching feed details...",
        "Almost there..."
    ]

    private let popularPicks: [(name: String, url: String)] = [
        ("The Verge", "https://www.theverge.com"),
        ("Ars Technica", "https://arstechnica.com"),
        ("kottke.org", "https://kottke.org"),
    ]

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        switch sheetState {
                        case .input:
                            inputState
                        case .detecting:
                            detectingState
                        case .feedFound:
                            feedFoundState
                        case .notFound:
                            notFoundState
                        case .alreadySubscribed:
                            alreadySubscribedState
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .presentationDetents(sheetState == .feedFound ? [.fraction(0.9)] : [.fraction(0.6)])
            .presentationDragIndicator(.visible)
            .animation(Theme.gentleAnimation(response: 0.4, dampingFraction: 0.85), value: sheetState)
            .onAppear {
                isURLFieldFocused = true
            }
            .onDisappear {
                cyclingTimer?.invalidate()
            }
        }
    }

    // MARK: - State A: Input

    private var inputState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a source")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            // URL field
            HStack {
                TextField("Paste a site URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .focused($isURLFieldFocused)
                    .submitLabel(.go)
                    .onSubmit { startDetection() }

                Button {
                    if let clipboard = UIPasteboard.general.string {
                        urlText = clipboard
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Popular picks
            VStack(alignment: .leading, spacing: 10) {
                Text("Popular picks")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                HStack(spacing: 8) {
                    ForEach(popularPicks, id: \.url) { pick in
                        Button {
                            urlText = pick.url
                            startDetection()
                        } label: {
                            Text(pick.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Theme.surfaceRaised)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Theme.border, lineWidth: 1)
                                )
                        }
                    }
                }
            }

            Spacer().frame(height: 8)

            // CTA
            Button(action: startDetection) {
                Text("Look for articles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(Color.gray.opacity(0.3))
                            : AnyShapeStyle(Theme.accentGradient)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - State B: Detecting

    private var detectingState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a source")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            // Locked URL field
            HStack {
                Text(urlText)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Spacer().frame(height: 8)

            // CTA with spinner
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)

                Text(cyclingTexts[cyclingTextIndex])
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - State C: Feed Found

    private var feedFoundState: some View {
        VStack(spacing: 20) {
            // Feed header
            VStack(spacing: 12) {
                // Favicon
                if let siteURL = detectedFeed?.siteURL {
                    let faviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(siteURL.host ?? "")&sz=96")
                    AsyncImage(url: faviconURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        default:
                            letterAvatar(for: detectedFeed?.title ?? "?", size: 48)
                        }
                    }
                    .frame(width: 48, height: 48)
                } else {
                    letterAvatar(for: detectedFeed?.title ?? "?", size: 48)
                }

                Text(detectedFeed?.title ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(detectedFeed?.feedURL.absoluteString ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)

                // Article count pill
                if let count = detectedFeed?.items.count, count > 0 {
                    Text("\(count) articles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.accentGradient)
                        .clipShape(Capsule())
                }
            }

            // Editable name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                TextField("Source name", text: $editableName)
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Fetch frequency picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Check for new articles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                HStack(spacing: 8) {
                    frequencyCard(.automatic, title: "Auto", subtitle: "Periodically")
                    frequencyCard(.onOpen, title: "On open", subtitle: "When you launch")
                    frequencyCard(.manual, title: "Manual", subtitle: "Only when asked")
                }
            }

            // Save quality
            VStack(alignment: .leading, spacing: 6) {
                Text("Save quality")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                CacheFidelitySlider(selectedLevel: $selectedCacheLevel)
                    .padding(.horizontal, 4)
            }

            // Preview articles
            if let items = detectedFeed?.items.prefix(3), !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Here's what's inside")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                            Text(item.title)
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(16)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }

            // Primary CTA
            Button(action: addSource) {
                Text("Add to Preread")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            // Ghost button
            Button {
                resetToInput()
            } label: {
                Text("Not this one")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    // MARK: - State D: Not Found

    private var notFoundState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.textSecondary)
                .offset(x: shakeOffset)

            Text("No feed found")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("This site doesn't seem to have a public feed...")
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            // Ghost primary
            Button {
                resetToInput()
            } label: {
                Text("Try another URL")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }

            // Force-add link
            Button {
                Task { await forceAddSource() }
            } label: {
                Text("Add it anyway")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: - State E: Already Subscribed

    private var alreadySubscribedState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Image(systemName: "checkmark.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.accentGradient)
                .scaleEffect(checkmarkScale)
                .onAppear {
                    if Theme.reduceMotion {
                        checkmarkScale = 1.0
                    } else {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                            checkmarkScale = 1.0
                        }
                    }
                }

            Text("Already in your library")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            if let name = existingSourceName {
                Text("You're already subscribed to \(name).")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 8)

            Button {
                if let id = existingSourceID {
                    onSourceAdded?(id)
                }
                dismiss()
            } label: {
                Text("Take me there")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Frequency picker card

    private func frequencyCard(_ frequency: FetchFrequency, title: String, subtitle: String) -> some View {
        let isSelected = selectedFrequency == frequency
        return Button {
            selectedFrequency = frequency
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .white : Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceRaised))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.clear : Theme.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Letter avatar

    private func letterAvatar(for title: String, size: CGFloat) -> some View {
        let letter = String(title.prefix(1)).uppercased()
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(Theme.avatarGradient(for: title))
                .frame(width: size, height: size)
            Text(letter)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Actions

    private func startDetection() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Normalize URL
        var normalized = raw
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        urlText = normalized

        guard let url = URL(string: normalized) else { return }

        isURLFieldFocused = false
        sheetState = .detecting
        cyclingTextIndex = 0
        startCyclingTimer()

        Task {
            // Check for duplicate first
            do {
                let isDuplicate = try await FeedService.shared.checkForDuplicate(feedURL: normalized)
                if isDuplicate {
                    showAlreadySubscribed(feedURL: normalized)
                    return
                }
            } catch {
                // Continue with discovery
            }

            // Discover feed
            do {
                let feed = try await FeedService.shared.discoverFeed(from: url)

                // Check if discovered feed URL is a duplicate
                do {
                    let isDuplicate = try await FeedService.shared.checkForDuplicate(feedURL: feed.feedURL.absoluteString)
                    if isDuplicate {
                        showAlreadySubscribed(feedURL: feed.feedURL.absoluteString)
                        return
                    }
                } catch {
                    // Continue
                }

                stopCyclingTimer()
                detectedFeed = feed
                editableName = feed.title
                sheetState = .feedFound
            } catch {
                stopCyclingTimer()
                sheetState = .notFound
                triggerShake()
            }
        }
    }

    @MainActor
    private func showAlreadySubscribed(feedURL: String) {
        stopCyclingTimer()

        // Look up the existing source
        do {
            let source = try DatabaseManager.shared.dbPool.read { db in
                try Source.filter(Column("feedURL") == feedURL).fetchOne(db)
            }
            existingSourceName = source?.title
            existingSourceID = source?.id
        } catch {
            existingSourceName = nil
            existingSourceID = nil
        }

        checkmarkScale = 0.3
        sheetState = .alreadySubscribed
    }

    private func addSource() {
        guard let feed = detectedFeed else { return }

        Task {
            do {
                let nextSortOrder = try await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchCount(db)
                }

                // Build favicon URL from siteURL domain via Google's favicon service
                let iconURL: String? = {
                    guard let siteURL = feed.siteURL, let host = siteURL.host else { return nil }
                    return "https://www.google.com/s2/favicons?domain=\(host)&sz=96"
                }()

                let source = Source(
                    id: UUID(),
                    title: editableName.isEmpty ? feed.title : editableName,
                    feedURL: feed.feedURL.absoluteString,
                    siteURL: feed.siteURL?.absoluteString,
                    iconURL: iconURL,
                    addedAt: Date(),
                    lastFetchedAt: nil,
                    fetchFrequency: selectedFrequency,
                    fetchStatus: .idle,
                    cacheLevel: selectedCacheLevel,
                    sortOrder: nextSortOrder
                )

                try await DatabaseManager.shared.dbPool.write { db in
                    try source.save(db)
                }

                // Insert articles from feed
                try await DatabaseManager.shared.dbPool.write { db in
                    for item in feed.items {
                        let exists = try Article
                            .filter(Column("articleURL") == item.url.absoluteString)
                            .fetchCount(db) > 0
                        guard !exists else { continue }

                        let article = Article(
                            id: UUID(),
                            sourceID: source.id,
                            title: item.title,
                            articleURL: item.url.absoluteString,
                            publishedAt: item.publishedAt,
                            thumbnailURL: item.thumbnailURL?.absoluteString,
                            cachedAt: nil,
                            fetchStatus: .pending,
                            isRead: false,
                            isSaved: false,
                            cacheSizeBytes: nil,
                            lastHTTPStatus: nil,
                            etag: nil,
                            lastModified: nil
                        )
                        try article.save(db)
                    }
                }

                onSourceAdded?(source.id)
                dismiss()

                // Kick off caching in background
                Task {
                    await FetchCoordinator.shared.refreshSingleSource(source)
                }
            } catch {
                // Show error
                ToastManager.shared.show("Couldn't add source", type: .error)
            }
        }
    }

    private func forceAddSource() async {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else { return }

        // Try to fetch <title> from the page
        var pageTitle = url.host ?? "Untitled"
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let html = String(data: data, encoding: .utf8) {
                let doc = try SwiftSoup.parse(html)
                if let title = try? doc.title(), !title.isEmpty {
                    pageTitle = title
                }
            }
        } catch {
            // Use host as title
        }

        do {
            let nextSortOrder = try await DatabaseManager.shared.dbPool.read { db in
                try Source.fetchCount(db)
            }

            let source = Source(
                id: UUID(),
                title: pageTitle,
                feedURL: raw,
                siteURL: raw,
                iconURL: nil,
                addedAt: Date(),
                lastFetchedAt: nil,
                fetchFrequency: .manual,
                fetchStatus: .idle,
                cacheLevel: nil,
                sortOrder: nextSortOrder
            )

            try await DatabaseManager.shared.dbPool.write { db in
                try source.save(db)
            }

            // Insert the URL itself as a single article
            let article = Article(
                id: UUID(),
                sourceID: source.id,
                title: pageTitle,
                articleURL: raw,
                publishedAt: Date(),
                thumbnailURL: nil,
                cachedAt: nil,
                fetchStatus: .pending,
                isRead: false,
                isSaved: false,
                cacheSizeBytes: nil,
                lastHTTPStatus: nil,
                etag: nil,
                lastModified: nil
            )

            try await DatabaseManager.shared.dbPool.write { db in
                try article.save(db)
            }

            onSourceAdded?(source.id)
            dismiss()

            // Cache the single article
            Task {
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)
            }
        } catch {
            ToastManager.shared.show("Couldn't add source", type: .error)
        }
    }

    private func resetToInput() {
        urlText = ""
        detectedFeed = nil
        sheetState = .input
        isURLFieldFocused = true
    }

    // MARK: - Cycling timer

    private func startCyclingTimer() {
        cyclingTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                cyclingTextIndex = (cyclingTextIndex + 1) % cyclingTexts.count
            }
        }
    }

    private func stopCyclingTimer() {
        cyclingTimer?.invalidate()
        cyclingTimer = nil
    }

    // MARK: - Shake animation

    private func triggerShake() {
        withAnimation(.default) { shakeOffset = -10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = 10 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { shakeOffset = 0 }
        }
    }
}
