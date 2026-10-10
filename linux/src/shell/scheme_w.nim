# w:// scheme content (port of
# macos/Sources/Navigation/HomepageSchemeHandler.swift:30).
# Serves exactly three addresses, like Swift:
#   w://about                     → bundled homepage markup
#   w://homepage/whatever_bg.jpg  → background image
#   w://homepage/whatever_logo.svg → logo
# Anything else fails. Assets live in linux/assets/homepage (copied from
# macos/Resources/Homepage).
import std/os
import std/strutils

proc homepageDir*(): string =
  let here = currentSourcePath().parentDir() / ".." / ".." / "assets" /
    "homepage"
  if dirExists(here): return here
  getEnv("XDG_DATA_HOME", getHomeDir() & ".local/share") /
    "whatever" / "homepage"

type
  WRoute* = enum
    wrAbout, wrBackground, wrLogo, wrUnknown

proc wRoute*(uri: string): WRoute =
  ## Split a w:// URI into one of the three served routes.
  var rest = uri.strip()
  if rest.startsWith("w://"): rest = rest[4 .. ^1]
  elif rest.startsWith("w:"): rest = rest[2 .. ^1]
  rest = rest.strip(chars = {'/'})
  let slash = rest.find('/')
  let host =
    if slash < 0: rest
    else: rest[0 ..< slash]
  let path =
    if slash < 0: "/"
    else: rest[slash .. ^1]
  if host == "about" and (path == "/" or path.len == 0):
    return wrAbout
  if host == "homepage" and path == "/whatever_bg.jpg":
    return wrBackground
  if host == "homepage" and path == "/whatever_logo.svg":
    return wrLogo
  wrUnknown

proc wSchemePath*(uri: string): string =
  ## Legacy helper: "about" for the start page, else the raw path.
  case wRoute(uri)
  of wrAbout: "about"
  of wrBackground: "homepage/whatever_bg.jpg"
  of wrLogo: "homepage/whatever_logo.svg"
  of wrUnknown: uri

var cachedHtml = ""
var cachedBg = ""
var cachedLogo = ""

proc wAboutBytes*(): string =
  if cachedHtml.len == 0:
    cachedHtml = readFile(homepageDir() / "home.html")
  cachedHtml

proc wBackgroundBytes*(): string =
  if cachedBg.len == 0:
    cachedBg = readFile(homepageDir() / "whatever_bg.jpg")
  cachedBg

proc wLogoBytes*(): string =
  if cachedLogo.len == 0:
    cachedLogo = readFile(homepageDir() / "whatever_logo.svg")
  cachedLogo
