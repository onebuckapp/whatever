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

# Feed storage C ABI tests.
#
# Exercises subscriptions, fallback discovery, Atom/RSS ingestion, article
# state, and persisted media against a throwaway feeds store. Payloads are
# inline fixtures because feed URLs must never be fetched by the test suite.

import std/[envvars, os, unittest]
import openparser/json
import ../api/[abi, feed_api]

proc readJson(call: proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32): JsonNode =
  var needed: int32 = 0
  check call(nil, 0'i32, addr needed) == ErrBufferTooSmall
  var buffer = newString(needed.int)
  var filled: int32 = 0
  check call(addr buffer[0], needed, addr filled) == Ok
  parseJson($buffer)

let scratchRoot = getTempDir() / "whatever-feed-tests"
removeDir(scratchRoot)
createDir(scratchRoot)
putEnv("WHATEVER_STORE_ROOT", scratchRoot)

const
  RssFeedUrl = "https://example.com/feed.xml"
  RssPageUrl = "https://example.com/articles"
  AtomFeedUrl = "https://example.org/atom.xml"
  AtomPageUrl = "https://example.org/"
  DiscoveryPageUrl = "https://example.net/articles/page"
  OnePixelPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

  RssFixture = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Example News</title>
    <link>https://example.com/articles</link>
    <description>Example feed</description>
    <item>
      <guid>article-one</guid>
      <title>First article</title>
      <link>https://example.com/articles/one</link>
      <description><![CDATA[<p>First body <img src="/one.jpg" width="640" height="360"></p>]]></description>
      <enclosure url="https://example.com/enclosure-one.jpg" type="image/jpeg" length="123" />
      <pubDate>Wed, 01 Oct 2025 12:00:00 GMT</pubDate>
    </item>
    <item>
      <guid>article-two</guid>
      <title>Second article</title>
      <link>/articles/two</link>
      <description>Second body</description>
      <pubDate>2025-10-02T12:00:00Z</pubDate>
    </item>
  </channel>
</rss>
"""

  AtomFixture = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:example.org,2025:feed</id>
  <title>Example Journal</title>
  <updated>2025-10-03T12:00:00Z</updated>
  <author><name>Example Newsroom</name></author>
  <icon>https://example.org/icon.png</icon>
  <link href="https://example.org/"/>
  <entry>
    <id>tag:example.org,2025:alpha</id>
    <title>Alpha story</title>
    <updated>2025-10-03T12:00:00Z</updated>
    <author><name>Alpha Reporter</name></author>
    <link href="https://example.org/alpha"/>
    <summary>Alpha summary</summary>
  </entry>
</feed>
"""

  DiscoveryFixture = """<!doctype html>
<html>
  <head>
    <title>Example Page</title>
    <link rel="alternate" type="application/rss+xml" title="Example RSS" href="/feed.xml">
    <link rel="stylesheet" href="/site.css">
    <link rel="alternate" type="text/html" hreflang="fr" href="/fr/">
  </head>
</html>
"""

  CdataFeedUrl = "https://example.com/cdata.xml"
  CdataPageUrl = "https://example.com/cdata"
  RdfFeedUrl = "https://example.com/rdf.xml"
  CdataAtomUrl = "https://example.org/cdata-atom.xml"

  CdataFixture = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Example CDATA News</title>
    <link>https://example.com/cdata</link>
    <description>Feed with CDATA everywhere</description>
    <item>
      <guid>cdata-one</guid>
      <title><![CDATA[First “quoted” story & more]]></title>
      <link>https://example.com/cdata/one</link>
      <description><![CDATA[First summary with <b>markup</b> &amp; entities]]></description>
      <pubDate>Wed, 01 Oct 2025 12:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>
"""

  RdfFixture = """<?xml version="1.0" encoding="UTF-8"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
  <channel>
    <title>Example RDF News</title>
    <link>https://example.com/rdf</link>
    <description>RDF feed</description>
  </channel>
  <item>
    <title><![CDATA[RDF story one]]></title>
    <link>https://example.com/rdf/one</link>
    <description><![CDATA[RDF summary one]]></description>
  </item>
</rdf:RDF>
"""

  CdataAtomFixture = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:example.org,2025:cdata</id>
  <title>Example CDATA Journal</title>
  <updated>2025-10-03T12:00:00Z</updated>
  <link href="https://example.org/cdata"/>
  <entry>
    <id>tag:example.org,2025:cdata-one</id>
    <title><![CDATA[CDATA atom story]]></title>
    <updated>2025-10-03T12:00:00Z</updated>
    <link href="https://example.org/cdata-one"/>
    <summary>CDATA atom summary</summary>
  </entry>
</feed>
"""

suite "feed c abi":
  test "subscriptions converge on one normalized feed row":
    check feedSubscribe(RssFeedUrl.cstring, RssPageUrl.cstring, "".cstring, "Example RSS".cstring,
      "application/rss+xml".cstring, 1_700_000_100'i64) == Ok
    check feedSubscribe("https://example.com/feed.xml#today".cstring,
      "https://example.com/other".cstring, "Example Site".cstring, "".cstring, "".cstring,
      1_700_000_200'i64) == Ok

    let subscriptions = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedSubscriptions(buffer, capacity, needed))
    check subscriptions.len == 1
    check subscriptions[0]["feedURL"].getStr == RssFeedUrl
    check subscriptions[0]["pageURL"].getStr == "https://example.com/other"
    check subscriptions[0]["siteName"].getStr == "Example Site"
    check subscriptions[0]["feedFormat"].getStr == "rss"
    check subscriptions[0]["subscribedAt"].getInt == 1_700_000_100

  test "subscriptions reject unsupported addresses":
    check feedSubscribe("ftp://example.com/feed.xml".cstring, RssPageUrl.cstring,
      "".cstring, "".cstring, "".cstring, 0'i64) == ErrBadInput
    check feedSubscribe("".cstring, RssPageUrl.cstring, "".cstring, "".cstring, "".cstring,
      0'i64) == ErrBadInput

  test "discovery keeps standard feed links and ignores the rest":
    let found = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedDiscoverFromHtml(DiscoveryPageUrl.cstring, DiscoveryFixture.cstring, buffer, capacity, needed))
    check found["pageURL"].getStr == DiscoveryPageUrl
    check found["candidates"].len == 1
    check found["candidates"][0]["url"].getStr == "https://example.net/feed.xml"
    check found["candidates"][0]["format"].getStr == "rss"
    check found["candidates"][0]["title"].getStr == "Example RSS"

  test "RSS ingestion stores normalized articles and preserves display state":
    let report = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedIngest(RssFeedUrl.cstring, 1_700_000_300'i64, RssFixture.cstring, buffer, capacity, needed))
    check report["stored"].getInt == 2
    check report["format"].getStr == "rss"

    var listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(RssFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check listed.len == 2
    check listed[0]["title"].getStr == "Second article"
    check listed[0]["url"].getStr == "https://example.com/articles/two"
    check listed[0]["publishedAt"].getInt == listed[1]["publishedAt"].getInt + 86400
    check listed[1]["thumbnail"]["remoteURL"].getStr == "https://example.com/enclosure-one.jpg"
    check listed[1]["thumbnail"]["source"].getStr == "enclosure"
    check listed[1]["siteName"].getStr == "Example Site"

    let firstId = listed[0]["id"].getInt
    check feedSetArticleState(int64(firstId), 1'i32, 1'i32) == Ok
    let refreshed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedIngest(RssFeedUrl.cstring, 1_700_000_400'i64, RssFixture.cstring, buffer, capacity, needed))
    check refreshed["updated"].getInt == 2
    listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(RssFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check listed[0]["isRead"].getBool
    check listed[0]["isSaved"].getBool

  test "CDATA titles and summaries survive ingestion":
    # Publishers like Digi24 wrap every title and description in CDATA, which
    # stdlib innerText reports as empty. Articles must keep their real titles
    # instead of falling back to showing their URL.
    for row in [
      (CdataFeedUrl, CdataPageUrl, CdataFixture),
      (RdfFeedUrl, "https://example.com/rdf", RdfFixture),
      (CdataAtomUrl, "https://example.org/cdata", CdataAtomFixture),
    ]:
      let (feedUrl, pageUrl, fixture) = row
      check feedSubscribe(feedUrl.cstring, pageUrl.cstring, "".cstring, "".cstring,
        "".cstring, 0'i64) == Ok
      let report = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
        feedIngest(feedUrl.cstring, 1_700_000_900'i64, fixture.cstring, buffer, capacity, needed))
      check report["stored"].getInt == 1
      let listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
        feedArticles(feedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
      check listed.len == 1
      check listed[0]["title"].getStr.len > 0
      # The empty-title fallback shows the URL; a real title must differ.
      check listed[0]["title"].getStr != listed[0]["url"].getStr
    let rssListed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(CdataFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check rssListed[0]["title"].getStr == "First “quoted” story & more"
    check rssListed[0]["summary"].getStr == "First summary with markup & entities"
    let rdfListed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(RdfFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check rdfListed[0]["title"].getStr == "RDF story one"
    check rdfListed[0]["summary"].getStr == "RDF summary one"
    let atomListed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(CdataAtomUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check atomListed[0]["title"].getStr == "CDATA atom story"

  test "Atom ingestion stores authors and feed metadata":
    check feedSubscribe(AtomFeedUrl.cstring, AtomPageUrl.cstring, "".cstring, "".cstring,
      "".cstring, 0'i64) == Ok
    let report = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedIngest(AtomFeedUrl.cstring, 1_700_000_500'i64, AtomFixture.cstring, buffer, capacity, needed))
    check report["format"].getStr == "atom"
    check report["stored"].getInt == 1

    let subscriptions = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedSubscriptions(buffer, capacity, needed))
    var atomSubscription = subscriptions[0]
    for subscription in subscriptions.items:
      if subscription["feedURL"].getStr == AtomFeedUrl:
        atomSubscription = subscription
    check atomSubscription["faviconRemoteURL"].getStr == "https://example.org/icon.png"

    let listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(AtomFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check listed.len == 1
    check listed[0]["authors"].len == 1
    check listed[0]["authors"][0].getStr == "Alpha Reporter"
    check listed[0]["feedTitle"].getStr == "Example Journal"

  test "validated thumbnail and favicon bytes round-trip through the store":
    let listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(RssFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    var target = 0
    for entry in listed.items:
      if entry["thumbnail"]["remoteURL"].getStr.len > 0:
        target = entry["id"].getInt
    check target > 0
    check feedAttachThumbnail(int64(target), "image/png".cstring, 1'i64, 1'i64,
      OnePixelPng.cstring) == Ok
    check feedAttachFavicon(RssFeedUrl.cstring, "https://example.com/favicon.png".cstring,
      "image/png".cstring, OnePixelPng.cstring) == Ok

    let thumbnail = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedThumbnail(int64(target), buffer, capacity, needed))
    check thumbnail["mime"].getStr == "image/png"
    check thumbnail["imageBase64"].getStr == OnePixelPng
    let icon = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedFavicon(RssFeedUrl.cstring, buffer, capacity, needed))
    check icon["imageBase64"].getStr == OnePixelPng
    check icon["remoteURL"].getStr == "https://example.com/favicon.png"

  test "strict ingestion rejects recoverable feeds while lenient ingestion keeps them":
    const strictUrl = "https://example.com/strict.xml"
    check feedSubscribe(strictUrl.cstring, RssPageUrl.cstring, "".cstring, "".cstring,
      "".cstring, 0'i64) == Ok
    const malformedAtom = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>tag:example.com,2025:strict</id>
  <title>Strict feed</title>
  <link href="https://example.com/strict"/>
  <entry>
    <id>tag:example.com,2025:strict-one</id>
    <title>Recoverable story</title>
    <link href="https://example.com/strict-one"/>
  </entry>
</feed>
"""
    check feedIngestStrict(strictUrl.cstring, 1_700_000_600'i64, malformedAtom.cstring,
      nil, 0'i32, nil) == ErrBadInput
    let empty = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(strictUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check empty.len == 0
    let recovered = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedIngest(strictUrl.cstring, 1_700_000_700'i64, malformedAtom.cstring, buffer, capacity, needed))
    check recovered["stored"].getInt == 1
    check recovered["format"].getStr == "atom"

  test "explicit retention keeps the newest articles":
    const pruneUrl = "https://example.com/prune.xml"
    check feedSubscribe(pruneUrl.cstring, RssPageUrl.cstring, "".cstring, "".cstring,
      "".cstring, 0'i64) == Ok
    discard readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedIngest(pruneUrl.cstring, 1_700_000_800'i64, RssFixture.cstring, buffer, capacity, needed))
    check feedPrune(pruneUrl.cstring, 1'i32) == Ok
    let retained = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(pruneUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check retained.len == 1
    check retained[0]["title"].getStr == "Second article"
    check feedPrune("https://example.com/missing.xml".cstring, 10'i32) == ErrNotFound
    check feedPrune(pruneUrl.cstring, 0'i32) == ErrBadInput

  test "unsubscribing removes articles before the subscription":
    check feedUnsubscribe(RssFeedUrl.cstring) == Ok
    let listed = readJson(proc (buffer: ptr char, capacity: int32, needed: ptr int32): int32 =
      feedArticles(RssFeedUrl.cstring, 0'i32, 10'i32, 0'i64, 0'i64, buffer, capacity, needed))
    check listed.len == 0
    check feedUnsubscribe(RssFeedUrl.cstring) == ErrNotFound
