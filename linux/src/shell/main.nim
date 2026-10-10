# Whatever Linux MVP shell — imperative GTK4 + Adwaita + WebKitGTK 6.0.
# Ports (MVP subset):
#   BrowserWindowController.swift:510 (window) +
#   BrowserTabController.swift (newTab/closeTab/switch) +
#   BrowserTabState.swift (tab_model) +
#   AddressParser.swift (address) +
#   HomepageSchemeHandler.swift:30 (scheme_w + wSchemeHandler) +
#   NavigationController.swift:38 (decide-policy) +
#   WebViewFactory.swift (newTabView) +
#   HistoryRecording.swift (onLoadFinished) +
#   SessionStore.swift (saveSession/restoreSession via helper IPC)
import std/json
import std/os
import bindings/gtk4_min
import bindings/adw_min
import bindings/webkit6_min
import shell/tab_model
import shell/address
import shell/scheme_w
import shell/chrome
import shell/icons
import shell/modal
import shell/popovers
import shell/settings_modal
import shell/store_client

{.push importc, cdecl.}
proc g_bytes_new_take*(data: pointer, len: csize_t): pointer {.
    importc: "g_bytes_new_take".}
proc g_memory_input_stream_new_from_bytes*(b: pointer): pointer {.
    importc: "g_memory_input_stream_new_from_bytes".}
{.pop.}

type
  AppCtx = object
    app: pointer
    window: pointer
    notebook: pointer
    entry: pointer
    backBtn: pointer
    fwdBtn: pointer
    reloadBtn: pointer
    shieldBtn: pointer

  LiveTab = object
    state: TabState
    view: pointer # WebKitWebView (navigation, history, entry all use this)
    frame: pointer # GtkOverlay page child (what the notebook tracks)
    tabLabel: pointer # GtkLabel inside the notebook tab header

var ctx: AppCtx
var tabs: seq[LiveTab] = @[]
var activeView: pointer = nil
let debugLog = getEnv("WHATEVER_DEBUG", "") != ""

proc dbg(msg: string) =
  if debugLog:
    try: stderr.writeLine("[whatever] " & msg)
    except: discard

proc newTab(url: string = "w://about")
proc syncChromeFor(view: pointer)

const MaxRestoreTabs = 25

proc navigate(view: pointer, input: string) =
  let t = toTarget(input)
  webkit_web_view_load_uri(view, t.url.cstring)

proc tabIndexOf(v: pointer): int =
  ## Accepts either the webview or its overlay frame.
  for i, t in tabs:
    if t.view == v or t.frame == v: return i
  -1

proc resolveView(v: pointer): pointer =
  ## Overlay frames never drive navigation — map back to the webview.
  let ti = tabIndexOf(v)
  if ti >= 0: tabs[ti].view else: v

proc pageIndexOf(view: pointer): cint =
  let ti = tabIndexOf(view)
  if ti < 0: return -1
  let frame = tabs[ti].frame
  let n = gtk_notebook_get_n_pages(ctx.notebook)
  for i in 0 ..< n:
    if gtk_notebook_get_nth_page(ctx.notebook, i) == frame:
      return i
  -1

proc syncActiveTo(view: pointer) =
  # Single source of truth for tab<->view linkage. Callers always pass
  # the exact view — never query the notebook, because during
  # `switch-page` emission `get_current_page` still returns the OLD page
  # (classic GTK gotcha that unlinked tabs from webviews).
  let ti = tabIndexOf(view)
  if ti < 0:
    # Transient emission (e.g. first-page auto-select during append,
    # before the tab entry exists) — never let an untracked widget
    # become the active view.
    dbg("ignoring switch to untracked view")
    return
  activeView = resolveView(view)
  if ctx.entry != nil and tabs[ti].state.url.len > 0:
    gtk_editable_set_text(ctx.entry, tabs[ti].state.url.cstring)
  syncChromeFor(activeView)
  dbg("active tab now " & tabs[ti].state.url)

proc saveSession() =
  var arr = newJArray()
  for t in tabs:
    if t.state.url.len > 0 and t.state.url != "w://about":
      arr.add(%*{"url": t.state.url, "title": t.state.title})
  discard callHelper("session.save", %*{"document": {"tabs": arr}})

# w:// scheme: serve bundled homepage + assets (HomepageSchemeHandler port).
proc wFail(req: pointer, msg: cstring) =
  let err = g_error_new_literal(0, 0, msg)
  webkit_uri_scheme_request_finish_error(req, err)

proc wServe(req: pointer, data: string, mime: cstring) =
  if data.len == 0:
    wFail(req, "homepage asset is empty")
    return
  # WebKit reads the stream asynchronously, so hand it heap bytes owned
  # by a GBytes (freed with the stream — never a Nim-managed copy that
  # ARC could reclaim under us, which matters for the JPEG's NULs too).
  let heap = alloc(data.len)
  copyMem(heap, data[0].unsafeAddr, data.len)
  let bytes = g_bytes_new_take(heap, data.len.csize_t)
  let stream = g_memory_input_stream_new_from_bytes(bytes)
  webkit_uri_scheme_request_finish(req, stream, data.len.clonglong, mime)

proc wSchemeHandler(req: pointer, userData: pointer) {.cdecl.} =
  let uri = $webkit_uri_scheme_request_get_uri(req)
  try:
    case wRoute(uri)
    of wrAbout:
      wServe(req, wAboutBytes(), "text/html")
    of wrBackground:
      wServe(req, wBackgroundBytes(), "image/jpeg")
    of wrLogo:
      wServe(req, wLogoBytes(), "image/svg+xml")
    of wrUnknown:
      wFail(req, "unsupported w:// address")
  except IOError:
    wFail(req, "homepage asset missing")

proc onBackClicked(btn: pointer, userData: pointer) {.cdecl.} =
  if activeView != nil and webkit_web_view_can_go_back(activeView) != 0:
    webkit_web_view_go_back(activeView)

proc onFwdClicked(btn: pointer, userData: pointer) {.cdecl.} =
  if activeView != nil and webkit_web_view_can_go_forward(activeView) != 0:
    webkit_web_view_go_forward(activeView)

proc currentTabUrl(): string =
  let ti = tabIndexOf(activeView)
  if ti >= 0: tabs[ti].state.url else: ""

proc syncShieldIcon() =
  ## ShieldCheck while blocking, ShieldX where paused (per-site exception).
  if ctx.shieldBtn == nil or activeView == nil: return
  let uri = $webkit_web_view_get_uri(activeView)
  let host = hostOfUrl(if uri.len > 0: uri else: currentTabUrl())
  var paused = false
  if host.len > 0:
    let doc = callHelper("settings.get")
    if doc != nil and doc.kind == JObject and doc.hasKey("adblock") and
        doc["adblock"].kind == JObject and
        doc["adblock"].hasKey("exceptions") and
        doc["adblock"]["exceptions"].kind == JArray:
      for e in doc["adblock"]["exceptions"]:
        if e.getStr("") == host:
          paused = true
          break
  setButtonIcon(ctx.shieldBtn, if paused: "ShieldX" else: "ShieldCheck")

proc syncChromeFor(view: pointer) =
  ## Back/forward sensitivity + reload/stop glyph follow the live view
  ## (port of BrowserToolbarController syncControls).
  if view == nil or ctx.backBtn == nil: return
  gtk_widget_set_sensitive(ctx.backBtn,
    webkit_web_view_can_go_back(view))
  gtk_widget_set_sensitive(ctx.fwdBtn,
    webkit_web_view_can_go_forward(view))
  if ctx.reloadBtn != nil:
    setButtonIcon(ctx.reloadBtn,
      if webkit_web_view_is_loading(view) != 0: "Stop" else: "TablerReload")
  syncShieldIcon()

proc onReloadClicked(btn: pointer, userData: pointer) {.cdecl.} =
  # Reload while idle, stop while loading (Swift xmark/stop state).
  if activeView == nil: return
  if webkit_web_view_is_loading(activeView) != 0:
    webkit_web_view_stop_loading(activeView)
  else:
    webkit_web_view_reload(activeView)

proc onShieldClicked(btn: pointer, userData: pointer) {.cdecl.} =
  var url = currentTabUrl()
  if activeView != nil:
    let live = webkit_web_view_get_uri(activeView)
    if live != nil and ($live).len > 0:
      url = $live
  showShieldFor(btn, url)

proc onPasswordsClicked(btn: pointer, userData: pointer) {.cdecl.} =
  showPasswords(btn)

proc onBookmarksClicked(btn: pointer, userData: pointer) {.cdecl.} =
  showBookmarks(btn)

proc onDownloadsClicked(btn: pointer, userData: pointer) {.cdecl.} =
  showDownloads(btn)

proc onSettingsClicked(btn: pointer, userData: pointer) {.cdecl.} =
  showSettingsModal()

proc onEntryActivate(entry: pointer, userData: pointer) {.cdecl.} =
  if activeView == nil: return
  let text = $gtk_editable_get_text(entry)
  dbg("entry activate: " & text)
  navigate(activeView, text)

proc onKeyPressed(ctl: pointer, keyval: cuint, keycode: cuint,
    state: cuint, userData: pointer): cint {.cdecl.} =
  # Escape dismisses any open modal first.
  if keyval == GDK_KEY_ESCAPE and modalOpen():
    closeModal()
    return 1
  # Ctrl+L focuses the address bar, Ctrl+T opens a tab (like macOS ⌘L/⌘T).
  if (state and GDK_CONTROL_MASK) != 0:
    if keyval == GDK_KEY_LLOWER or keyval == GDK_KEY_LUPPER:
      if ctx.entry != nil:
        discard gtk_widget_grab_focus(ctx.entry)
      return 1
    if keyval == GDK_KEY_TLOWER:
      newTab()
      return 1
  return 0

proc onLoadChanged(view: pointer, ev: cint,
    userData: pointer) {.cdecl.} =
  if ev == WEBKIT_LOAD_STARTED.ord:
    if view == activeView:
      syncChromeFor(view)
    return
  if ev == WEBKIT_LOAD_FINISHED.ord:
    let uri = $webkit_web_view_get_uri(view)
    let titleC = webkit_web_view_get_title(view)
    let title =
      if titleC == nil or ($titleC).len == 0: uri
      else: $titleC
    let ti = tabIndexOf(view)
    if ti >= 0:
      tabs[ti].state = tabs[ti].state.withUrl(uri).withTitle(title)
    if view == activeView and ctx.entry != nil and uri.len > 0:
      gtk_editable_set_text(ctx.entry, uri.cstring)
    if view == activeView:
      syncChromeFor(view)
    if helperShouldRecord(uri):
      helperRecordVisit(uri, title)
    saveSession()

proc onTitleChanged(view: pointer, pspec: pointer,
    userData: pointer) {.cdecl.} =
  let t = webkit_web_view_get_title(view)
  if t == nil: return
  let title = $t
  let ti = tabIndexOf(view)
  if ti >= 0:
    tabs[ti].state = tabs[ti].state.withTitle(title)
    if tabs[ti].tabLabel != nil:
      gtk_label_set_text(tabs[ti].tabLabel, title.cstring)
  if view == activeView and ctx.window != nil:
    gtk_window_set_title(ctx.window, t)

proc onDecidePolicy(view: pointer, decision: pointer, dtype: cint,
    userData: pointer): cint {.cdecl.} =
  # MVP policy (NavigationPolicy.swift subset): allow in-engine types,
  # new-window opens in place (a new tab in the next increment).
  webkit_policy_decision_use(decision)
  return 1

proc onSwitchPage(nb: pointer, page: pointer, idx: cuint,
    userData: pointer) {.cdecl.} =
  # Signature mirrors GtkNotebook::switch-page (void return, params
  # notebook/page/page_num per Gtk-4.0.gir). `page` is the page being
  # switched TO — use it directly: querying `get_current_page` here
  # returns the page being switched FROM.
  syncActiveTo(page)

proc wireView(view: pointer) =
  discard gSignalConnect(view, "load-changed".cstring,
    cast[pointer](onLoadChanged))
  discard gSignalConnect(view, "notify::title".cstring,
    cast[pointer](onTitleChanged))
  discard gSignalConnect(view, "decide-policy".cstring,
    cast[pointer](onDecidePolicy))

proc onCloseClicked(btn: pointer, view: pointer) {.cdecl.} =
  let idx = pageIndexOf(view)
  if idx < 0: return
  let ti = tabIndexOf(view)
  gtk_notebook_remove_page(ctx.notebook, idx)
  if ti >= 0:
    tabs.delete(ti)
  if tabs.len == 0:
    # Last tab closed → fresh start page (never a tab-less window).
    newTab()
  else:
    # Deterministic: select the neighbour explicitly instead of querying
    # notebook state. set_current_page re-emits switch-page, which syncs
    # via onSwitchPage (no-op if GTK already selected this page).
    let n = gtk_notebook_get_n_pages(ctx.notebook)
    let cur = min(idx, n - 1)
    gtk_notebook_set_current_page(ctx.notebook, cur)
    syncActiveTo(gtk_notebook_get_nth_page(ctx.notebook, cur))
  saveSession()

proc cornerMask(cls: cstring, halign: cint): pointer =
  let c = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  gtk_widget_add_css_class(cast[pointer](c), "webview-corner")
  gtk_widget_add_css_class(cast[pointer](c), cls)
  gtk_widget_set_size_request(cast[pointer](c), 12, 12)
  gtk_widget_set_halign(cast[pointer](c), halign)
  gtk_widget_set_valign(cast[pointer](c), 2) # GTK_ALIGN_END
  gtk_widget_set_can_target(cast[pointer](c), 0)
  cast[pointer](c)

proc newTab(url = "w://about") =
  let view = webkit_web_view_new()
  wireView(view)
  # Overlay frame: webview + bottom corner masks (true rounded mask —
  # CSS alone cannot clip composited web content).
  let frame = cast[pointer](gtk_overlay_new())
  gtk_overlay_set_child(frame, view)
  let bl = cornerMask("webview-corner-bl", GTK_ALIGN_START)
  let br = cornerMask("webview-corner-br", GTK_ALIGN_END)
  gtk_overlay_add_overlay(frame, bl)
  gtk_overlay_add_overlay(frame, br)
  gtk_overlay_set_clip_overlay(frame, bl, 1)
  gtk_overlay_set_clip_overlay(frame, br, 1)
  let header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)
  let label = gtk_label_new("New Tab")
  let closeBtn = iconButton("TablerCircleX", "Close Tab", px = 16)
  gtk_widget_add_css_class(cast[pointer](closeBtn), "tab-close")
  gtk_box_append(cast[pointer](header), cast[pointer](label))
  gtk_box_append(cast[pointer](header), cast[pointer](closeBtn))
  discard gtk_notebook_append_page(ctx.notebook, frame,
    cast[pointer](header))
  tabs.add(LiveTab(state: newTabState(url), view: view, frame: frame,
    tabLabel: cast[pointer](label)))
  # Close button carries the view as signal data (BrowserTabController
  # closeTab port).
  discard g_signal_connect_data(cast[pointer](closeBtn), "clicked",
    cast[pointer](onCloseClicked), view, nil, G_CONNECT_AFTER)
  let n = gtk_notebook_get_n_pages(ctx.notebook)
  gtk_notebook_set_current_page(ctx.notebook, n - 1)
  # set_current_page fires switch-page synchronously (syncs to the old
  # page's replacement first); re-sync to the new view explicitly so the
  # address bar never shows the previous tab's URL.
  syncActiveTo(view)
  webkit_web_view_load_uri(view, url.cstring)
  saveSession()

proc onNewTabClicked(btn: pointer, userData: pointer) {.cdecl.} =
  newTab()

proc onActivate(appPtr: pointer, userData: pointer) {.cdecl.} =
  adw_init()
  applyCompactChrome()
  ctx.app = appPtr
  let win = adw_application_window_new(appPtr)
  applyCornerMasks(win)
  ctx.window = win
  gtk_window_set_title(win, "Whatever")
  gtk_window_set_default_size(win, 1100, 750)

  let root = cast[pointer](gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))

  # AdwHeaderBar with LOOSE centering: the title widget (entry)
  # fills the available width instead of staying strictly centered.
  let bar = adw_header_bar_new()
  adw_header_bar_set_centering_policy(cast[pointer](bar),
    ADW_CENTERING_POLICY_LOOSE)

  # Leading: back / forward / reload (Swift leading strip).
  ctx.backBtn = iconButton("TablerChevronLeft", "Back")
  ctx.fwdBtn = iconButton("TablerChevronRight", "Forward")
  ctx.reloadBtn = iconButton("TablerReload", "Reload")
  let leading = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  gtk_box_append(cast[pointer](leading), ctx.backBtn)
  gtk_box_append(cast[pointer](leading), ctx.fwdBtn)
  gtk_box_append(cast[pointer](leading), ctx.reloadBtn)

  # Trailing: shield / passwords / bookmarks / downloads / settings
  # (Swift trailing strip). New-tab lives on the tab strip now.
  ctx.shieldBtn = iconButton("ShieldCheck", "Content Blocker")
  let passBtn = iconButton("TablerAsterisk", "Password Manager")
  let bmBtn = iconButton("TablerBookmark", "Bookmarks")
  let dlBtn = iconButton("TablerDownloads", "Downloads")
  let setBtn = iconButton("TablerSettings", "Settings")
  let trailing = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2)
  for b in [ctx.shieldBtn, passBtn, bmBtn, dlBtn, setBtn]:
    gtk_box_append(cast[pointer](trailing), b)

  ctx.entry = cast[pointer](gtk_entry_new())
  gtk_entry_set_placeholder_text(ctx.entry, "Search or enter address")
  gtk_widget_set_hexpand(ctx.entry, 1)

  adw_header_bar_pack_start(bar, cast[pointer](leading))
  adw_header_bar_pack_end(bar, cast[pointer](trailing))
  adw_header_bar_set_title_widget(bar, ctx.entry)

  gtk_box_append(root, cast[pointer](bar))

  ctx.notebook = cast[pointer](gtk_notebook_new())
  gtk_widget_add_css_class(ctx.notebook, "tabstrip")
  gtk_widget_set_hexpand(ctx.notebook, 1)
  gtk_widget_set_vexpand(ctx.notebook, 1)
  # Scrollable tab strip (like the Swift strip): overflow tabs scroll
  # under wheel/touch gestures instead of stretching the window. No
  # scrollbar widget — only step arrows while overflowing.
  gtk_notebook_set_scrollable(ctx.notebook, 1)
  # New-tab button pinned after the last tab (Chrome-style).
  let newTabBtn = iconButton("Plus", "New Tab")
  gtk_notebook_set_action_widget(ctx.notebook, cast[pointer](newTabBtn),
    GTK_PACK_END)

  gtk_box_append(root, ctx.notebook)
  # Window-level overlay: main content + modal layer on top.
  let winOverlay = cast[pointer](gtk_overlay_new())
  gtk_overlay_set_child(winOverlay, root)
  adw_application_window_set_content(win, winOverlay)
  initModalLayer(winOverlay)

  # Ctrl+L / Ctrl+T accelerators (macOS ⌘L/⌘T equivalents).
  let keyCtl = gtk_event_controller_key_new()
  gtk_widget_add_controller(root, keyCtl)
  discard gSignalConnect(keyCtl, "key-pressed".cstring,
    cast[pointer](onKeyPressed))

  let webctx = webkit_web_context_get_default()
  webkit_web_context_register_uri_scheme(webctx, "w",
    wSchemeHandler, nil, nil)

  discard gSignalConnect(ctx.backBtn, "clicked".cstring,
    cast[pointer](onBackClicked))
  discard gSignalConnect(ctx.fwdBtn, "clicked".cstring,
    cast[pointer](onFwdClicked))
  discard gSignalConnect(ctx.reloadBtn, "clicked".cstring,
    cast[pointer](onReloadClicked))
  discard gSignalConnect(ctx.shieldBtn, "clicked".cstring,
    cast[pointer](onShieldClicked))
  discard gSignalConnect(passBtn, "clicked".cstring,
    cast[pointer](onPasswordsClicked))
  discard gSignalConnect(bmBtn, "clicked".cstring,
    cast[pointer](onBookmarksClicked))
  discard gSignalConnect(dlBtn, "clicked".cstring,
    cast[pointer](onDownloadsClicked))
  discard gSignalConnect(setBtn, "clicked".cstring,
    cast[pointer](onSettingsClicked))
  discard gSignalConnect(newTabBtn, "clicked".cstring,
    cast[pointer](onNewTabClicked))
  discard gSignalConnect(ctx.entry, "activate".cstring,
    cast[pointer](onEntryActivate))
  discard gSignalConnect(ctx.notebook, "switch-page".cstring,
    cast[pointer](onSwitchPage))

  # Session restore (SessionStore port): reopen last tabs, else start page.
  var restored = 0
  let sess = callHelper("session.load")
  if sess != nil and sess.kind == JObject and sess.hasKey("tabs") and
      sess["tabs"].kind == JArray:
    for item in sess["tabs"]:
      if restored >= MaxRestoreTabs: break
      let u =
        if item.hasKey("url"): item["url"].getStr("")
        else: ""
      if u.len == 0 or u == "w://about": continue
      newTab(u)
      inc restored
  if restored == 0:
    newTab()

  gtk_window_present(win)

proc main() =
  # NOTE: the shell never inits/links the core (single Nim runtime per
  # process; the helper owns the stores). History goes over UDS.
  # WHATEVER_APP_ID overrides the bus id for headless test launches so
  # they never merge into a live instance.
  let appId = getEnv("WHATEVER_APP_ID", "app.onebuck.whatever")
  let app = cast[pointer](
    gtk_application_new(appId.cstring, G_APPLICATION_FLAGS_NONE))
  discard gSignalConnect(app, "activate".cstring,
    cast[pointer](onActivate))
  discard g_application_run(app, 0, nil)

when isMainModule:
  main()
