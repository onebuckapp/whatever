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
import AVFoundation

/// Hosts the `AVPlayerLayer` behind the window.
///
/// Looping goes through `AVQueuePlayer` with an `AVPlayerLooper` rather than
/// seeking on a timer: the looper keeps a second copy of the item ready, so the
/// loop has no gap and there is no seek hitch at the seam.
///
/// Playback is suspended whenever the window is not worth spending power on,
/// which is most of the time for a background video. Pausing is not the same as
/// clearing the configuration, so the picture stays put and resumes where it
/// stopped.
final class BackgroundVideoLayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var item: AVPlayerItem?
    private var observers: [NSObjectProtocol] = []

    /// Whether the user asked for playback at all.
    private var wantsPlayback = false

    private var path: String?
    private var options = BackgroundMediaConfiguration.VideoOptions()
    /// Set from outside: the window has no background, or it is fully
    /// transparent. Deliberately separate from the window-derived pause below, so
    /// neither can cancel the other out.
    private var isExternallySuspended = false
    private var hasAppliedStartTime = false
    /// Reported once the player is actually producing frames, so the poster can
    /// be dropped rather than left on top of the video forever.
    private var readyObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The player layer is the view's backing layer, which is what makes the
        // video GPU-composited instead of drawn into a bitmap.
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspectFill
        setAccessibilityElement(false)
        observeWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Event transparency

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override var isOpaque: Bool {
        false
    }

    // MARK: - Configuration

    func apply(
        path: String?,
        options: BackgroundMediaConfiguration.VideoOptions,
        fit: BackgroundMediaConfiguration.Fit,
        isActive: Bool,
        isSuspended: Bool
    ) {
        self.options = options
        isExternallySuspended = isSuspended
        wantsPlayback = isActive && !(path ?? "").isEmpty

        // `AVPlayerLayer` has no tile mode, so tiling is not offered for video at
        // all; the size modes are the ones it can express.
        switch fit {
        case .original, .contain:
            playerLayer.videoGravity = .resizeAspect
        case .fill, .stretch, .custom:
            playerLayer.videoGravity = .resizeAspectFill
        }

        if let player, player.rate != 0 {
            player.rate = Float(options.playbackSpeed)
        }

        guard self.path != path else {
            reconcilePlayback()
            return
        }
        self.path = path
        loadPlayer(for: path)
        reconcilePlayback()
    }

    private func loadPlayer(for path: String?) {
        teardownPlayer()
        guard let path, !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            onError?(.unreadableFile(path: path))
            return
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        guard asset.isPlayable else {
            onError?(.unsupportedVideo(path: path))
            return
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        // Always muted. A window that starts making noise unasked is the exact
        // thing the tab mute button exists to prevent.
        player.isMuted = true
        player.actionAtItemEnd = .advance
        self.item = item
        self.player = player
        playerLayer.player = player
        hasAppliedStartTime = false

        // Always loops: a background video that stopped would leave a frozen
        // frame behind the page for as long as the window was open.
        looper = AVPlayerLooper(player: player, templateItem: item)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            MainActor.assumeIsolated { self?.onFirstFrame?() }
        }
    }

    private func teardownPlayer() {
        readyObservation = nil
        looper = nil
        player?.pause()
        playerLayer.player = nil
        player = nil
        item = nil
    }

    /// Whether the window itself should stop the video.
    ///
    /// "Inactive" means the *application* is in the background, not that this
    /// window lost focus. A window that is visible on screen but not key is still
    /// being looked at, and a background video that froze because someone clicked
    /// their other monitor would be wrong.
    ///
    /// The user's two preferences gate this: with "pause when inactive" off, a
    /// background video keeps playing while they use another app, which is
    /// occasionally what someone wants and is never the default.
    private var shouldPauseForWindow: Bool {
        if options.pauseWhenInactive, !NSApp.isActive { return true }
        let hidden = window?.isMiniaturized != false
            || window?.isVisible != true
            || window?.occlusionState.contains(.visible) != true
            || NSApp.isHidden
        return options.pauseWhenHidden && hidden
    }

    /// Whether the system has asked for reduced motion, re-read each time rather
    /// than cached: it can change while the app is running, and a background
    /// video that keeps animating after someone turns the setting on is exactly
    /// the thing the setting is for.
    private var isReducedMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Plays, pauses, or changes rate, according to what everything currently
    /// wants. Kept in one place so no caller has to remember the full condition.
    private func reconcilePlayback() {
        guard let player else { return }
        let shouldRun = wantsPlayback
            && !isExternallySuspended
            && !shouldPauseForWindow
            // Autoplay off means the video sits on its first frame instead of
            // moving.
            && options.autoplay
            && !(options.respectsReduceMotion && isReducedMotionEnabled)
        guard shouldRun else {
            if player.rate != 0 { player.pause() }
            return
        }
        if !hasAppliedStartTime, options.startTime > 0 {
            hasAppliedStartTime = true
            player.seek(to: CMTime(seconds: options.startTime, preferredTimescale: 600))
        }
        // A rate of exactly 0 would freeze a still image; 1 is the floor.
        let rate = Float(max(options.playbackSpeed, 1))
        player.playImmediately(atRate: rate)
    }

    // MARK: - Window lifecycle

    /// Surfaces a failure to whoever is showing the background.
    var onError: ((BackgroundMediaError) -> Void)?
    /// Told when the first frame is up, so the poster behind can be dropped.
    var onFirstFrame: (() -> Void)?

    private func observeWindow() {
        let center = NotificationCenter.default
        // App-level activation, not the window's key state: a visible window that
        // merely lost focus is still on screen, and pausing there would look
        // like the feature had broken.
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            // Reduced motion can be switched on while the app is running, and a
            // video that keeps animating afterwards defeats the point of it.
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] note in
                MainActor.assumeIsolated { self?.windowStateChanged(note) }
            })
        }
    }

    private func windowStateChanged(_ note: Notification) {
        reconcilePlayback()
    }
}