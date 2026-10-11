# Store helper client — mirrors macos/Sources/Storage/StoreClient.swift.
# Talks JSON over UDS to src/helper/store_service. No core linkage:
# the shell never links libbrowsercore.a (avoids duplicate Nim runtimes).
# All calls are best-effort: helper down → empty values, never a crash.
import std/json
import std/net
import std/os
import helper/protocol

var nextId = 0

proc callHelper*(op: string, args: JsonNode = newJObject()): JsonNode =
  inc nextId
  let path = socketPath()
  var sock = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    sock.connectUnix(path)
    sock.send(encodeRequest(nextId, op, args) & "")
    var line = ""
    sock.readLine(line)
    if line.len == 0: return nil
    let j = parseJson(line)
    if j{"ok"}.getBool(false): return j{"payload"}
    return nil
  except OSError, IOError, JsonParsingError:
    return nil
  finally:
    try: sock.close()
    except: discard

proc helperVersion*(): string =
  let p = callHelper("version")
  if p == nil or p.kind != JString: return ""
  p.getStr

proc helperRecordVisit*(url, title: string) =
  discard callHelper("history.record",
    %*{"url": url, "title": title, "visited_at": 0,
      "collapse_window_secs": 10})

proc helperShouldRecord*(url: string): bool =
  let p = callHelper("history.should_record", %*{"url": url})
  if p == nil or p.kind != JObject: return true
  p{"record"}.getBool(true)
