# Whatever — Linux (GTK4 + Adwaita + WebKitGTK 6.0)

Imperative Nim shell reusing the portable core (`core/nim-core` via
`core/include/browsercore.h`). Mirrors the macOS Swift shell:

- `macos/Sources/Browser/BrowserTabState.swift` → `src/shell/tab_model.nim`
- `macos/Sources/Navigation/AddressParser.swift` → `src/shell/address.nim`
- `macos/Sources/Navigation/HomepageSchemeHandler.swift` → `src/shell/scheme_w.nim`
- `macos/Sources/Storage/ContentBlockerStore.swift` → `src/shell/blocker.nim`
- `macos/Store/StoreService.swift` + `Shared/WhateverStoreProtocol.swift`
  → `src/helper/store_service.nim` + `src/helper/protocol.nim` (UDS JSON)

## Deps

```
sudo apt install libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev
```

No gintro / owlkettle codegen: `src/bindings/*_min.nim` are minimal
handwritten `importc` bindings (`pkg-config --cflags/--libs`), in the same
style as `owlkettle/bindings/gtk.nim` (`distinct pointer` + `g_signal_connect_data`).

Why not gintro: `gintro@1.0.0`'s `before install` hook needs `tests/gen.nim`,
which is excluded by its own `skipDirs`, so `nimble install gintro` fails
before any `gtk4.nim` is generated. Minimal bindings avoid that fragility
for the MVP; gintro can be revisited once upstream fixes packaging.

## Build

```
make linux        # from repo root (builds core first)
make -C linux build
make -C linux run # runs ./build/whatever
make -C linux helper # builds ./build/whatever-store
```

`WHATEVER_STORE_ROOT` overrides the store path (default XDG:
`~/.local/share/whatever`; macOS default stays
`~/Library/Application Support/Whatever`).
