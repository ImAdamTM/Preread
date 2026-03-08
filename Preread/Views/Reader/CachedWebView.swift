import SwiftUI
import WebKit

struct CachedWebView: UIViewRepresentable {
    let htmlFileURL: URL
    let articleDirectory: URL
    let isDarkMode: Bool
    let isReaderMode: Bool
    let useLightMode: Bool
    /// When true, Dark Reader injection is skipped (HTML is already pre-darkened).
    let skipDarkReader: Bool
    let textSize: CGFloat
    let fontFamily: String
    var useTransparentBackground: Bool = false
    var heroImageURL: URL? = nil
    var heroFallbackGradientColors: [UIColor]? = nil
    @Binding var retryDarkMode: Bool
    let onScrollDown: () -> Void
    let onScrollUp: () -> Void
    let onLinkTapped: (URL) -> Void
    let onDarkReaderReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScrollDown: onScrollDown,
            onScrollUp: onScrollUp,
            onLinkTapped: onLinkTapped,
            onDarkReaderReady: onDarkReaderReady
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

        // Load Dark Reader source from bundle for full-page dark mode
        if let drURL = Bundle.main.url(forResource: "darkreader.min", withExtension: "js"),
           let drSource = try? String(contentsOf: drURL, encoding: .utf8) {
            context.coordinator.darkReaderSource = drSource
        }

        // Pass initial state to coordinator so it can apply after page loads
        context.coordinator.pendingDarkMode = isDarkMode
        context.coordinator.pendingIsReaderMode = isReaderMode
        context.coordinator.pendingUseLightMode = useLightMode
        context.coordinator.pendingTextSize = textSize
        context.coordinator.pendingFontFamily = fontFamily
        context.coordinator.skipDarkReader = skipDarkReader

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
        coordinator.pendingDarkMode = isDarkMode
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

        // Only apply JS if the page has finished loading
        guard coordinator.pageLoaded else { return }

        // Force re-inject Dark Reader when retry flag is toggled
        if retryDarkMode {
            DispatchQueue.main.async {
                self.retryDarkMode = false
            }
            coordinator.forceRetryDarkReader(on: webView)
            return
        }

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
        let onDarkReaderReady: () -> Void
        weak var webView: WKWebView?

        var darkReaderSource: String?
        var darkReaderInjected = false
        var currentDarkMode = false
        var pageLoaded = false

        // Pending state set by SwiftUI, applied after page load
        var pendingDarkMode = false
        var pendingIsReaderMode = false
        var pendingUseLightMode = false
        var pendingTextSize: CGFloat = 18
        var pendingFontFamily: String = "system-ui"
        var skipDarkReader = false

        private var lastContentOffset: CGFloat = 0
        private var isTracking = false

        init(onScrollDown: @escaping () -> Void,
             onScrollUp: @escaping () -> Void,
             onLinkTapped: @escaping (URL) -> Void,
             onDarkReaderReady: @escaping () -> Void) {
            self.onScrollDown = onScrollDown
            self.onScrollUp = onScrollUp
            self.onLinkTapped = onLinkTapped
            self.onDarkReaderReady = onDarkReaderReady
        }

        /// Applies text size, font, and dark/light mode to the web view.
        /// Called after page load and on SwiftUI state changes.
        func applyCurrentState(to webView: WKWebView) {
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

            if pendingIsReaderMode {
                // Reader-mode: toggle .light-mode class on <html>
                let lightModeJS: String
                if pendingUseLightMode {
                    lightModeJS = "document.documentElement.classList.add('light-mode');"
                } else {
                    lightModeJS = "document.documentElement.classList.remove('light-mode');"
                }
                webView.evaluateJavaScript(lightModeJS)
            } else if !skipDarkReader {
                // Full page — use Dark Reader for intelligent dark mode
                // (skipped when loading pre-darkened HTML)
                let wasDark = currentDarkMode
                currentDarkMode = pendingDarkMode

                if pendingDarkMode && !wasDark {
                    enableDarkReader(on: webView)
                } else if !pendingDarkMode && wasDark {
                    webView.evaluateJavaScript("if(typeof DarkReader!=='undefined'){DarkReader.disable();}")
                }
            }
        }

        private func enableDarkReader(on webView: WKWebView) {
            guard let drSource = darkReaderSource else {
                onDarkReaderReady()
                return
            }

            // Only inject the library once per page load
            let libraryJS = darkReaderInjected ? "" : drSource + "\n"
            darkReaderInjected = true

            // Clean up page before Dark Reader:
            // - Remove CSP meta tags (old caches)
            // - Remove <script> and <noscript> tags
            // - Inline any remaining external stylesheets (old caches that weren't
            //   inlined at cache time) so Dark Reader can read them via the DOM
            let cleanupJS = """
            (function() {
                document.querySelectorAll('meta[http-equiv="Content-Security-Policy"]').forEach(function(el) { el.remove(); });
                document.querySelectorAll('script').forEach(function(el) { el.remove(); });
                document.querySelectorAll('noscript').forEach(function(el) { el.remove(); });
                var remaining = document.querySelectorAll('link[rel="stylesheet"]');
                remaining.forEach(function(link) {
                    try {
                        var xhr = new XMLHttpRequest();
                        xhr.open('GET', link.href, false);
                        xhr.send();
                        if (xhr.status === 200 || xhr.status === 0) {
                            var style = document.createElement('style');
                            style.textContent = xhr.responseText;
                            link.parentNode.replaceChild(style, link);
                        }
                    } catch(e) {
                        console.log('[Preread] Failed to inline stylesheet: ' + link.href + ' error: ' + e);
                    }
                });
                console.log('[Preread] Cleanup done. Remaining link[stylesheet]: ' + document.querySelectorAll('link[rel="stylesheet"]').length + ', style tags: ' + document.querySelectorAll('style').length);
            })();
            """

            let enableJS = cleanupJS + libraryJS + """
            DarkReader.enable({
                brightness: 100,
                contrast: 95,
                sepia: 0
            }, {
                css: 'html, body { background-color: #000000 !important; } a { color: #7B7BEE !important; } pre, code { background-color: #1C1C28 !important; }'
            });
            """
            webView.evaluateJavaScript(enableJS) { [weak self] _, error in
                if let error {
                    print("[CachedWebView] Dark Reader injection error: \(error)")
                }
                DispatchQueue.main.async {
                    self?.onDarkReaderReady()
                }
            }
        }

        /// Force-retry: disable Dark Reader, reset state, re-inject from scratch.
        func forceRetryDarkReader(on webView: WKWebView) {
            guard pendingDarkMode else { return }

            // Disable existing Dark Reader if any
            let disableJS = "if(typeof DarkReader!=='undefined'){DarkReader.disable();}"
            webView.evaluateJavaScript(disableJS) { [weak self] _, _ in
                guard let self else { return }

                // Reset injection state so the library is re-injected fresh
                self.darkReaderInjected = false
                self.currentDarkMode = false

                // Log diagnostic info
                let diagJS = """
                (function() {
                    var sheets = document.styleSheets.length;
                    var inlineStyles = document.querySelectorAll('[style]').length;
                    var bodyBg = window.getComputedStyle(document.body).backgroundColor;
                    var htmlBg = window.getComputedStyle(document.documentElement).backgroundColor;
                    return 'sheets=' + sheets + ' inline=' + inlineStyles + ' bodyBg=' + bodyBg + ' htmlBg=' + htmlBg;
                })();
                """
                webView.evaluateJavaScript(diagJS) { result, _ in
                    let info = (result as? String) ?? "nil"
                    print("[CachedWebView] Pre-retry diagnostics: \(info)")
                }

                // Re-enable
                self.enableDarkReader(on: webView)

                // Check result after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let checkJS = """
                    (function() {
                        var drActive = typeof DarkReader !== 'undefined' && DarkReader.isEnabled();
                        var bodyBg = window.getComputedStyle(document.body).backgroundColor;
                        var htmlBg = window.getComputedStyle(document.documentElement).backgroundColor;
                        return 'drActive=' + drActive + ' bodyBg=' + bodyBg + ' htmlBg=' + htmlBg;
                    })();
                    """
                    webView.evaluateJavaScript(checkJS) { result, error in
                        let info = (result as? String) ?? "nil"
                        let errMsg = error.map { String(describing: $0) } ?? "none"
                        print("[CachedWebView] Post-retry diagnostics: \(info) error: \(errMsg)")
                    }
                }
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            darkReaderInjected = false // Reset for fresh page
            currentDarkMode = false    // Reset so Dark Reader re-evaluates
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
