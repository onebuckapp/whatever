# Windows port plan — Whatever browser

Locked decisions (2026-10-10): native **C# + WebView2 on WinUI 3** for Windows,
Nim core as a DLL. Linux later: Nim + gintro GTK4 + WebKitGTK 6.0. macOS stays
Swift + WKWebView + XPC.

## Why this shape

- The bridge is already portable. Swift never touches Nim directly: Nim builds a
  static lib behind a clean C ABI (`core/include/browsercore.h` — cstring in,
  caller-owned buffer out, two-phase size probe, `BC_*` status codes) with JSON
  docs over XPC. On Windows/Linux the same ABI becomes an in-process DLL/.so,
  which is simpler than XPC — no service plumbing.
- Exactly one sane engine on Windows: **WebView2 (Edge Chromium)**. Gecko
  desktop embedding is dead; CEF adds a multi-process model and ~150MB binary
  for no benefit over the evergreen WebView2 runtime.
- GTK-on-Windows rejected: no production WebKitGTK port exists, and even
  gintro's author positions GTK as Linux-first. A Windows browser needs
  Chromium.
- Flutter rejected for browser use: `webview_windows`-family plugins render
  off-screen via `Windows.Graphics.Capture` (per-frame capture tax), disable
  WebView2 context menus, and expose no custom-scheme registration or
  request-interception APIs — insufficient for `w://`, the content blocker,
  downloads, and multi-window.
- Qt/QML noted as the "one UI codebase for Win+Linux" alternative
  (`QWebEngineUrlSchemeHandler` is the nicest `w://` story), but costs a giant
  dependency plus a license decision, and every Swift view gets rewritten in
  QML anyway.

## WPF vs WinUI 3

Both wrap the same `CoreWebView2` COM object, so engine behavior is identical.
Chose **WinUI 3** (current MS direction, nicer Composition visuals). Note its
costs: framework-package deployment friction, and custom-window-chrome scenarios
fight the framework more than in WPF.

## Hard constraint: airspace

WebView2 is HWND-hosted, so on Windows nothing can paint XAML over the page.
Popup modals and shields over web content must be separate top-level `Popup`
windows, never in-tree overlays like on macOS (`WKWebView` is a composited
NSView). The modal architecture already isolates shield+card behind presenters,
so budget "popup host = HWND" per card. The noise overlay sits over chrome, not
the page, so it is unaffected.

## Target architecture

```
Whatever.Windows (WinUI 3, .NET 9+, unpackaged exe + optional MSIX)
├── Interop/
│   ├── BrowserCore.cs      # P/Invoke: bc_init / bc_register_thread / bc_shutdown + every bc_*
│   └── CoreClient.cs       # async wrappers + JSON (de)serialization — 1:1 mirror of StoreClient.swift
├── Core/
│   └── browsercore.dll     # Nim --app:lib --cc:vcc (or MinGW-w64), same sources as macOS static lib
└── Shell/                  # XAML + code-behind, ports of the Swift views
```

The JSON wire format stays identical to XPC, so macOS and Windows share protocol
tests. All `bc_*` calls run on one dedicated thread (`bc_register_thread` per
thread — same contract as `StoreService.swift`).

## Phase 1 — Core portability (Nim side, no UI)

1. DLL build: `core/Makefile` target `browsercore.dll` via `--app:lib`; verify
   exports against `browsercore.h` with `dumpbin /exports` (port of `check-abi`).
2. Platform seams: app-support path (`%APPDATA%/Whatever`), file lock
   (`LockFileEx`), path separators — isolate behind the storage module, no API
   changes.
3. Two new exports so all shells share behavior currently living in Swift:
   - `bc_engine_*` — search engines (today Swift-only in `SearchEngine.swift`).
   - `bc_filter_match(url)` — stateless matcher over compiled rules, so C# can
     enforce the content blocker via `WebResourceRequested` (WebView2 has no
     content-blocker-JSON API; WebKitGTK consumes it natively).
4. Blend to core (recommended): the history/bookmark merge in
   `SpotlightController` should move next to the fuzzy ranker so WinUI and GTK
   get identical ordering for free.

## Phase 2 — Windows shell scaffold

1. Project: Blank App, Packaged (WinUI 3 in Desktop) template, then switch to
   **unpackaged** (simpler single-exe distribution; keep a `wapproj` packaging
   project for optional MSIX later). Windows floor: **10 1809+** (WebView2
   requirement, non-negotiable).
2. Runtime strategy: Evergreen bootstrapper check at startup via
   `CoreWebView2Environment.GetAvailableBrowserVersionString()` → friendly
   "install WebView2 Runtime" dialog if missing. Fixed-version packaging only
   for offline/LTSC installs.
3. WebView2 environment: one custom `CoreWebView2Environment` (user-data folder
   under `%APPDATA%`), register the **`w://` custom scheme at environment
   creation** (immutable afterward — all windows share the environment, like the
   single XPC service). Serve `w://` responses from core via
   `WebResourceRequested`; mark the scheme secure-context.
4. Per-tab controllers: one `WebView2` per tab in a custom `Panel`-based strip
   (the tab strip is bespoke — port `TabBarView` measurement/layout logic, not
   `TabView`).

## Phase 3 — Chrome port (dependency order)

1. Toolbar (leading/center/trailing, width-responsive) → Spotlight dropdown
   (omnibox results, keyboard wrap, full-URL subtitles) → tab strip (drag,
   groups, sleeper) → bookmark bar (scroll, DnD, editor card).
2. Settings: one `Window` + `NavigationView` sidebar, 9 panes mirroring
   `SettingsDetailViews`; port the row kit once, reuse 9 times.
3. Cards: each of the ~13 popups becomes a WinUI `Popup`/`ContentDialog` driven
   by a presenter class mirroring the Swift presenters. Shield = transparent
   full-window `Popup` swallowing pointer input (left dismisses, right/middle
   swallowed — same semantics as `ModalEventShieldView`).
4. Effects: noise overlay = `CompositionEffectBrush` (turbulence) or cached
   `CanvasBitmap` tiled over chrome only, hit-test-invisible; crawl ticker =
   `Composition` offset keyframes on a single rendered strip, fed by
   `bc_feed_articles` — same "one texture, move it" design as
   `CrawlTickerNSView`.
5. Credits/About: port `CreditsContent` verbatim (already just data + URLs).

## Phase 4 — Parity + Linux prep

- Port the Swift suite's assertions as the acceptance spec (xUnit): ranking
  order, shield click semantics, width-demand, focus rules.
- Linux reuses everything except the shell: gintro GTK4 + `webkit6`,
  `importc` against `libbrowsercore.so`, content-blocker JSON consumed natively
  by `WebKitUserContentFilterStore`, `w://` via
  `webkit_web_context_register_uri_scheme`.

## First step when building starts

Phase 1 items 1–2: DLL builds, exports verified, Windows smoke test calling
`bc_version` / `bc_history_fuzzy_search` from a C# console harness — de-risks
the whole plan before any XAML exists.
