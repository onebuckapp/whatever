# feed_api — feed subscriptions and cached articles C ABI.
#
# A separate Boogie `feeds` store holds subscriptions, normalized feed metadata,
# cached articles, and persisted media bytes. The service owns the store; the
# app only sees JSON through the two-phase buffer protocol.
#
# Networking stays outside this module. Swift downloads page, feed, favicon,
# and thumbnail bytes with `URLSession`, then hands validated payloads here for
# parsing, normalization, deduplication, persistence, and retrieval. That keeps
# credentials, redirects, conditional requests, image decoding, and timeouts in
# the app process, and keeps this synchronous API free of outbound I/O.
#
# openparser supplies the document parsing:
#   * `openparser/rss` for RSS 2.0 payloads,
#   * `openparser/feed` for Atom payloads,
#   * `openparser/html` for explicitly supplied page-source fallback discovery.
# Strict parsers run first. A lenient projection follows when a real-world feed
# omits nominally required metadata, because rejecting an otherwise readable
# feed would make discovery dishonest.
#
# Ownership, threading and sync: see api/abi.nim.

import std/[algorithm, base64, options, sequtils, strutils, tables, times, unicode, uri, xmlparser, xmltree]
import openparser/json
import openparser/rss
import openparser/feed
import openparser/html
import boogie/stores/rdbms
import ../storage/database
import ../storage/schema
import ./abi
import ./settings_api

const
  ## Rejects an absurd download before parsing it. A feed large enough to need
  ## more room is an abuse case, not a reading list.
  MaxFeedBodyBytes = 2 * 1024 * 1024

  ## One explicitly supplied page source for fallback discovery is subject to
  ## the same bound. Live DOM discovery does not download the page at all.
  MaxDiscoveryHtmlBytes = 2 * 1024 * 1024

  ## Upper bound on discovery links retained from one document, in document
  ## order. A page declaring more is almost certainly generated noise.
  MaxDiscoveryCandidates = 8

  ## Longest accepted URL or page source reference. Longer values are rejected
  ## rather than truncated, because truncation creates a different address.
  MaxUrlChars = 2048

  ## Retained articles per subscription. New arrivals displace the oldest rows;
  ## read and saved state never displaces anything on its own.
  MaxArticlesPerFeed = 200

  ## Bounds for an explicit retention request. One article would turn a reader
  ## into a headline ticker; thousands would turn a store write into a cleanup
  ## operation of its own.
  MinPruneArticles = 1
  MaxPruneArticles = 5000

  ## Upper bound for one article listing. The reader pages through older rows
  ## with a publication cursor.
  MaxArticleResults = 500

  ## Encoded-image bounds. Boogie has text rather than binary columns, so bytes
  ## travel as Base64. These limits are on the encoded payload, not the decoded
  ## image, because the encoded form is what the store has to hold.
  MaxThumbnailEncodedBytes = 350_000
  MaxFaviconEncodedBytes = 90_000

  AllowedThumbnailMimes = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  AllowedFaviconMimes = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/x-icon"]

type
  FeedFormat = enum
    ffUnknown, ffRss, ffAtom

  FeedCandidate = object
    url: string
    title: string
    mime: string
    format: FeedFormat

  NormalizedMedia = object
    remoteUrl: string
    mime: string
    width: int64
    height: int64
    source: string

  NormalizedEntry = object
    guid: string
    link: string
    title: string
    authors: seq[string]
    publishedAt: int64
    updatedAt: int64
    publishedRaw: string
    summaryText: string
    summaryHtml: string
    contentText: string
    contentHtml: string
    media: NormalizedMedia
    hasMedia: bool

  NormalizedFeed = object
    format: FeedFormat
    title: string
    siteUrl: string
    iconUrl: string
    description: string
    entries: seq[NormalizedEntry]

# MARK: - Small validation helpers

proc requiredText(value: cstring, name: string): string =
  if value.isNil or ($value).strip.len == 0:
    setError(name & " is required")
    return ""
  ($value).strip

proc optionalText(value: cstring): string =
  if value.isNil:
    return ""
  ($value).strip

proc validFlag(value: int32, name: string): bool =
  if value != 0'i32 and value != 1'i32:
    setError(name & " must be 0 or 1")
    return false
  true

proc asciiPrintable(input: string): bool =
  for ch in input:
    if ord(ch) < 0x20 or ord(ch) == 0x7f:
      return false
  true

proc isHttpScheme(scheme: string): bool =
  scheme == "http" or scheme == "https"

proc normalizeUri(uri: Uri): string =
  var cleaned = uri
  cleaned.scheme = cleaned.scheme.toLowerAscii()
  cleaned.hostname = cleaned.hostname.toLowerAscii()
  cleaned.username = ""
  cleaned.password = ""
  if (cleaned.scheme == "http" and cleaned.port == "80") or
     (cleaned.scheme == "https" and cleaned.port == "443"):
    cleaned.port = ""
  cleaned.anchor = ""
  $cleaned

proc normalizeUrl(raw: string, base = ""): string =
  ## Absolute HTTP(S) URL, or the empty string when `raw` is not acceptable.
  ##
  ## Credentials are stripped because a subscription id must not retain a
  ## password. Fragments are stripped because they address a location inside a
  ## document rather than a different feed or article. Queries are preserved
  ## because many feeds and images require them.
  var text = raw.strip
  if text.len == 0 or text.len > MaxUrlChars or not asciiPrintable(text):
    return ""
  let lowered = text.toLowerAscii()
  for prefix in ["javascript:", "data:", "blob:", "file:", "about:", "mailto:"]:
    if lowered.startsWith(prefix):
      return ""
  if lowered.startsWith("feed:"):
    text = text[5 .. ^1].strip
    if text.len == 0:
      return ""
  if text.startsWith("//"):
    let baseScheme = if base.len > 0: parseUri(base).scheme.toLowerAscii() else: ""
    text = (if baseScheme.len > 0: baseScheme else: "https") & ":" & text
  let target = parseUri(text)
  var combined = target
  if not target.isAbsolute:
    if base.len == 0:
      return ""
    let baseUri = parseUri(base)
    if not isHttpScheme(baseUri.scheme.toLowerAscii()) or baseUri.hostname.len == 0:
      return ""
    combined = combine(baseUri, target)
  if not isHttpScheme(combined.scheme.toLowerAscii()) or combined.hostname.len == 0:
    return ""
  if combined.port.len > 0:
    try:
      let port = parseInt(combined.port)
      if port < 1 or port > 65535:
        return ""
    except ValueError:
      return ""
  normalizeUri(combined)

proc hostOfUrl(url: string): string =
  parseUri(url).hostname.toLowerAscii()

proc formatName(format: FeedFormat): string =
  case format
  of ffRss: "rss"
  of ffAtom: "atom"
  else: "unknown"

proc formatOfMime(mime: string): FeedFormat =
  let mediaType = mime.strip.toLowerAscii.split(';')[0].strip
  case mediaType
  of "application/rss+xml", "application/rss", "text/rss":
    ffRss
  of "application/atom+xml", "application/atom":
    ffAtom
  of "application/rdf+xml":
    ffRss
  else:
    ffUnknown

proc stableIdentity(parts: openArray[string]): string =
  ## Deterministic fallback identity when a feed supplies neither a GUID nor a
  ## usable link. Two FNV-1a lanes are enough here because this only has to be
  ## stable inside one subscription, not globally unique.
  var first = 0xcbf29ce484222325'u64
  var second = 0x84222325cbf29ce4'u64
  for part in parts:
    for ch in part:
      first = (first xor uint64(ord(ch))) * 0x100000001b3'u64
      second = (second xor (uint64(ord(ch)) + 0x9e3779b97f4a7c15'u64)) * 0x100000001b3'u64
  "hash-" & first.toHex(16).toLowerAscii & second.toHex(16).toLowerAscii

# MARK: - Row helpers

proc feedTables(db: var Database): tuple[subscriptions: DbTable, articles: DbTable] =
  let subscriptions = db.feeds.getTable(FeedSubscriptionsTable).get()
  let articles = db.feeds.getTable(FeedArticlesTable).get()
  (subscriptions, articles)

proc cellText(data: RowData, key: string): string =
  if not tables.hasKey(data, key):
    return ""
  let value = tables.`[]`(data, key)
  if value.kind == dtText: value.strVal else: ""

proc cellInt(data: RowData, key: string): int64 =
  if not tables.hasKey(data, key):
    return 0'i64
  let value = tables.`[]`(data, key)
  if value.kind == dtInt: value.intVal else: 0'i64

proc cellBool(data: RowData, key: string): bool =
  if not tables.hasKey(data, key):
    return false
  let value = tables.`[]`(data, key)
  if value.kind == dtBool: value.boolVal else: false

proc cellJsonStrings(data: RowData, key: string): seq[string] =
  if not tables.hasKey(data, key):
    return @[]
  let value = tables.`[]`(data, key)
  if value.kind != dtJson:
    return @[]
  try:
    for item in parseJson(value.jsonVal).items:
      if item.kind == JString:
        result.add(item.getStr)
  except CatchableError:
    discard

proc existingSubscription(table: DbTable, feedUrl: string): tuple[found: bool, pk: string, data: RowData] =
  for row in table.where("feedURL", newTextValue(feedUrl)):
    return (true, row[0], row[1])
  (false, "", initOrderedTable[string, Value]())

proc nowSeconds(): int64 =
  int64(epochTime())

proc articleSortKey(id: int64, publishedAt, fetchedAt: int64): tuple[published: int64, fetched: int64, id: int64] =
  (publishedAt, fetchedAt, id)

proc pruneArticles(db: var Database, articles: DbTable, feedUrl: string, maximum: int)

# MARK: - Dates

proc parseRfc3339Time(text: string): int64 =
  var cleaned = text.strip
  if cleaned.len == 0:
    return 0'i64
  # A fractional second is valid RFC 3339 but irrelevant to article ordering.
  # Removing it keeps one parser shape instead of a family of them.
  let tPos = cleaned.find('T')
  if tPos < 0:
    # A bare date is midnight UTC, which is also how a missing time should read.
    if cleaned.len == 10 and cleaned[4] == '-' and cleaned[7] == '-':
      cleaned.add("T00:00:00Z")
    else:
      return 0'i64
  else:
    var endPos = tPos + 1
    while endPos < cleaned.len and (cleaned[endPos].isDigit or cleaned[endPos] == ':'):
      inc endPos
    if endPos < cleaned.len and cleaned[endPos] == '.':
      var fractionEnd = endPos + 1
      while fractionEnd < cleaned.len and cleaned[fractionEnd].isDigit:
        inc fractionEnd
      cleaned = cleaned[0 ..< endPos] & cleaned[fractionEnd .. ^1]
    if cleaned.endsWith("Z") or cleaned.endsWith("z"):
      cleaned = cleaned[0 .. ^2] & "+00:00"
    elif cleaned.len >= 5 and cleaned[^3] != ':' and
         (cleaned[^5] == '+' or cleaned[^5] == '-'):
      cleaned = cleaned[0 .. ^3] & ":" & cleaned[^2 .. ^1]
  try:
    return parse(cleaned, "yyyy-MM-dd'T'HH:mm:sszzz").toTime.toUnix
  except TimeParseError:
    discard
  try:
    return parse(cleaned, "yyyy-MM-dd'T'HH:mm:ss").toTime.toUnix
  except TimeParseError:
    discard
  0'i64

proc parseRfc822Time(text: string): int64 =
  ## Handles both comma and hyphen separators and both numeric and common named
  ## zones. Real feeds use all of these.
  var cleaned = text.strip
  if cleaned.len == 0:
    return 0'i64
  let upper = cleaned.toUpperAscii()
  if upper.endsWith(" GMT") or upper.endsWith(" UT") or upper.endsWith(" UTC"):
    cleaned = cleaned[0 ..< cleaned.rfind(' ')] & " +0000"
  for pattern in ["ddd, dd MMM yyyy HH:mm:ss ZZZ", "ddd, dd-MMM-yyyy HH:mm:ss ZZZ"]:
    try:
      return parse(cleaned, pattern).toTime.toUnix
    except TimeParseError:
      discard
  0'i64

proc parseFeedTime(raw: string): int64 =
  let text = raw.strip
  if text.len == 0:
    return 0'i64
  if text.allIt(it.isDigit or (it == '-' and text.len > 0)):
    try:
      let seconds = parseBiggestInt(text)
      if seconds > 0 and seconds < 4102444800:
        return seconds
    except ValueError:
      discard
  let rfc3339 = parseRfc3339Time(text)
  if rfc3339 > 0:
    return rfc3339
  parseRfc822Time(text)

# MARK: - Text and markup helpers

proc at(text: string, index: int, prefix: string): bool =
  index >= 0 and index + prefix.len <= text.len and
    text[index ..< index + prefix.len] == prefix

proc decodeEntities(text: string): string =
  result = text
  for (entity, replacement) in [
    ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
    ("&apos;", "'"), ("&nbsp;", " ")
  ]:
    result = result.replace(entity, replacement)
  var start = result.find("&#")
  while start >= 0:
    let stop = result.find(';', start + 2)
    if stop < 0 or stop - start > 10:
      break
    let body = result[start + 2 ..< stop]
    var code = -1
    if body.len > 1 and (body[0] == 'x' or body[0] == 'X'):
      try: code = parseHexInt(body[1 .. ^1]) except ValueError: discard
    else:
      try: code = parseInt(body) except ValueError: discard
    if code >= 32 and code <= 0x10FFFF and code notin 0xD800 .. 0xDFFF:
      result = result[0 ..< start] & $Rune(code) & result[stop + 1 .. ^1]
      start = result.find("&#", start + 1)
    else:
      start = result.find("&#", stop + 1)

proc stripMarkup(html: string): string =
  ## Conservative tag stripper for summaries and content excerpts. It does not
  ## try to understand scripts, styles, comments, or malformed markup perfectly;
  ## those regions are skipped rather than emitted as text.
  ##
  ## CDATA sections are content, not markup: their payload flows inline with
  ## no word separator (a `<b>` splits words, but `<![CDATA[foo]]>` IS the
  ## word). The payload itself is markup again — descriptions routinely wrap
  ## HTML in CDATA — so it recurses through this same stripper instead of
  ## emitting raw. Entities therefore decode inside descriptions exactly as
  ## they do outside them; a payload without any `>` no longer swallows the
  ## whole description the way the old find-the-next-`>` skip did.
  var text = newStringOfCap(html.len)
  var run = newStringOfCap(64)
  proc flushRun() =
    ## Entities decode per text run, outside CDATA only.
    if run.len > 0:
      text.add(decodeEntities(run))
      run.setLen(0)
  proc separate() =
    if text.len == 0 or text[^1] != ' ':
      text.add(' ')
  var i = 0
  while i < html.len:
    if html[i] == '<':
      if at(html, i, "<![CDATA["):
        flushRun()
        let stop = html.find("]]>", i + 9)
        if stop < 0:
          text.add(stripMarkup(html[i + 9 .. ^1]))
          break
        text.add(stripMarkup(html[i + 9 ..< stop]))
        i = stop + 3
      elif at(html, i, "<!--"):
        flushRun()
        let stop = html.find("-->", i + 4)
        i = if stop < 0: html.len else: stop + 3
        separate()
      elif at(html, i, "<script") or at(html, i, "<SCRIPT") or
           at(html, i, "<style") or at(html, i, "<STYLE"):
        flushRun()
        let tagEnd = html.find('>', i + 1)
        if tagEnd < 0:
          break
        let closing = if html[i + 1] == 's' or html[i + 1] == 'S': "</script" else: "</style"
        let stop = html.toLowerAscii.find(closing, tagEnd + 1)
        i = if stop < 0: html.len else: html.find('>', stop) + 1
        separate()
      else:
        flushRun()
        let stop = html.find('>', i + 1)
        i = if stop < 0: html.len else: stop + 1
        separate()
    else:
      run.add(html[i])
      inc i
  flushRun()
  strutils.splitWhitespace(text).join(" ").strip

proc innerXml(node: XmlNode): string =
  ## Markup inside `node` without its own outer tags, so an RSS description or
  ## Atom XHTML payload can be retained verbatim while `innerText` supplies the
  ## plain-text excerpt.
  let outer = $node
  let start = outer.find('>')
  let stop = outer.rfind('<')
  if start < 0 or stop < 0 or stop <= start:
    return ""
  outer[start + 1 ..< stop]

proc localTagName(tag: string): string =
  let name = tag.strip.toLowerAscii
  let colon = name.rfind(':')
  if colon >= 0 and colon + 1 < name.len: name[colon + 1 .. ^1] else: name

proc childElements(parent: XmlNode): seq[XmlNode] =
  if parent.isNil:
    return @[]
  for child in parent:
    if child.kind == xnElement:
      result.add(child)

proc firstNamedChild(parent: XmlNode, names: openArray[string]): XmlNode =
  for child in childElements(parent):
    if localTagName(child.tag) in names:
      return child
  nil

proc richText(node: XmlNode): string =
  ## CDATA-aware text extraction. Stdlib `innerText` returns "" for `xnCData`,
  ## which silently drops every title, link, and description a publisher wraps
  ## in `<![CDATA[…]]>`; the article then falls back to showing its URL as its
  ## title. Text, entity, and CDATA children all count as content here, while
  ## comments stay excluded exactly like `innerText` excludes them.
  if node.isNil:
    return ""
  case node.kind
  of xnText, xnVerbatimText, xnEntity, xnCData:
    node.text
  of xnElement:
    var text = newStringOfCap(64)
    for child in node:
      text.add(richText(child))
    text
  else:
    ""

proc childText(parent: XmlNode, names: openArray[string]): string =
  let node = firstNamedChild(parent, names)
  if node.isNil: "" else: richText(node).strip

proc allNamedDescendants(parent: XmlNode, names: openArray[string]): seq[XmlNode] =
  if parent.isNil:
    return @[]
  for child in childElements(parent):
    if localTagName(child.tag) in names:
      result.add(child)
    result.add(allNamedDescendants(child, names))

proc attributeValue(node: XmlNode, name: string): string =
  if node.isNil:
    return ""
  # Feed attribute names are conventionally lowercase, so direct access is both
  # correct and fast. The lowercase fallback tolerates the occasional document
  # that shouts its attribute names.
  let direct = node.attr(name).strip
  if direct.len > 0:
    return direct
  node.attr(name.toLowerAscii).strip

proc linkHref(node: XmlNode): string =
  let href = attributeValue(node, "href")
  if href.len > 0:
    return href
  attributeValue(node, "url")

proc chooseAlternateLink(parent: XmlNode): string =
  ## Prefers an explicit alternate HTML link, then an untyped link, then any
  ## link. Feed documents routinely carry self, edit, and hub links alongside
  ## the article address; taking the first link blindly is how readers open API
  ## endpoints.
  var fallback = ""
  for child in childElements(parent):
    if localTagName(child.tag) != "link":
      continue
    let href = linkHref(child)
    if href.len == 0:
      continue
    let rel = attributeValue(child, "rel").toLowerAscii
    if rel == "" or rel == "alternate":
      return href
    if fallback.len == 0:
      fallback = href
  fallback

proc htmlImageSources(node: HtmlNode): seq[string]
proc allNamedDescendantsImage(document: HtmlDocument): seq[string]
proc firstContentImage(htmlText, baseUrl: string): NormalizedMedia
proc allNamedDescendantsHtml(node: HtmlNode, tags: openArray[HtmlTag]): seq[HtmlNode]
proc entryThumbnail(node: XmlNode, baseUrl: string): NormalizedMedia =
  for child in allNamedDescendants(node, ["thumbnail", "content", "enclosure"]):
    # `localTagName` collapses namespaces, so confirm the media shape from the
    # full tag before treating a generic `content` node as an image.
    let tag = child.tag.toLowerAscii
    let isMediaContent = tag == "media:content" or tag == "media:thumbnail"
    let isEnclosure = localTagName(tag) == "enclosure"
    if not (isMediaContent or isEnclosure):
      continue
    let remote = normalizeUrl(linkHref(child), baseUrl)
    if remote.len == 0:
      continue
    let mime = attributeValue(child, "type").toLowerAscii.split(';')[0].strip
    if child.tag.toLowerAscii == "media:thumbnail" or
       (mime.len > 0 and mime.startsWith("image/")):
      var width, height = 0'i64
      try: width = parseBiggestInt(attributeValue(child, "width")) except ValueError: discard
      try: height = parseBiggestInt(attributeValue(child, "height")) except ValueError: discard
      return NormalizedMedia(
        remoteUrl: remote,
        mime: mime,
        width: max(width, 0'i64),
        height: max(height, 0'i64),
        source: if isEnclosure: "enclosure" else: "media"
      )
  NormalizedMedia()

proc htmlImageSources(node: HtmlNode): seq[string] =
  if node.isNil or node.kind != htmlTag:
    return @[]
  if node.tag == tagImg and not node.attributes.isNil:
    for name, value in tables.pairs(node.attributes):
      if name.toLowerAscii in ["src", "data-src"] and value.strip.len > 0:
        result.add(value.strip)
        break
  for child in node.children:
    result.add(htmlImageSources(child))

proc allNamedDescendantsImage(document: HtmlDocument): seq[string] =
  for node in document.nodes:
    result.add(htmlImageSources(node))

proc firstContentImage(htmlText, baseUrl: string): NormalizedMedia =
  if htmlText.strip.len == 0:
    return NormalizedMedia()
  try:
    let document = parseHtml(htmlText)
    for image in allNamedDescendantsImage(document):
      let remote = normalizeUrl(image, baseUrl)
      if remote.len > 0:
        return NormalizedMedia(remoteUrl: remote, source: "content")
  except CatchableError:
    discard
  NormalizedMedia()

proc authorsText(authors: seq[string]): JsonNode =
  result = newJArray()
  for author in authors:
    if author.strip.len > 0:
      result.add(newJString(author.strip))

# MARK: - Feed discovery from supplied HTML

proc attributeText(node: HtmlNode, name: string): string =
  if node.isNil or node.attributes.isNil:
    return ""
  let wanted = name.toLowerAscii
  for key, value in tables.pairs(node.attributes):
    if key.toLowerAscii == wanted:
      return value.strip
  ""

proc documentTitle(document: HtmlDocument): string =
  for node in document.nodes:
    if node.kind != htmlTag:
      continue
    for title in allNamedDescendantsHtml(node, @[tagTitle]):
      let text = title.innerText.strip
      if text.len > 0:
        return text
  ""

proc allNamedDescendantsHtml(node: HtmlNode, tags: openArray[HtmlTag]): seq[HtmlNode] =
  if node.isNil or node.kind != htmlTag:
    return @[]
  if node.tag in tags:
    result.add(node)
  for child in node.children:
    result.add(allNamedDescendantsHtml(child, tags))

proc discoverCandidates(document: HtmlDocument, pageUrl: string): seq[FeedCandidate] =
  let fallbackTitle = documentTitle(document)
  for node in document.nodes:
    if node.kind != htmlTag:
      continue
    for link in allNamedDescendantsHtml(node, @[tagLink]):
      let rel = strutils.splitWhitespace(attributeText(link, "rel").toLowerAscii)
      if "alternate" notin rel:
        continue
      let mime = attributeText(link, "type").split(';')[0].strip
      if formatOfMime(mime) == ffUnknown:
        continue
      let url = normalizeUrl(attributeText(link, "href"), pageUrl)
      if url.len == 0:
        continue
      var title = attributeText(link, "title")
      if title.len == 0:
        title = fallbackTitle
      let candidate = FeedCandidate(
        url: url,
        title: title,
        mime: mime.toLowerAscii,
        format: formatOfMime(mime)
      )
      if candidate notin result:
        result.add(candidate)
      if result.len >= MaxDiscoveryCandidates:
        return result

proc feedDiscoverFromHtml*(pageUrl: cstring, html: cstring, buffer: ptr char,
                           capacity: int32, needed: ptr int32): int32 {.exportc: "bc_feed_discover_from_html".} =
  ## Candidate feeds declared by explicitly supplied page source.
  ##
  ## The live browser path should prefer the rendered DOM, which already knows
  ## the base URL, executed scripts, and dynamically injected links. This entry
  ## point exists for manual subscription flows and recovery paths, where
  ## downloading the page again is the user's explicit choice rather than a
  ## background side effect.
  let page = requiredText(pageUrl, "page url")
  if page.len == 0:
    return ErrBadInput
  let source = requiredText(html, "html")
  if source.len == 0:
    return ErrBadInput
  if source.len > MaxDiscoveryHtmlBytes:
    setError("page source is too large: " & $source.len & " bytes")
    return ErrBadInput
  let normalizedPage = normalizeUrl(page)
  if normalizedPage.len == 0:
    setError("page url is not a supported HTTP(S) address")
    return ErrBadInput
  var document = newJArray()
  let status = catchingStore("discover feeds from html"):
    let parsed = parseHtml(source)
    for candidate in discoverCandidates(parsed, normalizedPage):
      document.add(%*{
        "url": candidate.url,
        "title": candidate.title,
        "type": candidate.mime,
        "format": formatName(candidate.format),
      })
    Ok
  if status != Ok:
    return status
  var envelope = newJObject()
  envelope["pageURL"] = newJString(normalizedPage)
  envelope["candidates"] = document
  emitJson(envelope, buffer, capacity, needed)

# MARK: - Subscription storage

proc subscriptionRow(feedUrl, pageUrl, siteHost, siteName, format, title,
                     declaredTitle, declaredType: string,
                     subscribedAt: int64): RowData =
  rdbms.row([
    ("feedURL", newTextValue(feedUrl)),
    ("pageURL", newTextValue(pageUrl)),
    ("siteHost", newTextValue(siteHost)),
    ("siteName", newTextValue(siteName)),
    ("feedFormat", newTextValue(format)),
    ("feedTitle", newTextValue(title)),
    ("declaredTitle", newTextValue(declaredTitle)),
    ("declaredType", newTextValue(declaredType)),
    ("faviconRemoteURL", newNullValue()),
    ("faviconMime", newNullValue()),
    ("faviconImageBase64", newNullValue()),
    ("subscribedAt", newIntValue(subscribedAt)),
    ("lastCheckedAt", newNullValue()),
    ("lastETag", newNullValue()),
    ("lastModified", newNullValue()),
    ("lastStatus", newTextValue("subscribed")),
    ("lastError", newNullValue()),
    ("autoRefreshEnabled", newBoolValue(true)),
  ])

proc feedSubscribe*(feedUrl: cstring, pageUrl: cstring, siteName: cstring,
                    declaredTitle: cstring, declaredType: cstring,
                    subscribedAt: int64): int32 {.exportc: "bc_feed_subscribe".} =
  ## Records a subscription without fetching anything. Fetching is a separate,
  ## explicit call because subscribing must not imply network activity on its
  ## own: the reader decides when a refresh is due, and private contexts can
  ## decline to subscribe at all.
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let page = requiredText(pageUrl, "page url")
  if page.len == 0:
    return ErrBadInput
  let normalizedFeed = normalizeUrl(feed)
  let normalizedPage = normalizeUrl(page)
  if normalizedFeed.len == 0 or normalizedPage.len == 0:
    setError("feed and page urls must be supported HTTP(S) addresses")
    return ErrBadInput
  let title = optionalText(declaredTitle)
  let mime = optionalText(declaredType).split(';')[0].strip.toLowerAscii
  let suppliedSite = optionalText(siteName)
  let stamp = if subscribedAt > 0: subscribedAt else: nowSeconds()
  var db = storeRef()
  catchingStore("subscribe to feed"):
    let (subscriptions, _) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalizedFeed)
    let siteHost = hostOfUrl(normalizedPage)
    let fallbackHost = if siteHost.len > 0: siteHost else: hostOfUrl(normalizedFeed)
    let siteDisplay = if suppliedSite.len > 0: suppliedSite else: fallbackHost
    if existing.found:
      # A second discovery of the same feed must converge on the existing row,
      # refreshing its context without resetting subscription age or read state.
      var refreshed = existing.data
      refreshed["pageURL"] = newTextValue(normalizedPage)
      refreshed["siteHost"] = newTextValue(siteHost)
      if suppliedSite.len > 0:
        refreshed["siteName"] = newTextValue(suppliedSite)
      if title.len > 0:
        refreshed["declaredTitle"] = newTextValue(title)
      if mime.len > 0:
        refreshed["feedFormat"] = newTextValue(formatName(formatOfMime(mime)))
        refreshed["declaredType"] = newTextValue(mime)
      discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
      db.feeds.insertRow(FeedSubscriptionsTable, existing.pk, refreshed)
    else:
      db.feeds.insertRow(FeedSubscriptionsTable, normalizedFeed, subscriptionRow(
        normalizedFeed, normalizedPage, siteHost, siteDisplay,
        formatName(formatOfMime(mime)), siteDisplay, title, mime, stamp
      ))
    Ok

proc deleteArticlesForFeed(db: var Database, articles: DbTable, feedUrl: string) =
  ## Foreign keys are RESTRICT-only, so articles go first. Primary keys are
  ## collected before deleting because the store cannot be mutated mid-walk.
  var doomed: seq[string] = @[]
  for row in articles.where("feedURL", newTextValue(feedUrl)):
    doomed.add(row[0])
  for pk in doomed:
    discard db.feeds.deleteRow(FeedArticlesTable, pk)

proc feedUnsubscribe*(feedUrl: cstring): int32 {.exportc: "bc_feed_unsubscribe".} =
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalized = normalizeUrl(feed)
  if normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  var db = storeRef()
  catchingStore("unsubscribe from feed"):
    let (subscriptions, articles) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalized)
    if not existing.found:
      return ErrNotFound
    deleteArticlesForFeed(db, articles, normalized)
    discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
    Ok

proc feedPrune*(feedUrl: cstring, maximumArticles: int32): int32 {.exportc: "bc_feed_prune".} =
  ## Retains the newest `maximumArticles` rows for one subscription and deletes
  ## the rest, children-first by publication order. Retention preferences can
  ## therefore be applied after ingestion without reopening or re-downloading a
  ## feed.
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalized = normalizeUrl(feed)
  if normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  if maximumArticles < MinPruneArticles or maximumArticles > MaxPruneArticles:
    setError("maximum articles must be between 1 and 5000")
    return ErrBadInput
  var db = storeRef()
  catchingStore("prune feed articles"):
    let (subscriptions, articles) = feedTables(db)
    if not existingSubscription(subscriptions, normalized).found:
      return ErrNotFound
    pruneArticles(db, articles, normalized, maximumArticles.int)
    Ok

proc subscriptionJson(db: var Database, pk: string, data: RowData): JsonNode =
  let articles = feedTables(db)[1]
  var total = 0
  var unread = 0
  for row in articles.where("feedURL", newTextValue(cellText(data, "feedURL"))):
    inc total
    if not cellBool(row[1], "isRead"):
      inc unread
  %*{
    "feedURL": cellText(data, "feedURL"),
    "pageURL": cellText(data, "pageURL"),
    "siteHost": cellText(data, "siteHost"),
    "siteName": cellText(data, "siteName"),
    "feedFormat": cellText(data, "feedFormat"),
    "feedTitle": cellText(data, "feedTitle"),
    "declaredTitle": cellText(data, "declaredTitle"),
    "declaredType": cellText(data, "declaredType"),
    "faviconRemoteURL": cellText(data, "faviconRemoteURL"),
    "faviconMime": cellText(data, "faviconMime"),
    "hasFavicon": cellText(data, "faviconImageBase64").len > 0,
    "subscribedAt": cellInt(data, "subscribedAt"),
    "lastCheckedAt": cellInt(data, "lastCheckedAt"),
    "lastETag": cellText(data, "lastETag"),
    "lastModified": cellText(data, "lastModified"),
    "lastStatus": cellText(data, "lastStatus"),
    "lastError": cellText(data, "lastError"),
    "autoRefreshEnabled": cellBool(data, "autoRefreshEnabled"),
    "articleCount": total,
    "unreadCount": unread,
  }

proc feedSubscriptions*(buffer: ptr char, capacity: int32, needed: ptr int32): int32 {.exportc: "bc_feed_subscriptions".} =
  var db = storeRef()
  var document = newJArray()
  let status = catchingStore("list feed subscriptions"):
    let (subscriptions, _) = feedTables(db)
    var rows: seq[tuple[subscribed: int64, entry: JsonNode]] = @[]
    for row in rdbms.allRows(subscriptions):
      rows.add((cellInt(row[1], "subscribedAt"), subscriptionJson(db, row[0], row[1])))
    rows.sort(proc(a, b: tuple[subscribed: int64, entry: JsonNode]): int =
      cmp(b.subscribed, a.subscribed))
    for row in rows:
      document.add(row.entry)
    Ok
  if status != Ok:
    return status
  emitJson(document, buffer, capacity, needed)

# MARK: - Feed document parsing

proc rootTagName(payload: string): string =
  ## The first element's local name, skipping declarations, comments, doctypes,
  ## and a UTF-8 BOM. Sniffing avoids trusting either the HTTP content type or
  ## the file extension, both of which feeds routinely get wrong.
  var i = 0
  if at(payload, 0, "\xEF\xBB\xBF"):
    i = 3
  while i < payload.len:
    if payload[i] in {' ', '\t', '\r', '\n'}:
      inc i
    elif at(payload, i, "<!--"):
      let stop = payload.find("-->", i + 4)
      if stop < 0:
        return ""
      i = stop + 3
    elif at(payload, i, "<?"):
      let stop = payload.find("?>", i + 2)
      if stop < 0:
        return ""
      i = stop + 2
    elif at(payload, i, "<!"):
      let stop = payload.find('>', i + 2)
      if stop < 0:
        return ""
      i = stop + 1
    else:
      break
  if i >= payload.len or payload[i] != '<':
    return ""
  inc i
  if i < payload.len and payload[i] == '/':
    return ""
  let start = i
  while i < payload.len and payload[i] notin {' ', '\t', '\r', '\n', '/', '>'}:
    inc i
  localTagName(payload[start ..< i])

proc normalizeEntryDate(raw: string): tuple[unix: int64, text: string] =
  let cleaned = raw.strip
  (parseFeedTime(cleaned), cleaned)

proc normalizeAuthors(values: seq[string]): seq[string] =
  for value in values:
    let cleaned = value.strip
    if cleaned.len > 0 and cleaned notin result:
      result.add(cleaned)

proc mediaJson(media: NormalizedMedia, hasBytes: bool): JsonNode =
  %*{
    "remoteURL": media.remoteUrl,
    "mime": media.mime,
    "width": media.width,
    "height": media.height,
    "source": media.source,
    "hasBytes": hasBytes,
  }

proc chooseThumbnail(candidates: seq[NormalizedMedia]): NormalizedMedia =
  ## Prefers publisher-declared media over scraped content images, and larger
  ## declared dimensions within the same source. A card thumbnail is a filing
  ## decision as much as a visual one: enclosures and media RSS are deliberate,
  ## while the first inline image may be a logo, spacer, or tracking-adjacent.
  for source in ["media", "enclosure", "content"]:
    var best = NormalizedMedia()
    var found = false
    for candidate in candidates:
      if candidate.source != source or candidate.remoteUrl.len == 0:
        continue
      if not found or candidate.width * candidate.height > best.width * best.height:
        best = candidate
        found = true
    if found:
      return best
  NormalizedMedia()

proc baseUrlForFeed(feedUrl, siteUrl: string): string =
  if siteUrl.len > 0: siteUrl else: feedUrl

proc strictRssEntries(feed: RssFeed, feedUrl, siteUrl: string): seq[NormalizedEntry] =
  let base = baseUrlForFeed(feedUrl, siteUrl)
  for item in feed.items:
    let guid = item.guid.get("").strip
    let link = normalizeUrl(item.link.get(""), base)
    let identity = if guid.len > 0: guid
      elif link.len > 0: link
      else: stableIdentity([feedUrl, item.title.get(""), item.description.get(""), item.pubDate.get("")])
    let (published, publishedRaw) = normalizeEntryDate(item.pubDate.get(""))
    result.add(NormalizedEntry(
      guid: identity,
      link: link,
      title: item.title.get("").strip,
      authors: @[],
      publishedAt: published,
      updatedAt: published,
      publishedRaw: publishedRaw,
      summaryText: stripMarkup(item.description.get("")),
      summaryHtml: item.description.get(""),
      media: NormalizedMedia(),
    ))

proc strictAtomEntries(feed: AtomFeed, feedUrl, siteUrl: string): seq[NormalizedEntry] =
  let base = baseUrlForFeed(feedUrl, siteUrl)
  for entry in feed.entries:
    var link = ""
    for candidate in entry.links:
      let rel = candidate.rel.get("alternate").toLowerAscii
      if candidate.href.strip.len > 0 and (rel == "" or rel == "alternate"):
        link = normalizeUrl(candidate.href, base)
        if link.len > 0:
          break
    let identity = if entry.id.strip.len > 0: entry.id.strip
      elif link.len > 0: link
      else: stableIdentity([feedUrl, entry.title.value, entry.updated, entry.published.get("")])
    let (published, publishedRaw) = normalizeEntryDate(entry.published.get(entry.updated))
    let (updated, _) = normalizeEntryDate(entry.updated)
    var authors: seq[string] = @[]
    for author in entry.authors:
      authors.add(author.name)
    for contributor in entry.contributors:
      authors.add(contributor.name)
    let summary = entry.summary.map(proc(text: AtomText): string = text.value).get("")
    let summaryKind = entry.summary.map(proc(text: AtomText): string = text.kind).get("text")
    let body = entry.content.flatMap(proc(content: AtomContent): Option[string] = content.value).get("")
    let bodyKind = entry.content.flatMap(proc(content: AtomContent): Option[string] = content.kind).get("text")
    let summaryHtml = if summaryKind.toLowerAscii in ["html", "xhtml"]: summary else: ""
    let bodyHtml = if bodyKind.toLowerAscii in ["html", "xhtml"]: body else: ""
    result.add(NormalizedEntry(
      guid: identity,
      link: link,
      title: entry.title.value.strip,
      authors: normalizeAuthors(authors),
      publishedAt: published,
      updatedAt: updated,
      publishedRaw: publishedRaw,
      summaryText: if summaryHtml.len > 0: stripMarkup(summary) else: summary.strip,
      summaryHtml: summaryHtml,
      contentText: if bodyHtml.len > 0: stripMarkup(body) else: body.strip,
      contentHtml: bodyHtml,
      media: NormalizedMedia(),
    ))

proc channelNode(document: XmlNode): XmlNode =
  for child in childElements(document):
    if localTagName(child.tag) == "channel":
      return child
  for child in childElements(document):
    let found = channelNode(child)
    if not found.isNil:
      return found
  nil

proc feedChannelTitle(document: XmlNode, root: string): string =
  let channel = if root == "rdf": channelNode(document) else: firstNamedChild(document, ["channel"])
  let target = if channel.isNil: document else: channel
  childText(target, ["title"])

proc feedSiteUrl(document: XmlNode, root, base: string): string =
  let channel = if root == "rdf": channelNode(document) else: firstNamedChild(document, ["channel"])
  let target = if channel.isNil: document else: channel
  if root == "feed":
    let href = chooseAlternateLink(target)
    if href.len > 0:
      return normalizeUrl(href, base)
  normalizeUrl(childText(target, ["link"]), base)

proc rawItemNodes(document: XmlNode, root: string): seq[XmlNode] =
  if root == "feed":
    return allNamedDescendants(document, ["entry"])
  if root == "rdf":
    # RDF/RSS 1.0 nests items beside the channel rather than inside it.
    return allNamedDescendants(document, ["item"])
  let channel = firstNamedChild(document, ["channel"])
  if channel.isNil:
    return @[]
  for child in childElements(channel):
    if localTagName(child.tag) == "item":
      result.add(child)

proc rawEntryAuthors(item: XmlNode): seq[string] =
  for child in childElements(item):
    case localTagName(child.tag)
    of "author", "creator", "name":
      let text = richText(child).strip
      if text.len > 0:
        result.add(text)
    else:
      discard
  normalizeAuthors(result)

proc rawEntryMedia(item: XmlNode, base: string): seq[NormalizedMedia] =
  let thumbnail = entryThumbnail(item, base)
  if thumbnail.remoteUrl.len > 0:
    result.add(thumbnail)

proc rawEntryHtml(item: XmlNode): tuple[summary: string, content: string] =
  let summary = firstNamedChild(item, ["description", "summary"])
  let body = firstNamedChild(item, ["encoded", "content"])
  if summary.isNil and body.isNil:
    result = (summary: "", content: "")
  elif body.isNil:
    result = (summary: innerXml(summary), content: "")
  elif summary.isNil:
    result = (summary: "", content: innerXml(body))
  else:
    result = (summary: innerXml(summary), content: innerXml(body))

proc lenientRssEntries(document: XmlNode, feedUrl, siteUrl: string): seq[NormalizedEntry] =
  let base = baseUrlForFeed(feedUrl, siteUrl)
  let items = rawItemNodes(document, "rss")
  let rdfItems = rawItemNodes(document, "rdf")
  for item in items & rdfItems:
    let guid = firstNamedChild(item, ["guid"])
    let guidText = if guid.isNil: "" else: guid.innerText.strip
    let link = normalizeUrl(childText(item, ["link"]), base)
    let title = childText(item, ["title"])
    let date = firstNamedChild(item, ["pubdate", "date", "updated", "published"])
    let (published, publishedRaw) = normalizeEntryDate(if date.isNil: "" else: date.innerText)
    let (summaryHtml, contentHtml) = rawEntryHtml(item)
    let summaryText = if summaryHtml.len > 0: stripMarkup(summaryHtml) else: ""
    let contentText = if contentHtml.len > 0: stripMarkup(contentHtml) else: ""
    let media = chooseThumbnail(rawEntryMedia(item, base) & @[firstContentImage(contentHtml, base),
      firstContentImage(summaryHtml, base)])
    let identity = if guidText.len > 0: guidText
      elif link.len > 0: link
      else: stableIdentity([feedUrl, title, summaryText, publishedRaw])
    result.add(NormalizedEntry(
      guid: identity,
      link: link,
      title: title,
      authors: rawEntryAuthors(item),
      publishedAt: published,
      updatedAt: published,
      publishedRaw: publishedRaw,
      summaryText: summaryText,
      summaryHtml: summaryHtml,
      contentText: contentText,
      contentHtml: contentHtml,
      media: media,
      hasMedia: media.remoteUrl.len > 0,
    ))

proc lenientAtomEntries(document: XmlNode, feedUrl, siteUrl: string): seq[NormalizedEntry] =
  let base = baseUrlForFeed(feedUrl, siteUrl)
  for item in rawItemNodes(document, "feed"):
    let id = firstNamedChild(item, ["id"])
    let idText = if id.isNil: "" else: id.innerText.strip
    let link = normalizeUrl(chooseAlternateLink(item), base)
    let title = childText(item, ["title"])
    let published = firstNamedChild(item, ["published", "updated"])
    let updated = firstNamedChild(item, ["updated"])
    let (publishedUnix, publishedRaw) = normalizeEntryDate(if published.isNil: "" else: published.innerText)
    let (updatedUnix, _) = normalizeEntryDate(if updated.isNil: "" else: updated.innerText)
    let (summaryHtml, contentHtml) = rawEntryHtml(item)
    let summaryText = if summaryHtml.len > 0: stripMarkup(summaryHtml) else: ""
    let contentText = if contentHtml.len > 0: stripMarkup(contentHtml) else: ""
    let media = chooseThumbnail(rawEntryMedia(item, base) & @[firstContentImage(contentHtml, base),
      firstContentImage(summaryHtml, base)])
    let identity = if idText.len > 0: idText
      elif link.len > 0: link
      else: stableIdentity([feedUrl, title, summaryText, publishedRaw])
    result.add(NormalizedEntry(
      guid: identity,
      link: link,
      title: title,
      authors: rawEntryAuthors(item),
      publishedAt: publishedUnix,
      updatedAt: updatedUnix,
      publishedRaw: publishedRaw,
      summaryText: summaryText,
      summaryHtml: summaryHtml,
      contentText: contentText,
      contentHtml: contentHtml,
      media: media,
      hasMedia: media.remoteUrl.len > 0,
    ))

proc enrichStrictEntries(entries: var seq[NormalizedEntry], document: XmlNode,
                         root, feedUrl, siteUrl: string) =
  ## Strict parsers validate and project the easy fields; the raw document
  ## supplies media, content payloads, and authors for real-world markup that a
  ## validating parser either ignores or rejects.
  let base = baseUrlForFeed(feedUrl, siteUrl)
  for item in rawItemNodes(document, root):
    let guid = firstNamedChild(item, ["guid", "id"])
    let guidText = if guid.isNil: "" else: richText(guid).strip
    let link = normalizeUrl(chooseAlternateLink(item), base)
    let resolved = if link.len > 0: link
      else: normalizeUrl(childText(item, ["link"]), base)
    for entry in entries.mitems:
      if (guidText.len > 0 and entry.guid == guidText) or
         (resolved.len > 0 and entry.link == resolved):
        # The validating parser drops CDATA titles the same way `innerText`
        # does, so an empty strict title is re-read from the raw document
        # instead of leaving the article to display its URL.
        if entry.title.len == 0:
          let rawTitle = childText(item, ["title"])
          if rawTitle.len > 0:
            entry.title = rawTitle
        let (summaryHtml, contentHtml) = rawEntryHtml(item)
        if summaryHtml.len > 0 and entry.summaryHtml.len == 0:
          entry.summaryHtml = summaryHtml
          entry.summaryText = stripMarkup(summaryHtml)
        if contentHtml.len > 0 and entry.contentHtml.len == 0:
          entry.contentHtml = contentHtml
          entry.contentText = stripMarkup(contentHtml)
        if entry.authors.len == 0:
          entry.authors = rawEntryAuthors(item)
        if not entry.hasMedia:
          entry.media = chooseThumbnail(rawEntryMedia(item, base) &
            @[firstContentImage(entry.contentHtml, base),
              firstContentImage(entry.summaryHtml, base)])
          entry.hasMedia = entry.media.remoteUrl.len > 0
        break

proc feedIconUrl(document: XmlNode, root, base: string): string =
  ## Publisher-supplied site graphic, used as the first favicon candidate. An
  ## RSS channel image and Atom icon/logo are both deliberate brand marks,
  ## unlike an image scraped from an arbitrary article.
  let channel = if root == "rdf": channelNode(document)
    elif root == "feed": document
    else: firstNamedChild(document, ["channel"])
  if channel.isNil:
    return ""
  for name in ["icon", "logo", "image"]:
    let node = firstNamedChild(channel, [name])
    if node.isNil:
      continue
    let remote = normalizeUrl(childText(node, ["url"]), base)
    if remote.len > 0:
      return remote
    let direct = normalizeUrl(richText(node).strip, base)
    if direct.len > 0:
      return direct
  ""

proc normalizeFeedDocument(payload, feedUrl: string, strictOnly = false): NormalizedFeed =
  let root = rootTagName(payload)
  if root notin ["rss", "rdf", "feed"]:
    raise newException(ValueError, "unsupported feed document: expected rss, rdf, or atom feed")
  let document =
    try:
      parseXml(payload)
    except XmlError as error:
      raise newException(ValueError, "feed XML could not be parsed: " & error.msg)
  var siteUrl = feedSiteUrl(document, root, feedUrl)
  if siteUrl.len == 0:
    siteUrl = feedUrl
  let title = feedChannelTitle(document, root)
  let description = block:
    let channel = if root == "rdf": channelNode(document) else: firstNamedChild(document, ["channel"])
    let target = if channel.isNil: document else: channel
    let node = firstNamedChild(target, ["description", "subtitle", "tagline"])
    if node.isNil: "" else: richText(node).strip
  case root
  of "rss":
    try:
      let parsed = parseRss(payload)
      var entries = strictRssEntries(parsed, feedUrl, siteUrl)
      enrichStrictEntries(entries, document, root, feedUrl, siteUrl)
      return NormalizedFeed(
        format: ffRss,
        title: if parsed.title.strip.len > 0: parsed.title.strip else: title,
        siteUrl: if parsed.link.strip.len > 0: normalizeUrl(parsed.link, feedUrl) else: siteUrl,
        iconUrl: feedIconUrl(document, root, siteUrl),
        description: if parsed.description.strip.len > 0: parsed.description.strip else: description,
        entries: entries
      )
    except CatchableError as error:
      if strictOnly:
        raise newException(ValueError, error.msg)
      discard
    return NormalizedFeed(
      format: ffRss,
      title: title,
      siteUrl: siteUrl,
      iconUrl: feedIconUrl(document, root, siteUrl),
      description: description,
      entries: lenientRssEntries(document, feedUrl, siteUrl)
    )
  of "rdf":
    if strictOnly:
      # RDF/RSS 1.0 has no validating parser in the current openparser
      # surface. Strict mode therefore declines to guess at it rather than
      # silently applying the lenient projection.
      raise newException(ValueError, "strict parsing does not support RDF/RSS 1.0 documents")
    return NormalizedFeed(
      format: ffRss,
      title: title,
      siteUrl: siteUrl,
      iconUrl: feedIconUrl(document, root, siteUrl),
      description: description,
      entries: lenientRssEntries(document, feedUrl, siteUrl)
    )
  else:
    try:
      let parsed = parseAtom(payload)
      var entries = strictAtomEntries(parsed, feedUrl, siteUrl)
      enrichStrictEntries(entries, document, root, feedUrl, siteUrl)
      var site = siteUrl
      for link in parsed.links:
        let rel = link.rel.get("alternate").toLowerAscii
        if (rel == "" or rel == "alternate") and link.href.strip.len > 0:
          site = normalizeUrl(link.href, feedUrl)
          if site.len > 0:
            break
      return NormalizedFeed(
        format: ffAtom,
        title: if parsed.title.value.strip.len > 0: parsed.title.value.strip else: title,
        siteUrl: site,
        iconUrl: feedIconUrl(document, root, site),
        description: description,
        entries: entries
      )
    except CatchableError as error:
      if strictOnly:
        raise newException(ValueError, error.msg)
      discard
    return NormalizedFeed(
      format: ffAtom,
      title: title,
      siteUrl: siteUrl,
      iconUrl: feedIconUrl(document, root, siteUrl),
      description: description,
      entries: lenientAtomEntries(document, feedUrl, siteUrl)
    )

# MARK: - Ingestion and article storage

proc articleRow(feedUrl, siteName, siteHost: string, entry: NormalizedEntry,
                fetchedAt: int64): RowData =
  rdbms.row([
    ("feedURL", newTextValue(feedUrl)),
    ("guid", newTextValue(entry.guid)),
    ("canonicalURL", newTextValue(entry.link)),
    ("title", newTextValue(entry.title)),
    ("authorsJson", newJSONValue(authorsText(entry.authors))),
    ("publishedAt", newIntValue(entry.publishedAt)),
    ("updatedAt", newIntValue(entry.updatedAt)),
    ("publishedRaw", newTextValue(entry.publishedRaw)),
    ("fetchedAt", newIntValue(fetchedAt)),
    ("summaryText", newTextValue(entry.summaryText)),
    ("summaryHTML", newTextValue(entry.summaryHtml)),
    ("contentText", newTextValue(entry.contentText)),
    ("contentHTML", newTextValue(entry.contentHtml)),
    ("thumbnailRemoteURL", newTextValue(entry.media.remoteUrl)),
    ("thumbnailMime", newTextValue(entry.media.mime)),
    ("thumbnailWidth", newIntValue(entry.media.width)),
    ("thumbnailHeight", newIntValue(entry.media.height)),
    ("thumbnailSource", newTextValue(entry.media.source)),
    ("thumbnailImageBase64", newNullValue()),
    ("siteName", newTextValue(siteName)),
    ("siteHost", newTextValue(siteHost)),
    ("isRead", newBoolValue(false)),
    ("isSaved", newBoolValue(false)),
  ])

proc pruneArticles(db: var Database, articles: DbTable, feedUrl: string, maximum: int) =
  ## Keeps the newest rows and drops the rest. Publication date is the order;
  ## fetch order and primary key break ties deterministically when a feed omits
  ## dates altogether.
  var retained: seq[tuple[key: tuple[published: int64, fetched: int64, id: int64], pk: string]] = @[]
  for row in articles.where("feedURL", newTextValue(feedUrl)):
    let pk = row[0]
    var id = 0'i64
    try: id = parseBiggestInt(pk) except ValueError: discard
    retained.add((
      articleSortKey(id, cellInt(row[1], "publishedAt"), cellInt(row[1], "fetchedAt")),
      pk
    ))
  retained.sort(proc(a, b: tuple[key: tuple[published: int64, fetched: int64, id: int64], pk: string]): int =
    if a.key != b.key: cmp(b.key, a.key) else: cmp(a.pk, b.pk))
  if retained.len > maximum:
    for doomed in retained[maximum .. ^1]:
      discard db.feeds.deleteRow(FeedArticlesTable, doomed.pk)

proc upsertArticles(db: var Database, articles: DbTable, feed: NormalizedFeed,
                    feedUrl, siteName, siteHost: string,
                    fetchedAt: int64): tuple[stored: int, updated: int] =
  var stored = 0
  var updated = 0
  for entry in feed.entries:
    if entry.guid.len == 0 or entry.guid.len > MaxUrlChars:
      continue
    var matchedPk = ""
    var matched: RowData = initOrderedTable[string, Value]()
    var matchedRead = false
    var matchedSaved = false
    for row in articles.where("guid", newTextValue(entry.guid)):
      if cellText(row[1], "feedURL") == feedUrl:
        matchedPk = row[0]
        matched = row[1]
        matchedRead = cellBool(row[1], "isRead")
        matchedSaved = cellBool(row[1], "isSaved")
        break
    var next = articleRow(feedUrl, siteName, siteHost, entry, fetchedAt)
    if matchedPk.len > 0:
      # Refreshing content must not silently mark an article unread or unsave
      # it. Display state belongs to the reader, not the publisher.
      next["isRead"] = newBoolValue(matchedRead)
      next["isSaved"] = newBoolValue(matchedSaved)
      # A thumbnail already downloaded must survive a refresh that only carries
      # the remote URL again. Re-downloading every image on every refresh would
      # turn a quiet reader into a crawler.
      if cellText(matched, "thumbnailImageBase64").len > 0:
        next["thumbnailImageBase64"] = matched["thumbnailImageBase64"]
        if cellText(next, "thumbnailRemoteURL").len == 0:
          next["thumbnailRemoteURL"] = matched["thumbnailRemoteURL"]
          next["thumbnailMime"] = matched["thumbnailMime"]
          next["thumbnailWidth"] = matched["thumbnailWidth"]
          next["thumbnailHeight"] = matched["thumbnailHeight"]
          next["thumbnailSource"] = matched["thumbnailSource"]
      discard db.feeds.deleteRow(FeedArticlesTable, matchedPk)
      db.feeds.insertRow(FeedArticlesTable, next)
      inc updated
    else:
      db.feeds.insertRow(FeedArticlesTable, next)
      inc stored
  pruneArticles(db, articles, feedUrl, MaxArticlesPerFeed)
  (stored, updated)

proc ingestFeedDocument(feedUrl: cstring, fetchedAt: int64, payload: cstring, strictOnly: bool,
                        buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
  ## Shared ingestion path for lenient and strict parsing. Strict mode recovers
  ## nothing: a document the validating parser rejects is recorded as a parse
  ## error and refused.
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalizedFeed = normalizeUrl(feed)
  if normalizedFeed.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  let text = requiredText(payload, "feed payload")
  if text.len == 0:
    return ErrBadInput
  if text.len > MaxFeedBodyBytes:
    setError("feed payload is too large: " & $text.len & " bytes")
    return ErrBadInput
  let stamp = if fetchedAt > 0: fetchedAt else: nowSeconds()
  var db = storeRef()
  ## The payload is text the app already downloaded. This call never performs
  ## network I/O; it only parses, deduplicates, persists, and reports what it
  ## stored.
  let status = catchingStore("ingest feed"):
    let (subscriptions, articles) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalizedFeed)
    if not existing.found:
      return ErrNotFound
    var parsed: NormalizedFeed
    try:
      parsed = normalizeFeedDocument(text, normalizedFeed, strictOnly)
    except ValueError as error:
      var failed = existing.data
      failed["lastCheckedAt"] = newIntValue(stamp)
      failed["lastStatus"] = newTextValue("parse-error")
      failed["lastError"] = newTextValue(error.msg)
      discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
      db.feeds.insertRow(FeedSubscriptionsTable, existing.pk, failed)
      setError(error.msg)
      return ErrBadInput
    let siteHost = block:
      let parsedHost = hostOfUrl(parsed.siteUrl)
      if parsedHost.len > 0: parsedHost
      else: cellText(existing.data, "siteHost")
    let siteName = block:
      let current = cellText(existing.data, "siteName")
      if current.len > 0:
        current
      elif parsed.title.len > 0:
        parsed.title
      elif siteHost.len > 0:
        siteHost
      else:
        current
    # Deduplicate repeated entries before counting or writing: the same GUID
    # twice in one download is one article, not one insert plus one update.
    var uniqueEntries: seq[NormalizedEntry] = @[]
    var seenGuids = initTable[string, bool]()
    for entry in parsed.entries:
      if entry.guid.len == 0 or entry.guid.len > MaxUrlChars:
        continue
      if not tables.hasKey(seenGuids, entry.guid):
        seenGuids[entry.guid] = true
        uniqueEntries.add(entry)
    parsed.entries = uniqueEntries
    let title = if parsed.title.len > 0: parsed.title
      else: cellText(existing.data, "feedTitle")
    var wouldStore = 0
    var wouldUpdate = 0
    for entry in parsed.entries:
      var alreadyStored = false
      for row in articles.where("guid", newTextValue(entry.guid)):
        if cellText(row[1], "feedURL") == normalizedFeed:
          alreadyStored = true
          break
      if alreadyStored:
        inc wouldUpdate
      else:
        inc wouldStore
    var preview = newJObject()
    preview["feedURL"] = newJString(normalizedFeed)
    preview["format"] = newJString(formatName(parsed.format))
    preview["title"] = newJString(title)
    preview["siteName"] = newJString(siteName)
    preview["siteHost"] = newJString(siteHost)
    preview["stored"] = newJInt(wouldStore)
    preview["updated"] = newJInt(wouldUpdate)
    preview["articles"] = newJInt(parsed.entries.len)
    # The two-phase buffer protocol calls a JSON export twice: once with a NULL
    # buffer to learn the size, and once with an exactly sized buffer. Nothing
    # may be persisted during the sizing pass, or every ingestion would run
    # twice and report the second run rather than the first.
    let required = int32(($preview).len + 1)
    if not needed.isNil:
      needed[] = required
    if buffer.isNil or capacity < required:
      return ErrBufferTooSmall
    let (stored, updated) = upsertArticles(db, articles, parsed, normalizedFeed,
      siteName, siteHost, stamp)
    var refreshed = existing.data
    refreshed["feedFormat"] = newTextValue(formatName(parsed.format))
    refreshed["feedTitle"] = newTextValue(title)
    refreshed["siteHost"] = newTextValue(siteHost)
    refreshed["siteName"] = newTextValue(siteName)
    if cellText(refreshed, "faviconRemoteURL").len == 0 and parsed.iconUrl.len > 0:
      # Publisher-declared art is the first favicon candidate. Bytes still need
      # an explicit validated attachment; a remote address alone is not enough.
      refreshed["faviconRemoteURL"] = newTextValue(parsed.iconUrl)
    refreshed["lastCheckedAt"] = newIntValue(stamp)
    refreshed["lastStatus"] = newTextValue("ok")
    refreshed["lastError"] = newNullValue()
    discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
    db.feeds.insertRow(FeedSubscriptionsTable, existing.pk, refreshed)
    var report = preview
    report["stored"] = newJInt(stored)
    report["updated"] = newJInt(updated)
    emitJson(report, buffer, capacity, needed)
  status

proc feedIngest*(feedUrl: cstring, fetchedAt: int64, payload: cstring, buffer: ptr char,
                 capacity: int32, needed: ptr int32): int32 {.exportc: "bc_feed_ingest".} =
  ## Parses one downloaded feed document and replaces the subscription's cached
  ## articles with the normalized result. A document the validating parser
  ## rejects is recovered with a lenient projection whenever its usable fields
  ## can still be identified.
  ingestFeedDocument(feedUrl, fetchedAt, payload, false, buffer, capacity, needed)

proc feedIngestStrict*(feedUrl: cstring, fetchedAt: int64, payload: cstring, buffer: ptr char,
                       capacity: int32, needed: ptr int32): int32 {.exportc: "bc_feed_ingest_strict".} =
  ## Strict variant of `bc_feed_ingest`. Nothing is recovered: malformed feeds,
  ## missing required metadata, and RDF/RSS 1.0 documents are recorded as parse
  ## errors and refused.
  ingestFeedDocument(feedUrl, fetchedAt, payload, true, buffer, capacity, needed)

proc feedNoteFetch*(feedUrl: cstring, checkedAt: int64, status: cstring,
                    error: cstring, etag: cstring, lastModified: cstring): int32 {.exportc: "bc_feed_note_fetch".} =
  ## Records an HTTP outcome that carried no parseable replacement, such as a
  ## conditional 304 or a transport failure. Separating this from ingestion
  ## keeps “nothing changed” from looking like a broken feed.
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalized = normalizeUrl(feed)
  if normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  let outcome = optionalText(status).toLowerAscii
  if outcome notin ["ok", "not-modified", "transport-error", "http-error", "parse-error"]:
    setError("fetch status is not recognized")
    return ErrBadInput
  let stamp = if checkedAt > 0: checkedAt else: nowSeconds()
  var db = storeRef()
  catchingStore("record feed fetch"):
    let (subscriptions, _) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalized)
    if not existing.found:
      return ErrNotFound
    var next = existing.data
    next["lastCheckedAt"] = newIntValue(stamp)
    next["lastStatus"] = newTextValue(outcome)
    let failure = optionalText(error)
    next["lastError"] = if failure.len > 0: newTextValue(failure) else: newNullValue()
    let tag = optionalText(etag)
    next["lastETag"] = if tag.len > 0: newTextValue(tag) else: newNullValue()
    let modified = optionalText(lastModified)
    next["lastModified"] = if modified.len > 0: newTextValue(modified) else: newNullValue()
    discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
    db.feeds.insertRow(FeedSubscriptionsTable, existing.pk, next)
    Ok

# MARK: - Article queries and state

proc articleSummaryJson(pk: string, data: RowData, subscription: RowData): JsonNode =
  %*{
    "id": parseBiggestInt(pk),
    "feedURL": cellText(data, "feedURL"),
    "guid": cellText(data, "guid"),
    "url": cellText(data, "canonicalURL"),
    "title": cellText(data, "title"),
    "authors": cellJsonStrings(data, "authorsJson"),
    "publishedAt": cellInt(data, "publishedAt"),
    "updatedAt": cellInt(data, "updatedAt"),
    "publishedRaw": cellText(data, "publishedRaw"),
    "fetchedAt": cellInt(data, "fetchedAt"),
    "summary": cellText(data, "summaryText"),
    "summaryHTML": cellText(data, "summaryHTML"),
    "hasContent": cellText(data, "contentText").len > 0 or cellText(data, "contentHTML").len > 0,
    "thumbnail": mediaJson(NormalizedMedia(
      remoteUrl: cellText(data, "thumbnailRemoteURL"),
      mime: cellText(data, "thumbnailMime"),
      width: cellInt(data, "thumbnailWidth"),
      height: cellInt(data, "thumbnailHeight"),
      source: cellText(data, "thumbnailSource")
    ), cellText(data, "thumbnailImageBase64").len > 0),
    "siteName": cellText(data, "siteName"),
    "siteHost": cellText(data, "siteHost"),
    "feedTitle": cellText(subscription, "feedTitle"),
    "hasFavicon": cellText(subscription, "faviconImageBase64").len > 0,
    "isRead": cellBool(data, "isRead"),
    "isSaved": cellBool(data, "isSaved"),
  }

proc articleDetailJson(pk: string, data: RowData, subscription: RowData): JsonNode =
  result = articleSummaryJson(pk, data, subscription)
  result["content"] = newJString(cellText(data, "contentText"))
  result["contentHTML"] = newJString(cellText(data, "contentHTML"))
  result["thumbnailImageBase64"] = newJString(cellText(data, "thumbnailImageBase64"))

proc subscriptionByUrl(subscriptions: DbTable, feedUrl: string): RowData =
  let existing = existingSubscription(subscriptions, feedUrl)
  if not existing.found:
    return initOrderedTable[string, Value]()
  existing.data

proc feedArticles*(feedUrl: cstring, onlyUnread: int32, limit: int32,
                   beforePublishedAt: int64, beforeId: int64,
                   buffer: ptr char, capacity: int32,
                   needed: ptr int32): int32 {.exportc: "bc_feed_articles".} =
  ## Newest-first article summaries for one feed, or every subscription when the
  ## feed URL is empty.
  ##
  ## Bodies and image bytes are deliberately omitted here; the list can span
  ## hundreds of rows, while `bc_feed_article` and the media calls return the
  ## heavy fields for the rows actually on screen. Pagination uses the sort key
  ## rather than an offset, so newly arrived rows cannot shift a cursor.
  if not validFlag(onlyUnread, "only unread"):
    return ErrBadInput
  if limit <= 0 or limit > MaxArticleResults:
    setError("limit must be between 1 and 500")
    return ErrBadInput
  let feed = optionalText(feedUrl)
  let normalized = if feed.len > 0: normalizeUrl(feed) else: ""
  if feed.len > 0 and normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  var db = storeRef()
  var document = newJArray()
  let status = catchingStore("list feed articles"):
    let (subscriptions, articles) = feedTables(db)
    var selected: seq[tuple[key: tuple[published: int64, fetched: int64, id: int64],
                            pk: string, data: RowData]] = @[]
    var sourceRows: seq[tuple[pk: string, data: RowData]] = @[]
    if normalized.len > 0:
      for row in articles.where("feedURL", newTextValue(normalized)):
        sourceRows.add((row[0], row[1]))
    else:
      for row in rdbms.allRows(articles):
        sourceRows.add((row[0], row[1]))
    for row in sourceRows:
      let pk = row[0]
      var id = 0'i64
      try: id = parseBiggestInt(pk) except ValueError: continue
      let published = cellInt(row[1], "publishedAt")
      let fetched = cellInt(row[1], "fetchedAt")
      if beforePublishedAt > 0:
        if published > beforePublishedAt:
          continue
        if published == beforePublishedAt and (beforeId <= 0 or id >= beforeId):
          continue
      if onlyUnread == 1'i32 and cellBool(row[1], "isRead"):
        continue
      selected.add((articleSortKey(id, published, fetched), pk, row[1]))
    selected.sort(proc(a, b: tuple[key: tuple[published: int64, fetched: int64, id: int64],
                                   pk: string, data: RowData]): int =
      if a.key != b.key: cmp(b.key, a.key) else: cmp(a.pk, b.pk))
    if selected.len > limit.int:
      selected.setLen(limit.int)
    var subscriptionsByUrl = initTable[string, RowData]()
    for entry in selected:
      let url = cellText(entry.data, "feedURL")
      if not tables.hasKey(subscriptionsByUrl, url):
        subscriptionsByUrl[url] = subscriptionByUrl(subscriptions, url)
      document.add(articleSummaryJson(entry.pk, entry.data, subscriptionsByUrl[url]))
    Ok
  if status != Ok:
    return status
  emitJson(document, buffer, capacity, needed)

proc feedArticle*(articleId: int64, buffer: ptr char, capacity: int32,
                  needed: ptr int32): int32 {.exportc: "bc_feed_article".} =
  if articleId <= 0:
    setError("article id is required")
    return ErrBadInput
  var db = storeRef()
  var document = newJObject()
  let status = catchingStore("read feed article"):
    let (subscriptions, _) = feedTables(db)
    let row = db.feeds.getRow(FeedArticlesTable, $articleId)
    if row.isNone:
      return ErrNotFound
    let data = row.get()
    let subscription = subscriptionByUrl(subscriptions, cellText(data, "feedURL"))
    document = articleDetailJson($articleId, data, subscription)
    Ok
  if status != Ok:
    return status
  emitJson(document, buffer, capacity, needed)

proc feedSetArticleState*(articleId: int64, isRead: int32, isSaved: int32): int32 {.exportc: "bc_feed_set_article_state".} =
  if articleId <= 0:
    setError("article id is required")
    return ErrBadInput
  if not validFlag(isRead, "is read"):
    return ErrBadInput
  if not validFlag(isSaved, "is saved"):
    return ErrBadInput
  var db = storeRef()
  catchingStore("update feed article state"):
    let row = db.feeds.getRow(FeedArticlesTable, $articleId)
    if row.isNone:
      return ErrNotFound
    # Concurrent mode cannot update a row in place, so state changes rewrite
    # the same row. Nothing else in the row is touched.
    var next = row.get()
    next["isRead"] = newBoolValue(isRead == 1'i32)
    next["isSaved"] = newBoolValue(isSaved == 1'i32)
    discard db.feeds.deleteRow(FeedArticlesTable, $articleId)
    db.feeds.insertRow(FeedArticlesTable, $articleId, next)
    Ok

# MARK: - Persisted media

proc decodedImageBytes(encoded: string, maxEncodedBytes: int, name: string): string =
  let cleaned = encoded.strip
  if cleaned.len == 0:
    raise newException(ValueError, name & " image is required")
  if cleaned.len > maxEncodedBytes:
    raise newException(ValueError, name & " image exceeds its size limit")
  try:
    result = decode(cleaned)
  except ValueError:
    raise newException(ValueError, name & " image is not valid Base64")
  if result.len == 0:
    raise newException(ValueError, name & " image is empty")

proc recognizedImageMime(bytes: string, allowed: openArray[string], name: string): string =
  var mime = ""
  if bytes.len >= 8 and bytes[0 .. 7] == "\x89PNG\r\n\x1a\n":
    mime = "image/png"
  elif bytes.len >= 3 and bytes[0 .. 2] == "\xFF\xD8\xFF":
    mime = "image/jpeg"
  elif bytes.len >= 6 and (bytes[0 .. 5] == "GIF87a" or bytes[0 .. 5] == "GIF89a"):
    mime = "image/gif"
  elif bytes.len >= 12 and bytes[0 .. 3] == "RIFF" and bytes[8 .. 11] == "WEBP":
    mime = "image/webp"
  elif bytes.len >= 4 and bytes[0 .. 3] == "\x00\x00\x01\x00":
    mime = "image/x-icon"
  if mime.len == 0 or mime notin allowed:
    raise newException(ValueError, name & " image must be PNG, JPEG, GIF, WebP" &
      (if "image/x-icon" in allowed: ", or ICO" else: ""))
  mime

proc checkedDimensions(width, height: int64, name: string): tuple[width: int64, height: int64] =
  if width <= 0 or height <= 0 or width > 8192 or height > 8192:
    raise newException(ValueError, name & " dimensions are not usable")
  (width, height)

proc feedAttachThumbnail*(articleId: int64, mime: cstring, width: int64, height: int64,
                          imageBase64: cstring): int32 {.exportc: "bc_feed_attach_thumbnail".} =
  ## Stores validated thumbnail bytes for one article.
  ##
  ## The app downloads, sniffs, downscales, and encodes the image; the core
  ## verifies the encoding, magic bytes, declared dimensions, and size before
  ## persisting. Claimed dimensions cannot be proved from Base64 without an
  ## image decoder in the store, so the app remains responsible for measuring
  ## them honestly.
  if articleId <= 0:
    setError("article id is required")
    return ErrBadInput
  let declaredMime = optionalText(mime).toLowerAscii.split(';')[0].strip
  let encoded = optionalText(imageBase64)
  var db = storeRef()
  let status = catchingStore("attach feed thumbnail"):
    let row = db.feeds.getRow(FeedArticlesTable, $articleId)
    if row.isNone:
      return ErrNotFound
    var bytes: string
    var actualMime: string
    try:
      bytes = decodedImageBytes(encoded, MaxThumbnailEncodedBytes, "thumbnail")
      actualMime = recognizedImageMime(bytes, AllowedThumbnailMimes, "thumbnail")
    except ValueError as error:
      setError(error.msg)
      return ErrBadInput
    if declaredMime.len > 0 and declaredMime != actualMime:
      setError("thumbnail MIME does not match its bytes")
      return ErrBadInput
    let checked = try:
      checkedDimensions(width, height, "thumbnail")
    except ValueError as error:
      setError(error.msg)
      return ErrBadInput
    var next = row.get()
    next["thumbnailMime"] = newTextValue(actualMime)
    next["thumbnailWidth"] = newIntValue(checked.width)
    next["thumbnailHeight"] = newIntValue(checked.height)
    if cellText(next, "thumbnailSource").len == 0:
      next["thumbnailSource"] = newTextValue("attached")
    next["thumbnailImageBase64"] = newTextValue(encoded.strip)
    discard db.feeds.deleteRow(FeedArticlesTable, $articleId)
    db.feeds.insertRow(FeedArticlesTable, $articleId, next)
    Ok
  status

proc feedThumbnail*(articleId: int64, buffer: ptr char, capacity: int32,
                    needed: ptr int32): int32 {.exportc: "bc_feed_thumbnail".} =
  if articleId <= 0:
    setError("article id is required")
    return ErrBadInput
  var db = storeRef()
  var document = newJObject()
  let status = catchingStore("read feed thumbnail"):
    let row = db.feeds.getRow(FeedArticlesTable, $articleId)
    if row.isNone:
      return ErrNotFound
    let data = row.get()
    let encoded = cellText(data, "thumbnailImageBase64")
    if encoded.len == 0:
      return ErrNotFound
    document = mediaJson(NormalizedMedia(
      remoteUrl: cellText(data, "thumbnailRemoteURL"),
      mime: cellText(data, "thumbnailMime"),
      width: cellInt(data, "thumbnailWidth"),
      height: cellInt(data, "thumbnailHeight"),
      source: cellText(data, "thumbnailSource")
    ), true)
    document["imageBase64"] = newJString(encoded)
    Ok
  if status != Ok:
    return status
  emitJson(document, buffer, capacity, needed)

proc feedAttachFavicon*(feedUrl: cstring, remoteUrl: cstring, mime: cstring,
                        imageBase64: cstring): int32 {.exportc: "bc_feed_attach_favicon".} =
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalized = normalizeUrl(feed)
  if normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  let remote = optionalText(remoteUrl)
  let normalizedRemote = if remote.len > 0: normalizeUrl(remote) else: ""
  if remote.len > 0 and normalizedRemote.len == 0:
    setError("favicon url is not a supported HTTP(S) address")
    return ErrBadInput
  let declaredMime = optionalText(mime).toLowerAscii.split(';')[0].strip
  let encoded = optionalText(imageBase64)
  var db = storeRef()
  let status = catchingStore("attach feed favicon"):
    let (subscriptions, _) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalized)
    if not existing.found:
      return ErrNotFound
    var bytes: string
    var actualMime: string
    try:
      bytes = decodedImageBytes(encoded, MaxFaviconEncodedBytes, "favicon")
      actualMime = recognizedImageMime(bytes, AllowedFaviconMimes, "favicon")
    except ValueError as error:
      setError(error.msg)
      return ErrBadInput
    if declaredMime.len > 0 and declaredMime != actualMime:
      setError("favicon MIME does not match its bytes")
      return ErrBadInput
    var next = existing.data
    if normalizedRemote.len > 0:
      next["faviconRemoteURL"] = newTextValue(normalizedRemote)
    next["faviconMime"] = newTextValue(actualMime)
    next["faviconImageBase64"] = newTextValue(encoded.strip)
    discard db.feeds.deleteRow(FeedSubscriptionsTable, existing.pk)
    db.feeds.insertRow(FeedSubscriptionsTable, existing.pk, next)
    Ok
  status

proc feedFavicon*(feedUrl: cstring, buffer: ptr char, capacity: int32,
                  needed: ptr int32): int32 {.exportc: "bc_feed_favicon".} =
  let feed = requiredText(feedUrl, "feed url")
  if feed.len == 0:
    return ErrBadInput
  let normalized = normalizeUrl(feed)
  if normalized.len == 0:
    setError("feed url is not a supported HTTP(S) address")
    return ErrBadInput
  var db = storeRef()
  var document = newJObject()
  let status = catchingStore("read feed favicon"):
    let (subscriptions, _) = feedTables(db)
    let existing = existingSubscription(subscriptions, normalized)
    if not existing.found:
      return ErrNotFound
    let encoded = cellText(existing.data, "faviconImageBase64")
    if encoded.len == 0:
      return ErrNotFound
    document["feedURL"] = newJString(normalized)
    document["remoteURL"] = newJString(cellText(existing.data, "faviconRemoteURL"))
    document["mime"] = newJString(cellText(existing.data, "faviconMime"))
    document["imageBase64"] = newJString(encoded)
    Ok
  if status != Ok:
    return status
  emitJson(document, buffer, capacity, needed)
