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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false          // the SwiftUI ScrollView scrolls
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .white
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let doc = Self.wrap(html)
        guard context.coordinator.lastHTML != doc else { return }
        context.coordinator.lastHTML = doc
        web.loadHTMLString(doc, baseURL: nil)
    }

    /// Wrap the raw HTML with a responsive viewport + light base styling so wide
    /// emails don't overflow and text stays legible.
    static func wrap(_ html: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light; }
          html, body { margin:0; padding:0; background:#fff; color:#111;
            font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Arial,sans-serif;
            font-size:16px; line-height:1.45; -webkit-text-size-adjust:100%; }
          body { padding:16px; word-wrap:break-word; overflow-wrap:break-word; }
          img { max-width:100% !important; height:auto !important; }
          table { max-width:100% !important; }
          a { color:#6a4cf0; }
        </style></head><body>\(html)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: EmailHTMLView
        var lastHTML: String?
        init(_ parent: EmailHTMLView) { self.parent = parent }

        func webView(_ web: WKWebView, didFinish nav: WKNavigation!) {
            measure(web)
            // Re-measure once more after remote images have had a chance to load.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.measure(web) }
        }

        private func measure(_ web: WKWebView) {
            web.evaluateJavaScript("document.body.scrollHeight") { value, _ in
                let h = (value as? CGFloat) ?? CGFloat((value as? Double) ?? 0)
                if h > 0 {
                    DispatchQueue.main.async { self.parent.height = max(h, 60) }
                }
            }
        }

        // Don't navigate away inside the reader when a link is tapped.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .linkActivated ? .cancel : .allow)
        }
    }
}
