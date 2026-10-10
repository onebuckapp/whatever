# Minimal WebKitGTK 6.0 bindings for the Whatever MVP.
# Covers: WebView lifecycle, navigation, history, URI scheme (w://),
# content-filter store, find controller, downloads.
# Full API: /usr/include/webkitgtk-6.0/webkit/*.h, GIR: WebKit-6.0.gir
import std/strutils

{.passc: gorge("pkg-config --cflags webkitgtk-6.0").}
{.passl: gorge("pkg-config --libs webkitgtk-6.0").}

type
  WebKitWebView* = distinct pointer
  WebKitWebContext* = distinct pointer
  WebKitURISchemeRequest* = distinct pointer
  WebKitPolicyDecision* = distinct pointer
  WebKitNavigationPolicyDecision* = distinct pointer
  WebKitResponsePolicyDecision* = distinct pointer
  WebKitDownload* = distinct pointer
  WebKitFindController* = distinct pointer
  WebKitUserContentFilterStore* = distinct pointer
  WebKitUserContentManager* = distinct pointer
  WebKitSettings* = distinct pointer
  WebKitBackForwardList* = distinct pointer

proc isNil*(w: WebKitWebView): bool {.borrow.}

type
  WebKitLoadEvent* {.size: sizeof(cint).} = enum
    WEBKIT_LOAD_STARTED = 0, WEBKIT_LOAD_REDIRECTED,
    WEBKIT_LOAD_COMMITTED, WEBKIT_LOAD_FINISHED
  WebKitPolicyDecisionType* {.size: sizeof(cint).} = enum
    WEBKIT_POLICY_DECISION_USE_RESPONSE = 0,
    WEBKIT_POLICY_DECISION_USE_NAVIGATION_ACTION = 1,
    WEBKIT_POLICY_DECISION_USE_NEW_WINDOW_ACTION = 2
  WebKitNavigationType* {.size: sizeof(cint).} = enum
    WEBKIT_NAVIGATION_TYPE_LINK_CLICKED = 0,
    WEBKIT_NAVIGATION_TYPE_FORM_SUBMITTED,
    WEBKIT_NAVIGATION_TYPE_BACK_FORWARD,
    WEBKIT_NAVIGATION_TYPE_RELOAD,
    WEBKIT_NAVIGATION_TYPE_FORM_RESUBMITTED,
    WEBKIT_NAVIGATION_TYPE_OTHER
  WebKitFindOptions* {.size: sizeof(cuint).} = enum
    WEBKIT_FIND_OPTIONS_NONE = 0,
    WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE = 1,
    WEBKIT_FIND_OPTIONS_AT_WORD_STARTS = 2,
    WEBKIT_FIND_OPTIONS_TREAT_MEDIAL_CAPITAL_AS_WORD_START = 4,
    WEBKIT_FIND_OPTIONS_BACKWARDS = 8,
    WEBKIT_FIND_OPTIONS_WRAP_AROUND = 16,
    WEBKIT_FIND_OPTIONS_HIGHLIGHT_ALL_MATCHES = 32

  WebKitURISchemeRequestCallback* =
    proc(request: pointer, userData: pointer) {.cdecl.}

{.push importc, cdecl.}
# --- WebView lifecycle (WebKitWebView.h:355,376) ---
proc webkit_web_view_new*(): pointer
proc webkit_web_view_new_with_context*(ctx: pointer): pointer
proc webkit_web_view_load_uri*(view: pointer, uri: cstring)
proc webkit_web_view_get_uri*(view: pointer): cstring
proc webkit_web_view_get_title*(view: pointer): cstring
proc webkit_web_view_is_loading*(view: pointer): cint
proc webkit_web_view_get_estimated_load_progress*(view: pointer): cdouble
proc webkit_web_view_reload*(view: pointer)
proc webkit_web_view_reload_bypass_cache*(view: pointer)
proc webkit_web_view_stop_loading*(view: pointer)
proc webkit_web_view_go_back*(view: pointer)
proc webkit_web_view_go_forward*(view: pointer)
proc webkit_web_view_can_go_back*(view: pointer): cint
proc webkit_web_view_can_go_forward*(view: pointer): cint
proc webkit_web_view_get_settings*(view: pointer): pointer
proc webkit_web_view_get_context*(view: pointer): pointer
proc webkit_web_view_get_find_controller*(view: pointer): pointer
proc webkit_web_view_get_back_forward_list*(view: pointer): pointer
proc webkit_web_view_evaluate_javascript*(view: pointer, script: cstring,
  length: clonglong, worldName, sourceUri: cstring,
  cancellable: pointer, callback, userData: pointer)

# --- WebContext (WebKitWebContext.h:111) ---
proc webkit_web_context_get_default*(): pointer
proc webkit_web_context_register_uri_scheme*(ctx: pointer, scheme: cstring,
  cb: WebKitURISchemeRequestCallback, userData: pointer, destroyNotify: pointer)
proc webkit_web_context_set_process_model*(ctx: pointer, model: cint)

# --- URI scheme request ---
proc webkit_uri_scheme_request_get_scheme*(req: pointer): cstring
proc webkit_uri_scheme_request_get_uri*(req: pointer): cstring
proc webkit_uri_scheme_request_get_path*(req: pointer): cstring
proc webkit_uri_scheme_request_finish*(req: pointer, stream: pointer,
  streamLength: clonglong, contentType: cstring)
proc webkit_uri_scheme_request_finish_error*(req: pointer, err: pointer)
proc g_error_new_literal*(domain: cuint, code: cint,
    msg: cstring): pointer {.importc: "g_error_new_literal".}

# --- Policy decisions ---
proc webkit_policy_decision_get_type*(d: pointer): cint
proc webkit_policy_decision_use*(d: pointer)
proc webkit_policy_decision_ignore*(d: pointer)
proc webkit_policy_decision_download*(d: pointer)
proc webkit_navigation_policy_decision_get_navigation_type*(d: pointer): cint
proc webkit_navigation_policy_decision_get_request*(d: pointer): pointer
proc webkit_response_policy_decision_get_response*(d: pointer): pointer
proc webkit_uri_request_get_uri*(req: pointer): cstring

# --- Content filters (WebKitUserContentFilterStore.h:45ff) ---
proc webkit_user_content_filter_store_new*(path: cstring): pointer
proc webkit_user_content_filter_store_save*(store: pointer, id: cstring,
  source: pointer, cancellable: pointer, callback, userData: pointer)
proc webkit_user_content_filter_store_load*(store: pointer, id: cstring,
  cancellable: pointer, callback, userData: pointer)

# --- Find (WebKitFindController) ---
proc webkit_find_controller_search*(fc: pointer, text: cstring,
  options: cuint, maxCount: cuint)
proc webkit_find_controller_search_next*(fc: pointer)
proc webkit_find_controller_search_previous*(fc: pointer)
proc webkit_find_controller_search_finish*(fc: pointer)
proc webkit_find_controller_count_matches*(fc: pointer, text: cstring,
  options: cuint, maxCount: cuint)

# --- Downloads ---
proc webkit_download_get_request*(dl: pointer): pointer
proc webkit_download_get_destination*(dl: pointer): cstring
proc webkit_download_set_destination*(dl: pointer, path: cstring)
proc webkit_download_cancel*(dl: pointer)

# --- Settings bits used by WebSettings+WebKit.swift port ---
proc webkit_settings_set_enable_javascript*(s: pointer, v: cint)
proc webkit_settings_set_enable_media_stream*(s: pointer, v: cint)
proc webkit_settings_set_enable_webrtc*(s: pointer, v: cint)
{.pop.}
