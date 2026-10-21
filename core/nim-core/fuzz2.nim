import api/abi
import api/history_api
import api/find_api
import std/[json, strutils]

var fails = 0
proc drive(label: string, call: proc(buf: ptr char, cap: int32,
    needed: ptr int32): int32) =
  var needed: int32 = 0
  var rc = call(nil, 0, addr needed)
  if rc != ErrBufferTooSmall:
    echo label, " phase1 rc=", rc
    inc fails
    return
  var buf = newString(needed.int)
  var filled: int32 = 0
  rc = call(addr buf[0], needed, addr filled)
  if rc != Ok:
    echo label, " phase2 rc=", rc
    inc fails
    return
  discard parseJson(buf)

let nasties = @["", "\x00", "\xFF\xFE", "x".repeat(300000),
  "%s%n%x", "\n".repeat(50000), "'; DROP TABLE history; --",
  "http://" & "a".repeat(100000), "zzz_nothing_matches_this_qqq"]
for q in nasties:
  let query = q
  drive("hint:" & $query.len, proc(buf: ptr char, cap: int32,
      needed: ptr int32): int32 =
    spotlightHint(query.cstring, buf, cap, needed))
  drive("fuzzy:" & $query.len, proc(buf: ptr char, cap: int32,
      needed: ptr int32): int32 =
    historyFuzzySearch(query.cstring, 20, buf, cap, needed))
echo "done fails=", fails
