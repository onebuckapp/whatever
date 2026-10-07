# Download history C ABI tests.
#
# Exercises recording, progress, terminal states, listing order, removal,
# and input validation against a throwaway store. Payloads are inline because
# the suite never touches the network or the filesystem beyond its scratch
# directory.

import std/[envvars, os, unittest]
import openparser/json
import ../api/[abi, feed_api, downloads_api]

let scratchRoot = getTempDir() / "whatever-download-tests"
removeDir(scratchRoot)
createDir(scratchRoot)
putEnv("WHATEVER_STORE_ROOT", scratchRoot)

# Touch the feeds surface first so the shared store opens exactly the way the
# service opens it, with every table present.
doAssert feedSubscribe("https://example.com/feed.xml".cstring,
  "https://example.com/".cstring, "".cstring, "".cstring, "".cstring, 0'i64) == Ok

suite "download c abi":
  test "record, progress, and finish track one download":
    check bc_download_record("dl-one".cstring, "https://example.com/a.zip".cstring,
      "a.zip".cstring, "/Users/test/Downloads/a.zip".cstring, 1000'i64,
      1_700_000_100'i64) == Ok
    check bc_download_progress("dl-one".cstring, 400'i64) == Ok
    check bc_download_finish("dl-one".cstring, 1000'i64, 1_700_000_200'i64) == Ok
    # Terminal rows ignore late progress; the finish owns the final count.
    check bc_download_progress("dl-one".cstring, 10'i64) == Ok

    var needed: int32 = 0
    check bc_download_list(nil, 0'i32, addr needed) == ErrBufferTooSmall
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check bc_download_list(addr buffer[0], needed, addr filled) == Ok
    let listed = parseJson($buffer)
    check listed.len == 1
    check listed[0]["id"].getStr == "dl-one"
    check listed[0]["sourceURL"].getStr == "https://example.com/a.zip"
    check listed[0]["filename"].getStr == "a.zip"
    check listed[0]["destinationPath"].getStr == "/Users/test/Downloads/a.zip"
    check listed[0]["bytesExpected"].getInt == 1000
    check listed[0]["bytesReceived"].getInt == 1000
    check listed[0]["state"].getStr == "done"
    check listed[0]["startedAt"].getInt == 1_700_000_100
    check listed[0]["finishedAt"].getInt == 1_700_000_200

  test "unknown sizes and failure states persist":
    check bc_download_record("dl-unknown".cstring, "https://example.com/b.iso".cstring,
      "b.iso".cstring, "/Users/test/Downloads/b.iso".cstring, -1'i64,
      1_700_000_300'i64) == Ok
    check bc_download_fail("dl-unknown".cstring, "connection reset".cstring,
      512'i64, 1_700_000_400'i64) == Ok
    check bc_download_record("dl-cancelled".cstring, "https://example.com/c.dmg".cstring,
      "c.dmg".cstring, "/Users/test/Downloads/c.dmg".cstring, 200'i64,
      1_700_000_500'i64) == Ok
    check bc_download_cancel("dl-cancelled".cstring, 1_700_000_600'i64) == Ok

    var needed: int32 = 0
    discard bc_download_list(nil, 0'i32, addr needed)
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check bc_download_list(addr buffer[0], needed, addr filled) == Ok
    let listed = parseJson($buffer)
    # Newest first across the earlier finished row.
    check listed.len == 3
    check listed[0]["id"].getStr == "dl-cancelled"
    check listed[0]["state"].getStr == "cancelled"
    check listed[1]["id"].getStr == "dl-unknown"
    check listed[1]["state"].getStr == "failed"
    check listed[1]["errorText"].getStr == "connection reset"
    check listed[1]["bytesExpected"].getInt == -1
    check listed[2]["id"].getStr == "dl-one"

  test "recording an existing id restarts it":
    check bc_download_record("dl-one".cstring, "https://example.com/a.zip".cstring,
      "a.zip".cstring, "/Users/test/Downloads/a.zip".cstring, 1000'i64,
      1_700_000_700'i64) == Ok
    var needed: int32 = 0
    discard bc_download_list(nil, 0'i32, addr needed)
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check bc_download_list(addr buffer[0], needed, addr filled) == Ok
    let listed = parseJson($buffer)
    check listed.len == 3
    check listed[0]["id"].getStr == "dl-one"
    check listed[0]["state"].getStr == "in-progress"
    check listed[0]["bytesReceived"].getInt == 0

  test "removal forgets rows without touching anything else":
    check bc_download_remove("dl-unknown".cstring) == Ok
    check bc_download_remove("dl-unknown".cstring) == ErrNotFound
    var needed: int32 = 0
    discard bc_download_list(nil, 0'i32, addr needed)
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check bc_download_list(addr buffer[0], needed, addr filled) == Ok
    check parseJson($buffer).len == 2

  test "clear forgets all history":
    check bc_download_clear() == Ok
    var needed: int32 = 0
    discard bc_download_list(nil, 0'i32, addr needed)
    var buffer = newString(needed.int)
    var filled: int32 = 0
    check bc_download_list(addr buffer[0], needed, addr filled) == Ok
    check parseJson($buffer).len == 0

  test "bad input is refused":
    check bc_download_record("".cstring, "https://example.com/a.zip".cstring,
      "a.zip".cstring, "/tmp/a.zip".cstring, 1'i64, 0'i64) == ErrBadInput
    check bc_download_record("dl-bad".cstring, "".cstring,
      "a.zip".cstring, "/tmp/a.zip".cstring, 1'i64, 0'i64) == ErrBadInput
    check bc_download_progress("dl-missing".cstring, 1'i64) == ErrNotFound
    check bc_download_finish("dl-missing".cstring, 1'i64, 0'i64) == ErrNotFound
    check bc_download_fail("dl-missing".cstring, "nope".cstring, 0'i64, 0'i64) == ErrNotFound
    check bc_download_cancel("dl-missing".cstring, 0'i64) == ErrNotFound
    check bc_download_remove("dl-missing".cstring) == ErrNotFound
