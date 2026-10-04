# Adblocker plan (hosts MVP, bundled snapshot, block + hide)

Date: 2026-10-04. Decisions: hosts-only sources first (AdAway-derived + custom user rules; EasyList converter later), bundled snapshot only (no network fetching), per-site exceptions via new Settings tab "Content Blocker" plus toolbar adblock button with per-site popup, scope is network block plus element hiding (`##` cosmetic rules in user rules).

## 1. Architecture split

| Layer | Owns | Rationale |
|---|---|---|
| Nim core (`api/filter_api.nim`) | Parse, normalize, dedupe, emit WebKit JSON + meta (ruleCount, sha256 of input, source version) | Pure string processing, stateless like QR, tested by `make test` |
| Swift app | Read bundled snapshot, XPC to core, chunk JSON at 40k rules per list (WebKit limit is 50k), compile via `WKContentRuleListStore.default()`, attach in `WebViewFactory`, cache compiled lists across launches | Compilation and attachment are WebKit APIs that must run in the app process; a `WKContentRuleList` cannot cross the XPC boundary, only its JSON source can |
| Settings doc | `AdBlockSettings` group: `enabled`, `exceptions: Set<String>`, `userRules: String`, `lastCompiledHash`, `snapshotVersion` | Existing `decodeIfPresent` pattern keeps old documents loading |

Data flow at launch: `WhateverApp` Task (after `SettingsStore.load`, before `restore/newTab`) reads `Resources/Blocklists/*.txt` plus `settings.adblock.userRules`, calls `BrowserCore.compiledFilters` (XPC to `bc_filter_compile`), and only when `meta.sha256 != settings.adblock.lastCompiledHash` chunks and recompiles (`blocker.0`, `blocker.1`, ...), otherwise reuses via `lookUpContentRuleList`. `ContentBlockerStore.shared.lists` is then read by every `WebViewFactory.makeWebView`.

## 2. Nim core work

New file `core/nim-core/api/filter_api.nim`, following `history_api.nim` idioms (`cstring` in, `catchingStore`, `emitJson` out):

- `bc_filter_compile(lists, version, buffer, capacity, needed)`: input is one text blob (snapshot + user rules concatenated Swift-side). Line grammar:
  - hosts: `0.0.0.0 host`, `127.0.0.1 host`, bare `host`; strip `#` comments (full-line and inline), blank lines, lowercase, skip `localhost*`, broadcast, IPs, malformed entries, dedupe.
  - user-rule extras: `||domain^` network rule, `@@||domain^` exception, `##selector` cosmetic rule. Anything else is ignored and counted in meta as `skippedLines`.
- Output JSON array: hosts/`||` entries become block rules with the `(^|:)//([^/]*\.)?host([/:]|$)` anchoring (never naive substring), `resource-type` set, `load-type: ["third-party"]`. `##selector` becomes `css-display-none` rules with `url-filter: .*`. `@@` entries become `ignore-previous-rules` with `if-domain`, appended after block rules.
- `bc_filter_meta(...)`: `ruleCount`, `blockCount`, `cosmeticCount`, `exceptionCount`, `skippedLines`, input hash hex, `sourceVersion`.
- Wiring: add to `core/Makefile` `NIM_SOURCES`, import/export in `browsercore.nim`, section in `core/include/browsercore.h`, new `tests/test_filter.nim` (comment styles, `0.0.0.0` vs bare, uppercase, dupes, localhost skip, inline comments, `||`/`@@`/`##`, invalid chars, anchor correctness so `not-ads.example.com.evil.test` never matches). Verify `make test` and `make check-abi` (append-only `bc_*`, no ordinal changes).

## 3. Swift plumbing (XPC + compile + attach)

1. `Shared/WhateverStoreProtocol.swift`: `filterCompile(_:_:reply:)` + `filterMeta` returning `Data`.
2. `Store/StoreService.swift`: handlers via existing `CoreBuffer.read` two-phase driver on `coreQueue`.
3. `Sources/Storage/StoreClient.swift` + `Sources/Core/BrowserCore.swift`: `compiledFilters(text:version:)` facade.
4. New `Sources/Privacy/ContentBlockerStore.swift` (`@MainActor` singleton): owns `[WKContentRuleList]`, `compileIfNeeded()` (hash compare, chunk, compile or lookup), `setEnabled(_:)` fan-out (iterate open tabs, add/remove lists, reload since rule lists apply at navigation start).
5. `WebViewFactory.swift:27-28`: after `settings.web.apply`, attach lists when enabled. Skip `QRCodePopup.swift:72-79`.
6. Launch hook in `WhateverApp.swift:85-96` Task before first tab; live-toggle hook via existing `onChange` plus `BrowserCoordinator.applyLiveContentBlocker()` modeled on `applyLiveWebSettings`.
7. `project.yml`: add `Resources/Blocklists/adaway-hosts.txt` (+ version file) to resources build phase.

## 4. UI

Settings tab "Content Blocker": new `SettingsSection` case `contentBlocker` with pane in `SettingsDetailViews.swift` (global toggle via `store.binding`, stats rows for source/version/counts/hash, user-rules editor, exception host list editor, AdAway CC BY 3.0 attribution row). `SettingsStore.swift` gains an `AdBlockSettings` group with `decodeIfPresent` fallback.

Toolbar button plus per-site popup: adblock button in `BrowserToolbarController`/`BrowserToolbarView` next to the bookmark button (same 24pt styling); opens a small Mijick `CenterPopup` over the page (same pattern as `QRCodePopup` with a per-pane presenter): current host via `SiteIdentity.normalizedHost`, per-site toggle writing `settings.adblock.exceptions`, "Manage in Settings" button opening the Content Blocker tab.

Per-site enforcement is removal-at-navigation, not JSON regen: in `BrowserTab.load` / `NavigationController.decidePolicyFor navigationAction`, if the host is excepted (with subdomain match) remove lists from that webview's controller (re-add and reload when lifted). No recompile on exception change, immediate effect, covers network plus cosmetic uniformly.

## 5. Attribution and legal

AdAway-derived list is CC BY 3.0: keep `Resources/Blocklists/NOTICE` (source repo URL, retrieval date, license pointer), surface source plus license in the Content Blocker tab, never present converted rules as original data.

## 6. Test matrix (manual, no app-target harness exists)

Launch attach on first tab, global toggle off/on with reload, excepted host fully unblocked, toolbar popup round-trip with Settings list, user-rules edit covering `||`, `@@`, `##`, invalid-line diagnostics via `skippedLines`, QR popup unaffected, private tabs blocked same as regular, snapshot version displayed matches bundled file.

## 7. Non-goals

Auto-update/downloads, full EasyList syntax (scriptlets, `:has`, redirects), blocked-count badges (rule lists do not report hits), DNS/firewall coverage, same-origin ad detection.

## 8. Milestones

- M1: `filter_api.nim` plus C header plus `test_filter.nim`; green `make test` plus `make check-abi`.
- M2: XPC plumbing plus `ContentBlockerStore` plus factory attach plus launch compile plus chunking; manual launch/toggle test.
- M3: exceptions engine (navigation hook) plus Content Blocker settings tab plus toolbar button plus per-site popup.
- M4: attribution/NOTICE, bundled snapshot final, full manual matrix, commit.
