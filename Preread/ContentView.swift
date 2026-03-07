import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // iPhone: NavigationStack (handled inside SourcesListView)
        // iPad: NavigationSplitView wrapping the same views
        if sizeClass == .regular {
            NavigationSplitView {
                SourcesListView()
            } detail: {
                Text("Select a source")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.textSecondary)
            }
        } else {
            SourcesListView()
        }
    }
}

#Preview {
    ContentView()
        .tint(Theme.accent)
        .environmentObject(ToastManager.shared)
        .environmentObject(DeepLinkRouter())
}
