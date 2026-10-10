# Minimal importc surface for the portable core.
# Full contract: core/include/browsercore.h (two-phase NULL→size→fill,
# BC_* codes, one caller thread at a time, bc_register_thread per thread).
import std/os
{.passc: "-I" & currentSourcePath().parentDir() & "/../../../core/include".}

const
  BC_OK* = 0'i32
  BC_ERR_BAD_INPUT* = 1'i32
  BC_ERR_BUFFER_TOO_SMALL* = 2'i32
  BC_ERR_STORAGE* = 3'i32
  BC_ERR_ENCODER* = 4'i32
  BC_ERR_NOT_FOUND* = 5'i32
  BC_ERR_LOCKED* = 6'i32
  BC_ERR_WRONG_PASSWORD* = 8'i32

{.push importc, cdecl, header: "browsercore.h".}
proc bc_init*()
proc bc_register_thread*()
proc bc_shutdown*()
proc bc_version*(): cstring
proc bc_last_error*(buffer: cstring, capacity: int32): int32

proc bc_settings_get*(buffer: cstring, capacity: int32,
    needed: ptr int32): int32
proc bc_settings_set*(document: cstring, written: ptr int32): int32

proc bc_history_record*(url, title: cstring, visitedAt: int64,
    collapseWindowSecs: int64): int32
proc bc_history_should_record*(url: cstring): int32
proc bc_history_recent*(limit: int32, buffer: cstring, capacity: int32,
    needed: ptr int32): int32
proc bc_history_fuzzy_search*(query: cstring, limit: int32, buffer: cstring,
    capacity: int32, needed: ptr int32): int32

proc bc_find_matches*(text, query: cstring, matchCase: int32,
    wholeWords: int32, limit: int32, buffer: cstring, capacity: int32,
    needed: ptr int32): int32

proc bc_session_load*(buffer: cstring, capacity: int32,
    needed: ptr int32): int32
proc bc_session_save*(document: cstring): int32

proc bc_filter_compile*(lists, buffer: cstring, capacity: int32,
    needed: ptr int32): int32
proc bc_filter_meta*(lists, version, buffer: cstring, capacity: int32,
    needed: ptr int32): int32

proc bc_bookmark_list*(buffer: cstring, capacity: int32,
    needed: ptr int32): int32
proc bc_download_record*(id, sourceUrl, filename, destPath: cstring,
    bytesExpected: int64, startedAt: int64): int32
proc bc_download_finish*(id: cstring, bytesReceived: int64,
    finishedAt: int64): int32
proc bc_download_fail*(id, err: cstring, bytesReceived: int64,
    finishedAt: int64): int32
proc bc_download_list*(buffer: cstring, capacity: int32,
    needed: ptr int32): int32
{.pop.}

proc bcCall*(op: proc(buf: cstring, cap: int32, needed: ptr int32): int32): string =
  ## Two-phase helper (mirrors macos/Store/CoreBridge.swift CoreBuffer.Fill).
  var needed: int32 = 0
  discard op(nil, 0, addr needed)
  if needed <= 1:
    return ""
  var buf = newString(needed)
  let rc = op(buf.cstring, needed, addr needed)
  if rc != BC_OK and rc != BC_ERR_BUFFER_TOO_SMALL:
    return ""
  buf.setLen(max(0, needed - 1))
  buf
