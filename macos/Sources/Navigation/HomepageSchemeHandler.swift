// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import WebKit

/// Serves the `w://` scheme from memory.
///
/// `w://about` always returns the bundled homepage markup, so the
/// homepage is a real navigation: reload re-serves it, and back/forward
/// treats it like any other page. Its background image loads from
/// `w://homepage/whatever_bg.jpg` and its logo from
/// `w://homepage/whatever_logo.svg`, both served from the bundle the same
/// way. Anything else under the scheme fails: the handler serves exactly
/// these three addresses, never arbitrary paths.
final class HomepageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if url.host == "about", url.path.isEmpty || url.path == "/" {
            serveText(BrowserConstants.homePageHTML, mimeType: "text/html", for: urlSchemeTask)
        } else if url.host == "homepage", url.path == "/whatever_bg.jpg",
                  let imageURL = Bundle.main.url(forResource: "whatever_bg", withExtension: "jpg"),
                  let image = try? Data(contentsOf: imageURL)
        {
            serveData(image, mimeType: "image/jpeg", for: urlSchemeTask)
        } else if url.host == "homepage", url.path == "/whatever_logo.svg",
                  let imageURL = Bundle.main.url(forResource: "whatever_logo", withExtension: "svg"),
                  let image = try? Data(contentsOf: imageURL)
        {
            serveData(image, mimeType: "image/svg+xml", for: urlSchemeTask)
        } else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }
    }

    private func serveText(_ string: String, mimeType: String, for task: WKURLSchemeTask) {
        serveData(Data(string.utf8), mimeType: mimeType, textEncoding: "utf-8", for: task)
    }

    private func serveData(
        _ data: Data,
        mimeType: String,
        textEncoding: String? = nil,
        for task: WKURLSchemeTask
    ) {
        let response = URLResponse(
            url: task.request.url!,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: textEncoding
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // The homepage is served synchronously; nothing to cancel.
    }
}
