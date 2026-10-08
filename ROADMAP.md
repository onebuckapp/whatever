# Whatever Roadmap

Whatever is a local-first browser: your tabs, library, and settings live in
on-device databases, with no accounts and no sync servers. Everything below
keeps that deal. Items are roughly ordered — finishing what's started comes
before starting what's new.

## Finishing what's started

- **Bookmarks (in progress).** Basic saving and the settings pane exist, but
  the feature is not done: folders, editing and organizing, a bookmarks bar,
  and importing from Safari / Chrome / Firefox are all still missing.
- **History.** Searchable history works; still to come are full-text search,
  smart folders (e.g. "this week"), and bulk cleanup tools.
- **Downloads.** The history popup, retry, and badge are in; missing are
  bandwidth limits, automatic file sorting by type, and resuming interrupted
  transfers where the server allows it.
- **Feeds.** The reader, discovery, and crawl ticker are solid; planned are
  OPML import/export, per-feed retention, and article search.

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
- **Print to PDF and screenshots.** Full-page capture and clean PDF export
  from the page menu.

## Privacy and safety

- **Local password manager.** Encrypted on-device vault with generation and
  autofill. No cloud, in line with everything else.
- **Fingerprinting resistance.** Optional canvas/font/user-agent hardening
  per site, next to the existing blocker exceptions.
- **Cookie management.** See and clear per-site storage without nuking all
  logins.
- **HTTPS-only mode.** Strict upgrades with a one-click bypass, building on
  the existing upgrade-known-hosts option.
- **Tracker report.** A per-site panel showing what the blocker stopped on
  the current page.

## Customization and automation

- **User scripts.** Page-level scripts (à la userscripts) with per-site
  toggles, running through the existing content pipeline.
- **User styles.** Custom CSS per site, themed with the window background.
- **Keyboard-first navigation.** Vim-style bindings and full keyboard
  operation of tabs, panes, and the library.
- **Theme sharing.** Export and import window/tab themes as files.

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
