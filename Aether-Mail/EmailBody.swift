import SwiftUI
import WebKit
import EmailKit

/// Renders an email the way a real mail client does: the message's own HTML in a
/// self-sizing web view on a white "paper" card. Falls back to formatted plain
/// text. The aurora glass is the chrome around it; the message itself reads like
/// an actual email.
struct EmailBodyView: View {
    let content: MailBody
    @State private var height: CGFloat = 80

    var body: some View {
        Group {
            if let html = content.html, !html.isEmpty {
                EmailHTMLView(html: html, height: $height)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.15)))
            } else {
                Text(plain)
                    .font(.body).foregroundStyle(.black).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var plain: String {
        if let t = content.plainText, !t.isEmpty { return t }
        return "(no content)"
    }
}

/// A self-sizing WKWebView that renders sanitized email HTML and reports its
/// content height back to SwiftUI so the outer ScrollView owns the scrolling.
private struct EmailHTMLView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> EmailHTMLCoordinator {
        EmailHTMLCoordinator(onHeightChange: { [self] newHeight in
            self.height = newHeight
        })
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(context.coordinator), name: "openExternal")
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false          // the SwiftUI ScrollView scrolls
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .white
        web.allowsLinkPreview = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if web.navigationDelegate == nil { web.navigationDelegate = context.coordinator }
        if web.uiDelegate == nil { web.uiDelegate = context.coordinator }
        context.coordinator.onHeightChange = { newHeight in
            self.height = newHeight
        }

        let doc = Self.wrap(html)
        guard context.coordinator.lastHTML != doc else { return }
        context.coordinator.lastHTML = doc
        web.loadHTMLString(doc, baseURL: nil)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: EmailHTMLCoordinator) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Wrap the raw HTML with a responsive viewport + base styling so wide
    /// emails don't overflow, word wraps nicely, and text stays legible.
    /// Injects an active link interceptor to prevent any in-frame navigation.
    static func wrap(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
        <base target="_blank">
        <style>
          :root { color-scheme: light; }
          * { box-sizing: border-box; }
          html, body {
            margin: 0;
            padding: 0;
            background: #ffffff;
            color: #111111;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            font-size: 16px;
            line-height: 1.45;
            -webkit-text-size-adjust: 100%;
          }
          body {
            padding: 12px;
            word-wrap: break-word;
            overflow-wrap: anywhere;
          }
          img {
            max-width: 100% !important;
            height: auto !important;
          }
          table {
            max-width: 100% !important;
          }
          td, th {
            max-width: 100% !important;
            overflow-wrap: anywhere;
            word-break: break-word;
          }
          pre, code {
            white-space: pre-wrap !important;
            overflow-wrap: anywhere;
          }
          a {
            color: #6a4cf0;
            overflow-wrap: anywhere;
          }
        </style>
        <script>
        (function() {
          document.addEventListener('click', function(e) {
            var a = e.target.closest('a');
            if (a && a.href) {
              var href = a.href;
              if (href.indexOf('http://') === 0 || href.indexOf('https://') === 0 || href.indexOf('mailto:') === 0 || href.indexOf('tel:') === 0) {
                e.preventDefault();
                e.stopPropagation();
                try {
                  window.webkit.messageHandlers.openExternal.postMessage(href);
                } catch (err) {}
                return false;
              }
            }
          }, true);
        })();
        </script>
        </head><body>\(html)</body></html>
        """
    }
}

/// Trampoline to avoid retain cycle between WKUserContentController and coordinator.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

/// Declared at file scope (like Aether-Courier's HTMLLinkCoordinator) so @objc
/// WKNavigationDelegate and WKUIDelegate selectors are reliably visible to WebKit
/// and links never accidentally navigate in the email body frame.
final class EmailHTMLCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    var onHeightChange: ((CGFloat) -> Void)?
    var lastHTML: String?
    private var pendingWebViews: [WKWebView] = []

    private static let internalSchemes: Set<String> = ["about", "applewebdata", "data", "blob"]

    init(onHeightChange: ((CGFloat) -> Void)? = nil) {
        self.onHeightChange = onHeightChange
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "openExternal", let href = message.body as? String, let url = URL(string: href) {
            _ = handleExternalLink(url: url)
        }
    }

    func webView(_ web: WKWebView, didFinish nav: WKNavigation!) {
        measure(web)
        // Re-measure after remote images have had a chance to load and lay out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak web] in
            guard let web else { return }
            self?.measure(web)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak web] in
            guard let web else { return }
            self?.measure(web)
        }
    }

    private func measure(_ web: WKWebView) {
        // Auto-scale content if wide tables or images exceed viewport width,
        // then report the actual rendered height back to SwiftUI.
        let script = """
        (function() {
            document.body.style.zoom = '1';
            var viewWidth = window.innerWidth || document.documentElement.clientWidth;
            if (!viewWidth || viewWidth <= 0) {
                viewWidth = document.body.clientWidth;
            }
            var contentWidth = Math.max(
                document.body.scrollWidth,
                document.documentElement.scrollWidth,
                document.body.offsetWidth,
                document.documentElement.offsetWidth
            );
            var scale = 1.0;
            if (viewWidth > 0 && contentWidth > viewWidth + 1) {
                scale = viewWidth / contentWidth;
                document.body.style.zoom = scale;
            }
            return Math.max(
                document.body.scrollHeight,
                document.documentElement.scrollHeight,
                document.body.offsetHeight,
                document.documentElement.offsetHeight
            );
        })()
        """
        web.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self else { return }
            let h = (value as? CGFloat) ?? CGFloat((value as? Double) ?? 0)
            if h > 0 {
                DispatchQueue.main.async { self.onHeightChange?(max(h, 60)) }
            }
        }
    }

    /// Open external links (http, https, mailto, tel) in Google Chrome if installed, or system default.
    @discardableResult
    func handleExternalLink(url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard !scheme.isEmpty, !Self.internalSchemes.contains(scheme) else {
            return false
        }
        DispatchQueue.main.async {
            // If it's a web URL (http or https), prioritize Google Chrome if installed
            if scheme == "http" || scheme == "https" {
                if let chromeURL = Self.chromeURL(from: url), UIApplication.shared.canOpenURL(chromeURL) {
                    UIApplication.shared.open(chromeURL, options: [:], completionHandler: nil)
                    return
                }
            }

            // Default system handling (Safari / default browser, or mailto / tel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return true
    }

    private static func chromeURL(from url: URL) -> URL? {
        let absolute = url.absoluteString
        if absolute.hasPrefix("https://") {
            let replaced = "googlechromes://" + absolute.dropFirst("https://".count)
            return URL(string: replaced)
        } else if absolute.hasPrefix("http://") {
            let replaced = "googlechrome://" + absolute.dropFirst("http://".count)
            return URL(string: replaced)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if let url = navigationAction.request.url, handleExternalLink(url: url) {
            pendingWebViews.removeAll { $0 == webView }
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, handleExternalLink(url: url) {
            pendingWebViews.removeAll { $0 == web }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, handleExternalLink(url: url) {
            return nil
        }
        let temp = WKWebView(frame: .zero, configuration: configuration)
        temp.navigationDelegate = self
        temp.uiDelegate = self
        pendingWebViews.append(temp)
        return temp
    }
}
