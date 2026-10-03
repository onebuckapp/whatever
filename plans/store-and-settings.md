# Store and settings

Move persistent browser data into an XPC service backed by boogie, and expose
it — plus the `WKWebView` surface — through one settings modal.

Supersedes `plans/nim-bridge.md`, whose "synchronous, main thread only" and
"Swift owns all memory" rules assume an in-process static library. `plans/nim.md`
already requires database work off the main thread, so the boundary is now
asynchronous and crosses a process.

## Stores

boogie is used in-process inside the XPC service; it has no network mode, so the
transport is ours to write.

| Domain | boogie store | Notes |
|---|---|---|
| Settings | `kv` | one JSON document under one key |
| Bookmarks | `docstore` | JSON-native, nested folders trivial |
| History | `rdbms` | append-only logstore has no delete |
| Sessions | `rdbms` | `windows` and `tabs` tables |

boogie holds an exclusive `flock` on a store path for the store's lifetime, so
exactly one process may open them. Only the service does. The app must never
link the stores directly.

There is no migration framework and `createTableIfNotExist` ignores changed
columns, so every schema change bumps a version and runs an explicit migration.
Foreign keys are `RESTRICT` only: delete children before parents.

## Phase 1 — XPC service

`core/nim-core/`:

- `browsercore.nimble` gains `requires "boogie >= 0.2.1"`. clue already resolves
  it through `clue develop`.
- `storage/database.nim` owns all four handles under
  `~/Library/Application Support/Whatever/`.
- `storage/schema.nim` holds table definitions and the version key.
- `api/{settings,bookmark,history,session}_api.nim` expose the C ABI.

ABI: JSON in a two-phase caller-owned buffer for list results, status ordinals
plus `bc_last_error`, and `bc_free_string` only where a stable pointer is
genuinely easier than the two-phase form.

Built with `--threads:on --mm:arc` and `enableConcurrency = true`, so the
service can serve XPC on a private queue. Consequences: `updateRow` raises, so
callers fetch-merge-write-back; `readOnly` is unavailable with concurrency.

Built with `-d:boogieNoCrashHandlers`. Boogie's default handlers
flush-then-terminate on `SIGTERM`, which turns logout into a non-graceful exit
and an XPC service receives `SIGTERM` on idle eviction. The service calls
`flushAllStores()` and `checkpoint()` from its own shutdown path instead.

`macos/`:

- New `WhateverStore` (`xpc-service`) target embedding into the app, with
  `macos/Sources/Store/` holding the listener plumbing and the `@objc` protocol
  mirroring the C ABI.
- QR moves into the service, so `BrowserCore.qrSVG` and `QRPopupPresenter` go
  async (spinner while pending, still beeps on failure).
- `-lbrowsercore` and the bridging header leave the app target once QR is fully
  behind the service.
- `core/Makefile` extends `check-abi` for the new exports.

A single long-lived `StoreClient` connection singleton, reconnecting on
invalidation. A busy-lock error is retryable, never a hang.

## Phase 2 — Settings

One `Codable` `WhateverSettings` with `general`, `appearance`, and `web`
sections, stored as one JSON document. The existing noise overlay config nests
under `appearance` rather than being re-specified.

Live where WebKit allows, and flag the rest for reload:

| Live on `WKWebView` | Config-time on `WKWebViewConfiguration` |
|---|---|
| `pageZoom` | `allowsContentJavaScript` |
| `customUserAgent` | `upgradeKnownHostsToHTTPS` |
| `allowsLinkPreview` | `mediaTypesRequiringUserActionForPlayback` |
| `underPageBackgroundColor` | `allowsInlineMediaPlayback` |
| `allowsMagnification` | `limitsNavigationsToAppBoundDomains` |
| `allowsBackForwardNavigationGestures` | `javaScriptCanOpenWindowsAutomatically` |
| `tabFocusesLinks`, `elementFullscreenEnabled` (`WKPreferences`) | `minimumFontSize`, `siteSpecificQuirksModeEnabled` (`WKPreferences`) |

Live changes apply immediately to every open view. Config-time changes set a
`needsReload` flag that surfaces a "Reload tabs to apply" affordance. Nothing
reloads behind the user's back.

`WebViewFactory.makeWebView` applies the config-time half; the window gets an
`applyLiveSettings()` that walks the open views.

Availability, checked against the SDK headers:

- `WKWebpagePreferences.preferredContentMode` is `API_AVAILABLE(ios(13.0))` —
  not exposed on macOS.
- `preferredHTTPSNavigationPolicy` is macOS 15.2+ and the deployment target is
  14.0, so it needs `#available` and is hidden otherwise.

Migration: if kv has no settings document and UserDefaults has
`whatever.noiseOverlay`, decode it, write it as the `appearance` section, and
keep the UserDefaults key as a rollback fallback until the write is confirmed.

## Phase 3 — Settings modal

Mijick `CenterPopup`, roughly 720×520, fixed ~200pt sidebar and a scrollable
detail pane. Same treatment as the QR card: `cornerRadius(20)`,
`overlayColor(.black.opacity(0.38))`, `tapOutsideToDismissPopup(true)`, the
two-layer shadow, `.padding(.vertical, 88)` for shadow room, and a consuming
`.onTapGesture {}` so clicks on empty card space do not reach the tap-outside
layer.

Sections: **General**, **Appearance** (the noise overlay controls move here; the
toolbar grain button stays as a shortcut), **Web** (grouped WebKit table),
**Bookmarks**, **History**, **Search**, **Downloads** (placeholder until
`WKDownloadDelegate` exists).

Entry points: hamburger menu, a gear toolbar item, and replacing the empty
SwiftUI `Settings { EmptyView() }` so the app menu opens the modal rather than a
blank window. All three reuse `ModalEventShieldView` and the coordinator
pattern, so page clicks stay swallowed.

## Phase 4 — History

`HistoryEntry` gains `visitCount` and `lastVisited`. `NavigationController`
records only for non-private tabs with per-tab recording enabled. A repeat of
the same URL within 10s updates the existing row instead of inserting.

`rdbms.where` is equality-only — no ranges, no `OR`, no `ORDER BY` — so:

- history by day via an indexed `dayBucket` text column queried by equality,
- recency via `allRows` (PK order), truncated,
- text search as a bounded full scan with an early cap.

Per-entry delete and delete-older-than both work.

## Phase 5 — Sessions and lazy tabs

New rdbms store: `windows` and `tabs` (`tabs.windowID → windows.id`).
Persisted: window frame, tab order, pinned state, each tab's URL and title, the
per-tab back/forward URL array and its index, selected tab, split layout and
divider ratio. No scroll position — pages already load fresh. Private tabs are
never persisted.

`BrowserTab.webView` becomes optional:

```swift
private(set) var webView: WKWebView?
func ensureWebView() -> WKWebView   // create + load current URL on demand
func discardWebView()               // drop the view, keep history
```

`init` creates a tab with a URL and no view. `selectTab`, or becoming a
displayed split pane, calls `ensureWebView()`. Callers that genuinely need a
view — the QR menu item, focus, `makeFirstResponder` — call it too; the rest go
nil-safe. `BrowserTabController` is retargeted on both creation and discard,
publishing cleared state so the toolbar never shows a stale title.

This is the riskiest phase. `replaceWebView()` on every navigation is what
gives each page its own process pool, and `BrowserPaneController.viewDidLoad`
assumes a view exists. Behavior must stay identical for the active tab.

Snapshot writes are debounced ~1s on any tab, window, or layout change, plus on
`applicationWillTerminate` and window close. Force-quit is survivable; a
quit-only write is not.

## Process model: reuse within a site, isolate across sites

The app currently hands every page a fresh `WKProcessPool`, which gives each
page its own WebContent processes but also means following a link from
`example.com/a` to `example.com/b` pays a full process spawn. Same-site
navigation should stay in one process.

The unit of sharing is the **eTLD+1** ("registrable domain"), not the host, so
`example.com` and `www.example.com` share. A pool cache keyed on that:

- a web view built for a URL already in the cache reuses that pool, so
  same-site navigation stays in one process and keeps cookies warm;
- a first visit to a site mints a pool, and leaving the site lets it be
  released when its last view goes away.

This sits alongside the lazy-tab work rather than replacing it. Two things to
get right:

- **A pool must not outlive its last view.** Retaining it forever is a slower
  leak than the one being fixed, so entries are reference counted and dropped
  at zero. The lazy-tab refactor is what makes that tractable: a hidden tab
  holds no view, so it holds no pool either.
- **`WKWebsiteDataStore` still has to match.** Two views in one process with
  different data stores is an error. Regular tabs share the persistent default
  store; private tabs get one non-persistent store per tab, so a private tab
  cannot share a pool with a regular one. The cache is keyed on
  (registrable domain, privacy mode).

There is no public API to read a site's eTLD+1, so it needs a small public
suffix check. A compact list of the common multi-label suffixes (`co.uk`,
`com.au`, and friends) covers real use; anything not recognised falls back to
the last two labels, which is wrong only for unusual suffixes.

## Sequencing

Phases 1-3 land as one reviewable unit: the service exists, the settings modal
is usable, nothing is lazy yet. Phases 4-5 follow separately so the session work
cannot destabilize a working app. The process-model change lands with phase 5,
since it depends on tabs being able to drop their views.