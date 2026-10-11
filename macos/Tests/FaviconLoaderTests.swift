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

import AppKit
import Foundation
import Testing
@testable import Whatever

/// Retina favicon lookup: the smallest source covering 32px wins, the
/// well-known high-res filenames are always probed, the walk measures what
/// arrives rather than believing the page's `sizes` claim, and the winner is
/// rasterized into the 16pt tab slot before anyone draws it.
@MainActor
struct FaviconLoaderTests {
    private typealias Entry = (url: URL, width: Int, isTouch: Bool)

    private var page: URL { URL(string: "https://example.com/some/page")! }

    private func entry(_ href: String, width: Int = 0, isTouch: Bool = false) -> Entry {
        (URL(string: href, relativeTo: page)!.absoluteURL, width, isTouch)
    }

    @Test("32 sorts before 48 before larger files")
    func closestCoveringFirst() {
        // A 32px source rasterizes 1:1 into the tab slot; anything bigger only
        // adds download for the same drawn pixels.
        let entries = [
            entry("/icon-180.png", width: 180),
            entry("/icon-48.png", width: 48),
            entry("/icon-96.png", width: 96),
            entry("/icon-32.png", width: 32),
        ]
        let urls = FaviconLoader.candidates(from: entries, pageURL: page).map(\.lastPathComponent)
        #expect(urls[0] == "icon-32.png")
        #expect(urls[1] == "icon-48.png")
        #expect(urls[2] == "icon-96.png")
        #expect(urls[3] == "icon-180.png")
    }

    @Test("a small known icon sorts before unknown sizes")
    func knownSmallBeforeUnknown() {
        let entries = [
            entry("/apple-touch-icon.png", isTouch: true),
            entry("/icon-16.png", width: 16),
        ]
        let urls = FaviconLoader.candidates(from: entries, pageURL: page).map(\.lastPathComponent)
        #expect(urls[0] == "icon-16.png")
        #expect(urls[1] == "apple-touch-icon.png")
    }

    @Test("unsized touch icon sorts before unsized plain icon")
    func touchWinsUnknownSizes() {
        // The conventions reserve touch icons for large artwork while an
        // unsized plain icon is usually 16 or 32px. Preferring the probably
        // bigger file is what keeps tabs sharp.
        let entries = [
            entry("/favicon-16.png"),
            entry("/apple-touch-icon.png", isTouch: true),
        ]
        let urls = FaviconLoader.candidates(from: entries, pageURL: page).map(\.absoluteString)
        #expect(urls[0] == "https://example.com/apple-touch-icon.png")
        #expect(urls[1] == "https://example.com/favicon-16.png")
    }

    @Test("data-URI icon sorts first: it costs no request to try")
    func dataURIFirst() {
        let entries = [
            entry("/icon-192.png", width: 192),
            entry("data:image/png;base64,iVBORw0KGgo="),
        ]
        let urls = FaviconLoader.candidates(from: entries, pageURL: page).map(\.absoluteString)
        #expect(urls.first?.hasPrefix("data:image/png") == true)
        #expect(urls[1] == "https://example.com/icon-192.png")
    }

    @Test("high-res probes ride along and skip what the page declared")
    func probesAppendedDeduped() {
        let entries = [entry("/apple-touch-icon.png", isTouch: true)]
        let urls = FaviconLoader.candidates(from: entries, pageURL: page).map(\.absoluteString)
        #expect(urls.contains("https://example.com/apple-touch-icon.png"))
        #expect(urls.filter { $0 == "https://example.com/apple-touch-icon.png" }.count == 1)
        #expect(urls.last == "https://example.com/apple-touch-icon-precomposed.png")
    }

    @Test("probes resolve at the origin root, not the page directory")
    func probesAtOrigin() {
        let probes = FaviconLoader.highResProbes(
            for: URL(string: "https://example.com/deep/nested/page")!,
            excluding: []
        ).map(\.absoluteString)
        #expect(probes == [
            "https://example.com/apple-touch-icon.png",
            "https://example.com/apple-touch-icon-precomposed.png",
        ])
    }

    @Test("a page declaring nothing falls back to favicon.ico, then probes")
    func fallbackThenProbes() {
        let urls = FaviconLoader.candidates(from: [], pageURL: page).map(\.absoluteString)
        #expect(urls == [
            "https://example.com/favicon.ico",
            "https://example.com/apple-touch-icon.png",
            "https://example.com/apple-touch-icon-precomposed.png",
        ])
    }

    @Test("candidate list is capped")
    func capped() {
        let entries = (0..<20).map { entry("/icon-\($0).png", width: $0) }
        let urls = FaviconLoader.candidates(from: entries, pageURL: page)
        #expect(urls.count == FaviconLoader.maximumCandidates)
        #expect(urls.first?.absoluteString == "https://example.com/icon-19.png")
    }

    @Test("pixel width reports the widest representation on hand")
    func pixelWidthMeasures() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let small = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let large = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 180, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        image.addRepresentation(small)
        image.addRepresentation(large)
        // A multi-image `.ico` lands here the same way: several sizes side by
        // side, and only the widest decides whether the lookup can stop.
        #expect(FaviconLoader.pixelWidth(of: image) == 180)
    }

    @Test("a 16px source is below the cutoff, 32px covers it")
    func cutoff() {
        #expect(16 < FaviconLoader.sufficientPixels)
        #expect(32 >= FaviconLoader.sufficientPixels)
    }

    @Test("the winner rasterizes into the 16pt tab slot with 32px of backing")
    func tabSlot() throws {
        let normalized = FaviconLoader.tabIcon(from: try image(pixels: 180))
        #expect(normalized.size == NSSize(width: 16, height: 16))
        #expect(normalized.representations.map(\.pixelsWide).max() == 32)
        #expect(normalized.representations.map(\.pixelsHigh).max() == 32)
    }

    @Test("a 16px source is normalized, not dropped")
    func smallSourceNormalized() throws {
        let normalized = FaviconLoader.tabIcon(from: try image(pixels: 16))
        #expect(normalized.size == NSSize(width: 16, height: 16))
        #expect(normalized.representations.map(\.pixelsWide).max() == 32)
    }

    @Test("a wide source fits the slot without stretching it")
    func aspectFit() throws {
        let normalized = FaviconLoader.tabIcon(from: try image(pixels: 64, height: 32))
        #expect(normalized.size == NSSize(width: 16, height: 16))
        #expect(normalized.representations.map(\.pixelsWide).max() == 32)
        #expect(normalized.representations.map(\.pixelsHigh).max() == 32)
    }

    @Test("slot sharpening keeps the size and lifts edges")
    func sharpening() throws {
        // Mid-tone step, dark grey to light grey: a pure black/white edge
        // would saturate the kernel math straight back to identical bytes and
        // prove nothing, while a flat field is exactly identity by
        // construction (the kernel sums to 1). Both properties pinned here.
        let space = CGColorSpaceCreateDeviceRGB()
        let stepped = try #require(CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        stepped.setFillColor(CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1))
        stepped.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
        stepped.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
        stepped.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
        let raster = try #require(stepped.makeImage())
        let sharpened = FaviconLoader.sharpen(raster)
        #expect(sharpened.width == 32)
        #expect(sharpened.height == 32)
        let before = raster.dataProvider?.data as Data?
        let after = sharpened.dataProvider?.data as Data?
        #expect(before != nil && after != nil && before != after)

        let flat = try #require(CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        flat.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        flat.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let flatRaster = try #require(flat.makeImage())
        let flatOut = FaviconLoader.sharpen(flatRaster)
        #expect((flatRaster.dataProvider?.data as Data?) == (flatOut.dataProvider?.data as Data?))
    }

    private func image(pixels: Int, height: Int? = nil) throws -> NSImage {
        let height = height ?? pixels
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = NSImage(size: NSSize(width: pixels, height: height))
        image.addRepresentation(rep)
        return image
    }
}
