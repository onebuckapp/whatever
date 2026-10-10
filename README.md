<p align="center">
  <img src="https://github.com/onebuckapp/whatever/blob/main/.github/app_icon_128.png" width=“64px" height="64px"><br>
  This is Whatever – the perfect app for browsing the dead internet ☠️<br>
  Powered by WebKit &bullet; Written in Nim and Swift
</p>

<img src="https://github.com/onebuckapp/whatever/blob/main/.github/screenshots/2026-10-10-1-1506PM.png" width="1024"><br>

## 😍 Key Features

**Browsing**
- WebKit pages with draggable tabs, side-by-side split view, and session restore
- Private tabs, per-tab mute, and per-tab history with Back / Forward
- Sleeping tabs: untouched tabs release their memory, reload on return
- Per-state tab themes: solid, image, or looping video backgrounds
- Personal start page on `w://`, with backdrop and logo
- Address bar that stretches full width, with adjustable roundness and height
- Link menu that works: Open in New Tab, Open in New Window, no stray downloads
- Popup windows open as real tabs; `window.close` and JavaScript dialogs handled
- External schemes (`mailto:`, `tel:`...) hand off to the system
- Reload and reload-from-origin (`⌘R` / `⇧⌘R`), with stop while loading
- Find in Page (Highlight All / Match Case / Whole Words)
- Spotlight address bar with fuzzy autocomplete, search engines, and file paths
- Lock icon reflects the connection: secured `https`, broken lock for plain `http`

**Privacy**
- Built-in Ad blocker with >13k rules and Zero JavaScript
- Per-site exceptions with a card, and a toolbar shield showing the live state
- Local-first storage: everything lives in on-device databases, no account

**Files & Downloads**
- Native directory browser popup instead of WebKit's listing
- Real downloads with a history popup: progress, retry, Reveal in Finder
- Unseen-download badge on the toolbar button, deleted files marked as such
- Per-site blocker exceptions, managed from the card or Settings

**Feeds**
- Built-in RSS / Atom reader: subscriptions, discovery, unread & saved
- Favicons, thumbnails, retention limits, offline reading
- Headline crawl bar: scrolling ticker with speed, direction, font size, separator, and favicons!

**Extras**
- Share any page as a QR Code
- Beautiful film-grain overlay over the entire Web
- Custom Window Background supporting:
  - Solid colors
  - Linear/Radial gradients
  - Image or Video
- Beautiful Settings modal (General, Appearance, Web, Blocker, Bookmarks, Feeds, History, Search, Downloads)
- Bookmarks (in progress) and searchable History
- Written in Nim language and Swift
- Open Source | `GPLv3` License

### About
**Whatever is the browser for the dead internet** Popular browsers sell your data: feeds full of ads, trackers on every click, your tabs and history synced to somebody's cloud. Whatever goes the other way. Pages render on WebKit behind a blocker that compiles 13,000+ rules on your own machine. Your tabs come back where you left them. Your bookmarks, feeds, history, and downloads live in on-device databases — no accounts, no sync servers, ever.

It also happens to be beautiful and weird: a start page and window you theme yourself, a headline crawl for your RSS, film grain over the whole web if you want it, and a Spotlight-grade address bar that keeps up with you.

### 🗺 Roadmap
Where this goes next — tab groups and workspaces, profiles, a reader mode, user scripts, importing from other browsers, and native Linux and Windows editions that reuse the portable Nim core. See [ROADMAP.md](ROADMAP.md) for the full list.

### 🛠 Build
- `make macos` — build the app (includes the Nim core)
- `make core` — build only the Nim core
- `make test` — run the core test suite (macOS UI tests live in the `WhateverTests` scheme)
- `make check-abi` — verify the core's C ABI still matches its header

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/onebuckapp/whatever/issues)
- 👋 Wanna help? [Fork it!](https://github.com/onebuckapp/whatever/fork)

### 🎩 License
GPLv3 license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
