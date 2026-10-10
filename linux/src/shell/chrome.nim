# Compact window chrome — pulls the headerbar (and with it the
# minimize/maximize/close controls) closer to the window edges.
# Swift-side analogue: BrowserToolbarView.windowButtonInset.
import std/math
import std/strformat
import bindings/gtk4_min

const ChromeBaseCss* = """
headerbar {
  padding-left: 2px;
  padding-right: 2px;
  padding-top: 0;
  padding-bottom: 0;
  min-height: 0;
  border-bottom-width: 0;
  box-shadow: none;
}
windowcontrols button {
  padding: 0;
  margin: 0;
  min-width: 24px;
  min-height: 24px;
}
windowcontrols button image {
  -gtk-icon-transform: scale(0.85);
}
/* Address bar: Adwaita entry default is 34px — slimmer. */
headerbar entry {
  min-height: 24px;
}
notebook,
notebook header,
notebook stack {
  border: none;
  box-shadow: none;
}
/* Tab unit: strip spans the full width; the page (webview) below
   keeps breathing room on the sides and bottom, none on top, so the
   active tab flows straight into the page. */
notebook.tabstrip {
  margin: 0;
}
notebook.tabstrip header {
  padding-left: 0;
  padding-right: 0;
}
notebook.tabstrip stack {
  margin-top: 0;
  margin-left: 7px;
  margin-right: 7px;
  margin-bottom: 7px;
}
/* Pages: rounded bottom corners flowing toward the window edge.
   (GTK has no `overflow` property — real masking is done by the
   .webview-corner overlays below.) */
notebook.tabstrip stack {
  border-radius: 0 0 12px 12px;
}
/* Tabs: classic tab shape — rounded tops, straight bottoms.
   Slimmer height, wider body. */
notebook.tabstrip header tabs tab {
  border-radius: 8px 8px 0 0;
  min-height: 24px;
  min-width: 150px;
  padding-top: 3px;
  padding-bottom: 3px;
}
/* Tab strip shares the toolbar background — one continuous unit,
   tracking active and inactive (backdrop) window states. */
notebook.tabstrip header {
  background: @headerbar_bg_color;
}
notebook.tabstrip header:backdrop {
  background: @headerbar_backdrop_color;
}
/* Tab close button: 12px glyph, zero padding, no hover wash. */
button.tab-close {
  padding: 0;
  margin: 0;
  min-width: 16px;
  min-height: 16px;
  background: transparent;
  border: none;
  box-shadow: none;
}
button.tab-close:hover,
button.tab-close:active {
  background: transparent;
  box-shadow: none;
}
/* Modal layer: fullscreen shield (transparent or dimmed) + centered
   card. Clicking the shield closes the modal; the card carries no
   close button by default. */
.modal-shield {
  background: transparent;
}
.modal-shield-dim {
  background: rgba(0, 0, 0, 0.45);
}
.modal-card {
  background: @window_bg_color;
  border-radius: 12px;
  padding: 18px;
  min-width: 460px;
}
/* Webview corner masks: CSS rounding cannot clip WebKit's composited
   content, so 12px overlays paint window-bg everywhere except a
   quarter-circle — a real mask, no halo, click-through. */
.webview-corner {
  min-width: 12px;
  min-height: 12px;
}
"""

const CompactChromeCss* = ChromeBaseCss

proc windowBgCss*(win: pointer): string =
  ## Corner-mask rules with the theme's real window background baked in.
  ## `@window_bg_color` does not resolve from app-priority CSS, so look
  ## the color up on the live widget and inline it (theme-following,
  ## works light and dark). Falls back to transparent = no mask.
  var rgba = GdkRGBA(red: 0, green: 0, blue: 0, alpha: 0)
  let ctx = gtk_widget_get_style_context(win)
  if ctx != nil and gtk_style_context_lookup_color(ctx,
      "window_bg_color", addr rgba) != 0:
    let c = fmt"rgba({round(rgba.red * 255)}, {round(rgba.green * 255)}, " &
      fmt"{round(rgba.blue * 255)}, {rgba.alpha})"
    result = ".webview-corner-bl {\n" &
      "  background: radial-gradient(circle at 0% 100%, transparent 0px, " &
      "transparent 11px, " & c & " 11px);\n}\n" &
      ".webview-corner-br {\n" &
      "  background: radial-gradient(circle at 100% 100%, transparent 0px, " &
      "transparent 11px, " & c & " 11px);\n}\n"
  else:
    result = ""

proc applyCompactChrome*() =
  let display = gdk_display_get_default()
  if display == nil: return
  let provider = gtk_css_provider_new()
  gtk_css_provider_load_from_data(provider, ChromeBaseCss.cstring,
    ChromeBaseCss.len.clong, nil)
  gtk_style_context_add_provider_for_display(display, provider,
    GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)

proc applyCornerMasks*(win: pointer) =
  ## Second pass once the window exists: theme-resolved corner masks.
  let display = gdk_display_get_default()
  if display == nil or win == nil: return
  let css = windowBgCss(win)
  if css.len == 0: return
  let provider = gtk_css_provider_new()
  gtk_css_provider_load_from_data(provider, css.cstring,
    css.len.clong, nil)
  gtk_style_context_add_provider_for_display(display, provider,
    GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
