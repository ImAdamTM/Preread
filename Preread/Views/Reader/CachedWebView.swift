import SwiftUI
import WebKit

struct CachedWebView: UIViewRepresentable {
    let htmlFileURL: URL
    let articleDirectory: URL
    let isDarkMode: Bool
    let isReaderMode: Bool
    let useLightMode: Bool
    let textSize: CGFloat
    let fontFamily: String
    var useTransparentBackground: Bool = false
    var heroImageURL: URL? = nil
    var heroFallbackGradientColors: [UIColor]? = nil
    let onScrollDown: () -> Void
    let onScrollUp: () -> Void
    let onLinkTapped: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScrollDown: onScrollDown,
            onScrollUp: onScrollUp,
            onLinkTapped: onLinkTapped
        )
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true

        // Hero backdrop (behind the web view)
        let backdropView = buildHeroBackdrop()
        backdropView.tag = 100
        container.addSubview(backdropView)
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: container.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdropView.heightAnchor.constraint(equalToConstant: 240)
        ])

        // Load hero image asynchronously
        if let heroImageURL {
            loadHeroImage(from: heroImageURL, into: backdropView)
        }

        let config = WKWebViewConfiguration()
        config.preferences.isTextInteractionEnabled = true

        // Block ALL remote resource loads — only local file:// content is allowed
        let rulesJSON = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.maximumZoomScale = 1.0

        // Tell the web view which appearance to report for prefers-color-scheme.
        // Sites with native dark mode will use their own dark CSS.
        if isReaderMode {
            webView.overrideUserInterfaceStyle = useLightMode ? .light : .dark
        } else {
            webView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
        }

        // Set the webview background to match the app theme
        // Full-page caches are light by default; reader mode uses template dark bg
        if useTransparentBackground {
            webView.backgroundColor = .clear
        } else if isReaderMode {
            webView.backgroundColor = useLightMode
                ? UIColor(red: 250/255, green: 250/255, blue: 250/255, alpha: 1) // #FAFAFA
                : UIColor.black
        } else {
            webView.backgroundColor = isDarkMode
                ? UIColor.black
                : .white
        }

        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        context.coordinator.webView = webView
        context.coordinator.currentHTMLFileURL = htmlFileURL

        // Pass initial state to coordinator so it can apply after page loads
        context.coordinator.pendingIsReaderMode = isReaderMode
        context.coordinator.pendingUseLightMode = useLightMode
        context.coordinator.pendingTextSize = textSize
        context.coordinator.pendingFontFamily = fontFamily

        // Compile content rules asynchronously, then load
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PrereadBlockRules",
            encodedContentRuleList: rulesJSON
        ) { ruleList, error in
            if let ruleList {
                webView.configuration.userContentController.add(ruleList)
            }
            // Load regardless of whether rules compiled
            webView.loadFileURL(htmlFileURL, allowingReadAccessTo: articleDirectory)
        }

        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        let coordinator = context.coordinator

        // Update pending state on coordinator — these are applied after page load
        // or immediately if the page has already loaded
        coordinator.pendingIsReaderMode = isReaderMode
        coordinator.pendingUseLightMode = useLightMode
        coordinator.pendingTextSize = textSize
        coordinator.pendingFontFamily = fontFamily

        // Update appearance override so prefers-color-scheme stays in sync
        if isReaderMode {
            webView.overrideUserInterfaceStyle = useLightMode ? .light : .dark
        } else {
            webView.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
        }

        // Update webview background colour to prevent flash
        if useTransparentBackground {
            webView.backgroundColor = .clear
        } else if isReaderMode {
            webView.backgroundColor = useLightMode
                ? UIColor(red: 250/255, green: 250/255, blue: 250/255, alpha: 1)
                : UIColor.black
        } else {
            webView.backgroundColor = isDarkMode
                ? UIColor.black
                : .white
        }

        // If the HTML file changed (e.g. light ↔ dark variant swap), reload
        if coordinator.currentHTMLFileURL != htmlFileURL {
            coordinator.currentHTMLFileURL = htmlFileURL
            coordinator.pageLoaded = false
            webView.loadFileURL(htmlFileURL, allowingReadAccessTo: articleDirectory)
            return
        }

        // Only apply JS if the page has finished loading
        guard coordinator.pageLoaded else { return }

        coordinator.applyCurrentState(to: webView)
    }

    // MARK: - Hero backdrop (UIKit)

    private func buildHeroBackdrop() -> UIView {
        let backdrop = GradientMaskedView()
        backdrop.clipsToBounds = true
        backdrop.isUserInteractionEnabled = false

        // Content image view (will be populated async or with gradient)
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.tag = 101
        backdrop.addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor)
        ])

        // Apply blur
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurView = UIVisualEffectView(effect: blurEffect)
        backdrop.addSubview(blurView)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor)
        ])

        backdrop.alpha = 0.4

        // Gradient mask applied on layout (needs frame)
        backdrop.tag = 100

        return backdrop
    }

    private func loadHeroImage(from url: URL, into backdropView: UIView) {
        let task = URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                if let imageView = backdropView.viewWithTag(101) as? UIImageView {
                    imageView.image = image
                }
            }
        }
        task.resume()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        let onScrollDown: () -> Void
        let onScrollUp: () -> Void
        let onLinkTapped: (URL) -> Void
        weak var webView: WKWebView?

        var pageLoaded = false
        var currentHTMLFileURL: URL?

        // Pending state set by SwiftUI, applied after page load
        var pendingIsReaderMode = false
        var pendingUseLightMode = false
        var pendingTextSize: CGFloat = 18
        var pendingFontFamily: String = "system-ui"

        private var lastContentOffset: CGFloat = 0
        private var isTracking = false

        init(onScrollDown: @escaping () -> Void,
             onScrollUp: @escaping () -> Void,
             onLinkTapped: @escaping (URL) -> Void) {
            self.onScrollDown = onScrollDown
            self.onScrollUp = onScrollUp
            self.onLinkTapped = onLinkTapped
        }

        /// Applies text size, font, and dark/light mode to the web view.
        /// Called after page load and on SwiftUI state changes.
        func applyCurrentState(to webView: WKWebView) {
            // Disable pinch-to-zoom via viewport meta tag
            let viewportJS = """
            (function() {
                var meta = document.querySelector('meta[name="viewport"]');
                if (!meta) {
                    meta = document.createElement('meta');
                    meta.name = 'viewport';
                    document.head.appendChild(meta);
                }
                meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            })();
            """
            webView.evaluateJavaScript(viewportJS)

            // Inject text size and font family as CSS overrides
            let textSize = Int(pendingTextSize)
            let fontFamily = pendingFontFamily
            let cssJS = """
            (function() {
                var style = document.getElementById('preread-reader-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'preread-reader-style';
                    document.head.appendChild(style);
                }
                style.textContent = 'body { font-size: \(textSize)px !important; font-family: \(fontFamily), sans-serif !important; }';
            })();
            """
            webView.evaluateJavaScript(cssJS)

            // Disable sticky/fixed positioned elements (e.g. site headers)
            if !pendingIsReaderMode {
                let unstickJS = """
                (function() {
                    var style = document.getElementById('preread-unstick-style');
                    if (!style) {
                        style = document.createElement('style');
                        style.id = 'preread-unstick-style';
                        document.head.appendChild(style);
                    }
                    style.textContent = '[style*=\"position\"] { position: static !important; }';
                    var all = document.querySelectorAll('*');
                    for (var i = 0; i < all.length; i++) {
                        var pos = window.getComputedStyle(all[i]).position;
                        if (pos === 'sticky' || pos === 'fixed') {
                            all[i].style.setProperty('position', 'static', 'important');
                        }
                    }
                })();
                """
                webView.evaluateJavaScript(unstickJS)
            }

            if pendingIsReaderMode {
                // Reader-mode: toggle .light-mode class on <html>
                let lightModeJS: String
                if pendingUseLightMode {
                    lightModeJS = "document.documentElement.classList.add('light-mode');"
                } else {
                    lightModeJS = "document.documentElement.classList.remove('light-mode');"
                }
                webView.evaluateJavaScript(lightModeJS)
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            applyCurrentState(to: webView)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {

            let url = navigationAction.request.url

            // Allow file:// URLs (local cached content)
            if url?.isFileURL == true {
                // Block page-embedded JS for security.
                // Our evaluateJavaScript calls (Dark Reader etc.) still run.
                preferences.allowsContentJavaScript = false
                decisionHandler(.allow, preferences)
                return
            }

            // External link — only forward user-tapped links, block everything else
            if let externalURL = url, externalURL.scheme == "https" || externalURL.scheme == "http" {
                if navigationAction.navigationType == .linkActivated {
                    onLinkTapped(externalURL)
                }
                decisionHandler(.cancel, preferences)
                return
            }

            // Allow other navigations (about:blank, etc.)
            decisionHandler(.allow, preferences)
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // Reserved for future script message handling
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isTracking else { return }

            let currentOffset = scrollView.contentOffset.y
            let delta = currentOffset - lastContentOffset

            // Require a minimum delta to avoid jitter
            if delta > 8 {
                onScrollDown()
            } else if delta < -8 {
                onScrollUp()
            }

            lastContentOffset = currentOffset
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isTracking = true
            lastContentOffset = scrollView.contentOffset.y
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                isTracking = false
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isTracking = false
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Reset any zoom that managed to occur
            if scale != 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            }
        }
    }
}

// MARK: - Gradient-masked backdrop view

private class GradientMaskedView: UIView {
    private let gradientMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradientMask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        gradientMask.locations = [0, 0.3, 1.0]
        layer.mask = gradientMask
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientMask.frame = bounds
    }
}
