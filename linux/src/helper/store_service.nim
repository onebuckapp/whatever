# Whatever Linux store helper — port of macos/Store/StoreService.swift.
# Single owner of the core: compiled from source (import browsercore),
# so the helper process has exactly one Nim runtime. The shell never
# touches the core; it talks JSON over UDS (XPC-like isolation).
# Serial request handling: core shares module state, one caller at a time.
import std/json
import std/net
import std/os
import protocol
import browsercore

proc storeRoot(): string =
  let direct = getEnv("WHATEVER_STORE_ROOT", "")
  if direct.len > 0: return direct
  let xdg = getEnv("XDG_DATA_HOME", getHomeDir() & ".local/share")
  xdg & "/whatever"

type
  Buf32Op = proc(buf: ptr char, cap: int32, needed: ptr int32): int32
  BufCOp = proc(buf: ptr char, cap: cint, needed: ptr cint): cint

proc readBuffered32(
    op: Buf32Op): string =
  ## Two-phase (int32) buffer protocol → Nim string (without NUL).
  var needed: int32 = 0
  discard op(nil, 0, addr needed)
  if needed <= 1: return ""
  var buf = newString(needed)
  var needed2: int32 = needed
  let rc = op(cast[ptr char](addr buf[0]), needed, addr needed2)
  if rc != 0 and rc != 2: return ""
  buf.setLen(max(0, needed2 - 1))
  buf

proc readBufferedC(op: BufCOp): string =
  ## Two-phase (cint) variant used by bcFilterCompile/Meta.
  var needed: cint = 0
  discard op(nil, 0, addr needed)
  if needed <= 1: return ""
  var buf = newString(needed)
  var needed2: cint = needed
  let rc = op(cast[ptr char](addr buf[0]), needed, addr needed2)
  if rc != 0 and rc != 2: return ""
  buf.setLen(max(0, needed2 - 1))
  buf

proc dispatch(req: HelperRequest): HelperResponse =
  let a = req.args
  case req.op
  of "ping":
    okResp(req.id, %*"pong")
  of "version":
    okResp(req.id, %($bcVersion()))
  of "settings.get":
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 = settingsGet(b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s)
      else: parseJson("{}")))
  of "settings.set":
    let doc = if a.hasKey("document"): $a["document"] else: "{}"
    var written: int32 = 0
    let rc = settingsSet(doc.cstring, addr written)
    if rc == 0: okResp(req.id, %*{"written": written})
    else: errResp(req.id, "settings.set failed", rc)
  of "history.record":
    let rc = historyRecord(
      a{"url"}.getStr("").cstring, a{"title"}.getStr("").cstring,
      a{"visited_at"}.getBiggestInt(0).int64,
      a{"collapse_window_secs"}.getBiggestInt(10).int64)
    if rc == 0: okResp(req.id, %*{"ok": true})
    else: errResp(req.id, "history.record failed", rc)
  of "history.should_record":
    # Fail-open like the core: nonzero (page) → record.
    let rc = bcHistoryShouldRecord(a{"url"}.getStr("").cstring)
    okResp(req.id, %*{"record": rc != 0})
  of "history.recent":
    let lim = a{"limit"}.getInt(50).int32
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 =
        historyRecent(lim, b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJArray()))
  of "history.fuzzy_search":
    let q = a{"query"}.getStr("")
    let lim = a{"limit"}.getInt(20).int32
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 =
        historyFuzzySearch(q.cstring, lim, b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJArray()))
  of "find.matches":
    let t = a{"text"}.getStr("")
    let q = a{"query"}.getStr("")
    let mc = a{"match_case"}.getInt(0).int32
    let ww = a{"whole_words"}.getInt(0).int32
    let lim = a{"limit"}.getInt(2000).int32
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 =
        bcFindMatches(t.cstring, q.cstring, mc, ww, lim, b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s)
      else: parseJson("""{"matches":[],"total":0}""")))
  of "session.load":
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 = sessionLoad(b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJObject()))
  of "session.save":
    let docStr =
      if a.hasKey("document"): $a["document"]
      else: "{}"
    let rc = sessionSave(docStr.cstring)
    if rc == 0: okResp(req.id, %*{"ok": true})
    else: errResp(req.id, "session.save failed", rc)
  of "filter.compile":
    let lists = a{"lists"}.getStr("")
    let s = readBufferedC(
      proc(b: ptr char, c: cint, n: ptr cint): cint =
        bcFilterCompile(lists.cstring, b, c, n))
    okResp(req.id, % (if s.len > 0: s else: "[]"))
  of "filter.meta":
    let lists = a{"lists"}.getStr("")
    let ver = a{"version"}.getStr("1")
    let s = readBufferedC(
      proc(b: ptr char, c: cint, n: ptr cint): cint =
        bcFilterMeta(lists.cstring, ver.cstring, b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJObject()))
  of "bookmark.list":
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 = bookmarkList(b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJArray()))
  of "download.record":
    let rc = bc_download_record(
      a{"id"}.getStr("").cstring, a{"source_url"}.getStr("").cstring,
      a{"filename"}.getStr("").cstring,
      a{"destination_path"}.getStr("").cstring,
      a{"bytes_expected"}.getBiggestInt(-1).int64,
      a{"started_at"}.getBiggestInt(0).int64)
    if rc == 0: okResp(req.id, %*{"ok": true})
    else: errResp(req.id, "download.record failed", rc)
  of "download.finish":
    let rc = bc_download_finish(a{"id"}.getStr("").cstring,
      a{"bytes_received"}.getBiggestInt(-1).int64,
      a{"finished_at"}.getBiggestInt(0).int64)
    if rc == 0: okResp(req.id, %*{"ok": true})
    else: errResp(req.id, "download.finish failed", rc)
  of "download.fail":
    let rc = bc_download_fail(a{"id"}.getStr("").cstring,
      a{"error"}.getStr("").cstring,
      a{"bytes_received"}.getBiggestInt(0).int64,
      a{"finished_at"}.getBiggestInt(0).int64)
    if rc == 0: okResp(req.id, %*{"ok": true})
    else: errResp(req.id, "download.fail failed", rc)
  of "download.list":
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 =
        bc_download_list(b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s) else: newJArray()))
  of "password.status":
    let s = readBuffered32(
      proc(b: ptr char, c: int32, n: ptr int32): int32 =
        passwordStatus(b, c, n))
    okResp(req.id, % (if s.len > 0: parseJson(s)
      else: parseJson("""{"state":"unknown"}""")))
  else:
    errResp(req.id, "unknown op: " & req.op, 1)

proc serveOne(client: Socket) =
  try:
    while true:
      var line = ""
      client.readLine(line)
      if line.len == 0: break
      let req =
        try: decodeRequest(line)
        except JsonParsingError as e:
          client.send(encodeResponse(errResp(0, "bad json: " & e.msg)))
          continue
      client.send(encodeResponse(dispatch(req)))
  except OSError, IOError:
    discard
  finally:
    client.close()

proc main() =
  putEnv("WHATEVER_STORE_ROOT", storeRoot())
  bcInit()
  bcRegisterThread()
  let path = socketPath()
  try: removeFile(path)
  except OSError: discard
  var server = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  server.bindUnix(path)
  server.listen(8)
  echo "whatever-store listening on " & path
  while true:
    var client = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    try:
      server.accept(client)
    except OSError:
      continue
    serveOne(client)

when isMainModule:
  main()
