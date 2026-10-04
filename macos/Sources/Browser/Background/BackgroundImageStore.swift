import AppKit
import CoreGraphics
import CoreImage
import ImageIO

/// Reads a background image off the main thread, downsampled and colour-graded,
/// and remembers the result.
///
/// Two things this deliberately does not do. It does not use `NSCache`, because
/// that evicts under memory pressure and a wallpaper that blinks out mid-scroll
/// is worse than the memory it saves. And it does not use `NSImage(data:)`, which
/// decodes at full size: a 6K photograph is roughly 150 MB as a bitmap, to fill a
/// window that can never show more than a couple of thousand pixels across.
///
/// The cache is keyed by path, modification date, requested size and effects, so
/// editing a file in place, moving to another display, or dragging a slider all
/// miss the cache, and nothing else does.
final class BackgroundImageStore {
    /// Identifies one request, so a decode that finishes after the view has moved
    /// on can be recognised and dropped.
    struct Token: Hashable {
        fileprivate let id: Int
    }

    enum Loaded {
        case success(CGImage)
        case failure(BackgroundMediaError)
    }

    struct Outcome {
        let token: Token
        let loaded: Loaded
    }

    private struct Key: Hashable {
        let path: String
        let modified: Date
        let maxPixelSize: Int
        let effects: BackgroundMediaConfiguration.Effects
    }

    private struct Entry {
        let image: CGImage?
        let error: BackgroundMediaError?
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    private let queue = DispatchQueue(label: "app.whatever.background-image", qos: .userInitiated)
    private var cache: [Key: Entry] = [:]
    /// Bounded by hand because a wallpaper cache should not be the thing that
    /// grows without limit as the user browses.
    private var insertionOrder: [Key] = []
    private var nextToken = 0
    private let maximumEntries = 8

    @discardableResult
    func load(
        path: String,
        maxPixelSize: Int,
        effects: BackgroundMediaConfiguration.Effects,
        completion: @escaping (Outcome) -> Void
    ) -> Token {
        let token = Token(id: nextToken)
        nextToken += 1

        let url = URL(fileURLWithPath: path)
        let key = Key(
            path: path,
            modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast,
            maxPixelSize: maxPixelSize,
            effects: effects
        )

        queue.async {
            let entry: Entry
            if let cached = self.cache[key] {
                entry = cached
            } else {
                entry = self.produce(key: key, url: url)
                self.cache[key] = entry
                self.insertionOrder.append(key)
                while self.insertionOrder.count > self.maximumEntries {
                    self.cache.removeValue(forKey: self.insertionOrder.removeFirst())
                }
            }
            let outcome = Outcome(
                token: token,
                loaded: entry.image.map { Loaded.success($0) }
                    ?? .failure(entry.error ?? .unsupportedImage(path: path))
            )
            DispatchQueue.main.async { completion(outcome) }
        }
        return token
    }

    // MARK: - Decoding

    private func produce(key: Key, url: URL) -> Entry {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return Entry(image: nil, error: .unreadableFile(path: key.path))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // The cap is what keeps a huge source from becoming a huge bitmap.
            // `maxPixelSize` is in pixels, and the caller derives it from the
            // window's size in points times the backing scale.
            kCGImageSourceThumbnailMaxPixelSize: max(key.maxPixelSize, 64),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return Entry(image: nil, error: .unsupportedImage(path: key.path))
        }
        guard key.effects.isIdentity else {
            return Entry(
                image: apply(key.effects, to: raw, originalSize: pixelSize(of: source) ?? CGSize(width: raw.width, height: raw.height)),
                error: nil
            )
        }
        return Entry(image: raw, error: nil)
    }

    /// The source's real pixel dimensions, which the thumbnail has already thrown
    /// away by the time the filters run.
    private func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Runs the colour grading once per parameter set.
    ///
    /// Effects are baked into the decoded image rather than applied while
    /// drawing, so a window resize redraws a bitmap instead of re-running
    /// CoreImage. That is the single biggest performance decision here: the
    /// alternative re-filters on every frame of a live resize.
    private func apply(
        _ effects: BackgroundMediaConfiguration.Effects,
        to image: CGImage,
        originalSize: CGSize
    ) -> CGImage? {
        let source = CIImage(cgImage: image)
        // The blur radius is given in points and applied after downsampling, so
        // it is scaled by how much the image was reduced. Without that, one
        // number would mean a much weaker blur on a large photo than on a small
        // one.
        let reduction = originalSize.width > 0
            ? Double(image.width) / Double(originalSize.width)
            : 1
        var output = source

        if effects.blurRadius > 0.001 {
            // Clamped to the extent first: a Gaussian blur reads transparent
            // beyond its input, so the edges would fade to nothing without it.
            let clamped = source.clampedToExtent()
            let blurred = clamped.applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: effects.blurRadius * reduction]
            )
            output = blurred.cropped(to: source.extent)
        }

        // One filter for all three: CIColorControls is a single pass, and three
        // separate filters would be three full-image traversals.
        output = output.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: effects.brightness,
                kCIInputContrastKey: effects.contrast,
                kCIInputSaturationKey: effects.saturation,
            ]
        )

        guard let rendered = Self.context.createCGImage(output, from: source.extent) else {
            // A failed grade should still leave the user with their picture.
            return image
        }
        return rendered
    }
}