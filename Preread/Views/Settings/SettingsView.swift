import SwiftUI
import AppIntents
import GRDB

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // MARK: - Reading

    @AppStorage("readerFontFamily") private var fontFamily: String = "Inter Tight"
    @AppStorage("readerTextSize") private var textSize: Double = 18

    // MARK: - Syncing

    @AppStorage("wifiOnly") private var wifiOnly = false
    @AppStorage("backgroundRefreshEnabled") private var backgroundRefreshEnabled = true

    // MARK: - Storage

    @AppStorage("articleLimit") private var articleLimit: Int = 25

    // MARK: - Appearance

    @AppStorage("appAppearance") private var appAppearance: String = "system"

    // MARK: - State

    @State private var sources: [Source] = []
    @State private var editableSources: [Source] = []
    @State private var sourceToDelete: Source?
    @State private var faviconCache: [UUID: UIImage] = [:]
    @State private var sourcesEditMode: EditMode = .inactive
    @State private var storageBySource: [(source: Source, bytes: Int64)] = []
    @State private var totalStorageBytes: Int64 = 0
    @State private var freeSpaceMB: Int = Int.max
    private let fontOptions: [(name: String, display: String)] = [
        ("Inter Tight", "Inter Tight"),
        ("Georgia", "Georgia"),
        ("New York", "New York")
    ]

    private let textSizeStops: [Double] = [14, 16, 18, 20, 22, 24]

    var body: some View {
        List {
            appearanceSection
            readingSection
            syncingSection
            sourcesSection
            storageSection
            homeScreenSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .environment(\.editMode, $sourcesEditMode)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await loadSources()
            await loadStorageData()
            checkFreeSpace()
        }
        .confirmationDialog(
            "Delete \"\(sourceToDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { sourceToDelete != nil },
                set: { if !$0 { sourceToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete source", role: .destructive) {
                if let source = sourceToDelete {
                    Task { await deleteSource(source) }
                }
            }
            Button("Cancel", role: .cancel) { sourceToDelete = nil }
        } message: {
            Text("Saved articles from this source will be moved to your Saved collection.")
        }
    }

    // MARK: - Sources section

    private var sourcesSection: some View {
        Section {
            if editableSources.isEmpty {
                Text("No sources added yet")
                    .font(Theme.scaledFont(size: 14, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(editableSources) { source in
                    HStack(spacing: 12) {
                        sourceFavicon(source)
                            .frame(width: 28, height: 28)

                        Text(source.title)
                            .font(Theme.scaledFont(size: 15, weight: .medium, relativeTo: .subheadline))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
                .onMove { indices, newOffset in
                    editableSources.move(fromOffsets: indices, toOffset: newOffset)
                    Task { await persistSourceOrder() }
                }
                .onDelete { indices in
                    if let index = indices.first {
                        sourceToDelete = editableSources[index]
                    }
                }
            }
        } header: {
            HStack {
                sectionHeader("SOURCES")
                Spacer()
                if !editableSources.isEmpty {
                    Button {
                        withAnimation {
                            sourcesEditMode = sourcesEditMode.isEditing ? .inactive : .active
                        }
                    } label: {
                        Text(sourcesEditMode.isEditing ? "Done" : "Edit")
                            .font(Theme.scaledFont(size: 12, weight: .semibold, relativeTo: .caption))
                            .foregroundColor(Theme.accent)
                    }
                    .textCase(nil)
                }
            }
        }
        .listRowBackground(Theme.card)
    }

    @ViewBuilder
    private func sourceFavicon(_ source: Source) -> some View {
        if let favicon = faviconCache[source.id] {
            Image(uiImage: favicon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            let letter = String(source.title.prefix(1)).uppercased()
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.avatarGradient(for: source.title))
                Text(letter)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 28, height: 28)
        }
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appAppearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            .settingsRow()
        } header: {
            sectionHeader("APPEARANCE")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Reading section

    private var readingSection: some View {
        Section {
            // Reading font
            HStack {
                settingLabel("Reading font")
                Spacer()
                Menu {
                    ForEach(fontOptions, id: \.name) { font in
                        Button {
                            fontFamily = font.name
                        } label: {
                            HStack {
                                Text(font.display)
                                if fontFamily == font.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(fontOptions.first(where: { $0.name == fontFamily })?.display ?? "Inter Tight")
                            .font(Theme.scaledFont(size: 15, relativeTo: .subheadline))
                            .foregroundColor(Theme.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .frame(minWidth: 120, alignment: .trailing)
                }
            }
            .settingsRow()

            // Text size
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    settingLabel("Text size")
                    Spacer()
                    Text("\(Int(textSize))pt")
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.textSecondary)
                }

                HStack(spacing: 8) {
                    Text("A")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    Slider(
                        value: $textSize,
                        in: 14...24,
                        step: 2
                    ) {
                        Text("Text size")
                    }
                    .tint(Theme.accent)
                    .onChange(of: textSize) { _, newValue in
                        let snapped = textSizeStops.min(by: { abs($0 - newValue) < abs($1 - newValue) }) ?? newValue
                        if snapped != textSize {
                            textSize = snapped
                        }
                        HapticManager.sliderStep()
                    }

                    Text("A")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .settingsRow()
        } header: {
            sectionHeader("READING")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Syncing section

    private var syncingSection: some View {
        Section {
            Toggle(isOn: $wifiOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    settingLabel("WiFi only")
                    Text("Only fetch new articles when connected to WiFi.")
                        .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            .settingsRow()

            Toggle(isOn: $backgroundRefreshEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    settingLabel("Background refresh")
                    Text("Preread will periodically check for new articles in the background.")
                        .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            .settingsRow()
        } header: {
            sectionHeader("SYNCING")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Storage section

    private var storageSection: some View {
        Section {
            // Usage bar
            if totalStorageBytes > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel("Usage")

                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(storageBySource, id: \.source.id) { item in
                                let fraction = CGFloat(item.bytes) / CGFloat(max(totalStorageBytes, 1))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.avatarGradient(for: item.source.title))
                                    .frame(width: max(geo.size.width * fraction, 2))
                            }
                        }
                        .frame(height: 8)
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)

                    // Legend
                    FlowLayout(spacing: 8) {
                        ForEach(storageBySource, id: \.source.id) { item in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Theme.avatarGradient(for: item.source.title))
                                    .frame(width: 6, height: 6)
                                Text("\(item.source.title) (\(formatBytes(item.bytes)))")
                                    .font(Theme.scaledFont(size: 11, relativeTo: .caption2))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    Text("Total: \(formatBytes(totalStorageBytes))")
                        .font(Theme.scaledFont(size: 12, weight: .medium, relativeTo: .caption))
                        .foregroundColor(Theme.textPrimary)
                }
                .settingsRow()
            }

            // Article limit
            HStack {
                settingLabel("Article limit per source")
                Spacer()
                Picker("", selection: $articleLimit) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("75").tag(75)
                    Text("100").tag(100)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .settingsRow()

            Text("When a feed refreshes, old articles are replaced by the latest entries. Saved articles are kept until you remove them.")
                .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                .foregroundColor(Theme.textSecondary)
                .settingsRow()

            // Low storage banner
            if freeSpaceMB < 500 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.warning)

                    Text("Your device is running low on storage. You can free up space in Settings.")
                        .font(Theme.scaledFont(size: 13, relativeTo: .footnote))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(12)
                .background(Theme.warning.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .settingsRow()
            }
        } header: {
            sectionHeader("STORAGE")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Shortcuts section

    private var homeScreenSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)

                Text("Create shortcuts to open your sources directly. You can add them to your Home Screen from the Shortcuts app.")
                    .font(Theme.scaledFont(size: 12, relativeTo: .caption))
                    .foregroundColor(Theme.textSecondary)
            }
            .settingsRow()
        } header: {
            sectionHeader("SHORTCUTS")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - About section

    private var aboutSection: some View {
        Section {
            HStack {
                settingLabel("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .font(Theme.scaledFont(size: 15, relativeTo: .subheadline))
                    .foregroundColor(Theme.textSecondary)
            }
            .settingsRow()

            NavigationLink {
                LicencesView()
            } label: {
                settingLabel("Open source")
            }
            .settingsRow()
        } header: {
            sectionHeader("ABOUT")
        }
        .listRowBackground(Theme.card)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.scaledFont(size: 12, weight: .semibold, relativeTo: .caption))
            .tracking(1)
            .foregroundColor(Theme.textSecondary)
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.scaledFont(size: 15, weight: .medium, relativeTo: .subheadline))
            .foregroundColor(Theme.textPrimary)
    }

    // MARK: - Source management

    private func loadSources() async {
        do {
            let loaded = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
            }
            editableSources = loaded

            // Load favicons from disk cache
            for source in loaded {
                let sourceID = source.id
                let image = await Task.detached(priority: .utility) {
                    await PageCacheService.shared.cachedFavicon(for: sourceID)
                }.value
                if let image {
                    faviconCache[sourceID] = image
                }
            }
        } catch { }
    }

    private func persistSourceOrder() async {
        let ordered = editableSources
        do {
            try await DatabaseManager.shared.dbPool.write { db in
                for (index, var source) in ordered.enumerated() {
                    source.sortOrder = index
                    try source.update(db)
                }
            }
        } catch { }
    }

    private func deleteSource(_ source: Source) async {
        HapticManager.deleteConfirm()

        do {
            try await Source.deleteWithCleanup(source)

            withAnimation {
                editableSources.removeAll { $0.id == source.id }
            }

            // Refresh storage data since it changed
            await loadStorageData()
        } catch { }
    }

    // MARK: - Data

    private func loadStorageData() async {
        do {
            let loadedSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source.order(Column("sortOrder")).fetchAll(db)
            }
            sources = loadedSources

            var bySource: [(source: Source, bytes: Int64)] = []
            var total: Int64 = 0

            for source in loadedSources {
                let bytes = try await DatabaseManager.shared.dbPool.read { db -> Int64 in
                    let sql = """
                    SELECT COALESCE(SUM(cp.totalSizeBytes), 0)
                    FROM cachedPage cp
                    JOIN article a ON cp.articleID = a.id
                    WHERE a.sourceID = ?
                    """
                    return try Int64.fetchOne(db, sql: sql, arguments: [source.id]) ?? 0
                }
                if bytes > 0 {
                    bySource.append((source: source, bytes: bytes))
                    total += bytes
                }
            }

            storageBySource = bySource
            totalStorageBytes = total
        } catch {
            // Storage data load failed silently
        }
    }

    private func checkFreeSpace() {
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSize = attrs[.systemFreeSize] as? Int64 {
            freeSpaceMB = Int(freeSize / (1024 * 1024))
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Settings row modifier

private extension View {
    func settingsRow() -> some View {
        self
            .listRowSeparator(.hidden)
    }
}

// MARK: - FlowLayout for storage legend

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxHeight = max(maxHeight, y + rowHeight)
        }

        return (CGSize(width: maxWidth, height: maxHeight), positions)
    }
}
