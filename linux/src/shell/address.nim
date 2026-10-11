# AddressParser port (macos/Sources/Navigation/AddressParser.swift).
# Input → URL vs search vs file path. No dependencies.
import std/strutils
import std/uri

type
  AddressKind* = enum
    akUrl, akSearch, akFile

  AddressTarget* = object
    kind*: AddressKind
    url*: string

const DefaultSearchTemplate* =
  "https://duckduckgo.com/?q={query}"

proc looksLikeHost(s: string): bool =
  if " " in s: return false
  "." in s and not s.startsWith(".") and not s.endsWith(".")

proc toTarget*(input: string,
    searchTemplate = DefaultSearchTemplate): AddressTarget =
  let s = input.strip()
  if s.len == 0:
    return AddressTarget(kind: akUrl, url: "w://about")
  if s.startsWith("w://") or s.startsWith("about:"):
    return AddressTarget(kind: akUrl, url: s)
  if s.startsWith("/") or s.startsWith("file://"):
    let p = if s.startsWith("file://"): s else: "file://" & s
    return AddressTarget(kind: akFile, url: p)
  if s.startsWith("http://") or s.startsWith("https://"):
    return AddressTarget(kind: akUrl, url: s)
  if looksLikeHost(s) and " " notin s:
    let withScheme =
      if "://" in s: s else: "https://" & s
    try:
      discard parseUri(withScheme)
      return AddressTarget(kind: akUrl, url: withScheme)
    except: discard
  AddressTarget(kind: akSearch,
    url: searchTemplate.replace("{query}", encodeUrl(s)))
