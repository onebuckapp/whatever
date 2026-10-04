import WebKit

/// Page-level audio mute and playback detection.
///
/// WebKit offers neither on macOS. `requestMediaPlaybackState` answers a weaker
/// question (is *any* media playing, including media the page has itself muted or
/// turned down) and it is asynchronous, and there is no muting API at all, only
/// `pauseAllMediaPlayback` and `setAllMediaPlaybackSuspended`, which stop
/// playback rather than silence it. These three selectors are what Safari uses
/// for its own per-page mute, and they are the only thing that mutes a page
/// without the page being able to tell.
///
/// Checked present on macOS 14.8.9 with the 15.2 SDK. Nothing here is covered by
/// any compatibility promise, so `PageAudioBridge.isAvailable` is consulted before
/// every use: if a future WebKit renames these, tab muting degrades to doing
/// nothing rather than to misbehaving, and the loss is logged once.
///
/// Unlike `HTMLMediaElement.muted`, this mutes at the page's audio output. The
/// page sees no change to any element and cannot undo it, and it covers Web Audio
/// and WebRTC audio, which element-level muting never reached.
enum PageAudioMuteState {
    static let none: UInt64 = 0
    static let audio: UInt64 = 1 << 0
    /// Deliberately never set. Muting the page's microphone is not what a tab's
    /// mute button means, and asking for it here would be a privilege escalation
    /// dressed up as a convenience.
    static let captureDevices: UInt64 = 1 << 1
}

/// The private WebKit surface, declared as an `@objc` protocol so it can be
/// reached by `unsafeBitCast`.
///
/// `_setPageMuted:` takes a `uint64`, not an object, so `perform(_:with:)` cannot
/// carry the argument and an IMP-shaped protocol is the way to send it short of
/// hand-building an `NSInvocation` on every toggle.
@objc private protocol PageAudioControlling {
    func _isPlayingAudio() -> Bool
    func _setPageMuted(_ state: UInt64)
    func _mediaMutedState() -> UInt64
}

enum PageAudioBridge {
    /// Resolved once rather than per call: the answer cannot change while the
    /// process is running, and `instancesRespond(to:)` is not free.
    static let isAvailable: Bool = {
        let view: AnyClass = WKWebView.self
        return view.instancesRespond(to: NSSelectorFromString("_isPlayingAudio"))
            && view.instancesRespond(to: NSSelectorFromString("_setPageMuted:"))
            && view.instancesRespond(to: NSSelectorFromString("_mediaMutedState"))
    }()

    /// Whether the page is currently putting sound out.
    ///
    /// True for Web Audio and for WebRTC, so a page that makes noise without an
    /// `<audio>` or `<video>` element still counts. False when the only media is
    /// one the page has itself muted or turned to zero, and false while a hidden
    /// tab's audio is still running but silent.
    ///
    /// A plain getter rather than a property, so KVO has nothing to observe and
    /// this has to be polled.
    static func isProducingAudio(_ webView: WKWebView) -> Bool {
        guard isAvailable else { return false }
        return surface(for: webView)._isPlayingAudio()
    }

    /// What WebKit currently has muted on the page.
    static func mutedState(of webView: WKWebView) -> UInt64 {
        guard isAvailable else { return PageAudioMuteState.none }
        return surface(for: webView)._mediaMutedState()
    }

    static func setMuted(_ isMuted: Bool, on webView: WKWebView) {
        guard isAvailable else {
            if !hasLoggedUnavailable {
                hasLoggedUnavailable = true
                NSLog("Tab audio: this WebKit has no page-level mute. Tab muting is unavailable.")
            }
            return
        }
        surface(for: webView)._setPageMuted(
            isMuted ? PageAudioMuteState.audio : PageAudioMuteState.none
        )
    }

    private static var hasLoggedUnavailable = false

    private static func surface(for webView: WKWebView) -> PageAudioControlling {
        unsafeBitCast(webView, to: PageAudioControlling.self)
    }
}