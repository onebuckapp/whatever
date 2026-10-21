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
import Testing
@testable import Whatever

/// The PDF-routing rules, as pure value semantics. Every test here drives
/// the helpers directly: no tab, no view, no network.
struct PDFSupportTests {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    @Test("pdf extension matches regardless of case")
    func extensionMatchesCaseInsensitively() {
        #expect(PDFSupport.isPDFURL(url("file:///tmp/report.PDF")))
        #expect(PDFSupport.isPDFURL(url("https://example.com/x.pdf")))
        #expect(!PDFSupport.isPDFURL(url("https://example.com/x.html")))
        #expect(!PDFSupport.isPDFURL(url("https://example.com/pdf")))
    }

    @Test("mime match ignores case and parameters")
    func mimeIgnoresCaseAndParameters() {
        #expect(PDFSupport.isPDFMIMEType("application/pdf"))
        #expect(PDFSupport.isPDFMIMEType("Application/PDF; charset=utf-8"))
        #expect(!PDFSupport.isPDFMIMEType("text/html"))
        #expect(!PDFSupport.isPDFMIMEType(nil))
    }

    @Test("remote pdf urls are http(s) with a pdf path")
    func remotePDFURLs() {
        #expect(PDFSupport.isRemotePDFURL(url("https://example.com/a.pdf")))
        #expect(PDFSupport.isRemotePDFURL(url("http://example.com/a.PDF")))
        #expect(!PDFSupport.isRemotePDFURL(url("https://example.com/a.html")))
        #expect(!PDFSupport.isRemotePDFURL(url("file:///tmp/a.pdf")))
        #expect(!PDFSupport.isRemotePDFURL(url("w://about")))
    }

    @Test("display name prefers the filename")
    func displayNamePrefersFilename() {
        #expect(PDFSupport.displayName(for: url("https://example.com/report.pdf")) == "report.pdf")
        #expect(PDFSupport.displayName(for: url("file:///tmp/a.pdf")) == "a.pdf")
    }

    @Test("zoom steps multiply and clamp")
    func zoomSteps() {
        #expect(ZoomSupport.stepped(1.0, direction: 1) == 1.25)
        #expect(ZoomSupport.stepped(1.25, direction: -1) == 1.0)
        #expect(ZoomSupport.stepped(0.1, direction: -1) == ZoomSupport.minimumZoom)
        #expect(ZoomSupport.stepped(99, direction: 1) == ZoomSupport.maximumZoom)
        #expect(ZoomSupport.stepped(1.0, direction: 0) == 1.0)
    }

    @Test("zoom stops report nowhere to go")
    func zoomStops() {
        #expect(!ZoomSupport.canStep(ZoomSupport.maximumZoom, direction: 1))
        #expect(ZoomSupport.canStep(ZoomSupport.maximumZoom, direction: -1))
        #expect(!ZoomSupport.canStep(ZoomSupport.minimumZoom, direction: -1))
        #expect(ZoomSupport.canStep(1.0, direction: 1))
    }

    @Test("cookie matching follows domain, path and secure")
    func cookieMatching() {
        func cookie(
            domain: String,
            path: String = "/",
            secure: Bool = false
        ) -> HTTPCookie {
            HTTPCookie(properties: [
                .domain: domain,
                .path: path,
                .name: "s",
                .value: "v",
                .secure: secure ? "TRUE" : "FALSE",
            ])!
        }
        #expect(PDFDocumentLoader.cookieMatches(
            cookie(domain: "example.com"), url: url("https://example.com/a.pdf")))
        #expect(PDFDocumentLoader.cookieMatches(
            cookie(domain: ".example.com"), url: url("https://sub.example.com/a.pdf")))
        #expect(!PDFDocumentLoader.cookieMatches(
            cookie(domain: "other.com"), url: url("https://example.com/a.pdf")))
        #expect(!PDFDocumentLoader.cookieMatches(
            cookie(domain: "example.com", path: "/docs"), url: url("https://example.com/a.pdf")))
        #expect(!PDFDocumentLoader.cookieMatches(
            cookie(domain: "example.com", secure: true), url: url("http://example.com/a.pdf")))
    }

    @Test("remote filename prefers the server suggestion with pdf suffix")
    func remoteFilename() {
        let response = HTTPURLResponse(
            url: url("https://example.com/download"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Disposition": "attachment; filename=\"report\""]
        )!
        #expect(PDFDocumentLoader.filename(for: url("https://example.com/download"), response: response) == "report.pdf")
    }
}
