import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Make the extension's view invisible so no drawer appears
        view.alpha = 0
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractAndRedirect()
    }

    private func extractAndRedirect() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments, !attachments.isEmpty else {
            close()
            return
        }

        // Safari may provide the URL as public.url or public.plain-text
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
        DispatchQueue.main.async {
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

    /// Opens the containing app via the responder chain.
    /// Uses the non-deprecated open(_:options:completionHandler:) API
    /// which is required on iOS 18+.
    private func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.close()
                }
                return
            }
            responder = current.next
        }
        // Responder chain walk failed — close without opening
        close()
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
