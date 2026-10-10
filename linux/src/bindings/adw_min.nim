# Minimal libadwaita bindings for the Whatever MVP.
import std/strutils

{.passc: gorge("pkg-config --cflags libadwaita-1").}
{.passl: gorge("pkg-config --libs libadwaita-1").}

type
  AdwApplicationWindow* = distinct pointer
  AdwHeaderBar* = distinct pointer
  AdwApplication* = distinct pointer

const
  ADW_CENTERING_POLICY_LOOSE* = 0.cint
  ADW_CENTERING_POLICY_STRICT* = 1.cint

{.push importc, cdecl.}
proc adw_init*()
proc adw_header_bar_set_centering_policy*(bar: pointer, policy: cint)
proc adw_application_window_new*(app: pointer): pointer
proc adw_application_window_set_content*(win: pointer, content: pointer)
proc adw_header_bar_new*(): pointer
proc adw_header_bar_pack_start*(bar: pointer, child: pointer)
proc adw_header_bar_pack_end*(bar: pointer, child: pointer)
proc adw_header_bar_set_title_widget*(bar: pointer, child: pointer)
{.pop.}
