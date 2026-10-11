# Toolbar popovers — ports of the Swift card presenters (MVP slice).
# Downloads + bookmarks show real helper data; shield reads/writes the
# real settings document (same {"adblock":{"exceptions":[...]}} schema as
# macos/Sources/Storage/SettingsStore.swift); passwords shows real vault
# status; settings shows real version/store path. Full cards come later.
import std/json
import std/os
import std/sequtils
import std/strutils
import bindings/gtk4_min
import shell/store_client

const PopoverWidth = 320

proc hostOfUrl*(url: string): string =
  var s = url
  let scheme = s.find("://")
  if scheme >= 0: s = s[scheme + 3 .. ^1]
  for sep in ['/', '?', '#', ':']:
    let i = s.find(sep)
    if i >= 0:
      s = s[0 ..< i]
      break
  s.strip.toLowerAscii

proc baseBox(): pointer =
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
  gtk_widget_set_size_request(cast[pointer](box), PopoverWidth.cint, -1)
  cast[pointer](box)

proc titleLabel(text: string): pointer =
  let l = gtk_label_new(text.cstring)
  cast[pointer](l)

proc bodyLabel(text: string): pointer =
  let l = gtk_label_new(text.cstring)
  gtk_label_set_wrap(cast[pointer](l), 1)
  gtk_label_set_max_width_chars(cast[pointer](l), 38)
  cast[pointer](l)

proc popup(btn, content: pointer) =
  let pop = gtk_popover_new()
  gtk_widget_set_parent(pop, btn)
  gtk_popover_set_child(pop, content)
  gtk_popover_popup(pop)

proc listBox(title: string, rows: seq[string]): pointer =
  let box = baseBox()
  gtk_box_append(box, titleLabel(title))
  if rows.len == 0:
    gtk_box_append(box, bodyLabel("Nothing here yet."))
  else:
    let sw = gtk_scrolled_window_new()
    gtk_scrolled_window_set_min_content_height(
      cast[pointer](sw), 200.cint)
    let inner = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)
    for r in rows:
      gtk_box_append(cast[pointer](inner), bodyLabel(r))
    gtk_scrolled_window_set_child(cast[pointer](sw),
      cast[pointer](inner))
    gtk_box_append(box, cast[pointer](sw))
  box

proc showDownloads*(btn: pointer) =
  var rows: seq[string] = @[]
  let p = callHelper("download.list")
  if p != nil and p.kind == JArray:
    for item in p:
      let name =
        if item.hasKey("filename"): item["filename"].getStr("?")
        else: "?"
      let state =
        if item.hasKey("state"): item["state"].getStr("")
        else: ""
      rows.add(name & (if state.len > 0: " — " & state else: ""))
  popup(btn, listBox("Downloads", rows))

proc showBookmarks*(btn: pointer) =
  var rows: seq[string] = @[]
  let p = callHelper("bookmark.list")
  if p != nil and p.kind == JArray:
    for item in p:
      if item.kind != JObject:
        rows.add($item)
        continue
      let title =
        if item.hasKey("title"): item["title"].getStr("")
        else: ""
      let url =
        if item.hasKey("url"): item["url"].getStr("")
        else: ""
      rows.add(if title.len > 0 and url.len > 0: title & "\n" & url
        elif url.len > 0: url
        elif title.len > 0: title
        else: $item)
  popup(btn, listBox("Bookmarks", rows))

# --- shield (per-site exception, real settings round-trip) ---

proc showShieldFor*(btn: pointer, url: string)

var shieldHost: string = ""

proc shieldExceptions(doc: JsonNode): seq[string] =
  if doc.hasKey("adblock") and doc["adblock"].kind == JObject and
      doc["adblock"].hasKey("exceptions") and
      doc["adblock"]["exceptions"].kind == JArray:
    for e in doc["adblock"]["exceptions"]:
      result.add(e.getStr(""))

proc onShieldToggle(btn: pointer, ud: pointer) {.cdecl.} =
  let host = shieldHost
  if host.len == 0: return
  var doc = callHelper("settings.get")
  if doc == nil or doc.kind != JObject:
    doc = %*{"adblock": {"enabled": true, "exceptions": []}}
  if not doc.hasKey("adblock") or doc["adblock"].kind != JObject:
    doc["adblock"] = %*{"enabled": true, "exceptions": []}
  var exc = shieldExceptions(doc)
  if host in exc:
    exc = exc.filterIt(it != host)
  else:
    exc.add(host)
  var arr = newJArray()
  for e in exc: arr.add(%e)
  doc["adblock"]["exceptions"] = arr
  discard callHelper("settings.set", %*{"document": doc})
  # Re-open to reflect the new state.
  let parent = cast[pointer](ud)
  showShieldFor(parent, host)

proc showShieldFor*(btn: pointer, url: string) =
  let host = hostOfUrl(url)
  shieldHost = host
  let box = baseBox()
  let doc = callHelper("settings.get")
  let paused =
    if doc != nil: host in shieldExceptions(doc)
    else: false
  gtk_box_append(box, titleLabel(if paused: "Paused on this site"
    else: "Blocking on this site"))
  gtk_box_append(box, bodyLabel(if host.len > 0: host
    else: "No site address for this tab."))
  if host.len > 0:
    let t = gtk_button_new_with_label(if paused: "Resume on this site"
      else: "Pause on this site")
    discard gSignalConnect(cast[pointer](t), "clicked".cstring,
      cast[pointer](onShieldToggle), btn)
    gtk_box_append(box, cast[pointer](t))
    gtk_box_append(box, bodyLabel(
      "Takes effect when the WebKit filter store attach lands."))
  popup(btn, box)

proc showPasswords*(btn: pointer) =
  let box = baseBox()
  gtk_box_append(box, titleLabel("Password Manager"))
  let p = callHelper("password.status")
  var state = "unknown"
  if p != nil:
    if p.kind == JObject and p.hasKey("state"):
      state = p["state"].getStr("unknown")
    elif p.kind == JString:
      try: state = parseJson(p.getStr)["state"].getStr("unknown")
      except: discard
  gtk_box_append(box, bodyLabel("Vault: " & state))
  gtk_box_append(box, bodyLabel("Unlock and autofill UI comes next."))
  popup(btn, box)

proc showSettings*(btn: pointer) =
  let box = baseBox()
  gtk_box_append(box, titleLabel("Settings"))
  gtk_box_append(box, bodyLabel("Whatever " & helperVersion()))
  gtk_box_append(box, bodyLabel("Store: " & getEnv("WHATEVER_STORE_ROOT",
    getEnv("XDG_DATA_HOME", getHomeDir() & ".local/share") &
    "/whatever")))
  gtk_box_append(box, bodyLabel("Full Settings window comes next."))
  popup(btn, box)
