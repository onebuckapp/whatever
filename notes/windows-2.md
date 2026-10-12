# Windows port plan v2 — Whatever browser (WebKit engine)

Locked decisions (2026-10-12): native **C# + WebKit (Windows port) on WinUI 3**
for Windows, Nim core as a DLL. Linux later: Nim + gintro GTK4 + WebKitGTK 6.0.
macOS stays Swift + WKWebView + XPC.

This document supersedes `windows.md` (the WebView2 plan), which is kept as the
rejected-alternative record. The initial Whatever-on-Windows shape is unchanged:
only the engine embedding changes — WebView2 out, WebKit in. Sections carried
over verbatim say so; engine-specific sections are rewritten.

## Why this shape

- The bridge is already portable. Swift never touches Nim directly: Nim builds a
  static lib behind a clean C ABI (`core/include/browsercore.h` — cstring in,
  caller-owned buffer out, two-phase size probe, `BC_*` status codes) with JSON
  docs over XPC. On Windows/Linux the same ABI becomes an in-process DLL/.so,
  which is simpler than XPC — no service plumbing.
- **One engine across three shells.** macOS (WKWebView), Linux (WebKitGTK), and
  Windows (WebKit2 C API) all consume the same content-blocker JSON, user
  scripts, content worlds, and navigation-policy concepts. The macOS porting
  notes map ~1:1 to Windows instead of being re-derived for a second engine
  family. Tracker blocking, cosmetic filtering, quirk behavior, and `w://`
  semantics stay identical everywhere by construction.
- **Deterministic engine version.** We ship pinned WebKit DLLs with the app —
  no evergreen auto-update changing behavior under us, no "install the WebView2
  Runtime" dialog at startup, works offline and on LTSC by construction. The
  honest cost: engine security updates become our bump turnaround (see
  "Engine-bump policy" below), not Microsoft's.
- Exactly one sane non-Chromium engine on Windows: **the upstream Windows port
  of WebKit** (cairo/Skia graphics, libcurl network, Media Foundation media —
  see `OptionsWin.cmake`). Gecko desktop embedding is dead; CEF adds a
  multi-process model and ~150MB binary while forfeiting the shared-engine win.
- GTK-on-Windows rejected: no production WebKitGTK port exists, and even
  gintro's author positions GTK as Linux-first.
- Flutter rejected for browser use: `webview_windows`-family plugins render
  off-screen via `Windows.Graphics.Capture` (per-frame capture tax), disable
  context menus, and expose no custom-scheme registration or request
  interception — insufficient for `w://`, the content blocker, downloads, and
  multi-window.
- Qt/QML noted as the "one UI codebase for Win+Linux" alternative
  (`QWebEngineUrlSchemeHandler` is the nicest `w://` story), but costs a giant
  dependency plus a license decision, and every Swift view gets rewritten in
  QML anyway.
- WebView2 specifically rejected: a second engine family to track, evergreen
  nondeterminism, no native content-blocker API (the whole host-side
  interception design in `windows.md` exists only because of that gap), and a
  hard Microsoft-runtime dependency for no architectural benefit.

## Engine facts (verified against upstream)

- **Source: CI builds, never a local build.** Pin a green
  **Windows-64-bit-Release-Build** from <https://build.webkit.org/#/builders>,
  take the **Archive** link under `compile-webkit`, plus the matching
  [WebKitRequirements](https://github.com/WebKitForWindows/WebKitRequirements)
  release and the latest `vc_redist.x64.exe`. This is the documented path
  ("Downloading build artifacts from Buildbot" in the
  [Windows port docs](https://docs.webkit.org/Ports/WindowsPort.html)).
- 64-bit Windows only. Floor: **Windows 10 1809+** (`NTDDI_VERSION=0x0A000006`
  in `Source/cmake/OptionsWin.cmake`) — identical to the WebView2 plan's floor,
  no change.
- The docs' **WebKit command prompt** (batch file setting up
  `vcvars64` + clang-cl + test fonts, then `perl Tools/Scripts/build-webkit
  --release` producing `WebKitBuild/Release/bin64/MiniBrowser.exe`) is for
  local engine work only. We do not build WebKit; the command prompt matters
  only if we ever need to debug the engine itself or run `MiniBrowser` from
  source during a spike.
- WebKitRequirements caveat: upstream notes the GitHub Releases may end as
  vcpkg integrates directly into the port. Pin a known-good pair
  (build # + requirements version) and record both in the manifest; re-resolve
  deliberately, never floating.
- Engine capabilities (from `OptionsWin.cmake` on main): Media Foundation
  video, WebGL on, GPU process on, remote inspector on, fullscreen API on,
  user-message handlers on. Verify-before-rely gaps: `ENABLE_WEB_AUDIO` **off**,
  `ENABLE_MEDIA_SOURCE` **off**, almost certainly no PDF viewer (plan: download
  / OS handler instead of in-tab rendering), printing and the download manager
  need host-side work via policy clients (same as the WebView2 plan).

## Hard constraint: airspace (unchanged from windows.md)

WebKit's view is HWND-hosted too (WebKit2 docs: "`WKView[Ref]` — native view
that hooks into the platform's toolkit. On Windows, this wraps a HWND"). So on
Windows nothing can paint XAML over the page: popup modals and shields over web
content must be separate top-level `Popup` windows, never in-tree overlays like
on macOS (`WKWebView` is a composited NSView). The modal architecture already
isolates shield+card behind presenters, so budget "popup host = HWND" per card.
The noise overlay sits over chrome, not the page, so it is unaffected.

## Target architecture

```
Whatever.Windows (WinUI 3, .NET 9+, unpackaged exe + optional MSIX)
├── Interop/
│   ├── BrowserCore.cs      # P/Invoke: bc_init / bc_register_thread / bc_shutdown + every bc_*
│   ├── CoreClient.cs       # async wrappers + JSON (de)serialization — 1:1 mirror of StoreClient.swift
│   └── WebKit.Interop/    # P/Invoke over the WebKit2 C API (WK*Ref):
│                           # SafeHandles + WKRetain/Release, UTF-16 WKStringRef,
│                           # loader/navigation/policy client structs, callback marshaling.
│                           # Reference implementation: Tools/MiniBrowser in the WebKit tree.
├── third_party/webkit-win/ # vendored pinned engine binaries + import libs + C headers
│   ├── bin/                # WebKit.dll, JavaScriptCore.dll, WebProcess/NetworkProcess exes, ...
│   ├── lib/                # import libraries for link time
│   ├── include/            # WebKit2 C API headers (WK*.h) matching the pinned build
│   └── manifest.json       # pinned Buildbot build #, WebKitRequirements version, file SHAs
├── Core/
│   └── browsercore.dll     # Nim --app:lib --cc:vcc (or MinGW-w64), same sources as macOS static lib
└── Shell/                  # XAML + code-behind, ports of the Swift views
    └── WebKitHost          # FrameworkElement hosting the WebKit child HWND (manual
                            # parenting + layout sync — WinUI 3 has no HwndHost; WPF stays rejected)
```

The JSON wire format stays identical to XPC, so macOS and Windows share protocol
tests. All `bc_*` calls run on one dedicated thread (`bc_register_thread` per
thread — same contract as `StoreService.swift`).

Engine process model: WebKit2 runs WebProcess/NetworkProcess children out of
the app directory — multiprocess like WebView2, but unmanaged. Ship the child
executables beside the DLLs and define crash-recovery semantics (per-tab
reload on web-process crash), instead of inheriting WebView2's managed model.

One shared `WKContext` (user-data folder under `%APPDATA%`); all tabs share it
like the single XPC service. Per-tab controllers: one `WKPageRef` view per tab
in a custom `Panel`-based strip (the tab strip is bespoke — port `TabBarView`
measurement/layout logic, not `TabView`).

## Phase 1 — Core portability (Nim side, no UI; unchanged from windows.md)

1. DLL build: `core/Makefile` target `browsercore.dll` via `--app:lib`; verify
   exports against `browsercore.h` with `dumpbin /exports` (port of `check-abi`).
2. Platform seams: app-support path (`%APPDATA%/Whatever`), file lock
   (`LockFileEx`), path separators — isolate behind the storage module, no API
   changes.
3. One new export so all shells share behavior currently living in Swift:
   `bc_engine_*` — search engines (today Swift-only in `SearchEngine.swift`).
   (The `bc_filter_match` export from `windows.md` is **deleted**: content
   blocking is native now, no host-side request matching needed.)
4. Blend to core (recommended): the history/bookmark merge in
   `SpotlightController` should move next to the fuzzy ranker so WinUI and GTK
   get identical ordering for free.

## Phase 2 — Windows shell scaffold (rewritten for WebKit)

1. Project: Blank App, Packaged (WinUI 3 in Desktop) template, then switch to
   **unpackaged** (simpler single-exe distribution; keep a `wapproj` packaging
   project for optional MSIX later). Windows floor: **10 1809+** (WebKit
   requirement, non-negotiable — same floor WebView2 needed).
2. Engine vendoring: check the pinned DLLs/libs/headers into
   `third_party/webkit-win/` with `manifest.json` (Buildbot build #,
   WebKitRequirements version, SHAs). The app ships `bin/` contents (engine
   DLLs + process children + requirements DLLs) beside the exe; target machines
   need the VC++ redistributable (bundle the installer or document it).
3. `WebKit.Interop`: SafeHandle wrappers for `WKContextRef`/`WKPageRef`/
   `WKFrameRef`/`WKStringRef`/client structs. Confirmed C API surface to build
   on: `WKPageRunJavaScriptInMainFrame` (native→JS), scheme flags
   (`WKContextRegisterURLSchemeAsSecure`, …), loader/navigation/policy clients.
   MiniBrowser sources are the reference embedding — mirror its
   context-creation and client-wiring order.
4. `WebKitHost`: a `FrameworkElement` that parents the WebKit child HWND and
   syncs position/size on layout, DPI changes, and window moves (the
   CEF-in-WinUI-3 pattern). Focus forwarding, context-menu placement, and IME
   are explicit acceptance items (Spike 2).
5. WebKit context setup: one `WKContext` with the user-data directory under
   `%APPDATA%`, `w://` registered per the next section. Context configuration
   is immutable once pages exist — all windows share the one context, like the
   single XPC service.

## `w://` custom scheme (rewritten — no `setURLSchemeHandler` on Windows)

The Cocoa `setURLSchemeHandler:forURLScheme:` API does not exist in the
cross-platform C API, so `w://` is served one level lower:

1. **Primary: navigation interception + LoadData.** The page-navigation client
   intercepts top-level `w://` navigations and serves response bytes from core
   (same source the macOS scheme handler reads) via the frame data-load path.
   Internal pages stay **single-document** (inline CSS/JS, no subresources) —
   a stated constraint on internal-page authors, matching today's
   self-contained homepage. `WKContextRegisterURLSchemeAsSecure` marks `w://`
   so internal pages keep secure-context privileges.
2. **Escape hatch: loopback-HTTP bridge.** If internal pages ever need
   subresources or two-way JS messaging beyond what the C API offers, serve
   core content over `http://127.0.0.1:<port>/` (loopback-only bind: no
   firewall prompt; localhost is a secure context) and redirect `w://`
   top-level navigations there. Documented fallback, not the default — no
   sockets until needed.

## Phase 3 — Chrome port (unchanged from windows.md; dependency order)

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

## Phase 4 — Parity + Linux prep (unchanged, plus engine-bump policy)

- Port the Swift suite's assertions as the acceptance spec (xUnit): ranking
  order, shield click semantics, width-demand, focus rules.
- Linux reuses everything except the shell: gintro GTK4 + `webkit6`,
  `importc` against `libbrowsercore.so`, content-blocker JSON consumed natively
  by `WebKitUserContentFilterStore`, `w://` via
  `webkit_web_context_register_uri_scheme`.
- **Engine-bump policy:** monthly pin re-verify plus CVE fast-track. Checklist
  per bump: MiniBrowser smoke on the new archive → full xUnit parity suite →
  re-vendor + `manifest.json` update in one commit. Never float.

## First step when building starts

Spikes in order, each a go/no-go before the phase it de-risks:

- **Spike 0 — archive inventory.** Download one green
  Windows-64-bit-Release-Build archive + matching WebKitRequirements.
  Inventory: engine DLLs? import libs? C headers (`WK*.h`)? PDBs? Run
  `dumpbin /exports WebKit.dll` for the `WK*` entry points the interop layer
  needs, and null-check `WKUserContentExtensionStoreCreate` — the content
  entry points compile out (return null/fail) when
  `ENABLE(CONTENT_EXTENSIONS)` is off, and `OptionsWin.cmake` doesn't list the
  flag. If headers/libs are missing from the archive, decide: generate
  bindings from in-tree headers at the pinned commit, or link purely by
  ordinal-free `GetProcAddress` (P/Invoke needs only the DLL at runtime).
- **Spike 1 — bridges.** Confirm the JS→native path (is a script-message-
  handler C API exported in the pinned build?) and the `w://` intercept +
  LoadData path in a throwaway Win32 harness hosting one `WKPageRef`.
  Fallback to the loopback bridge only on failure.
- **Spike 2 — `WebKitHost`.** Bare WinUI 3 window + child HWND: resize sync,
  focus in/out, DPI change, context-menu placement, IME. Then the windows.md
  smoke test: DLL builds, exports verified, C# console harness calling
  `bc_version` / `bc_history_fuzzy_search` — de-risks the whole plan before
  any XAML exists.

## Content blocker on WebKit (native — replaces the WebView2 section)

WebKit compiles the same JSON rule format macOS uses (`compileContentRuleList`
path via `ContentBlockerStore.swift` → `bc_filter_compile`). On Windows the
C API exposes it directly:

1. **Compile once at settings-change time.** Core emits the standard
   content-blocker JSON (`bc_filter_compile`, keyed by the FNV hash
   `bc_filter_meta` returns); the shell compiles it via
   `WKUserContentExtensionStoreCompile` and looks it up on launch via
   `WKUserContentExtensionStoreLookup`. The store persists compiled rules on
   disk, same as `WKContentRuleListStore` on macOS.
2. **Attach to every page.** The resulting `WKUserContentFilterRef` is added
   to each tab's `WKUserContentController` — network blocking, cosmetic
   `display:none` selectors, and HTTPS-upgrade actions all run inside the
   engine. No host-side per-request matching, no UI-thread interception
   handler, no Edge tracking-prevention mapping (ITP-equivalent behavior is
   engine-inherent; per-site exceptions ride the same rule set).
3. Procedural cosmetics (`:has`, `:xpath`) remain a documented gap — at parity
   with the macOS content blocker, not behind it.

Rejected (carried over): bundling uBlock Origin Lite. There is no WebView2
extensions API to abuse anymore, but the rationale stands — it would bring its
own lists, update channel, and storage, breaking the local-first deal (user
lists compiled by core, driven by native settings UI).
