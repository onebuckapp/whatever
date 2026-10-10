# Content-blocker glue (port of macos/Sources/Storage/ContentBlockerStore.swift).
# Core compiles hosts/||/@@/## lists to WebKit JSON via bc_filter_compile;
# the shell persists that JSON to a file the WebKitUserContentFilterStore
# can load with webkit_user_content_filter_store_save_from_file.
import std/os
import ../bindings/browsercore_min

proc blockerDir*(): string =
  let xdg = getEnv("XDG_DATA_HOME", getHomeDir() & ".local/share")
  xdg & "/whatever/blocker"

proc rulesJsonPath*(): string =
  blockerDir() / "rules.json"

proc compileLists*(lists: string): string =
  bcCall(proc(b: cstring, c: int32, n: ptr int32): int32 =
    bc_filter_compile(lists.cstring, b, c, n))

proc saveRulesJson*(lists: string): string =
  let js = compileLists(lists)
  let payload = if js.len > 0: js else: "[]"
  createDir(blockerDir())
  writeFile(rulesJsonPath(), payload)
  rulesJsonPath()
