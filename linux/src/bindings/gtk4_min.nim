# Minimal GTK4 + GObject + Gio bindings for the Whatever MVP.
# Style follows owlkettle/bindings/gtk.nim: distinct pointers + importc.
import std/strutils

{.passc: gorge("pkg-config --cflags gtk4").}
{.passl: gorge("pkg-config --libs gtk4").}

type
  GtkWidget* = distinct pointer
  GApplication* = distinct pointer
  GtkApplication* = distinct pointer
  GtkWindow* = distinct pointer
  GtkBox* = distinct pointer
  GtkHeaderBar* = distinct pointer
  GtkEntry* = distinct pointer
  GtkButton* = distinct pointer
  GtkLabel* = distinct pointer
  GtkScrolledWindow* = distinct pointer
  GtkNotebook* = distinct pointer
  GListModel* = distinct pointer

proc isNil*(w: GtkWidget): bool {.borrow.}
proc isNil*(a: GApplication): bool {.borrow.}

type
  GConnectFlags* {.size: sizeof(cint).} = enum
    G_CONNECT_AFTER, G_CONNECT_SWAPPED
  GApplicationFlags* {.size: sizeof(cint).} = enum
    G_APPLICATION_FLAGS_NONE = 0
  GtkOrientation* {.size: sizeof(cint).} = enum
    GTK_ORIENTATION_HORIZONTAL, GTK_ORIENTATION_VERTICAL
  GtkSelectionMode* {.size: sizeof(cint).} = enum
    GTK_SELECTION_NONE, GTK_SELECTION_SINGLE, GTK_SELECTION_BROWSE,
    GTK_SELECTION_MULTIPLE

{.push importc, cdecl.}
proc g_signal_connect_data*(instance: pointer, name: cstring, callback,
    data, destroyData: pointer, flags: GConnectFlags): culong
proc g_object_unref*(obj: pointer)
proc g_free*(p: pointer)

proc gtk_init*()
proc gtk_window_new*(): GtkWidget
proc gtk_application_new*(id: cstring, flags: GApplicationFlags): GtkApplication
proc g_application_run*(app: pointer, argc: cint, argv: pointer): cint
proc g_application_quit*(app: pointer)

proc gtk_application_window_new*(app: GtkApplication): GtkWidget
proc gtk_window_set_title*(win: pointer, title: cstring)
proc gtk_window_set_default_size*(win: pointer, w, h: cint)
proc gtk_window_set_child*(win: pointer, child: pointer)
proc gtk_window_present*(win: pointer)
proc gtk_window_close*(win: pointer)

proc gtk_box_new*(orient: GtkOrientation, spacing: cint): GtkWidget
proc gtk_box_append*(box: pointer, child: pointer)
proc gtk_box_remove*(box: pointer, child: pointer)

proc gtk_header_bar_new*(): GtkWidget
proc gtk_header_bar_pack_start*(bar: pointer, child: pointer)
proc gtk_header_bar_pack_end*(bar: pointer, child: pointer)
proc gtk_header_bar_set_title_widget*(bar: pointer, child: pointer)

proc gtk_entry_new*(): GtkWidget
proc gtk_entry_set_placeholder_text*(entry: pointer, text: cstring)
proc gtk_editable_get_text*(editable: pointer): cstring
proc gtk_editable_set_text*(editable: pointer, text: cstring)

proc gtk_button_new_with_label*(label: cstring): GtkWidget
proc gtk_button_new*(): GtkWidget
proc gtk_button_set_label*(btn: pointer, label: cstring)
proc gtk_button_set_child*(btn: pointer, child: pointer)
proc gtk_button_set_has_frame*(btn: pointer, frame: cint)
proc gtk_image_new_from_file*(path: cstring): GtkWidget
proc gtk_image_set_pixel_size*(img: pointer, size: cint)
proc gtk_widget_set_sensitive*(w: pointer, s: cint)
proc gtk_widget_set_tooltip_text*(w: pointer, text: cstring)
proc gtk_widget_set_parent*(w: pointer, parent: pointer)
proc gtk_widget_set_size_request*(w: pointer, wdt, hgt: cint)
proc gtk_widget_add_css_class*(w: pointer, class: cstring)
proc gtk_widget_set_halign*(w: pointer, a: cint)
proc gtk_widget_set_valign*(w: pointer, a: cint)
proc gtk_widget_set_can_target*(w: pointer, v: cint)
proc gtk_widget_unparent*(w: pointer)
proc gtk_widget_get_first_child*(w: pointer): pointer
proc gtk_widget_get_next_sibling*(w: pointer): pointer
proc gtk_widget_remove_css_class*(w: pointer, class: cstring)
proc gtk_gesture_click_new*(): pointer
proc gtk_switch_new*(): GtkWidget
proc gtk_switch_get_active*(sw: pointer): cint
proc gtk_switch_set_active*(sw: pointer, v: cint)

const
  GTK_ALIGN_FILL* = 0.cint
  GTK_ALIGN_CENTER* = 3.cint
proc gtk_overlay_new*(): GtkWidget
proc gtk_overlay_set_child*(ov: pointer, child: pointer)
proc gtk_overlay_add_overlay*(ov: pointer, w: pointer)
proc gtk_overlay_set_clip_overlay*(ov: pointer, w: pointer, clip: cint)

const
  GTK_ALIGN_START* = 1.cint
  GTK_ALIGN_END* = 2.cint
proc gtk_css_provider_new*(): pointer
proc gtk_css_provider_load_from_data*(p: pointer, data: cstring,
    length: clong, err: pointer)
proc gtk_style_context_add_provider_for_display*(d: pointer, p: pointer,
    prio: cuint)
proc gdk_display_get_default*(): pointer
proc gtk_widget_get_style_context*(w: pointer): pointer
proc gtk_style_context_lookup_color*(ctx: pointer, name: cstring,
    color: pointer): cint

type GdkRGBA* = object
  red*, green*, blue*, alpha*: cfloat

const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION*: cuint = 600
proc gtk_popover_new*(): pointer
proc gtk_popover_set_child*(pop: pointer, child: pointer)
proc gtk_popover_popup*(pop: pointer)
proc gtk_popover_popdown*(pop: pointer)
proc gtk_label_set_wrap*(label: pointer, wrap: cint)
proc gtk_label_set_max_width_chars*(label: pointer, n: cint)
proc gtk_scrolled_window_set_min_content_height*(sw: pointer, h: cint)

proc gtk_label_new*(text: cstring): GtkWidget
proc gtk_label_set_text*(label: pointer, text: cstring)

proc gtk_scrolled_window_new*(): GtkWidget
proc gtk_scrolled_window_set_child*(sw: pointer, child: pointer)

proc gtk_notebook_new*(): GtkWidget
proc gtk_notebook_append_page*(nb: pointer, child, tabLabel: pointer): cint
proc gtk_notebook_get_n_pages*(nb: pointer): cint
proc gtk_notebook_get_nth_page*(nb: pointer, idx: cint): pointer
proc gtk_notebook_set_scrollable*(nb: pointer, s: cint)
proc gtk_notebook_set_action_widget*(nb: pointer, w: pointer, pack: cint)
proc gtk_window_handle_set_child*(h: pointer, child: pointer)
proc gtk_window_controls_new*(side: cint): GtkWidget

const
  GTK_PACK_START* = 0.cint
  GTK_PACK_END* = 1.cint
proc gtk_notebook_get_current_page*(nb: pointer): cint
proc gtk_notebook_set_current_page*(nb: pointer, idx: cint)
proc gtk_notebook_remove_page*(nb: pointer, idx: cint)

proc gtk_widget_set_hexpand*(w: pointer, expand: cint)
proc gtk_widget_set_vexpand*(w: pointer, expand: cint)
proc gtk_widget_grab_focus*(w: pointer): cint
proc gtk_widget_add_controller*(w: pointer, c: pointer)
proc gtk_event_controller_key_new*(): pointer

const
  GDK_CONTROL_MASK* = 0x4'u32
  GDK_KEY_LLOWER* = 0x6c'u32
  GDK_KEY_LUPPER* = 0x4c'u32
  GDK_KEY_TLOWER* = 0x74'u32
  GDK_KEY_ESCAPE* = 0xff1b'u32
proc gtk_widget_show*(w: pointer)
proc gtk_widget_set_visible*(w: pointer, visible: cint)
{.pop.}

proc gSignalConnect*(instance: pointer, name: cstring, callback,
    data: pointer = nil): culong =
  g_signal_connect_data(instance, name, callback, data, nil, G_CONNECT_AFTER)
