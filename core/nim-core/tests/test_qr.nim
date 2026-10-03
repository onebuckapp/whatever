# Round-trip tests for the QR C ABI.
#
# The encoder output is checked against openparser's own reader so a
# regression in the ABI layer (buffer size, row order, EC level) shows up
# as a decoding failure rather than a broken QR code on screen.

import std/[strutils, unittest]

import openparser/qr/model2

import ../api/qr_api

proc matrixFromAbi(payload: string, level: QrEc = qrEcMedium): QrMatrix =
  var modules: array[QrMaxModules, uint8]
  var width, height: cint
  let status = bcQrEncode(payload.cstring, level.ord.cint,
    addr modules[0], cint(modules.len), addr width, addr height)
  check status == QrStatus.qrOk.ord
  result = initQrMatrix(int(width), int(height))
  for y in 0 ..< int(height):
    for x in 0 ..< int(width):
      result[x, y] = modules[y * int(width) + x] == 1'u8

suite "qr c abi":
  test "round trips a url":
    let payload = "https://openpeeps.dev/some/deep/path?q=1"
    let decoded = decodeQrMatrix(matrixFromAbi(payload))
    check decoded.ok
    check decoded.text == payload
    check decoded.family == famModel2

  test "honours the requested error correction level":
    let matrix = matrixFromAbi("https://example.com", qrEcHigh)
    check decodeQrMatrix(matrix).ecLevel == ecHigh

  test "grows with payload length":
    let small = matrixFromAbi("hi").width
    let large = matrixFromAbi("https://example.com/" & "a".repeat(400)).width
    check large > small

  test "rejects an empty payload":
    var modules: array[QrMaxModules, uint8]
    var width, height: cint
    let status = bcQrEncode("", 1, addr modules[0], cint(modules.len),
      addr width, addr height)
    check status == QrStatus.qrBadInput.ord
    check bcLastError(nil, 0) > 0

  test "refuses an undersized module buffer":
    var tiny: array[4, uint8]
    var width, height: cint
    let status = bcQrEncode("hi", 1, addr tiny[0], cint(tiny.len),
      addr width, addr height)
    check status == QrStatus.qrBufferTooSmall.ord

  test "reports overflow for payloads past version 40":
    var modules: array[QrMaxModules, uint8]
    var width, height: cint
    let status = bcQrEncode("a".repeat(6000), 3, addr modules[0],
      cint(modules.len), addr width, addr height)
    check status == QrStatus.qrTooLong.ord

  test "renders svg through the two-phase buffer protocol":
    let payload = "https://openpeeps.dev/some/deep/path?q=1"
    var needed: cint
    check bcQrSvg(payload.cstring, 1, 8, 4, nil, nil, nil, 0, addr needed) ==
      QrStatus.qrBufferTooSmall.ord
    check needed > 0
    var document = newString(needed)
    var written: cint
    check bcQrSvg(payload.cstring, 1, 8, 4, nil, nil, addr document[0],
      needed, addr written) == QrStatus.qrOk.ord
    check written == needed
    check document.startsWith("<svg")
    check document.contains("<path")
    check document.contains("</svg>")

  test "svg honours custom colors":
    var needed: cint
    check bcQrSvg("hi", 1, 8, 4, "#112233", "none", nil, 0,
      addr needed) == QrStatus.qrBufferTooSmall.ord
    var document = newString(needed)
    check bcQrSvg("hi", 1, 8, 4, "#112233", "none", addr document[0],
      needed, nil) == QrStatus.qrOk.ord
    check document.contains("#112233")
    check document.contains("fill=\"none\"")

  test "svg rejects bad geometry":
    var needed: cint
    check bcQrSvg("hi", 1, 0, 4, nil, nil, nil, 0, addr needed) ==
      QrStatus.qrBadInput.ord
    check bcQrSvg("hi", 1, 8, -1, nil, nil, nil, 0, addr needed) ==
      QrStatus.qrBadInput.ord
    check bcQrSvg("", 1, 8, 4, nil, nil, nil, 0, addr needed) ==
      QrStatus.qrBadInput.ord