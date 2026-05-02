import AppIntents
import SwiftUI
import SwiftSoup
import GRDB

struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Optional URL to pre-fill and auto-detect. Used by the Share Extension deep link.
    var initialURL: String? = nil

    /// Called when a source is successfully added, passing the new source ID.
    var onSourceAdded: ((UUID) -> Void)?

    /// Called when a single webpage is saved (force-add), to navigate to the Saved view.
    var onSavedArticle: (() -> Void)?

    // MARK: - State

    @State private var urlText = ""
    @State private var sheetState: SheetState = .input
    @State private var detectedFeed: DiscoveredFeed?
    @State private var editableName = ""
    @State private var selectedCacheLevel: CacheLevel = .standard
    @State private var existingSourceName: String?
    @State private var existingSourceID: UUID?
    @State private var cyclingTextIndex = 0
    @State private var cyclingTimer: Timer?
    @State private var shakeOffset: CGFloat = 0
    @State private var checkmarkScale: CGFloat = 0
    @State private var isLoadingPageTitle = false
    @State private var shimmerOffset: CGFloat = -1.0
    @State private var detectingShimmerOffset: CGFloat = -1.0
    @State private var cyclingTextOffset: CGFloat = 0
    @State private var cyclingTextOpacity: Double = 1.0
    @State private var sheetContentHeight: CGFloat = 350
    @State private var detentSet: Set<PresentationDetent> = [.height(350), .large]
    @State private var selectedDetent: PresentationDetent = .height(350)
    @State private var showSourceLimitAlert = false
    @State private var previewFavicon: UIImage?

    // Discover state
    @State private var searchResults: [DiscoverFeed] = []
    @State private var subscribedURLs: Set<String> = []
    @State private var subscribedSiteURLs: Set<String> = []
    @State private var discoverFaviconCache: [String: UIImage] = [:]
    @State private var searchTask: Task<Void, Never>?
    @State private var discoverNavPath: [String] = []
    @State private var addedSourceName: String?

    @FocusState private var isURLFieldFocused: Bool

    /// True when the user typed a search term rather than a URL.
    private var isSearchMode: Bool {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        // If it already has a scheme, it's a URL
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") { return false }
        // If it contains a dot followed by letters (e.g. "example.com"), treat as URL
        let dotPattern = #"\.[a-zA-Z]{2,}"#
        if raw.range(of: dotPattern, options: .regularExpression) != nil { return false }
        // Otherwise it's a search term
        return true
    }

    private enum SheetState: Equatable {
        case input
        case detecting
        case feedFound
        case savePage
        case notFound
        case alreadySubscribed
        case sourceAdded
    }

    private var cyclingTexts: [String] {
        [
            "Checking for a feed...",
            "Fetching feed details...",
            "Almost there..."
        ]
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $discoverNavPath) {
            VStack(spacing: 24) {
                switch sheetState {
                case .input:
                    inputState
                        .transition(.opacity)
                case .detecting:
                    detectingState
                        .transition(.opacity)
                case .feedFound:
                    feedFoundState
                        .transition(.opacity)
                case .savePage:
                    savePageState
                        .transition(.opacity)
                case .notFound:
                    notFoundState
                        .transition(.opacity)
                case .alreadySubscribed:
                    alreadySubscribedState
                        .transition(.opacity)
                case .sourceAdded:
                    sourceAddedState
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.snappy(duration: 0.2), value: sheetState)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let h = geo.size.height + 76
                            sheetContentHeight = h
                            detentSet = [.height(h), .large]
                            selectedDetent = .height(h)
                        }
                        .onChange(of: geo.size.height) { _, newHeight in
                            let adjusted = newHeight + 76
                            guard abs(adjusted - sheetContentHeight) > 1 else { return }
                            sheetContentHeight = adjusted
                            let newDetent = PresentationDetent.height(adjusted)
                            detentSet.insert(newDetent)
                            withAnimation(.snappy(duration: 0.25)) {
                                selectedDetent = newDetent
                            }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(300))
                                detentSet = [selectedDetent, .large]
                            }
                        }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.sheetBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(Theme.scaledFont(size: 17))
                    .foregroundColor(Theme.textSecondary)
                }
            }
            .navigationDestination(for: String.self) { value in
                if value == "__discover__" {
                    discoverCategoryListDestination
                } else if value == "__countries__" {
                    countryListDestination
                } else {
                    categoryFeedListDestination(category: value)
                }
            }
        }
        .presentationDetents(detentSet, selection: $selectedDetent)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.sheetBackground)
        .onChange(of: discoverNavPath) { oldPath, newPath in
            if newPath.isEmpty && !oldPath.isEmpty {
                let detent = PresentationDetent.height(sheetContentHeight)
                detentSet.insert(detent)
                withAnimation(.snappy(duration: 0.25)) {
                    selectedDetent = detent
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    detentSet = [selectedDetent, .large]
                }
            }
        }
        .alert("Source limit reached", isPresented: $showSourceLimitAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You've reached the maximum of \(Source.maxSources) sources. Remove a source in Settings to make room.")
        }
        .onAppear {
            if let url = initialURL, !url.isEmpty {
                urlText = url
            }
            isURLFieldFocused = true
            subscribedURLs = FeedDirectory.shared.subscribedFeedURLs()
            subscribedSiteURLs = FeedDirectory.shared.subscribedSiteURLs()
        }
        .onDisappear {
            cyclingTimer?.invalidate()
            searchTask?.cancel()
        }
    }

    // MARK: - State A: Input

    private var inputState: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a source")
                    .font(Theme.scaledFont(size: 28, weight: .regular))
                    .foregroundColor(Theme.textPrimary)
                Text("Search or paste a link")
                    .font(Theme.scaledFont(size: 15))
                    .foregroundColor(Theme.textSecondary)
            }

            // URL field
            HStack {
                TextField("Search or paste a link", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.default)
                    .font(Theme.scaledFont(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .focused($isURLFieldFocused)
                    .submitLabel(looksLikeURL(urlText) ? .go : .done)
                    .onSubmit {
                        if looksLikeURL(urlText) {
                            startDetection()
                        } else {
                            isURLFieldFocused = false
                        }
                    }

                if !urlText.isEmpty {
                    Button {
                        urlText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(Theme.scaledFont(size: 16))
                            .foregroundColor(Theme.textSecondary.opacity(0.6))
                    }
                } else {
                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            urlText = clipboard
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(Theme.scaledFont(size: 16))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onChange(of: urlText) { _, newValue in
                debounceSearch(query: newValue)
            }

            // Search results or CTAs
            if isSearchMode && !searchResults.isEmpty {
                discoverSearchResults
            } else if isSearchMode && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Search mode with no results
                VStack(spacing: 6) {
                    Text("No feeds found for \"\(urlText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                        .font(Theme.scaledFont(size: 14))
                        .foregroundColor(Theme.textSecondary)
                    Text("Try a different term or paste a feed URL")
                        .font(Theme.scaledFont(size: 12))
                        .foregroundColor(Theme.textSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                let isEmpty = urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                HStack(spacing: 14) {
                    // Primary CTA
                    Button(action: startDetection) {
                        Text("Find articles")
                            .font(Theme.scaledFont(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                isEmpty
                                    ? AnyShapeStyle(Color.gray.opacity(0.3))
                                    : AnyShapeStyle(Theme.accentGradient)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(isEmpty)

                    // Secondary CTA
                    Button(action: startSavePageFlow) {
                        Text("Save single page")
                            .font(Theme.scaledFont(size: 15, weight: .medium))
                            .foregroundColor(isEmpty ? Theme.textSecondary.opacity(0.5) : Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isEmpty ? Theme.border.opacity(0.5) : Theme.border, lineWidth: 1)
                            )
                    }
                    .disabled(isEmpty)
                }
            }

            // Discover link
            Button {
                navigateToDiscover()
            } label: {
                HStack(spacing: 5) {
                    Text("Browse topics")
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                }
                .font(Theme.scaledFont(size: 15, weight: .medium))
                .foregroundColor(.white)
                .overlay(
                    Theme.accentGradient
                        .mask(
                            HStack(spacing: 5) {
                                Text("Browse topics")
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .font(Theme.scaledFont(size: 15, weight: .medium))
                        )
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    // MARK: - Discover search results

    private var discoverSearchResults: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, feed in
                    if index > 0 {
                        Divider()
                            .background(Theme.border)
                    }
                    DiscoverFeedRow(
                        feed: feed,
                        isSubscribed: isDiscoverFeedSubscribed(feed),
                        favicon: discoverFaviconCache[feed.siteURL ?? feed.feedURL],
                        onTap: { selectDiscoverFeed(feed) }
                    )
                    .task {
                        await loadDiscoverFavicon(for: feed)
                    }
                }
            }
        }
        .frame(maxHeight: 340)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    // MARK: - Discover category list destination

    private var discoverCategoryListDestination: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Browse topics")
                    .font(Theme.scaledFont(size: 28, weight: .regular))
                    .foregroundColor(Theme.textPrimary)

                // Topic categories
                VStack(spacing: 0) {
                    ForEach(Array(FeedDirectory.shared.categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 {
                            Divider()
                                .background(Theme.border)
                        }
                        Button {
                            discoverNavPath.append(category.name)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: category.icon)
                                    .font(Theme.scaledFont(size: 14))
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(width: 24)
                                Text(category.name)
                                    .font(Theme.scaledFont(size: 15, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                Text("\(category.feedCount)")
                                    .font(Theme.scaledFont(size: 13))
                                    .foregroundColor(Theme.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(Theme.scaledFont(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary.opacity(0.5))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Countries row
                    Divider()
                        .background(Theme.border)

                    Button {
                        discoverNavPath.append("__countries__")
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "globe")
                                .font(Theme.scaledFont(size: 14))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 24)
                            Text("Countries")
                                .font(Theme.scaledFont(size: 15, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(Theme.scaledFont(size: 12, weight: .semibold))
                                .foregroundColor(Theme.textSecondary.opacity(0.5))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Theme.sheetBackground)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Country list navigation destination

    private var countryListDestination: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(Theme.scaledFont(size: 20))
                        .foregroundColor(Theme.textSecondary)
                    Text("Countries")
                        .font(Theme.scaledFont(size: 28, weight: .regular))
                        .foregroundColor(Theme.textPrimary)
                }

                // Country list
                VStack(spacing: 0) {
                    ForEach(Array(FeedDirectory.shared.countries.enumerated()), id: \.element.id) { index, country in
                        if index > 0 {
                            Divider()
                                .background(Theme.border)
                        }
                        Button {
                            discoverNavPath.append(country.name)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: country.icon)
                                    .font(Theme.scaledFont(size: 14))
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(width: 24)
                                Text(country.name)
                                    .font(Theme.scaledFont(size: 15, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                Text("\(country.feedCount)")
                                    .font(Theme.scaledFont(size: 13))
                                    .foregroundColor(Theme.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(Theme.scaledFont(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textSecondary.opacity(0.5))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Theme.sheetBackground)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Category / country feed list destination

    private func categoryFeedListDestination(category: String) -> some View {
        let feeds = FeedDirectory.shared.feeds(in: category)
        let isCountry = FeedDirectory.shared.countries.contains(where: { $0.name == category })
        let icon: String
        if isCountry {
            icon = FeedDirectory.shared.countries.first(where: { $0.name == category })?.icon ?? "globe"
        } else {
            icon = FeedDirectory.shared.categories.first(where: { $0.name == category })?.icon ?? "square.grid.2x2"
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Category header
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(Theme.scaledFont(size: 20))
                        .foregroundColor(Theme.textSecondary)
                    Text(category)
                        .font(Theme.scaledFont(size: 28, weight: .regular))
                        .foregroundColor(Theme.textPrimary)
                }

                Text("\(feeds.count) feeds")
                    .font(Theme.scaledFont(size: 13))
                    .foregroundColor(Theme.textSecondary)

                // Feed list
                VStack(spacing: 0) {
                    ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
                        if index > 0 {
                            Divider()
                                .background(Theme.border)
                        }
                        DiscoverFeedRow(
                            feed: feed,
                            isSubscribed: isDiscoverFeedSubscribed(feed),
                            favicon: discoverFaviconCache[feed.siteURL ?? feed.feedURL],
                            onTap: { selectDiscoverFeed(feed) }
                        )
                        .task {
                            await loadDiscoverFavicon(for: feed)
                        }
                    }
                }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
        .background(Theme.sheetBackground)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - State B: Detecting

    private var detectingState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add a source")
                .font(Theme.scaledFont(size: 28, weight: .regular))
                .foregroundColor(Theme.textPrimary)

            // Locked URL field
            HStack {
                Text(urlText)
                    .font(Theme.scaledFont(size: 16))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Spinner + cycling text (inline, not a button)
            HStack(spacing: 14) {
                ProgressView()
                    .tint(Theme.accent)

                ZStack {
                    Text(cyclingTexts[cyclingTextIndex])
                        .font(Theme.scaledFont(size: 15, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                        .opacity(cyclingTextOpacity)
                        .offset(y: cyclingTextOffset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if !Theme.reduceMotion {
                    startDetectingShimmer()
                }
            }

            // Disabled placeholder buttons to maintain height
            HStack(spacing: 14) {
                Text("Find articles")
                    .font(Theme.scaledFont(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.gray.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text("Save single page")
                    .font(Theme.scaledFont(size: 15, weight: .medium))
                    .foregroundColor(Theme.textSecondary.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.surfaceRaised.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.border.opacity(0.3), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - State C: Feed Found

    private var feedFoundState: some View {
        VStack(spacing: 16) {
            Text("Ready to Preread")
                .font(Theme.scaledFont(size: 28, weight: .regular))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Feed header — favicon left, details right
            HStack(spacing: 14) {
                // Favicon — show real icon if fetched, else letter avatar
                if let favicon = previewFavicon {
                    Image(uiImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .background(Theme.faviconBackground, in: RoundedRectangle(cornerRadius: 44 * 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 44 * 0.2))
                } else {
                    letterAvatar(for: editableName.isEmpty ? "?" : editableName, size: 44)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(detectedFeed?.feedURL.absoluteString ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)

                    // Article count pill
                    if let count = detectedFeed?.items.count, count > 0 {
                        Text("\(count) articles")
                            .font(Theme.scaledFont(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accentGradient)
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Editable name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(Theme.scaledFont(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                TextField("Source name", text: $editableName)
                    .font(Theme.scaledFont(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Preview articles
            if let items = detectedFeed?.items.prefix(3), !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent articles")
                        .font(Theme.scaledFont(size: 13, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 5, height: 5)
                            Text(item.title)
                                .font(Theme.scaledFont(size: 13))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(12)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 1)
                )
            }

            // Primary CTA
            Button(action: addSource) {
                ZStack {
                    Text("Add to Preread")
                        .font(Theme.scaledFont(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    // Shimmer highlight masked to the text shape
                    if !Theme.reduceMotion {
                        Text("Add to Preread")
                            .font(Theme.scaledFont(size: 16, weight: .semibold))
                            .foregroundColor(.clear)
                            .overlay(ctaShimmerOverlay)
                            .mask(
                                Text("Add to Preread")
                                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .onAppear {
                if !Theme.reduceMotion {
                    startCTAShimmer()
                }
            }

            // Ghost button
            Button {
                resetToInput()
            } label: {
                Text("Not this one")
                    .font(Theme.scaledFont(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    // MARK: - State D: Save Page

    private var savePageState: some View {
        VStack(spacing: 16) {
            Text("Ready to Preread")
                .font(Theme.scaledFont(size: 28, weight: .regular))
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Page header — favicon left, URL right
            HStack(spacing: 14) {
                // Favicon (letter avatar; real favicon is cached when page is saved)
                letterAvatar(for: editableName.isEmpty ? "?" : editableName, size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(urlText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Editable name
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(Theme.scaledFont(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                HStack {
                    TextField("Page name", text: $editableName)
                        .font(Theme.scaledFont(size: 16))
                        .foregroundColor(Theme.textPrimary)

                    if isLoadingPageTitle {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Save quality
            VStack(alignment: .leading, spacing: 6) {
                Text("Save quality")
                    .font(Theme.scaledFont(size: 13, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                CacheFidelitySlider(selectedLevel: $selectedCacheLevel)
            }

            // Primary CTA
            Button(action: { Task { await savePage() } }) {
                ZStack {
                    Text("Save to Preread")
                        .font(Theme.scaledFont(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    // Shimmer highlight masked to the text shape
                    if !Theme.reduceMotion {
                        Text("Save to Preread")
                            .font(Theme.scaledFont(size: 16, weight: .semibold))
                            .foregroundColor(.clear)
                            .overlay(ctaShimmerOverlay)
                            .mask(
                                Text("Save to Preread")
                                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .onAppear {
                if !Theme.reduceMotion {
                    startCTAShimmer()
                }
            }

            // Ghost button
            Button {
                resetToInput()
            } label: {
                Text("Not this one")
                    .font(Theme.scaledFont(size: 14, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
    }

    // MARK: - State E: Not Found

    private var notFoundState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Image(systemName: "magnifyingglass")
                .font(Theme.scaledFont(size: 48, weight: .light))
                .foregroundColor(Theme.textSecondary)
                .offset(x: shakeOffset)

            Text("No feed found")
                .font(Theme.scaledFont(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("This site doesn't seem to have a public feed...")
                .font(Theme.scaledFont(size: 15))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            // Ghost primary
            Button {
                resetToInput()
            } label: {
                Text("Try another URL")
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
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

            // Save as single page
            Button {
                startSavePageFlow()
            } label: {
                Text("Save it anyway")
                    .font(Theme.scaledFont(size: 14, weight: .medium))
                    .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: - State E: Already Subscribed

    private var alreadySubscribedState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)

            Image(systemName: "checkmark.circle")
                .font(Theme.scaledFont(size: 56, weight: .light))
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
                .font(Theme.scaledFont(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            if let name = existingSourceName {
                Text("You're already subscribed to \(name).")
                    .font(Theme.scaledFont(size: 15))
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
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - State F: Source Added

    private var sourceAddedState: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 4)

            Image(systemName: "checkmark.circle")
                .font(Theme.scaledFont(size: 56, weight: .light))
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

            Text("Source added")
                .font(Theme.scaledFont(size: 22, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            if let name = addedSourceName {
                Text("\(name) is now in your library.")
                    .font(Theme.scaledFont(size: 15))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer().frame(height: 8)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(Theme.scaledFont(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button {
                resetToInput()
            } label: {
                Text("Add another source")
                    .font(Theme.scaledFont(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .overlay(
                        Theme.accentGradient
                            .mask(
                                Text("Add another source")
                                    .font(Theme.scaledFont(size: 14, weight: .medium))
                            )
                    )
            }
        }
    }

    // MARK: - Frequency picker card

    // MARK: - CTA shimmer

    private var ctaShimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color(red: 1.0, green: 0.7, blue: 0.85).opacity(0.6),
                    Color(red: 1.0, green: 0.75, blue: 0.88),
                    Color(red: 1.0, green: 0.7, blue: 0.85).opacity(0.6),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.35)
            .offset(x: shimmerOffset * geo.size.width)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private var detectingShimmerOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color(red: 1.0, green: 0.7, blue: 0.85).opacity(0.6),
                    Color(red: 1.0, green: 0.75, blue: 0.88),
                    Color(red: 1.0, green: 0.7, blue: 0.85).opacity(0.6),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.35)
            .offset(x: detectingShimmerOffset * geo.size.width)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private func startDetectingShimmer() {
        detectingShimmerOffset = -1.0
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: false)
            .delay(0.3)
        ) {
            detectingShimmerOffset = 1.2
        }
    }

    private func startCTAShimmer() {
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: false)
            .delay(0.5)
        ) {
            shimmerOffset = 1.2
        }
    }

    // MARK: - Favicon preview

    private func fetchPreviewFavicon(for feed: DiscoveredFeed) {
        previewFavicon = nil
        guard let siteURL = feed.siteURL else { return }
        Task {
            let image = await PageCacheService.shared.fetchFaviconImage(siteURL: siteURL)
            previewFavicon = image
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
                .font(Theme.scaledFont(size: size * 0.45, weight: .bold))
                .foregroundColor(.white)
        }
    }

    // MARK: - Helpers

    private func looksLikeURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(".") && !trimmed.contains(" ")
    }

    // MARK: - Actions

    private func startDetection() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        isURLFieldFocused = false
        sheetState = .detecting
        cyclingTextIndex = 0
        startCyclingTimer()

        // Normalize and run full discovery pipeline
        var normalized = raw
        if !normalized.lowercased().hasPrefix("http://") && !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        urlText = normalized

        guard let url = URL(string: normalized) else { return }

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
                    let isDuplicate = try await FeedService.shared.checkForDuplicate(
                        feedURL: feed.feedURL.absoluteString,
                        siteURL: feed.siteURL?.absoluteString
                    )
                    if isDuplicate {
                        showAlreadySubscribed(feedURL: feed.feedURL.absoluteString, siteURL: feed.siteURL?.absoluteString)
                        return
                    }
                } catch {
                    // Continue
                }

                stopCyclingTimer()
                detectedFeed = feed
                // If the user pasted a Google News RSS URL, use the domain
                // from the query instead of the raw feed title
                if feed.feedURL.host?.lowercased() == "news.google.com",
                   let inputURL = URL(string: normalized) {
                    let domain = inputURL.host?.replacingOccurrences(of: "www.", with: "") ?? feed.title
                    editableName = domain
                } else {
                    editableName = smartTitle(from: feed)
                }
                sheetState = .feedFound
                fetchPreviewFavicon(for: feed)
            } catch {
                stopCyclingTimer()
                sheetState = .notFound
                triggerShake()
            }
        }
    }

    @MainActor
    private func showAlreadySubscribed(feedURL: String, siteURL: String? = nil) {
        stopCyclingTimer()

        // Look up the existing source using normalized URL + siteURL comparison
        let source = FeedDirectory.shared.findExistingSource(feedURL: feedURL, siteURL: siteURL)
        existingSourceName = source?.title
        existingSourceID = source?.id

        checkmarkScale = 0.3
        sheetState = .alreadySubscribed
    }

    private func addSource() {
        guard let feed = detectedFeed else { return }

        Task {
            do {
                let userSourceCount = try await DatabaseManager.shared.dbPool.read { db in
                    let total = try Source.fetchCount(db)
                    // Exclude the hidden "Saved Pages" source from the count
                    return total - 1
                }

                if userSourceCount >= Source.maxSources {
                    showSourceLimitAlert = true
                    return
                }

                let source = Source(
                    id: UUID(),
                    title: editableName.isEmpty ? feed.title : editableName,
                    feedURL: feed.feedURL.absoluteString,
                    siteURL: feed.siteURL?.absoluteString,
                    iconURL: nil,
                    addedAt: Date(),
                    lastFetchedAt: nil,
                    fetchFrequency: .automatic,
                    fetchStatus: .idle,
                    cacheLevel: .standard,
                    appearanceMode: nil,
                    layout: nil,
                    homeLayout: nil,
                    isCollapsed: false,
                    sortOrder: 0
                )

                try await DatabaseManager.shared.dbPool.write { db in
                    // Bump all existing sources down to make room at the top
                    try db.execute(
                        sql: "UPDATE source SET sortOrder = sortOrder + 1 WHERE id != ?",
                        arguments: [Source.savedPagesID.uuidString]
                    )
                    try source.save(db)
                }

                // Save the already-fetched preview favicon to disk so the
                // source card can display it immediately. If the preview
                // hasn't loaded yet, kick off a background fetch instead.
                if let favicon = previewFavicon {
                    await PageCacheService.shared.saveFavicon(favicon, for: source.id)
                } else if let siteURL = feed.siteURL {
                    Task {
                        await PageCacheService.shared.discoverAndCacheFavicon(for: source.id, siteURL: siteURL)
                    }
                }

                onSourceAdded?(source.id)

                subscribedURLs.insert(FeedDirectory.normalizeURL(source.feedURL))
                if let siteURL = source.siteURL {
                    subscribedSiteURLs.insert(FeedDirectory.normalizeURL(siteURL))
                }

                addedSourceName = source.title
                checkmarkScale = 0.3
                sheetState = .sourceAdded

                PrereadShortcutsProvider.updateAppShortcutParameters()

                // Kick off article insertion + caching in background
                Task {
                    await FetchCoordinator.shared.refreshSingleSource(source)
                }
            } catch {
                // Show error
                ToastManager.shared.show("Couldn't add source", type: .error)
            }
        }
    }

    private func startSavePageFlow() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        var normalized = raw
        if !normalized.lowercased().hasPrefix("http://"),
           !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://\(normalized)"
        }
        urlText = normalized

        guard let url = URL(string: normalized) else { return }

        isURLFieldFocused = false
        selectedCacheLevel = .standard

        // Pre-fill with domain, improve with <title> in background
        editableName = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Untitled"

        sheetState = .savePage

        // Fetch <title> in background
        isLoadingPageTitle = true
        Task {
            defer { isLoadingPageTitle = false }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let html = String(data: data, encoding: .utf8) {
                    let doc = try SwiftSoup.parse(html)
                    if let title = try? doc.title(), !title.isEmpty {
                        editableName = shortenTitle(title, url: url)
                    }
                }
            } catch {
                // Keep domain name fallback
            }
        }
    }

    private func savePage() async {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // Check if this URL is already saved
            let existing = try await DatabaseManager.shared.dbPool.read { db in
                try Article.filter(Column("articleURL") == raw).fetchOne(db)
            }

            if let existing {
                // Already exists — mark as saved and navigate there
                if !existing.isSaved {
                    var updated = existing
                    updated.isSaved = true
                    updated.savedAt = Date()
                    let articleToSave = updated
                    try await DatabaseManager.shared.dbPool.write { db in
                        try articleToSave.update(db)
                    }
                }
                ToastManager.shared.snack("Already in your collection", icon: "bookmark.fill")
                onSavedArticle?()
                dismiss()
                return
            }

            let title = editableName.trimmingCharacters(in: .whitespacesAndNewlines)

            let article = Article(
                id: UUID(),
                sourceID: Source.savedPagesID,
                title: title.isEmpty ? (URL(string: raw)?.host ?? "Untitled") : title,
                articleURL: raw,
                publishedAt: Date(),
                addedAt: Date(),
                thumbnailURL: nil,
                cachedAt: nil,
                fetchStatus: .pending,
                isRead: false,
                isSaved: true,
                savedAt: Date(),
                originalSourceName: URL(string: raw)?.host?.replacingOccurrences(of: "www.", with: ""),
                originalSourceIconURL: nil,
                cacheSizeBytes: nil,
                lastHTTPStatus: nil,
                etag: nil,
                lastModified: nil,
                retryCount: 0
            )

            try await DatabaseManager.shared.dbPool.write { db in
                try article.save(db)
            }

            ToastManager.shared.snack("Saved to your collection", icon: "bookmark.fill")
            onSavedArticle?()
            dismiss()

            // Cache article content in background — performCacheArticle
            // handles favicon discovery from the page HTML automatically
            let cacheLevel = selectedCacheLevel
            Task {
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            }
        } catch {
            ToastManager.shared.show("Couldn't save page", type: .error)
        }
    }

    private func resetToInput() {
        urlText = ""
        detectedFeed = nil
        previewFavicon = nil
        searchResults = []
        sheetState = .input
        isURLFieldFocused = true
    }

    // MARK: - Discover actions

    private func debounceSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, isSearchMode else {
            searchResults = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            searchResults = FeedDirectory.shared.search(trimmed, limit: 20)
        }
    }

    /// Grows the sheet to .large first, then pushes the discover category list
    /// after the detent animation settles — avoids content clipping during transition.
    private func navigateToDiscover() {
        withAnimation(Theme.gentleAnimation(response: 0.4, dampingFraction: 0.85)) {
            selectedDetent = .large
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            discoverNavPath = ["__discover__"]
        }
    }

    private func selectDiscoverFeed(_ feed: DiscoverFeed) {
        urlText = feed.feedURL
        editableName = feed.name
        isURLFieldFocused = false
        discoverNavPath = []
        sheetState = .detecting
        cyclingTextIndex = 0
        startCyclingTimer()

        let cachedFavicon = discoverFaviconCache[feed.siteURL ?? feed.feedURL]

        Task {
            do {
                let isDuplicate = try await FeedService.shared.checkForDuplicate(feedURL: feed.feedURL, siteURL: feed.siteURL)
                if isDuplicate {
                    showAlreadySubscribed(feedURL: feed.feedURL, siteURL: feed.siteURL)
                    return
                }
            } catch {
                // Continue with discovery
            }

            guard let feedURL = URL(string: feed.feedURL) else {
                stopCyclingTimer()
                sheetState = .notFound
                triggerShake()
                return
            }

            let siteURL = feed.siteURL.flatMap { URL(string: $0) }

            do {
                let discovered = try await FeedService.shared.parseFeed(from: feedURL, siteURL: siteURL)

                do {
                    let isDuplicate = try await FeedService.shared.checkForDuplicate(
                        feedURL: discovered.feedURL.absoluteString,
                        siteURL: discovered.siteURL?.absoluteString
                    )
                    if isDuplicate {
                        showAlreadySubscribed(feedURL: discovered.feedURL.absoluteString, siteURL: discovered.siteURL?.absoluteString)
                        return
                    }
                } catch {
                    // Continue
                }

                stopCyclingTimer()
                detectedFeed = discovered
                editableName = feed.name
                sheetState = .feedFound

                if let cachedFavicon {
                    previewFavicon = cachedFavicon
                } else {
                    fetchPreviewFavicon(for: discovered)
                }
            } catch {
                stopCyclingTimer()
                sheetState = .notFound
                triggerShake()
            }
        }
    }

    private func loadDiscoverFavicon(for feed: DiscoverFeed) async {
        let key = feed.siteURL ?? feed.feedURL
        guard discoverFaviconCache[key] == nil else { return }
        guard let siteURL = feed.siteURL ?? URL(string: feed.feedURL)?.host.map({ "https://\($0)" }) else { return }
        let image = await PageCacheService.shared.fetchFaviconImage(siteURL: URL(string: siteURL)!)
        if let image {
            discoverFaviconCache[key] = image
        }
    }

    // MARK: - Smart title

    /// Derives a short, clean default name from a discovered feed.
    private func smartTitle(from feed: DiscoveredFeed) -> String {
        let url = feed.siteURL ?? feed.feedURL
        return shortenTitle(feed.title, url: url)
    }

    /// Shortens a long title by extracting the domain name if it appears
    /// in the title, or falling back to the first few meaningful words.
    /// Titles of 5 words or fewer are kept as-is.
    private func shortenTitle(_ title: String, url: URL) -> String {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }

        // Short titles are fine as-is — only shorten long ones
        let wordCount = raw.split(separator: " ").count
        guard wordCount > 5 else { return raw }

        // Extract domain label from URL
        let host = url.host ?? ""
        // "www.example.com" → "example"
        let domainLabel = host
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: ".").first ?? ""

        if !domainLabel.isEmpty {
            let words = raw.split(separator: " ").map(String.init)
            let punct = CharacterSet.punctuationCharacters
            func cleaned(_ w: String) -> String { w.trimmingCharacters(in: punct).lowercased() }

            // Direct single-word match (e.g. "Example" == "example")
            if let match = words.first(where: { cleaned($0) == domainLabel }) {
                return match.trimmingCharacters(in: punct)
            }

            // Concatenated words match (e.g. "My Site" → "mysite")
            for start in words.indices {
                var concat = ""
                for end in start..<words.count {
                    concat += cleaned(words[end])
                    if concat == domainLabel {
                        return words[start...end]
                            .map { $0.trimmingCharacters(in: punct) }
                            .joined(separator: " ")
                    }
                    if concat.count >= domainLabel.count { break }
                }
            }
        }

        // Fallback: take up to 3 real words, stripping separators
        let separatorChars = CharacterSet(charactersIn: "––—|>:·•")
        let separatorStrings: Set<String> = ["-", "–", "—", "|", ">", ":", "·", "•"]
        let realWords = raw.split(separator: " ")
            .map(String.init)
            .filter { !separatorStrings.contains($0) }
            .map { $0.trimmingCharacters(in: separatorChars) }
            .filter { !$0.isEmpty }

        if realWords.count > 3 {
            return realWords.prefix(3).joined(separator: " ")
        }
        return realWords.joined(separator: " ")
    }

    // MARK: - Cycling timer

    private func startCyclingTimer() {
        cyclingTextOffset = 0
        cyclingTextOpacity = 1.0
        cyclingTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            Task { @MainActor in
                // Animate current text out: slide up + fade
                withAnimation(.easeIn(duration: 0.25)) {
                    cyclingTextOffset = -8
                    cyclingTextOpacity = 0
                }

                // Swap text while invisible, position below
                try? await Task.sleep(for: .milliseconds(250))
                cyclingTextOffset = 8
                cyclingTextIndex = (cyclingTextIndex + 1) % cyclingTexts.count

                // Animate new text in: slide up to center + fade in
                withAnimation(.easeOut(duration: 0.25)) {
                    cyclingTextOffset = 0
                    cyclingTextOpacity = 1.0
                }
            }
        }
    }

    private func stopCyclingTimer() {
        cyclingTimer?.invalidate()
        cyclingTimer = nil
    }

    // MARK: - Subscription check

    /// Checks if a discover feed is already subscribed, matching by both
    /// normalized feed URL and normalized siteURL. Site URL matching catches
    /// cases where the user added a source via a different feed URL path than
    /// the discover directory entry (e.g. example.com/feed vs example.com/rss/index.xml).
    /// Using siteURL (not bare domain) preserves the ability to subscribe to
    /// multiple feeds from the same domain (their siteURLs differ).
    private func isDiscoverFeedSubscribed(_ feed: DiscoverFeed) -> Bool {
        if subscribedURLs.contains(FeedDirectory.normalizeURL(feed.feedURL)) {
            return true
        }
        if let siteURL = feed.siteURL {
            return subscribedSiteURLs.contains(FeedDirectory.normalizeURL(siteURL))
        }
        return false
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

#Preview("AddSourceSheet") {
    AddSourceSheet()
}
