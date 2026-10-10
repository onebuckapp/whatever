# History + session wrappers.
# MVP links the core directly (same bc_* as the helper); the helper IPC
# client takes over once the UDS server is running — JSON wire identical.
import std/json
import std/times
import ../bindings/browsercore_min

proc recordVisit*(url, title: string) =
  if url.len == 0: return
  discard bc_history_record(url.cstring, title.cstring,
    getTime().toUnix, 10)

proc shouldRecord*(url: string): bool =
  bc_history_should_record(url.cstring) == BC_OK

proc recentHistory*(limit = 50): JsonNode =
  let s = bcCall(proc(b: cstring, c: int32, n: ptr int32): int32 =
    bc_history_recent(limit.int32, b, c, n))
  if s.len > 0: parseJson(s) else: newJArray()

proc fuzzyHistory*(query: string, limit = 20): JsonNode =
  let s = bcCall(proc(b: cstring, c: int32, n: ptr int32): int32 =
    bc_history_fuzzy_search(query.cstring, limit.int32, b, c, n))
  if s.len > 0: parseJson(s) else: newJArray()

proc loadSession*(): JsonNode =
  let s = bcCall(proc(b: cstring, c: int32, n: ptr int32): int32 =
    bc_session_load(b, c, n))
  if s.len > 0 and s != "{}":
    try: return parseJson(s)
    except: discard
  newJObject()

proc saveSession*(tabs: JsonNode) =
  let doc = $(%*{"tabs": tabs, "saved_at": getTime().toUnix})
  discard bc_session_save(doc.cstring)
