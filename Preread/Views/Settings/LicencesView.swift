import SwiftUI
import SafariServices

struct LicencesView: View {
    private let libraries: [(name: String, copyright: String, url: String)] = [
        ("Dark Reader",
         "© 2014–2025 Alexander Shutau",
         "https://github.com/darkreader/darkreader"),
        ("SwiftSoup",
         "© 2016 Nabil Chatbi",
         "https://github.com/scinfu/SwiftSoup"),
        ("GRDB.swift",
         "© 2015–2024 Gwendal Roué",
         "https://github.com/groue/GRDB.swift"),
    ]

    @State private var safariURL: URL?
    @State private var showSafari = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Preread is built on the shoulders of these excellent projects.")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 16)

                ForEach(libraries, id: \.name) { lib in
                    licenceCard(lib)
                }
            }
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Open source")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSafari) {
            if let url = safariURL {
                LicenceSafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Card

    private func licenceCard(_ lib: (name: String, copyright: String, url: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(lib.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                // MIT gradient pill
                Text("MIT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.accentGradient)
                    .clipShape(Capsule())
            }

            Text(lib.copyright)
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)

            Button {
                safariURL = URL(string: lib.url)
                showSafari = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("View on GitHub")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(Theme.teal)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
}

// MARK: - SFSafariViewController wrapper

private struct LicenceSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(Theme.accent)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
