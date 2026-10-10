# Whatever Roadmap

Whatever is a local-first browser: your tabs, library, and settings live in
on-device databases, with no accounts and no sync servers. Everything below
keeps that deal. Items are roughly ordered — finishing what's started comes
before starting what's new.

## Finishing what's started

- [x] **History.** Searchable history works; still to come are full-text search,
  smart folders (e.g. "this week"), and bulk cleanup tools.
- [x] **Downloads.** The history popup, retry, and badge are in; missing are
  bandwidth limits, automatic file sorting by type, and resuming interrupted
  transfers where the server allows it.
- [x] **Feeds.** The reader, discovery, and crawl ticker are solid; planned are
  OPML import/export, per-feed retention, and article search.
- [x] **Bookmarks.** The bookmarks bar with folders, the editor, starring from
  the toolbar, drag reordering, and saving tabs by dragging them onto the bar
  are in.

## Browsing

- **Tab groups and workspaces.** Named groups with collapse, plus separate
  workspaces (e.g. work vs personal) with their own tab sets.
- **Profiles.** Independent cookie jars, history, and settings per profile,
  alongside the existing private tabs.
- **Vertical tabs.** An optional sidebar tab strip for narrow windows and
  many-tab workflows.
- **Reader mode.** A clean text view for articles, reusing the feed reader's
  extraction, with the window background and themes applied.
- **Translate.** On-device page translation where the OS provides it, with an
  offline fallback behind a toggle.
- **Memory saver UI.** Sleeping tabs already exist; add a visible panel
  showing what is asleep, how much was freed, and per-site exemptions.
- **Command palette.** The Spotlight address bar already matches fuzzily —
  extend it to browser commands ("mute this tab", "bookmark this page").
- **Per-site settings.** One panel per site: zoom, JavaScript, blocker, and
  sleep exemptions together, instead of scattered toggles.
- [x] **Print to PDF and screenshots.** Full-page capture and clean PDF export
  from the page menu.
- **Built-in torrent client.** Magnet links and .torrent files download
  in-app with progress, seeding controls, and selective file picking —
  peer-to-peer, no servers, in line with everything else.
- **Native media player.** A real macOS audio/video player for remote and
  local sources: playlists and queues, background playback, playback speed,
  picture-in-picture, and full subtitle support (external files, embedded
  tracks, styling, and sync adjustment) — everything a movie player needs,
  no web-page chrome around it.

## Privacy and safety

- [x] **Local password manager.** The encrypted on-device vault with generation
  is in; still to come is autofill. No cloud, in line with everything else.
- [x] **Private windows.** Window-scoped private browsing from the File and
  Dock menus is in; private tabs keep no history and leave nothing in the
  session document.
- **Fingerprinting resistance.** Optional canvas/font/user-agent hardening
  per site, next to the existing blocker exceptions.
- **Cookie management.** See and clear per-site storage without nuking all
  logins.
- **HTTPS-only mode.** Strict upgrades with a one-click bypass, building on
  the existing upgrade-known-hosts option.
- **Tracker report.** A per-site panel showing what the blocker stopped on
  the current page.
- **Proxy settings.** Manual HTTP/SOCKS configuration with bypass lists and
  PAC file support, plus per-profile proxies once profiles exist. Nothing
  leaves the machine except through the proxy the user chose.

## Customization and automation

- **User scripts.** Page-level scripts (à la userscripts) with per-site
  toggles, running through the existing content pipeline.
- **User styles.** Custom CSS per site, themed with the window background.
- **Keyboard-first navigation.** Vim-style bindings and full keyboard
  operation of tabs, panes, and the library.
- **Theme sharing.** Export and import window/tab themes as files.

## Automation and remote control

- **Programmatic control via WebSockets / UDS, Chrome-DevTools-style.**
  Drive a running Whatever instance from scripts and tools: list and select
  tabs, navigate, evaluate JavaScript, capture screenshots, observe
  downloads, and read the library (bookmarks, history, feeds). A Unix domain
  socket for local automation plus an opt-in WebSocket endpoint for remote
  use, speaking a small JSON protocol in the spirit of the DevTools Protocol
  rather than cloning it.
- **Security model.** Off by default; enabling requires an explicit flag,
  binds localhost only, and uses a per-launch token. No remote debugging
  without the user turning it on.
- **Headless mode.** Run without windows for scraping, testing, and CI,
  reusing the same protocol.

## Platform

The Nim core (`core/nim-core`: bookmarks, downloads, feeds, filters,
history, QR, session, settings, over SQLite) is platform-independent and
exposed through a C ABI, which `make check-abi` pins. A port reuses it as
is; only the web view and the shell are per-platform work, which is the
bulk of the effort in each case.

- **Linux.** WebKitGTK as the engine, reusing the Nim core unchanged. A
  GTK/Adwaita shell fits the local-first aesthetic; packaging as Flatpak
  plus distro natives.
- **Windows.** WebView2 (system Edge/Chromium) as the engine, reusing the
  Nim core unchanged. A WinUI shell; MSIX plus a portable build.
- **Mobile is explicitly out of scope.** The desktop interaction model —
  panes, splits, hover, context menus — does not transfer, and a phone port
  would be a different app wearing this one's name.

## Distribution and hygiene

- **Auto-update.** Sparkle on macOS; per-platform equivalents elsewhere,
  with release notes and a beta channel.
- **Homebrew cask** (and winget / Flatpak entries once those ports exist).
- **Onboarding.** First-run import, default-browser prompt, and a tour of
  the blocker, feeds, and sleeping tabs.
- **Crash and diagnostics.** Local crash logs with opt-in reporting —
  nothing phones home by default, ever.

## Non-goals

- Accounts, cloud sync, or any server-side component.
- A Chromium fork or an extension-store clone.
- Crypto wallets, VPN upsells, shopping assistants, or anything that treats
  the user as inventory.
