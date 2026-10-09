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

# Tests for the filter list compiler C ABI.
#
# The generated url-filter strings are asserted byte-for-byte: the anchor
# shape is the security property (a rule for `ads.example.com` must never
# match `not-ads.example.com.evil.test`), so the tests pin the exact
# pattern rather than checking it merely contains the hostname.

import std/unittest

import openparser/json

import ../api/[abi, filter_api]

proc compileDoc(text: string): JsonNode =
  var needed: cint
  check bcFilterCompile(text.cstring, nil, 0, addr needed) ==
    ErrBufferTooSmall
  # Querying with a NULL buffer reports required size as a buffer-too-small
  # status, exactly like the QR surface.
  check needed > 0
  var document = newString(needed)
  check bcFilterCompile(text.cstring, addr document[0], needed, nil) == Ok
  parseJson(document)

proc metaDoc(text: string, version = "test-1"): JsonNode =
  var needed: cint
  check bcFilterMeta(text.cstring, version.cstring, nil, 0,
    addr needed) == ErrBufferTooSmall
  check needed > 0
  var document = newString(needed)
  check bcFilterMeta(text.cstring, version.cstring, addr document[0],
    needed, nil) == Ok
  parseJson(document)

proc urlFilters(document: JsonNode): seq[string] =
  for rule in document:
    result.add(rule["trigger"]["url-filter"].getStr())

suite "filter c abi":
  test "compiles 0.0.0.0 and 127.0.0.1 entries with anchored patterns":
    let document = compileDoc("0.0.0.0 ads.example.com\n127.0.0.1 tracker.test\n")
    # Two rules per host: boundary character, then end of string.
    check document.len == 4
    check document[0]["action"]["type"].getStr() == "block"
    check document[0]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?ads\\.example\\.com[/:?#]"
    check document[1]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?ads\\.example\\.com$"
    check document[2]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?tracker\\.test[/:?#]"
    check document[3]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?tracker\\.test$"
    check document[0]["trigger"]["load-type"][0].getStr() == "third-party"

  test "accepts bare hosts and skips comments, blanks and headers":
    let text = """
# a full-line comment
[Adblock Plus 2.0]

bare.example.com   # inline comment
! an abp comment
"""
    let document = compileDoc(text)
    check document.len == 2
    check urlFilters(document) ==
      @["^[^:]+://([^/]*\\.)?bare\\.example\\.com[/:?#]",
        "^[^:]+://([^/]*\\.)?bare\\.example\\.com$"]

  test "lowercases and dedupes across both IP forms":
    let document = compileDoc(
      "0.0.0.0 Ads.Example.COM\n127.0.0.1 ads.example.com\n")
    check document.len == 2

  test "rejects localhost, IPs, single labels and malformed names":
    let text = """
0.0.0.0 localhost
0.0.0.0 localhost.local
127.0.0.1 0.0.0.0
intranet
0.0.0.0 -bad.example.com
0.0.0.0 bad..example.com
0.0.0.0 not a host at all
0.0.0.0 under_score.example.com
"""
    check compileDoc(text).len == 0
    # Eight rejected lines plus the triple-quoted string's leading newline.
    # The closing quotes sit on their own line, whose newline is not part
    # of the literal, so unlike `\n`-terminated inputs there is no trailing
    # empty line to count.
    check metaDoc(text)["skippedLines"].getInt() == 9

  test "compiles || rules and degrades paths to their host":
    let document = compileDoc("||cdn.example.com^\n||img.example.com/banners/\n")
    check document.len == 4
    check document[2]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?img\\.example\\.com[/:?#]"
    check document[3]["trigger"]["url-filter"].getStr() ==
      "^[^:]+://([^/]*\\.)?img\\.example\\.com$"

  test "emits exceptions after the rules they cancel":
    let document = compileDoc(
      "0.0.0.0 ads.example.com\n@@||allow.example.com^\n@@bare.test\n")
    check document.len == 4
    check document[0]["action"]["type"].getStr() == "block"
    check document[1]["action"]["type"].getStr() == "block"
    for i in 2 .. 3:
      check document[i]["action"]["type"].getStr() == "ignore-previous-rules"
      check document[i]["trigger"]["url-filter"].getStr() == ".*"
    check document[2]["trigger"]["if-domain"][0].getStr() == "allow.example.com"
    check document[2]["trigger"]["if-domain"][1].getStr() == "*.allow.example.com"

  test "emits global and domain-qualified cosmetic rules":
    let document = compileDoc("##.ad-banner\nexample.com##.sponsored\n##+js(noop)\n##\n")
    check document.len == 2
    check document[0]["action"]["type"].getStr() == "css-display-none"
    check document[0]["action"]["selector"].getStr() == ".ad-banner"
    check document[0]["trigger"]["url-filter"].getStr() == ".*"
    check document[1]["action"]["selector"].getStr() == ".sponsored"
    check document[1]["trigger"]["if-domain"][0].getStr() == "example.com"
    check document[1]["trigger"]["if-domain"][1].getStr() == "*.example.com"
    check metaDoc("##.ad-banner\nexample.com##.sponsored\n##+js(noop)\n##\n")["skippedLines"].getInt() == 3

  test "keeps first-seen order across mixed sources":
    let document = compileDoc(
      "0.0.0.0 b.example.com\n||a.example.com^\n##.x\n")
    check urlFilters(document) ==
      @["^[^:]+://([^/]*\\.)?b\\.example\\.com[/:?#]",
        "^[^:]+://([^/]*\\.)?b\\.example\\.com$",
        "^[^:]+://([^/]*\\.)?a\\.example\\.com[/:?#]",
        "^[^:]+://([^/]*\\.)?a\\.example\\.com$", ".*"]

  test "empty input compiles to an empty rule list":
    check compileDoc("").len == 0
    check compileDoc("\n  \n# only comments\n").len == 0
    let meta = metaDoc("")
    check meta["ruleCount"].getInt() == 0
    # The two blank lines, the comment line, and splitLines' trailing empty.
    check metaDoc("\n  \n# only comments\n")["skippedLines"].getInt() == 4

  test "meta reports counts, stable hash and echoed version":
    let text = "0.0.0.0 a.example.com\n##.x\n@@b.example.com\njunk line here\n"
    let first = metaDoc(text, "snapshot-7")
    # One host emits two rules, so ruleCount counts emitted rules while
    # blockCount counts hosts.
    check first["ruleCount"].getInt() == 4
    check first["blockCount"].getInt() == 1
    check first["cosmeticCount"].getInt() == 1
    check first["exceptionCount"].getInt() == 1
    # The junk line plus splitLines' trailing empty.
    check first["skippedLines"].getInt() == 2
    check first["sourceVersion"].getStr() == "snapshot-7"
    check first["inputHashHex"].getStr().len == 16
    check metaDoc(text, "snapshot-7")["inputHashHex"].getStr() ==
      first["inputHashHex"].getStr()
    check metaDoc(text & "# one more\n", "snapshot-7")["inputHashHex"].getStr() !=
      first["inputHashHex"].getStr()

  test "nil input is refused and sets the error slot":
    var needed: cint
    check bcFilterCompile(nil, nil, 0, addr needed) == ErrBadInput
    check abi.lastError(nil, 0) > 0
    check bcFilterMeta(nil, "v".cstring, nil, 0, addr needed) ==
      ErrBadInput

  test "nil version in meta is treated as empty, not a crash":
    var needed: cint
    check bcFilterMeta("0.0.0.0 a.example.com".cstring, nil, nil, 0,
      addr needed) == ErrBufferTooSmall
    var meta = newString(needed)
    check bcFilterMeta("0.0.0.0 a.example.com".cstring, nil, addr meta[0],
      needed, nil) == Ok
    check parseJson(meta)["sourceVersion"].getStr() == ""

  test "undersized buffer reports through needed without writing":
    var needed: cint
    let text = "0.0.0.0 a.example.com\n"
    check bcFilterCompile(text.cstring, nil, 0, addr needed) ==
      ErrBufferTooSmall
    var tiny = newString(4)
    check bcFilterCompile(text.cstring, addr tiny[0], 4,
      nil) == ErrBufferTooSmall
