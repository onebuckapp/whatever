import AppKit
import AVFoundation

/// Shared decoders for tab chrome: one image cache and one looping player
/// per media path, so fifteen tabs on the same video cost one decoder
/// rather than fifteen.
///
/// Main thread only, like the cells that use it.
enum TabThemeMedia {
    private static let images = NSCache<NSString, NSImage>()
    private static let animations = NSCache<NSString, AnimatedImageFrames>()

    /// Decoded image for a settings path, cached. A missing or unreadable
    /// file reads as nil and the cell falls back to no background; the pane
    /// says nothing, matching the window background's silent fallback.
    static func image(at path: String) -> NSImage? {
        if let hit = images.object(forKey: path as NSString) {
            return hit
        }
        guard FileManager.default.isReadableFile(atPath: path),
              let image = NSImage(contentsOfFile: path)
        else {
            return nil
        }
        images.setObject(image, forKey: path as NSString)
        return image
    }

    /// Decoded animation frames for a settings path, cached, or nil when the
    /// file is not animated. Frames are thumbnails bounded well above the
    /// largest cell, never full-size: a hundred full-size frames would turn
    /// one GIF into gigabytes.
    static func animation(at path: String) -> [AnimatedImageFrame]? {
        if let hit = animations.object(forKey: path as NSString) {
            return hit.frames.isEmpty ? nil : hit.frames
        }
        let frames = AnimatedImage.frames(
            at: URL(fileURLWithPath: path),
            maxPixelSize: 880
        ) ?? []
        animations.setObject(AnimatedImageFrames(frames: frames), forKey: path as NSString)
        return frames.isEmpty ? nil : frames
    }
}

/// `NSCache` holds objects, so the frame array rides in one.
private final class AnimatedImageFrames: NSObject {
    let frames: [AnimatedImageFrame]
    init(frames: [AnimatedImageFrame]) {
        self.frames = frames
    }
}

/// One muted looping player per video path, reference-counted by the cells
/// showing it. Playback runs while at least one cell holds the path and
/// pauses when the last one lets go; the picture is never cleared, so a
/// re-shown tab resumes where the loop is rather than flashing blank.
final class TabVideoPool {
    static let shared = TabVideoPool()

    private final class Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        var owners = 0

        init?(url: URL) {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer(playerItem: item)
            player.isMuted = true
            self.player = player
            self.looper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    private var players: [String: Entry] = [:]

    /// The looping player for `path`, or nil when the file cannot play.
    /// Call `release(path:)` when the cell stops showing it.
    func acquire(path: String) -> AVPlayer? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let entry: Entry
        if let existing = players[path] {
            entry = existing
        } else {
            guard let fresh = Entry(url: URL(fileURLWithPath: path)) else { return nil }
            players[path] = fresh
            entry = fresh
        }
        entry.owners += 1
        if entry.owners == 1 {
            entry.player.play()
        }
        return entry.player
    }

    func release(path: String) {
        guard let entry = players[path] else { return }
        entry.owners = max(0, entry.owners - 1)
        if entry.owners == 0 {
            entry.player.pause()
            players.removeValue(forKey: path)
        }
    }
}
