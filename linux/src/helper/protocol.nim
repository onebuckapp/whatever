# Whatever Linux helper protocol — mirrors macos/Shared/WhateverStoreProtocol.swift
# JSON over Unix-domain socket (XPC-like isolation per user decision).
# Request:  {"id": 1, "op": "<op>", "args": {...}}
# Response: {"id": 1, "ok": true, "payload": <json|string>} |
#           {"id": 1, "ok": false, "error": "...", "code": <bc status>}
import std/json
import std/os

proc socketPath*(): string =
  let uid =
    try: getEnv("UID", "")
    except: ""
  let uidEff = if uid.len > 0: uid else: "1000"
  let xdg = getEnv("XDG_RUNTIME_DIR", "/run/user/" & uidEff)
  xdg & "/whatever-store.sock"

type
  HelperRequest* = object
    id*: int
    op*: string
    args*: JsonNode

  HelperResponse* = object
    id*: int
    ok*: bool
    payload*: JsonNode
    error*: string
    code*: int32

proc encodeRequest*(id: int, op: string,
    args: JsonNode = newJObject()): string =
  $(%*{"id": id, "op": op, "args": args}) & "\n"

proc decodeRequest*(line: string): HelperRequest =
  let j = parseJson(line)
  var args = newJObject()
  if j.hasKey("args") and j["args"].kind == JObject:
    args = j["args"]
  HelperRequest(id: j["id"].getInt, op: j["op"].getStr, args: args)

proc encodeResponse*(r: HelperResponse): string =
  $(%*{"id": r.id, "ok": r.ok, "payload": r.payload,
    "error": r.error, "code": r.code}) & "\n"

proc okResp*(id: int, payload: JsonNode): HelperResponse =
  HelperResponse(id: id, ok: true, payload: payload, error: "", code: 0)

proc errResp*(id: int, msg: string, code: int32 = 3): HelperResponse =
  HelperResponse(id: id, ok: false, payload: newJNull(), error: msg,
    code: code)

const KnownOps* = [
  "version", "settings.get", "settings.set",
  "history.record", "history.should_record", "history.recent",
  "history.fuzzy_search", "find.matches",
  "session.load", "session.save",
  "filter.compile", "filter.meta",
  "bookmark.list", "download.record", "download.finish",
  "download.fail", "download.list", "password.status", "ping",
]
