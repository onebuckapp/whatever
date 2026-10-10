# BrowserTabState port (macos/Sources/Browser/BrowserTabState.swift:22-47).
# Value snapshot, independent from the WebKitWebView owned by the window.
type
  TabState* = object
    id*: string
    title*: string
    url*: string
    isLoading*: bool
    canGoBack*: bool
    canGoForward*: bool
    progress*: float

var tabSeq*: int = 0

proc newTabState*(url = "w://about"): TabState =
  inc tabSeq
  TabState(id: "tab-" & $tabSeq, title: "New Tab", url: url,
    isLoading: false, canGoBack: false, canGoForward: false, progress: 0.0)

proc withTitle*(t: TabState, title: string): TabState =
  result = t
  result.title = if title.len > 0: title else: "New Tab"

proc withUrl*(t: TabState, url: string): TabState =
  result = t
  result.url = url
