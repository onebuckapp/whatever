# core — platform-agnostic Nim backend

Built with `clue` (never raw `nim c`) into a static library Swift links
directly. `make build` produces `build/libbrowsercore.a` plus nothing else;
`make test` runs the suite, `make check-abi` proves the hand-written header
matches the archive's exported symbols.

## Ownership split

| Component   | Responsibility                                                        |
|-------------|-----------------------------------------------------------------------|
| Swift       | Windows, native tabs, SwiftUI state, menus, toolbar, user interaction |
| `WKWebView` | Web content, cookies, cache, page navigation, JavaScript              |
| Nim         | History, bookmarks, settings, sessions, download metadata, filtering |
| macOS       | Window tabbing, keychain, file panels, permissions, app storage       |

`WKWebView` stays owned by its individual `BrowserWindowController`.
Nim never touches a web view, window, or Swift type directly.

## Layout

```text
core/
├── nim-core/
│   ├── browsercore.nimble   # requires "openparser >= 0.3.8"
│   ├── browsercore.nim      # bc_init, bc_version
│   ├── api/qr_api.nim       # C ABI for QR generation
│   └── tests/test_qr.nim    # encode/decode round trips + SVG checks
├── include/
│   └── browsercore.h        # the C ABI Swift compiles against
└── build/
    └── libbrowsercore.a     # gitignored build output
```

`qr_api` imports only the `openparser/qr/model2` and `openparser/qr/render`
leaf modules, so the AES-backed SQRC/AQR encoders (and nimcypher) stay out
of the archive. The current `.a` is ~200 KB.

## C ABI rules (from plans/nim.md)

- Only C-compatible types cross the boundary: `int32/int64`, `double`,
  `bool`, UTF-8 strings, byte buffers, opaque handles, C callbacks.
- Nim never hands allocated memory to Swift: every export writes into a
  caller-owned buffer, so there is no cross-boundary free to get wrong.
- JSON for larger results (session snapshots, history queries).
- Every C function documents: who allocates, who frees, sync/async,
  thread-safety, error cases.

## Swift-side seams (already in place)

- `macos/Sources/Core/BrowserCore.swift` — thin wrapper over the C ABI
  (`BrowserCore.qrSVG`, `BrowserCore.version`, error mapping).
- `macos/Sources/Storage/HistoryRecording.swift` — `HistoryRecording`
  protocol with an in-memory implementation. When the history API lands,
  add a `NimHistoryRecorder` conformance that calls
  `history_add(url, title, timestamp)` through `browsercore.h`.
