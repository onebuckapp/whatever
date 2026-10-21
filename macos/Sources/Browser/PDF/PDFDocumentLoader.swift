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

/// Fetches the bytes the native PDF viewer shows.
///
/// Local files read straight off disk. Remote addresses go through
/// `URLSession` with the tab's own cookies copied over, so a PDF behind a
/// login loads the same document WebKit would have rendered — without
/// letting WebKit render it (its built-in toolbar is what this replaces).
/// A liar — a `.pdf` path serving HTML, or an `isPDFMIMEType` mismatch —
/// fails here and the caller falls back to the web view.
enum PDFDocumentLoader {
    /// Fetched bytes plus the filename the viewer and the save panel show.
    struct LoadedPDF {
        var data: Data
        var filename: String
    }

    /// Loads `url` for display. `dataStore` supplies cookies for remote
    /// addresses; nil sends none.
    static func load(
        from url: URL,
        dataStore: WKWebsiteDataStore? = nil
    ) async throws -> LoadedPDF {
        if url.isFileURL {
            let data = try Data(contentsOf: url)
            return LoadedPDF(data: data, filename: PDFSupport.displayName(for: url))
        }
        var request = URLRequest(url: url)
        if let dataStore {
            let cookies = await dataStore.httpCookieStore.allCookies()
            let headers = HTTPCookie.requestHeaderFields(with: cookies.filter {
                // Domain- and path-match what the session would send; the
                // request is always GET, so only those two can mismatch.
                cookieMatches($0, url: url)
            })
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard PDFSupport.isPDFMIMEType(http.mimeType) || PDFSupport.isPDFURL(url) else {
            // Served something else under a PDF-looking address: not ours.
            throw URLError(.cannotDecodeContentData)
        }
        guard data.starts(with: Self.pdfMagic) else {
            throw URLError(.cannotDecodeContentData)
        }
        return LoadedPDF(data: data, filename: Self.filename(for: url, response: http))
    }

    /// The first bytes of every PDF: `%PDF`. Checked before handing bytes
    /// to PDFKit, so an error page served as `application/pdf` fails here
    /// with a readable message instead of a nil document.
    private static let pdfMagic = Data("%PDF".utf8)

    /// Save-panel filename: the server's suggestion wins, then the URL's
    /// last component, then a constant. A `.pdf` suffix is enforced so the
    /// saved file always opens as a PDF.
    static func filename(for url: URL, response: HTTPURLResponse) -> String {
        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            return suggested.lowercased().hasSuffix(".pdf") ? suggested : suggested + ".pdf"
        }
        let last = PDFSupport.displayName(for: url)
        return last.lowercased().hasSuffix(".pdf") ? last : last + ".pdf"
    }

    /// Whether `cookie` would be sent to `url`. Replicates the session's
    /// own matching closely enough for a document fetch.
    static func cookieMatches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let domain = cookie.domain.lowercased()
        let hostMatches = host == domain || (domain.hasPrefix(".") && host.hasSuffix(domain))
            || (!domain.hasPrefix(".") && host.hasSuffix("." + domain))
        guard hostMatches else { return false }
        guard url.path.hasPrefix(cookie.path) else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" {
            return false
        }
        return true
    }
}
