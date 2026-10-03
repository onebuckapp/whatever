import Foundation
import WebKit

/// Serves the `whtvr://` scheme from memory.
///
/// `whtvr://about` always returns the bundled homepage markup, so the
/// homepage is a real navigation: reload re-serves it, and back/forward
/// treats it like any other page. Anything else under the scheme fails.
final class HomepageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard urlSchemeTask.request.url?.host == "about" else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }
        let data = Data(BrowserConstants.homePageHTML.utf8)
        let response = URLResponse(
            url: urlSchemeTask.request.url!,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // The homepage is served synchronously; nothing to cancel.
    }
}
