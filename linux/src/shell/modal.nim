# Generic modal layer — one flexible popup used by settings and all
# future cards. A modal always shows over a fullscreen shield overlay
# (transparent, or dimmed via ModalDimmed); clicking the shield —
# anywhere outside the card — closes the modal. No close button is
# added by default; content builders own their chrome.
import bindings/gtk4_min

var modalOverlay: pointer = nil
var modalShield: pointer = nil
var modalCard: pointer = nil
var modalCardVisible: bool = false

proc closeModal*()

proc onShieldPressed(gesture: pointer, nPress: cint, x, y: cdouble,
    userData: pointer) {.cdecl.} =
  closeModal()

proc initModalLayer*(overlay: pointer) =
  ## Call once with the window-level GtkOverlay. Creates the hidden
  ## shield + centered card holder.
  modalOverlay = overlay
  modalShield = cast[pointer](gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
  gtk_widget_set_hexpand(modalShield, 1)
  gtk_widget_set_vexpand(modalShield, 1)
  gtk_widget_set_can_target(modalShield, 1)
  let click = gtk_gesture_click_new()
  discard gSignalConnect(click, "pressed".cstring,
    cast[pointer](onShieldPressed))
  gtk_widget_add_controller(modalShield, click)
  modalCard = cast[pointer](gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
  gtk_widget_set_halign(modalCard, GTK_ALIGN_CENTER)
  gtk_widget_set_valign(modalCard, GTK_ALIGN_CENTER)
  gtk_widget_set_can_target(modalCard, 1)
  gtk_overlay_add_overlay(modalOverlay, modalShield)
  gtk_overlay_add_overlay(modalOverlay, modalCard)
  gtk_widget_set_visible(modalShield, 0)
  gtk_widget_set_visible(modalCard, 0)

proc modalOpen*(): bool =
  modalCardVisible

proc showModal*(content: pointer, dimmed = true) =
  ## Show `content` (a card widget) centered over the shield. Replaces
  ## any open modal. No close button is added — builders add their own.
  if modalOverlay == nil or modalShield == nil or modalCard == nil:
    return
  closeModal()
  gtk_widget_add_css_class(modalShield,
    if dimmed: "modal-shield-dim" else: "modal-shield")
  gtk_box_append(modalCard, content)
  gtk_widget_set_visible(modalShield, 1)
  gtk_widget_set_visible(modalCard, 1)
  modalCardVisible = true

proc closeModal*() =
  if modalShield == nil or modalCard == nil: return
  gtk_widget_set_visible(modalShield, 0)
  gtk_widget_set_visible(modalCard, 0)
  modalCardVisible = false
  # Drop the previous card content (built fresh on every show).
  var child = gtk_widget_get_first_child(modalCard)
  while child != nil:
    let next = gtk_widget_get_next_sibling(child)
    gtk_widget_unparent(child)
    child = next
  gtk_widget_remove_css_class(modalShield, "modal-shield-dim")
  gtk_widget_remove_css_class(modalShield, "modal-shield")
