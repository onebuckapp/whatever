# Whatever Browser – Made by Humans from OpenPeeps
#
#     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Tests for the find-in-page matching C ABI.
#
# Match ranges are asserted as exact byte offsets: the app maps them onto
# DOM text nodes, so an off-by-one here becomes a highlight on the wrong
# character. The pattern builder is pinned directly too, because a query
# must never compile into a wildcard.

import std/[strutils, unittest]

import openparser/json

import ../api/[abi, find_api]

proc findDoc(text: string, query: string, matchCase = false,
             wholeWords = false, limit = 0'i32): JsonNode =
  var needed: int32
  check bcFindMatches(text.cstring, query.cstring, int32(ord(matchCase)),
    int32(ord(wholeWords)), limit, nil, 0, addr needed) == ErrBufferTooSmall
  check needed > 0
  var document = newString(needed)
  check bcFindMatches(text.cstring, query.cstring, int32(ord(matchCase)),
    int32(ord(wholeWords)), limit, addr document[0], needed, nil) == Ok
  parseJson(document)

proc spans(document: JsonNode): seq[tuple[start: int, stop: int]] =
  for node in document["matches"]:
    result.add((node["start"].getInt(), node["stop"].getInt()))

suite "find pattern builder":
  test "escapes every metacharacter so a query cannot become a wildcard":
    check buildFindPattern("a+b (x) [y] {2} ^$ .|?*\\", false,
                           false) ==
      "[aA]\\+[bB] \\([xX]\\) \\[[yY]\\] \\{2\\} \\^\\$ \\.\\|\\?\\*\\\\"

  test "leaves case exact when match case is on":
    check buildFindPattern("Hi!", true, false) == "Hi!"

  test "wraps whole words in boundaries":
    check buildFindPattern("cat", false, true) == "\\b(?:[cC][aA][tT])\\b"

  test "keeps non-ascii bytes literal under folding":
    check buildFindPattern("Café", false, false) == "[cC][aA][fF]é"

suite "find c abi":
  test "reports every non-overlapping match front to back":
    let document = findDoc("hello world, hello", "hello")
    check spans(document) == @[(0, 5), (13, 18)]
    check document["total"].getInt() == 2
    check document["hasMore"].getBool() == false
    check document["truncated"].getBool() == false

  test "folds ascii case unless match case is on":
    check spans(findDoc("Hello HELLO hello", "hello")) ==
      @[(0, 5), (6, 11), (12, 17)]
    check spans(findDoc("Hello HELLO hello", "hello",
                        matchCase = true)) == @[(12, 17)]

  test "whole words skips substrings of longer words":
    check spans(findDoc("cat cats concatenate cat", "cat",
                        wholeWords = true)) == @[(0, 3), (21, 24)]
    check spans(findDoc("cat cats concatenate cat", "cat")) ==
      @[(0, 3), (4, 7), (12, 15), (21, 24)]

  test "matches regex metacharacters literally":
    check spans(findDoc("a+b and aab", "a+b")) == @[(0, 3)]

  test "limits the list but still reports the total":
    let document = findDoc("aaaa", "a", limit = 2)
    check spans(document) == @[(0, 1), (1, 2)]
    check document["total"].getInt() == 4
    check document["hasMore"].getBool() == true

  test "reports byte offsets for non-ascii text":
    # "Café": C a f are one byte each, é is two (bytes 3..4). The query
    # folds too, so "é" also meets the plain "e" in "über" (byte 9).
    let document = findDoc("Café über", "é")
    check spans(document) == @[(3, 5), (9, 10)]
    # Folded, then case-folded: "CAFÉ" finds "Café".
    check spans(findDoc("Café über", "CAFÉ")) == @[(0, 5)]

  test "empty query returns an empty list, not an error":
    let document = findDoc("some text", "")
    check document["matches"].len == 0
    check document["total"].getInt() == 0
    check document["hasMore"].getBool() == false

  test "truncates text over the cap and says so":
    let text = 'x'.repeat(MaxFindTextBytes + 100) & "needle"
    let document = findDoc(text, "needle")
    check document["truncated"].getBool() == true
    check document["total"].getInt() == 0

  test "null text is bad input":
    check bcFindMatches(nil, "x".cstring, 0, 0, 0, nil, 0, nil) ==
      ErrBadInput

suite "diacritic folding":
  test "folds the Romanian set and common Latin":
    check foldRune(0x219) == "s" # ș
    check foldRune(0x218) == "S" # Ș
    check foldRune(0x21B) == "t" # ț
    check foldRune(0x103) == "a" # ă
    check foldRune(0xE2) == "a" # â
    check foldRune(0xEE) == "i" # î
    check foldRune(0x153) == "oe" # œ
    check foldRune(0xDF) == "ss" # ß
    check foldRune(0x141) == "l" # Ł
    check foldRune(0x131) == "i" # ı

  test "leaves non-letters and non-Latin scripts exact":
    check foldRune(0xD7) == "" # × is not a letter
    check foldRune(0xF7) == "" # ÷ is not a letter
    check foldRune(0x43C) == "" # Cyrillic п
    check foldRune(0x41) == "" # plain A needs no fold

  test "maps folded bytes back to original offsets":
    let (folded, origOf) = foldDiacritics("xșasey")
    check folded == "xsasey"
    check origOf == @[0, 1, 3, 4, 5, 6]

  test "diacritic text meets plain query":
    check spans(findDoc("mănâncă șase", "sase")) == @[(11, 16)]

  test "plain text meets diacritic query":
    check spans(findDoc("sase frumoase", "șase")) == @[(0, 4)]

  test "diacritics fold before case":
    check spans(findDoc("ȘASE", "sase")) == @[(0, 5)]
    check spans(findDoc("sase", "ȘASE")) == @[(0, 4)]

  test "whole words work on folded text":
    check spans(findDoc("șase șasele", "sase",
                        wholeWords = true)) == @[(0, 5)]

  test "multi-character expansions translate whole":
    check spans(findDoc("cœur", "coeur")) == @[(0, 5)]

  test "non-Latin scripts still match exactly":
    check spans(findDoc("привет мир", "привет")) == @[(0, 12)]
