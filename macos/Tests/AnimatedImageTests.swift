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
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Whatever

/// Animated image decoding: frames, holds, and the layer loop.
struct AnimatedImageTests {
    /// A two-frame GIF on disk: red for 0.2s, blue for 0.3s.
    private func gifURL() throws -> URL {
        func frame(_ color: CGColor) -> CGImage {
            let context = CGContext(
                data: nil, width: 4, height: 4,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            return context.makeImage()!
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, 2, nil
        ) else {
            Issue.record("cannot create GIF destination")
            return URL(fileURLWithPath: "/dev/null")
        }
        let red: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2],
        ]
        let blue: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.3],
        ]
        CGImageDestinationAddImage(
            destination, frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            red as CFDictionary
        )
        CGImageDestinationAddImage(
            destination, frame(CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            blue as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("cannot finalize GIF")
            return URL(fileURLWithPath: "/dev/null")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatever-test-\(UUID().uuidString).gif")
        try (data as Data).write(to: url)
        return url
    }

    @Test("a GIF decodes to its frames with their holds")
    func decodesFrames() throws {
        let url = try gifURL()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let frames = AnimatedImage.frames(at: url, maxPixelSize: 64) else {
            Issue.record("no frames decoded")
            return
        }
        #expect(frames.count == 2)
        #expect(abs(frames[0].duration - 0.2) < 0.01)
        #expect(abs(frames[1].duration - 0.3) < 0.01)
    }

    @Test("a still image is not an animation")
    func stillIsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whatever-test-\(UUID().uuidString).png")
        let context = CGContext(
            data: nil, width: 4, height: 4,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        guard let image = context.makeImage() else {
            Issue.record("cannot make image")
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            Issue.record("cannot create PNG destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            Issue.record("cannot finalize PNG")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AnimatedImage.frames(at: url, maxPixelSize: 64) == nil)
    }

    @Test("the loop holds each frame for its own duration, forever")
    func loopAnimation() throws {
        let url = try gifURL()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let frames = AnimatedImage.frames(at: url, maxPixelSize: 64),
              let loop = AnimatedImage.loopAnimation(frames: frames)
        else {
            Issue.record("no loop built")
            return
        }
        #expect(loop.repeatCount == .infinity)
        #expect(loop.calculationMode == .discrete)
        #expect(abs(loop.duration - 0.5) < 0.01)
        let values = loop.values as? [CGImage] ?? []
        #expect(values.count == 2)
        let times = loop.keyTimes?.map(\.doubleValue) ?? []
        #expect(times.count == 2)
        #expect(abs(times[0]) < 0.01)
        #expect(abs(times[1] - 0.4) < 0.01)
    }
}
