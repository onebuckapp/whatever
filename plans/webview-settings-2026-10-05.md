# WebView settings and preferences

Survey of what `WKWebView` can be configured with on macOS, what Whatever
already exposes, and what is still available. Deployment target is macOS 14.0
and the SDK is 15.2, so anything marked 15.x needs an `#available` guard.

## The two examples this started from

### Picture in Picture: no public macOS API

`allowsPictureInPictureMediaPlayback` is declared inside `#if TARGET_OS_IPHONE`
in `WKWebViewConfiguration.h`. There is no macOS equivalent, and WebKit exposes
no PiP selector on macOS either. `allowsInlineMediaPlayback`,
`selectionGranularity`, `dataDetectorTypes` and `userInterfaceDirectionPolicy`
are iOS-gated the same way.

Decided: extract the video with AVPlayer and drive
`AVPictureInPictureController` from a floating panel, rather than reach for
private API.

Limits worth stating up front: this cannot work for DRM/EME streams (Netflix,
YouTube premium, most subscription video) or for `blob:`/MSE sources, because
the URL is not extractable in either case. It works for directly-playable MP4
and HLS. Anything built this way has to fail gracefully and say why.

### External links: a real bug, not a missing setting

`uiDelegate` is assigned nowhere in the app. `BrowserPaneController` conforms to
`WKUIDelegate` and implements `createWebViewWith`, but WebKit never asks,
because nothing points it at that object. Every `target="_blank"` link and every
`window.open()` is therefore dropped silently. Same-tab links work, which is why
it reads as "internal links fine, external links dead".

Non-web schemes are a separate path and already work:
`NavigationPolicy.decision(for:)` hands anything that is not http, https, file,
about, data, blob or `whtvr` to `NSWorkspace` and cancels in-tab.

## Milestone 1: fix what the settings depend on

1. Wire `uiDelegate`, add `webViewDidClose`.
2. `WebViewFactory.makeWebView` applies config-time settings but never
   `apply(toWebView:)`, so a freshly built page misses `pageZoom`,
   `allowsLinkPreview`, `allowsMagnification` and `customUserAgent` until some
   unrelated change triggers a live push.
3. `mediaTypesRequiringUserAction` is declared and listed in
   `configTimeWebKeys` but no code writes
   `configuration.mediaTypesRequiringUserActionForPlayback`. Becomes a
   `MediaAutoplayPolicy` enum, applied, with a tolerant decode of the old
   `[String]` form.
4. `configTimeWebKeys` has no call sites. Drive the settings footnotes from it
   so "applies immediately" is only claimed for settings that are actually live.
   The current Display group note is wrong for `minimumFontSize`.
5. `webViewWebContentProcessDidTerminate` is unimplemented, so a crashed content
   process leaves a permanently blank page with no way back.
6. JS `alert`/`confirm`/`prompt` and `runOpenPanelWith` are unimplemented.
   `alert()` currently hangs the run loop; file inputs cannot open anything.

## Milestone 2: new preferences

Available on macOS, currently unused, in rough order of usefulness:

| Setting | API | Since |
| --- | --- | --- |
| Text interaction | `WKPreferences.textInteractionEnabled` | 11.3 |
| AirPlay | `WKWebViewConfiguration.allowsAirPlayForMediaPlayback` | 10.11 |
| Lockdown mode | `WKWebpagePreferences.lockdownModeEnabled` | 13.0 |
| Background printing | `WKPreferences.shouldPrintBackgrounds` | 13.3 |
| Web Inspector | `WKWebView.isInspectable` | 13.3 |
| Inactive scheduling | `WKPreferences.inactiveSchedulingPolicy` | 14.0 |
| Inline predictions | `WKWebViewConfiguration.allowsInlinePredictions` | 14.0 |
| Camera/mic switch | `WKWebView.setCameraCaptureState` / `setMicrophoneCaptureState` | 12.0 |
| Adaptive image glyph | `WKWebViewConfiguration.supportsAdaptiveImageGlyph` | 15.0 |
| Writing Tools | `WKWebViewConfiguration.writingToolsBehavior` | 15.0 |

`inactiveSchedulingPolicy` takes `Suspend`, `Throttle` or `None`.
`WKWebpagePreferences.preferredHTTPSNavigationPolicy` is already pinned to
`.keepAsRequested`, which is what keeps `whtvr://` working.

## Milestone 3: AVPlayer Picture in Picture

As above: locate `<video>`, read `currentSrc`, and offer a floating
`AVPlayer`-backed panel when the source is directly playable.

## Deliberately out of scope

- **Replacing `_setPageMuted` with the public API.** `setAllMediaPlaybackSuspended`
  pauses; it does not mute. A muted tab has to keep playing video silently, and
  there is no public per-tab mute. The private bridge stays, already guarded by
  an availability check in `PageAudioBridge`.
- **Private tabs.** `BrowserPrivacyMode.privateBrowsing` has no reachable UI, so
  per-mode settings would be untestable. Noted, not built.
- **Downloads and HTTP auth challenges.** Real gaps, separate tasks.
- **`FaviconLoader` running `evaluateJavaScript` with JS disabled.** Harmless
  today (falls back to `/favicon.ico`), worth gating later.

## Note for whoever adds a `WKUserScript`

`PageTransparency` turns the setting off with `removeAllUserScripts()`, because
`WKUserContentController` has no `removeUserScript(_:)`. That is only safe
because nothing else injects a script. The first feature that needs a second
script has to convert this into an add/remove pair with the script held.
