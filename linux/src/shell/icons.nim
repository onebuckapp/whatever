# Toolbar icons — Tabler SVGs shared with macos/Resources/Assets.xcassets
# (copied to linux/assets/icons with currentColor baked to #8a8a8a, since
# file-loaded images don't inherit theme fg like symbolic theme icons do).
# Buttons mirror macos/Sources/Browser/Toolbar/BrowserToolbarController.swift:
# leading [back, forward, reload], trailing [shield, password, bookmarks,
# downloads, settings].
import std/os
import bindings/gtk4_min

const IconPx* = 16

proc iconsDir*(): string =
  ## Dev-tree location; falls back to XDG data install path.
  let here = currentSourcePath().parentDir() / ".." / ".." / "assets" /
    "icons"
  if dirExists(here): return here
  getEnv("XDG_DATA_HOME", getHomeDir() & ".local/share") /
    "whatever" / "icons"

proc iconImage*(name: string, px = IconPx): pointer =
  let img = gtk_image_new_from_file((iconsDir() / name & ".svg").cstring)
  gtk_image_set_pixel_size(cast[pointer](img), px.cint)
  cast[pointer](img)

proc iconButton*(iconName, tooltip: string, px = IconPx): pointer =
  ## Flat icon button like BrowserToolbarButton (no frame, tooltip).
  let btn = gtk_button_new()
  gtk_button_set_has_frame(cast[pointer](btn), 0)
  gtk_button_set_child(cast[pointer](btn), iconImage(iconName, px))
  gtk_widget_set_tooltip_text(cast[pointer](btn), tooltip.cstring)
  cast[pointer](btn)

proc setButtonIcon*(btn: pointer, iconName: string, px = IconPx) =
  gtk_button_set_child(btn, iconImage(iconName, px))
