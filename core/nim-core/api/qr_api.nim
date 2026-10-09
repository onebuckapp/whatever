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

# QR generation C ABI for the Whatever backend.
#
# Model 2 (ISO/IEC 18004) encoding is delegated to `openparser`. The leaf
# module is imported instead of the `openparser/qr` umbrella so the AES
# backed SQRC/AQR encoders (and with them nimcypher) stay out of this
# archive.
#
# Ownership rules:
#   * Nim never hands allocated memory to Swift. The caller owns the
#     module buffer it passes in and Nim only writes into it.
#   * `bcLastError` copies into a caller-owned buffer, so there is no
#     cross-boundary free to get wrong.
#
# Thread safety:
#   * Every export touches module-level state, so they are neither
#     re-entrant nor thread-safe. Call from the main thread only; the
#     whole call is a few microseconds for web-sized payloads.
#
# Sync: every call is synchronous and returns before Swift continues.

import openparser/qr/model2
import openparser/qr/render

# The error channel lives in abi.nim so the whole ABI has one last-message slot
# and one `bc_last_error` export.
import ./abi

const
  QrMaxSide* = 177
    ## Largest Model 2 symbol (version 40).
  QrMaxModules* = QrMaxSide * QrMaxSide
    ## Upper bound of modules in one symbol.

type
  QrEc* = enum
    ## Error correction level requested by the caller. The ordinals are
    ## part of the C ABI.
    qrEcLow = 0
    qrEcMedium = 1
    qrEcQuartile = 2
    qrEcHigh = 3

  QrStatus* = enum
    ## Result of `bcQrEncode` and `bcQrSvg`. The names are local; the ordinals
    ## are the shared status codes from abi.nim, so one caller can read a QR
    ## result with the same table it reads a store result with.
    ##
    ## This used to be numbered independently, which put `qrTooLong` on 2 and
    ## `qrBufferTooSmall` on 3 — the two ordinals the shared table already uses
    ## for the opposite meanings. A size query then read as a hard failure and
    ## the SVG was never written.
    qrOk = Ok.ord
    qrBadInput = ErrBadInput.ord
    qrTooLong = ErrPayloadTooLong.ord
    qrBufferTooSmall = ErrBufferTooSmall.ord
    qrEncoderFailure = ErrEncoder.ord

var moduleStore: array[QrMaxModules, uint8]

proc openParserLevel(level: QrEc): QrEcLevel {.inline.} =
  case level
  of qrEcLow: ecLow
  of qrEcMedium: ecMedium
  of qrEcQuartile: ecQuartile
  of qrEcHigh: ecHigh

proc requestedLevel(ecLevel: cint): QrEc {.inline.} =
  case ecLevel
  of 0: qrEcLow
  of 2: qrEcQuartile
  of 3: qrEcHigh
  else: qrEcMedium

proc encodeMatrix(text: string, level: QrEc): QrMatrix {.inline.} =
  encodeQr(text, QrEncodeOptions(ecLevel: openParserLevel(level)))

proc bcVersion*(): cstring {.exportc: "bc_version".} =
  ## Version of the core, mirrored in `browsercore.h`.
  "0.1.0"

proc bcQrEncode*(text: cstring, ecLevel: cint, outModules: ptr uint8,
                 capacity: cint, outWidth: ptr cint,
                 outHeight: ptr cint): cint {.exportc: "bc_qr_encode".} =
  ## Encodes UTF-8 `text` as a Model 2 QR symbol.
  ##
  ## Writes one byte per module into `outModules`, row-major from the
  ## top-left corner, `1` for a dark module and `0` for a light one.
  ## `capacity` is the byte length of that buffer and must be at least
  ## `QrMaxModules` (`177 * 177`); nothing is written when it is smaller.
  ## The symbol side length is returned through `outWidth` / `outHeight`.
  ##
  ## Synchronous, main thread only. Returns a `QrStatus` ordinal.
  if outModules.isNil or capacity < cint(QrMaxModules):
    setError("output buffer must hold " & $QrMaxModules & " bytes")
    return QrStatus.qrBufferTooSmall.ord
  if text.isNil or text.len == 0:
    setError("payload is empty")
    return QrStatus.qrBadInput.ord

  let level = requestedLevel(ecLevel)

  try:
    let matrix = encodeMatrix($text, level)
    let count = matrix.width * matrix.height
    if count > QrMaxModules:
      setError("encoded symbol exceeds " & $QrMaxModules & " modules")
      return QrStatus.qrEncoderFailure.ord

    for y in 0 ..< matrix.height:
      let row = y * matrix.width
      for x in 0 ..< matrix.width:
        moduleStore[row + x] = if matrix[x, y]: 1'u8 else: 0'u8
    copyMem(outModules, moduleStore[0].addr, count)

    if not outWidth.isNil: outWidth[] = cint(matrix.width)
    if not outHeight.isNil: outHeight[] = cint(matrix.height)
    clearError()
    QrStatus.qrOk.ord
  except CatchableError as error:
    setError(error.msg)
    QrStatus.qrTooLong.ord

proc bcQrSvg*(text: cstring, ecLevel: cint, scale: cint, border: cint,
              dark: cstring, light: cstring, outSvg: ptr char,
              capacity: cint, outNeeded: ptr cint): cint
              {.exportc: "bc_qr_svg".} =
  ## Encodes UTF-8 `text` as a Model 2 QR symbol and renders it with
  ## openparser's SVG renderer.
  ##
  ## `scale` is the pixel size of one module (at least 1) and `border` the
  ## quiet zone in modules (at least 0). `dark` / `light` are CSS colors for
  ## dark and light modules; a nil or empty value selects the defaults
  ## (`#000000` and `none`, i.e. a transparent background).
  ##
  ## The SVG document is written NUL-terminated into the caller-owned
  ## `outSvg` buffer and its full byte length including the terminator is
  ## reported through `outNeeded`, which may be nil. Pass nil for `outSvg`
  ## (or a buffer that is too small) to query the required size: nothing is
  ## written and `qrBufferTooSmall` is returned.
  ##
  ## Synchronous, main thread only. Returns a `QrStatus` ordinal.
  if text.isNil or text.len == 0:
    setError("payload is empty")
    return QrStatus.qrBadInput.ord
  if scale < 1 or border < 0:
    setError("scale must be positive and border must not be negative")
    return QrStatus.qrBadInput.ord

  try:
    let matrix = encodeMatrix($text, requestedLevel(ecLevel))
    let darkColor = if dark.isNil or dark.len == 0: "#000000" else: $dark
    let lightColor = if light.isNil or light.len == 0: "none" else: $light
    let svg = matrix.toSvg(scale = int(scale), border = int(border),
                            dark = darkColor, light = lightColor)
    let needed = svg.len + 1
    if not outNeeded.isNil: outNeeded[] = cint(needed)
    if outSvg.isNil or capacity < cint(needed):
      setError("output buffer must hold " & $needed & " bytes")
      return QrStatus.qrBufferTooSmall.ord

    copyMem(outSvg, svg[0].addr, svg.len)
    cast[ptr UncheckedArray[char]](outSvg)[svg.len] = '\0'
    clearError()
    QrStatus.qrOk.ord
  except CatchableError as error:
    setError(error.msg)
    QrStatus.qrTooLong.ord