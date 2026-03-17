import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var systemColorScheme
    @ObservedObject private var detailCoordinator = ArticleDetailCoordinator.shared
    @AppStorage("appAppearance") private var appAppearance: String = "system"

    private var preferredScheme: ColorScheme {
        switch appAppearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemColorScheme
        }
    }

    var body: some View {
        Group {
            // iPhone: NavigationStack (handled inside SourcesListView)
            // iPad: NavigationSplitView with reader in detail column
            if sizeClass == .regular {
                NavigationSplitView {
                    SourcesListView()
                } detail: {
                    if let selection = detailCoordinator.selection {
                        NavigationStack {
                            ReaderView(article: selection.article, source: selection.source)
                        }
                        .id(selection.id)
                        .toastOverlay()
                        .preferredColorScheme(preferredScheme)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(Theme.scaledFont(size: 48, weight: .light))
                                .foregroundColor(Theme.textSecondary)
                            Text("Select an article")
                                .font(Theme.scaledFont(size: 17))
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
            } else {
                SourcesListView()
            }
        }
        .onChange(of: sizeClass) { _, newValue in
            detailCoordinator.isSplitView = (newValue == .regular)
        }
        .onAppear {
            detailCoordinator.isSplitView = (sizeClass == .regular)
        }
    }
}

#Preview {
    ContentView()
        .tint(Theme.accent)
        .environmentObject(ToastManager.shared)
        .environmentObject(DeepLinkRouter())
}
