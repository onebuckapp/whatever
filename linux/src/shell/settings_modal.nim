# Settings modal — first real use of the generic modal layer.
# Title + live rows (version, store path) + a real content-blocker
# master switch (same {"adblock":{"enabled":...}} schema as
# macos/Sources/Storage/SettingsStore.swift). No close button by
# default: overlay click or Escape dismisses.
import std/json
import std/os
import bindings/gtk4_min
import shell/modal
import shell/store_client

proc ensureAdblock(doc: JsonNode): JsonNode =
  result = doc
  if result == nil or result.kind != JObject:
    result = %*{"adblock": {"enabled": true, "exceptions": []}}
  if not result.hasKey("adblock") or result["adblock"].kind != JObject:
    result["adblock"] = %*{"enabled": true, "exceptions": []}

proc onAdblockToggled(sw: pointer, state: cint,
    userData: pointer): cint {.cdecl.} =
  var doc = ensureAdblock(callHelper("settings.get"))
  doc["adblock"]["enabled"] = %*(state != 0)
  discard callHelper("settings.set", %*{"document": doc})
  return 0

proc switchRow(label: string, active: bool,
    onToggle: pointer): pointer =
  let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12)
  let l = gtk_label_new(label.cstring)
  gtk_widget_set_hexpand(cast[pointer](l), 1)
  gtk_widget_set_halign(cast[pointer](l), GTK_ALIGN_START)
  let sw = gtk_switch_new()
  gtk_switch_set_active(cast[pointer](sw), active.cint)
  discard gSignalConnect(cast[pointer](sw), "state-set".cstring, onToggle)
  gtk_box_append(cast[pointer](row), cast[pointer](l))
  gtk_box_append(cast[pointer](row), cast[pointer](sw))
  cast[pointer](row)

proc infoRow(text: string): pointer =
  let l = gtk_label_new(text.cstring)
  gtk_label_set_wrap(cast[pointer](l), 1)
  gtk_label_set_max_width_chars(cast[pointer](l), 52)
  gtk_widget_set_halign(cast[pointer](l), GTK_ALIGN_START)
  cast[pointer](l)

proc showSettingsModal*() =
  let card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)
  gtk_widget_add_css_class(cast[pointer](card), "modal-card")
  let title = gtk_label_new("Settings")
  gtk_widget_add_css_class(cast[pointer](title), "title-1")
  gtk_widget_set_halign(cast[pointer](title), GTK_ALIGN_START)
  gtk_box_append(cast[pointer](card), cast[pointer](title))
  gtk_box_append(cast[pointer](card),
    infoRow("Whatever " & helperVersion()))
  gtk_box_append(cast[pointer](card), infoRow("Store: " & getEnv(
    "WHATEVER_STORE_ROOT", getEnv("XDG_DATA_HOME",
      getHomeDir() & ".local/share") & "/whatever")))
  let doc = ensureAdblock(callHelper("settings.get"))
  let enabled =
    if doc["adblock"].hasKey("enabled"):
      doc["adblock"]["enabled"].getBool(true)
    else: true
  gtk_box_append(cast[pointer](card), switchRow("Content blocker",
    enabled, cast[pointer](onAdblockToggled)))
  gtk_box_append(cast[pointer](card),
    infoRow("More panes land here next. Click outside or press " &
      "Escape to close."))
  showModal(cast[pointer](card), dimmed = true)
