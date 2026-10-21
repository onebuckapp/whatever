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
import PDFKit

/// What the tab's native viewer is showing.
///
/// A single value (rather than three optionals) so the hosting pane has one
/// publisher to follow: any change re-hosts. `ready` holds the original
/// bytes alongside the document so save writes exactly what was fetched.
enum PDFViewerState: Equatable {
    case none
    case loading(URL)
    case ready(document: PDFDocument, data: Data, url: URL, filename: String)
    case failed(url: URL, message: String)

    /// The address this state belongs to, if any.
    var sourceURL: URL? {
        switch self {
        case .none: nil
        case .loading(let url): url
        case .ready(_, _, let url, _): url
        case .failed(let url, _): url
        }
    }

    static func == (lhs: PDFViewerState, rhs: PDFViewerState) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.loading(let a), .loading(let b)):
            return a == b
        case (.ready(let aDoc, let aData, let aURL, let aName),
              .ready(let bDoc, let bData, let bURL, let bName)):
            return aDoc === bDoc && aData == bData && aURL == bURL && aName == bName
        case (.failed(let aURL, let aMessage), .failed(let bURL, let bMessage)):
            return aURL == bURL && aMessage == bMessage
        default:
            return false
        }
    }
}

/// Pure PDF-routing rules: which addresses the native viewer owns, and
/// which responses it takes over from WebKit.
///
/// The viewer replaces WebKit's built-in PDF rendering everywhere, so its
/// own zoom/download/print toolbar is the only one on screen. Static and
/// dependency-free so the rules are unit-testable without a tab or a view.
enum PDFSupport {
    /// The MIME type WebKit reports for PDF bytes, file or remote.
    static let pdfMIMEType = "application/pdf"

    /// Whether `url` names a PDF by extension. Covers `file://` paths and
    /// remote links alike; the response's MIME type is the second net for
    /// addresses that serve PDFs without one (see `isPDFMIMEType`).
    static func isPDFURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// Whether `mimeType` names PDF bytes. Case- and parameter-insensitive:
    /// servers append `; charset=` noise to everything.
    static func isPDFMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        return mimeType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == pdfMIMEType
    }

    /// Whether `url` is a local PDF file that exists. Only existing files:
    /// a remote `https://…/x.pdf` is not on this machine, and a missing
    /// path is a 404 the page should report, not the viewer.
    static func isLocalPDFFile(_ url: URL) -> Bool {
        guard url.isFileURL, isPDFURL(url) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// Whether `url` is a remote address that probably serves a PDF: http(s)
    /// with a `.pdf` path. The response MIME type confirms the rest, so a
    /// liar just falls back to the web view when the fetch says otherwise.
    static func isRemotePDFURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return isPDFURL(url)
    }

    /// Display name for a PDF source: the filename, or the full address
    /// when the URL carries no usable last component.
    static func displayName(for url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty ? url.absoluteString : last
    }
}

/// Shared zoom stepping for web pages (`WKWebView.pageZoom`) and the PDF
/// viewer (`PDFView.scaleFactor`).
///
/// One helper because both answer ⌘+ / ⌘− / ⌘0: multiplicative steps feel
/// the same at every level, and both surfaces clamp to WebKit's documented
/// 0.25...5 range. Pure so tests pin it without a view.
enum ZoomSupport {
    /// Smallest and largest zoom either surface allows.
    static let minimumZoom = 0.25
    /// See above.
    static let maximumZoom = 5.0
    /// One ⌘+ / ⌘− step multiplies or divides by this.
    static let stepFactor = 1.25

    /// Steps `zoom` up (`direction` > 0) or down, clamped to the range.
    /// A zero direction answers the clamped input unchanged.
    static func stepped(_ zoom: Double, direction: Int) -> Double {
        let clamped = min(max(zoom, minimumZoom), maximumZoom)
        if direction > 0 {
            return min(clamped * stepFactor, maximumZoom)
        }
        if direction < 0 {
            return max(clamped / stepFactor, minimumZoom)
        }
        return clamped
    }

    /// Whether a stepped move would change anything: at the stops the keys
    /// still work, they just have nowhere to go.
    static func canStep(_ zoom: Double, direction: Int) -> Bool {
        stepped(zoom, direction: direction) != min(max(zoom, minimumZoom), maximumZoom)
    }
}
