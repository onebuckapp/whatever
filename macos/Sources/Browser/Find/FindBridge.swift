import WebKit

/// The find-in-page page bridge: a permanent user script plus documentation of
/// the calls the native side makes into it.
///
/// All control flows native-to-page; there is deliberately no script message
/// handler. The pipeline is `extractText` → `bc_find_matches` →
/// `applyMatches`, and `step` moves the current highlight without ever
/// leaving the page.
///
/// Staleness is verified, never observed: each applied span remembers the
/// text it wrapped, and `step` re-checks every span is still connected and
/// still holds that text before moving. A `MutationObserver` was tried and
/// removed — its callbacks run after the synchronous script that caused them
/// returns, so our own wrapping always looked like page dirt and every step
/// re-searched from the first match. Likewise `applyMatches` re-checks each
/// overlapped segment still holds its extracted text, so a page that mutated
/// between extraction and application drops the raced ranges instead of
/// wrapping the wrong text.
///
/// Text segmentation is the authoritative part: a `TreeWalker` walks the
/// visible text nodes and joins them with `""` inside one block container and
/// `"\n"` across block boundaries. Matches therefore never span a block
/// break unless the query itself contains a newline, which a single-line
/// field cannot produce — while inline splits (`Hel<b>lo</b>`) still match
/// across nodes. The core matches over exactly this string, so its byte
/// ranges map back onto the nodes that produced them.
///
/// Result numbers are display positions: highlight-all reports the position
/// among the wrapped matches, single-highlight the query position among every
/// range. Either way the label reads `index + 1 of count`.
///
/// Main frame only: same-origin and cross-origin iframes are not searched.
/// Elements under `script`, `style`, `noscript`, `template` or `head` are
/// skipped. `display:none` via stylesheet is not detected — those matches
/// highlight invisibly — only the `hidden` attribute is skipped.
enum FindBridge {
    /// Installed by `WebViewFactory` on every page configuration, so every
    /// page starts with the namespace. Idempotent under re-injection: a live
    /// document that already evaluated the script keeps its state.
    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    // swiftlint:disable:next line_length
    private static let source = """
    (() => {
        if (window.__whtvrFind) return;
        const HIT = 'whtvr-find-hit';
        const CURRENT = 'whtvr-find-current';
        const STYLE_ID = 'whtvr-find-style';
        const MAX_BYTES = 1048576;
        const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD']);
        const BLOCK_TAGS = new Set(['ADDRESS', 'ARTICLE', 'ASIDE', 'BLOCKQUOTE', 'DD', 'DETAILS', 'DIALOG', 'DIV', 'DL', 'DT', 'FIELDSET', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'FORM', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HGROUP', 'HR', 'LI', 'MAIN', 'NAV', 'OL', 'P', 'PRE', 'SECTION', 'TABLE', 'UL', 'TR', 'TD', 'TH', 'BR']);

        const encoder = new TextEncoder();
        let segments = [];
        let applied = [];
        let lastPayload = null;
        let lastKept = [];
        let selRange = -1;

        function ensureStyle() {
            if (document.getElementById(STYLE_ID)) return;
            const style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = '.' + HIT + '{background-color:rgba(255,214,10,.55);color:inherit;border-radius:2px}'
                + '.' + CURRENT + '{background-color:rgba(255,159,10,.92);color:#000}'
                + '@media (prefers-color-scheme:dark){.' + HIT + '{background-color:rgba(255,214,10,.42)}'
                + '.' + CURRENT + '{background-color:rgba(255,159,10,.95);color:#000}}';
            (document.head || document.documentElement).appendChild(style);
        }

        function blockContainer(node) {
            let el = node.parentElement;
            while (el) {
                if (BLOCK_TAGS.has(el.tagName)) return el;
                el = el.parentElement;
            }
            return null;
        }

        function extractText() {
            ensureStyle();
            segments = [];
            const parts = [];
            let bytes = 0;
            let truncated = false;
            let prevBlock = null;
            let first = true;
            const root = document.body || document.documentElement;
            if (!root) return { text: '', truncated: false };
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode(node) {
                    const parent = node.parentElement;
                    if (!parent || !node.nodeValue || node.nodeValue.length === 0) return NodeFilter.FILTER_REJECT;
                    if (SKIP_TAGS.has(parent.tagName)) return NodeFilter.FILTER_REJECT;
                    if (parent.closest && parent.closest('[hidden]')) return NodeFilter.FILTER_REJECT;
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            let node;
            while ((node = walker.nextNode())) {
                const value = node.nodeValue;
                const block = blockContainer(node);
                let join = 0;
                if (!first && block !== prevBlock) join = 1;
                const len = encoder.encode(value).length;
                if (bytes + join + len > MAX_BYTES) {
                    truncated = true;
                    break;
                }
                if (join === 1) {
                    parts.push('\\n');
                    bytes += 1;
                }
                first = false;
                prevBlock = block;
                parts.push(value);
                segments.push({ node: node, start: bytes, length: len, text: value });
                bytes += len;
            }
            return { text: parts.join(''), truncated: truncated };
        }

        function byteToCharIndex(text, target) {
            let b = 0;
            for (let i = 0; i < text.length; i++) {
                if (b === target) return i;
                const code = text.charCodeAt(i);
                if (code >= 0xD800 && code <= 0xDBFF) {
                    b += 4;
                    i++;
                } else if (code < 0x80) {
                    b += 1;
                } else if (code < 0x800) {
                    b += 2;
                } else {
                    b += 3;
                }
            }
            return b === target ? text.length : -1;
        }

        function segmentAt(offset) {
            let lo = 0;
            let hi = segments.length - 1;
            while (lo <= hi) {
                const mid = (lo + hi) >> 1;
                const seg = segments[mid];
                if (offset < seg.start) {
                    hi = mid - 1;
                } else if (offset >= seg.start + seg.length) {
                    lo = mid + 1;
                } else {
                    return mid;
                }
            }
            return -1;
        }

        function unwrap() {
            const parents = new Set();
            for (const span of applied) {
                if (!span.isConnected) continue;
                const parent = span.parentNode;
                while (span.firstChild) parent.insertBefore(span.firstChild, span);
                parent.removeChild(span);
                parents.add(parent);
            }
            applied = [];
            for (const parent of parents) {
                if (parent.isConnected && parent.normalize) parent.normalize();
            }
        }

        function wrapNodePieces(node, pieces) {
            // Descending by start, so earlier splits never move later offsets.
            // Each piece carries its range index: a match split across nodes
            // wraps as one span per node, all tagged with the same range.
            pieces.sort((a, b) => b[0] - a[0]);
            for (const [s, e, ri] of pieces) {
                node.splitText(e);
                const mid = node.splitText(s);
                const span = document.createElement('span');
                span.className = HIT;
                span.__whtvrRI = ri;
                // The wrapped text, remembered so `step` can tell a live span
                // from one the page edited after the search.
                span.__whtvrTx = mid.nodeValue;
                span.textContent = mid.nodeValue;
                mid.replaceWith(span);
            }
        }

        function wrapRanges(ranges, wanted) {
            // Wraps `wanted` range indices; returns the kept range indices in
            // ascending order plus whether any range raced a page edit. A
            // range is dropped whole when it crosses a block join, lands
            // mid-character, or overlaps a segment the page changed since
            // extraction — never partially wrapped.
            const perNode = new Map();
            const kept = [];
            let conflict = false;
            for (const ri of wanted) {
                const [s, e] = ranges[ri];
                if (!(s < e)) continue;
                const pieces = [];
                let ok = true;
                let cursor = s;
                while (cursor < e) {
                    const si = segmentAt(cursor);
                    if (si < 0) { ok = false; break; }
                    const seg = segments[si];
                    if (seg.start > cursor) { ok = false; break; }
                    if (!seg.node.isConnected || seg.node.nodeValue !== seg.text) {
                        ok = false;
                        conflict = true;
                        break;
                    }
                    const pieceEnd = Math.min(e, seg.start + seg.length);
                    const cs = byteToCharIndex(seg.text, cursor - seg.start);
                    const ce = byteToCharIndex(seg.text, pieceEnd - seg.start);
                    if (cs < 0 || ce < 0 || !(cs < ce)) { ok = false; break; }
                    pieces.push([seg.node, cs, ce]);
                    cursor = pieceEnd;
                }
                if (!ok || cursor !== e) continue;
                const byNode = new Map();
                let connected = true;
                for (const [node, cs, ce] of pieces) {
                    if (!node.isConnected) { connected = false; conflict = true; break; }
                    if (!byNode.has(node)) byNode.set(node, []);
                    byNode.get(node).push([cs, ce, ri]);
                }
                if (!connected) continue;
                kept.push(ri);
                for (const [node, list] of byNode) {
                    if (!perNode.has(node)) perNode.set(node, []);
                    for (const p of list) perNode.get(node).push(p);
                }
            }
            for (const [node, list] of perNode) {
                if (!node.isConnected) continue;
                wrapNodePieces(node, list);
            }
            // Rebuilt in document order. Spans carry their range index, so a
            // match split across nodes still selects as one: `applied` holds
            // spans while `kept` holds range indices, and the two align only
            // when no range needed splitting.
            const found = [];
            const it = document.createNodeIterator(document.body || document.documentElement, NodeFilter.SHOW_ELEMENT, {
                acceptNode(el) {
                    return el.classList && el.classList.contains(HIT) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
                }
            });
            let el;
            while ((el = it.nextNode())) found.push(el);
            applied = found;
            return { kept: kept, conflict: conflict };
        }

        function spansLive() {
            // Every applied span still in the document and still holding the
            // text it wrapped: the page has not touched the highlights.
            for (const span of applied) {
                if (!span.isConnected || span.textContent !== span.__whtvrTx) return false;
            }
            return true;
        }

        function paintRange(ri) {
            for (const span of applied) span.classList.remove(CURRENT);
            const span = applied.find((candidate) => candidate.__whtvrRI === ri);
            let scrolled = false;
            if (span) {
                span.classList.add(CURRENT);
                const rect = span.getBoundingClientRect();
                if (rect.bottom < 0 || rect.top > window.innerHeight || rect.right < 0 || rect.left > window.innerWidth) {
                    span.scrollIntoView({ block: 'center', inline: 'nearest' });
                    scrolled = true;
                }
            }
            return scrolled;
        }

        function posOf(rangeIdx) {
            // Nearest kept range at or before `rangeIdx`: a dropped range
            // still selects something rather than nothing.
            let pos = -1;
            for (let k = 0; k < lastKept.length; k++) {
                if (lastKept[k] <= rangeIdx) pos = k;
                else break;
            }
            return pos;
        }

        function applyMatches(payload) {
            unwrap();
            lastPayload = payload;
            lastKept = [];
            selRange = -1;
            const ranges = (payload && payload.ranges) || [];
            const highlightAll = !payload || payload.highlightAll !== false;
            if (ranges.length === 0) return { stale: false, index: -1, count: 0, scrolled: false };
            let index = (payload && payload.index) || 0;
            if (index < 0 || index >= ranges.length) index = 0;
            selRange = index;
            if (highlightAll) {
                const res = wrapRanges(ranges, ranges.map((_, i) => i));
                if (res.kept.length === 0) {
                    // Raced ranges report stale so the native side runs one
                    // fresh pass; a genuinely absent query reports empty.
                    return res.conflict
                        ? { stale: true }
                        : { stale: false, index: -1, count: 0, scrolled: false };
                }
                lastKept = res.kept;
                const pos = Math.max(0, posOf(selRange));
                selRange = lastKept[pos];
                const scrolled = paintRange(selRange);
                return { stale: false, index: pos, count: lastKept.length, scrolled: scrolled };
            }
            const res = wrapRanges(ranges, [index]);
            if (res.kept.length === 0 && res.conflict) return { stale: true };
            lastKept = res.kept;
            const scrolled = paintRange(selRange);
            return { stale: false, index: index, count: ranges.length, scrolled: scrolled };
        }

        function step(delta) {
            if (!lastPayload) return { stale: false, index: -1, count: 0, scrolled: false };
            const ranges = lastPayload.ranges || [];
            const highlightAll = lastPayload.highlightAll !== false;
            if (highlightAll) {
                if (lastKept.length === 0) return { stale: false, index: -1, count: 0, scrolled: false };
                if (!spansLive()) return { stale: true };
                let pos = posOf(selRange);
                if (pos < 0) pos = delta > 0 ? -1 : 0;
                pos = (pos + delta) % lastKept.length;
                if (pos < 0) pos += lastKept.length;
                selRange = lastKept[pos];
                const scrolled = paintRange(selRange);
                return { stale: false, index: pos, count: lastKept.length, scrolled: scrolled };
            }
            if (ranges.length === 0) return { stale: false, index: -1, count: 0, scrolled: false };
            if (applied.length > 0 && !spansLive()) return { stale: true };
            selRange = (selRange + delta) % ranges.length;
            if (selRange < 0) selRange += ranges.length;
            unwrap();
            const res = wrapRanges(ranges, [selRange]);
            if (res.kept.length === 0 && res.conflict) return { stale: true };
            lastKept = res.kept;
            const scrolled = paintRange(selRange);
            return { stale: false, index: selRange, count: ranges.length, scrolled: scrolled };
        }

        function clear() {
            unwrap();
            lastPayload = null;
            lastKept = [];
            selRange = -1;
            return true;
        }

        window.__whtvrFind = {
            extractText: extractText,
            applyMatches: applyMatches,
            step: step,
            clear: clear
        };
    })();
    """
}
