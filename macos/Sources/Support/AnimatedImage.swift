import AppKit
import ImageIO
import QuartzCore

/// One decoded animation frame: the bitmap plus how long it holds, in seconds.
struct AnimatedImageFrame {
    let image: CGImage
    let duration: TimeInterval
}

/// Decoded multi-frame images (GIFs and anything else ImageIO reports more
/// than one frame for), shared by tab chrome and the window background.
///
/// Frames come out as thumbnails bounded by `maxPixelSize`, exactly like the
/// background store's stills: a full-size frame per animation frame would
/// turn a hundred-frame GIF into gigabytes. Frame count is capped for the
/// same reason; truncating mid-loop only shortens the loop.
enum AnimatedImage {
    /// Upper bound on decoded frames. Past it the loop ends early rather
    /// than growing without limit.
    static let maximumFrames = 150
    /// Browser-conventional floor for a frame hold: GIFs authored with
    /// near-zero delays mean "as fast as possible", which every browser
    /// reads as ten frames per second.
    static let minimumDuration: TimeInterval = 0.1

    /// Frames and holds for the file at `url`, or nil when it is not an
    /// animated image or cannot be read. Single-frame files read as nil:
    /// the still paths already show those.
    static func frames(
        at url: URL,
        maxPixelSize: Int
    ) -> [AnimatedImageFrame]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1
        else { return nil }
        let count = min(CGImageSourceGetCount(source), maximumFrames)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 64),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        var frames: [AnimatedImageFrame] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary
            ) else { continue }
            frames.append(AnimatedImageFrame(
                image: image,
                duration: max(duration(at: index, in: source), minimumDuration)
            ))
        }
        return frames.isEmpty ? nil : frames
    }

    /// Hold for one frame: the unclamped delay when the encoder wrote one,
    /// else the clamped delay, else the conventional default. Other
    /// multi-frame formats have no standardised per-frame timing in ImageIO
    /// and play at the default.
    private static func duration(at index: Int, in source: CGImageSource) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let dictionary = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return minimumDuration
        }
        if let unclamped = dictionary[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval,
           unclamped > 0 {
            return unclamped
        }
        if let clamped = dictionary[kCGImagePropertyGIFDelayTime] as? TimeInterval,
           clamped > 0 {
            return clamped
        }
        return minimumDuration
    }

    /// Infinite loop over `frames` for a layer's `contents`: each bitmap
    /// held for its own duration, stepping discretely so frames flip rather
    /// than crossfade. The first frame is the layer's resting contents, so
    /// a layer that never runs the animation still shows the poster.
    static func loopAnimation(frames: [AnimatedImageFrame]) -> CAKeyframeAnimation? {
        guard !frames.isEmpty else { return nil }
        let total = frames.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return nil }
        var elapsed: TimeInterval = 0
        var times: [NSNumber] = []
        times.reserveCapacity(frames.count)
        for frame in frames {
            times.append(NSNumber(value: elapsed / total))
            elapsed += frame.duration
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.map(\.image)
        animation.keyTimes = times
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        return animation
    }
}
