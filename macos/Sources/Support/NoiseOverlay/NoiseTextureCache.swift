import CoreGraphics
import Foundation

/// The grain tile shared by every overlay.
///
/// Generation is ported from ScreenGrain by Matt Pedersen (MIT), which
/// this project keeps nearby as a reference implementation: a
/// deterministic SplitMix64 field per channel and per-texel alpha
/// proportional to each sample's magnitude. Mean-zero sparse specks
/// stay neutral on both light and dark content, where a full-coverage
/// gray tile would veil it. Only the independent-sample mode is used —
/// one spec per device pixel, which is what the compact look needs.
///
/// Tiles are cached by their full input set and never regenerated per
/// frame: views tile the image with plain `CGContext.draw` calls, and
/// the layer caches the result until the configuration changes.
enum NoiseTextureCache {
    /// Texel dimensions of the source tile, matching the reference.
    static let tileDimension = 512

    /// The tile is authored as a 2x asset, so on Retina it is drawn at
    /// half its pixel size — exactly like `<img src="grain.png"
    /// width="256">` for a 512px source. The source stays at 512px.
    static let sourcePixelsPerPoint: CGFloat = 2

    /// Side of the box the tile is drawn into, in points, so one texel
    /// covers exactly one device pixel and nothing is ever resampled.
    ///
    /// `backingScale` is the display's scale. `min` with the source's
    /// 2x density is what keeps the grain from ever being upscaled:
    /// a 2x screen halves the box (512px source at 256pt, the web
    /// 2x pattern), and a 1x screen keeps it at the source size rather
    /// than stretching a 256px-equivalent across 512 device pixels.
    /// Both cases land on 1:1 texel-to-device-pixel, which is why the
    /// grain reads as crisp specks instead of soft clumps.
    static func tileSidePoints(texSide: CGFloat, backingScale: CGFloat) -> CGFloat {
        guard texSide > 0 else { return 0 }
        let density = min(max(backingScale, 1), sourcePixelsPerPoint)
        return texSide / density
    }

    private struct Key: Hashable {
        let seed: UInt64
        let intensityQ: Int
        let contrastQ: Int
        let colorMode: GrainColorMode
    }

    private static var cached: [Key: CGImage] = [:]
    private static let lock = NSLock()

    /// Intensity is quantized to 1/1024 steps (as in the reference
    /// encoding) and contrast to 1/64, so near-identical values share
    /// one tile.
    static func image(
        seed: UInt64,
        intensity: CGFloat,
        contrast: CGFloat,
        colorMode: GrainColorMode
    ) -> CGImage {
        let key = Key(
            seed: seed,
            intensityQ: Int((min(max(Double(intensity), 0), 1) * 1024).rounded()),
            contrastQ: Int((min(max(Double(contrast), 1), 8) * 64).rounded()),
            colorMode: colorMode
        )
        lock.lock()
        defer { lock.unlock() }
        if let hit = cached[key] {
            return hit
        }
        if cached.count > 8 {
            cached.removeAll()
        }
        let made = GrainTextureGenerator.generate(
            seed: key.seed,
            intensityQ: key.intensityQ,
            contrastQ: key.contrastQ,
            colorMode: key.colorMode,
            dimension: tileDimension
        )
        cached[key] = made
        return made
    }
}

/// Deterministic grain tile generation, ported from ScreenGrain's
/// `TextureGenerator` (MIT, Matt Pedersen).
enum GrainTextureGenerator {
    /// `intensityQ` is the overall coverage in 1/1024 steps and
    /// `contrastQ` a gamma in 1/64 steps applied to each texel's alpha.
    static func generate(
        seed: UInt64,
        intensityQ: Int,
        contrastQ: Int,
        colorMode: GrainColorMode,
        dimension: Int
    ) -> CGImage {
        precondition(dimension > 1)

        let luminance = scalarField(seed: seed ^ 0xA076_1D64_78BD_642F, dimension: dimension)
        let red = scalarField(seed: seed ^ 0xE703_7ED1_A0B4_28DB, dimension: dimension)
        let green = scalarField(seed: seed ^ 0x8EBC_6AF0_9C88_C6E3, dimension: dimension)
        let blue = scalarField(seed: seed ^ 0x5899_65CC_7537_4CC3, dimension: dimension)

        let chromaQ: Int64 = colorMode == .monochrome ? 0 : 768
        var bytes = [UInt8]()
        bytes.reserveCapacity(dimension * dimension * 4)

        for index in luminance.indices {
            let luma = Int64(luminance[index])
            let dR = ((1024 - chromaQ) * luma + chromaQ * Int64(red[index])) / 1024
            let dG = ((1024 - chromaQ) * luma + chromaQ * Int64(green[index])) / 1024
            let dB = ((1024 - chromaQ) * luma + chromaQ * Int64(blue[index])) / 1024
            let coverageAmplitude = abs(luma)
            let colorAmplitude = max(abs(dR), abs(dG), abs(dB))

            guard coverageAmplitude > 0, colorAmplitude > 0, intensityQ > 0 else {
                bytes.append(contentsOf: [0, 0, 0, 0])
                continue
            }

            let linear = min(255, coverageAmplitude * Int64(intensityQ) * 255 / (32768 * 1024))
            // Gamma on the alpha: values above 1 push the weak majority
            // of texels toward fully transparent while leaving the
            // strong ones opaque, so the grain reads as hard black and
            // white specks instead of a uniform gray haze.
            let alpha = Int64(round(255 * pow(Double(linear) / 255, Double(contrastQ) / 64)))
            let divisor = 2 * colorAmplitude
            bytes.append(UInt8(clamping: alpha * (colorAmplitude + dR) / divisor))
            bytes.append(UInt8(clamping: alpha * (colorAmplitude + dG) / divisor))
            bytes.append(UInt8(clamping: alpha * (colorAmplitude + dB) / divisor))
            bytes.append(UInt8(clamping: alpha))
        }

        let space = CGColorSpaceCreateDeviceRGB()
        let image = bytes.withUnsafeMutableBufferPointer { buffer -> CGImage? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let image else {
            preconditionFailure("GrainTextureGenerator: failed to build \(dimension)x\(dimension) tile")
        }
        return image
    }

    static func scalarField(seed: UInt64, dimension: Int) -> [Int32] {
        var generator = GrainSplitMix64(seed: seed)
        return (0..<(dimension * dimension)).map { _ in
            Int32(generator.nextHighWord()) - 32768
        }
    }
}

private struct GrainSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextHighWord() -> UInt16 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return UInt16(truncatingIfNeeded: value >> 48)
    }
}
