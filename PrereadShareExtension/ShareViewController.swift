import UIKit
import UniformTypeIdentifiers

/// Share extension that immediately redirects to the Preread app
/// with the shared URL. No UI is shown — the extension extracts the
/// URL, builds a `preread://add?url=…` deep link, and opens the
/// containing app via the responder chain.
class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Hide the extension's view and make it as small as possible
        // so no blank drawer is visible while we extract the URL.
        view.alpha = 0
        preferredContentSize = .zero
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractAndRedirect()
    }

    // MARK: - URL extraction

    private func extractAndRedirect() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
            close()
            return
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] item, _ in
                self?.processItem(item)
            }
        } else if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] item, _ in
                self?.processItem(item)
            }
        } else {
            close()
        }
    }

    private func processItem(_ item: NSSecureCoding?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            var sharedURL: URL?
            if let url = item as? URL {
                sharedURL = url
            } else if let string = item as? String, let url = URL(string: string) {
                sharedURL = url
            } else if let data = item as? Data,
                      let string = String(data: data, encoding: .utf8),
                      let url = URL(string: string) {
                sharedURL = url
            }

            guard let url = sharedURL,
                  let encoded = url.absoluteString
                      .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let deepLink = URL(string: "preread://add?url=\(encoded)") else {
                self.close()
                return
            }

            self.openContainingApp(deepLink)
        }
    }

    // MARK: - Open containing app

    /// Opens the containing app via the responder chain.
    ///
    /// Share extensions can't reference `UIApplication.shared`
    /// directly, but at runtime the responder chain includes the host
    /// process's UIApplication. We walk the chain and call the
    /// non-deprecated `open(_:options:completionHandler:)`.
    /// This is the standard approach used by shipping apps and works
    /// on iOS 18+.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.close()
                }
                return
            }
            responder = current.next
        }
        // Responder chain walk failed — close gracefully
        close()
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
