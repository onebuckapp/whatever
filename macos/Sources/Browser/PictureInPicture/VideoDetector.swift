// Whatever Browser – Made by Humans from OpenPeeps
//
//     Copyright (C) 2026 George Lemon <georgelemon@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import WebKit

/// A page's video report: its eligible `<video>` elements, whether this
/// document currently holds a PiP window, and whether our floating
/// fallback owns one of its videos.
struct VideoReport: Equatable, Sendable {
    var candidates: [VideoCandidate] = []
    var pipActive = false
    var floating = false

    /// Parses a detector message body. Malformed bodies parse to an empty
    /// report rather than throwing: a page that re-renders mid-report must
    /// not break the toolbar.
    static func parse(_ body: Any?) -> VideoReport {
        guard let raw = body as? [String: Any] else {
            return VideoReport()
        }
        let videos = raw["videos"] as? [[String: Any]] ?? []
        return VideoReport(
            candidates: videos.compactMap(VideoCandidate.init(raw:)),
            pipActive: raw["pip"] as? Bool ?? false,
            floating: raw["floating"] as? Bool ?? false
        )
    }
}

/// One `<video>` element its frame reported, in that frame's order.
/// Indices are frame-local: entering resolves them inside the reporting
/// frame (see the traversal), never against the top document.
struct VideoCandidate: Hashable, Sendable {
    /// Position among its own frame's videos.
    let index: Int
    /// Actually advancing: not paused or ended, with data and a position.
    let isPlaying: Bool
    /// Rendered area in pixels. Zero or negative never wins selection.
    let area: Double
    /// Unmuted with volume up. Only a tie-break, never a requirement:
    /// muted autoplay clips are still watchable in PiP.
    let audible: Bool
    /// Media length in seconds. `-1` means live or unknown (Infinity and
    /// NaN both arrive so): a live stream outranks a clip, and an
    /// unmeasured element is never penalized for it.
    let duration: Double
    /// Whether the element demonstrably carries sound (decoded audio, an
    /// audio track — WebKit has no `mozHasAudio`). Ordering input only.
    let hasAudio: Bool
    /// Whether the page asked us not to PiP this element. Deprioritized,
    /// not disqualified: entry strips the attribute, so the button still
    /// works — and the failure facts still name it.
    let disabled: Bool
    /// Whether the element holds keyboard focus. A focused video is the
    /// one the user is driving, so it jumps the queue (Firefox's
    /// `findVideoToPiP` leads with `activeElement` the same way).
    let focused: Bool
    /// The element's current source, for debugging only.
    let src: String

    /// Live-or-unknown durations sort longest: `Infinity` never loses a
    /// comparison, and `-1` (our live/unknown marker) maps to it.
    var rankDuration: Double {
        duration < 0 ? .infinity : duration
    }

    init?(raw: [String: Any]) {
        guard let index = raw["index"] as? Int,
              let isPlaying = raw["playing"] as? Bool,
              let area = raw["area"] as? Double,
              let audible = raw["audible"] as? Bool
        else {
            return nil
        }
        self.index = index
        self.isPlaying = isPlaying
        self.area = area
        self.audible = audible
        self.duration = raw["duration"] as? Double ?? -1
        self.hasAudio = raw["hasAudio"] as? Bool ?? true
        self.disabled = raw["disabled"] as? Bool ?? false
        self.focused = raw["focused"] as? Bool ?? false
        self.src = raw["src"] as? String ?? ""
    }
}

/// Picks the video that enters Picture in Picture: the focused playing
/// one first, then the largest, preferring audible, undisabled, and
/// longer (live longest) on ties, then document order.
///
/// Reports the page's `<video>` elements to native code, so the toolbar
/// can offer Picture in Picture while one is playing. The script runs in
/// every frame, and each frame reports and enters for itself: a player
/// inside an embed is invisible to the top document's `querySelectorAll`,
/// and cross-origin frames are unreachable from it, so the top frame
/// could never drive them.
///
/// Capture-phase media listeners (`playing`/`pause`/`emptied`, which do
/// not bubble) plus a subtree `MutationObserver` for SPA re-renders that
/// swap nodes without media events. Reports the whole snapshot but only
/// on change, so play/pause toggles move the button without a poll.
/// Elements under 64x64 never report: tracking pixels and audio stubs
/// must not light the button.
///
/// Always on, like the hover reporter: tiny, idempotent, and harmless on
/// pages with no video.
///
/// The selection rule is pure inputs, so it is unit-testable without
/// WebKit. Paused, sizeless, and empty reports all answer nil: the
/// toolbar hides. The in-page `bestIndex` mirrors it; keep the two in
/// step if the rule ever changes.
enum VideoDetector {
    static func pickBestVideo(from candidates: [VideoCandidate]) -> VideoCandidate? {
        candidates
            .filter { $0.isPlaying && $0.area > 0 }
            .sorted {
                if $0.focused != $1.focused { return $0.focused }
                if $0.area != $1.area { return $0.area > $1.area }
                if $0.audible != $1.audible { return $0.audible }
                if $0.disabled != $1.disabled { return !$0.disabled }
                if $0.rankDuration != $1.rankDuration { return $0.rankDuration > $1.rankDuration }
                return $0.index < $1.index
            }
            .first
    }

    static let handlerName = "whateverVideo"

    private static let installed = "__whateverVideo"

    /// Rendered area under which an element is presumed not watchable.
    private static let minimumArea = 64 * 64

    static var source: String {
        """
        (() => {
            if (window.\(installed)) return;
            // Every <video> in this document, piercing open shadow roots:
            // players built as web components hide their element inside
            // one. Same-document only: frames are reached by traversal,
            // never here, because cross-origin frames are unreachable and
            // every frame runs this same script for itself.
            const findLocal = () => {
                const out = [];
                const visit = (root) => {
                    if (!root || typeof root.querySelectorAll !== "function") return;
                    const videos = root.querySelectorAll("video");
                    for (let i = 0; i < videos.length; i++) out.push(videos[i]);
                    const hosts = root.querySelectorAll("*");
                    for (let i = 0; i < hosts.length; i++) {
                        const shadow = hosts[i].shadowRoot;
                        if (shadow) visit(shadow);
                    }
                };
                visit(document);
                return out;
            };
            const describe = (v, i) => {
                let w = v.videoWidth || 0, h = v.videoHeight || 0;
                if ((!w || !h) && v.getBoundingClientRect) {
                    const r = v.getBoundingClientRect();
                    w = r.width; h = r.height;
                }
                // Duration is -1 for live and unmeasured alike: a live
                // stream outranks a clip, and an element without metadata
                // yet is never penalized for it. JSON cannot carry
                // Infinity or NaN, so the marker travels instead.
                let duration = -1;
                try {
                    const d = v.duration;
                    if (typeof d === "number" && isFinite(d)) duration = d;
                } catch (e) { /* unmeasured */ }
                // WebKit has no mozHasAudio: decoded bytes or an audio
                // track prove sound; anything else answers unknown-true
                // so the ordering never hides a video for it.
                let hasAudio = true;
                try {
                    hasAudio = (typeof v.mozHasAudio === "boolean") ? v.mozHasAudio
                        : ((v.audioTracks && v.audioTracks.length > 0)
                            || v.webkitAudioDecodedByteCount > 0
                            || (!v.muted && v.volume > 0));
                } catch (e) { /* unknown */ }
                let focused = false, disabled = false;
                try {
                    focused = (v.ownerDocument || document).activeElement === v;
                    disabled = !!v.disablePictureInPicture;
                } catch (e) { /* flags stay default */ }
                return {
                    index: i,
                    playing: !v.paused && !v.ended && v.readyState >= 2 && v.currentTime > 0,
                    area: w * h,
                    audible: !v.muted && v.volume > 0,
                    duration: duration,
                    hasAudio: hasAudio,
                    disabled: disabled,
                    focused: focused,
                    src: v.currentSrc || ""
                };
            };
            const snapshot = () => {
                const out = [];
                const videos = findLocal();
                for (let i = 0; i < videos.length; i++) {
                    const c = describe(videos[i], i);
                    if (c.area < \(minimumArea)) continue;
                    out.push(c);
                }
                return out;
            };
            // Best local candidate, mirroring `pickBestVideo` above.
            // A comparator, not a ternary chain: iterating in document
            // order and keeping the incumbent on full ties reproduces
            // the index-ascending last resort.
            const rankDuration = (d) => (d < 0 ? Infinity : d);
            const better = (c, b) => {
                if (!b) return true;
                if (c.focused !== b.focused) return c.focused;
                if (c.area !== b.area) return c.area > b.area;
                if (c.audible !== b.audible) return c.audible;
                if (c.disabled !== b.disabled) return !c.disabled;
                const dc = rankDuration(c.duration), db = rankDuration(b.duration);
                if (dc !== db) return dc > db;
                return false;
            };
            const bestIndex = () => {
                const videos = findLocal();
                let best = -1, bestDesc = null;
                for (let i = 0; i < videos.length; i++) {
                    const c = describe(videos[i], i);
                    if (!c.playing || c.area <= 0) continue;
                    if (better(c, bestDesc)) { best = i; bestDesc = c; }
                }
                return best;
            };
            const enterAt = (index) => {
                const v = findLocal()[index];
                if (!v) return "missing";
                try { v.removeAttribute("disablepictureinpicture"); } catch (e) { /* plain */ }
                const doc = v.ownerDocument || document;
                // Element facts ride on every failure answer, so a dead
                // button can say why: `Name|rs4|p0|d0`.
                const facts = () => {
                    try {
                        return "|rs" + v.readyState + "|p" + (v.paused ? 1 : 0)
                            + "|d" + (v.disablePictureInPicture ? 1 : 0);
                    } catch (e) { return ""; }
                };
                try {
                    if (doc.pictureInPictureElement === v) return "ok";
                } catch (e) { /* compare failed */ }
                // The Safari attempt's error is the signal when both fail:
                // the standard request failing without a gesture is noise.
                let webkitError = null;
                try {
                    if (typeof v.webkitSetPresentationMode === "function") {
                        v.webkitSetPresentationMode("picture-in-picture");
                        return "ok";
                    }
                } catch (e) { webkitError = (e && e.name) || "failed"; }
                if (!doc.pictureInPictureEnabled) return "unsupported" + facts();
                if (typeof v.requestPictureInPicture !== "function") {
                    return (webkitError || "unsupported") + facts();
                }
                // Fired, not awaited: the PiP events below report the
                // outcome, and a page promise never crosses the native
                // bridge back (see `enterPictureInPictureSource`).
                try {
                    v.requestPictureInPicture();
                    return "pending";
                } catch (e) {
                    return (webkitError || ((e && e.name) || "failed")) + facts();
                }
            };
            // In-page floating fallback. The box and slot are ours; the
            // video keeps playing because it never leaves the document.
            // A marker holds its layout spot so the page does not jump,
            // and the original inline style is restored on close.
            const floatId = "__whateverFloat";
            const floatSlotId = "__whateverFloatSlot";
            let floatingVideo = null;
            let floatingParent = null;
            let floatingSlot = null;
            let floatingCss = "";
            let floatMutating = false;
            const floatBox = () => {
                try { return document.getElementById(floatId); }
                catch (e) { return null; }
            };
            const makeFloatBox = () => {
                const box = document.createElement("div");
                box.id = floatId;
                box.setAttribute("style", "position:fixed;right:16px;bottom:16px;width:min(480px,40vw);aspect-ratio:16/10;max-height:40vh;background:#000;border-radius:10px;box-shadow:0 8px 32px rgba(0,0,0,.55);z-index:2147483647;overflow:hidden;display:flex;flex-direction:column;");
                const bar = document.createElement("div");
                bar.setAttribute("style", "height:28px;flex:0 0 28px;display:flex;align-items:center;justify-content:flex-end;padding:0 6px;background:rgba(20,20,22,.85);cursor:move;user-select:none;-webkit-user-select:none;");
                const close = document.createElement("button");
                close.textContent = "\\u00d7";
                close.setAttribute("aria-label", "Close floating video");
                close.setAttribute("style", "border:0;background:transparent;color:#fff;font-size:16px;line-height:1;cursor:pointer;padding:2px 8px;");
                close.addEventListener("click", (e) => {
                    e.stopPropagation();
                    try { window.\(installed).unfloat(); } catch (err) { /* gone */ }
                });
                bar.appendChild(close);
                box.appendChild(bar);
                // Drag by the bar: pin to left/top on first move so the
                // right/bottom anchor stops fighting the cursor.
                bar.addEventListener("mousedown", (e) => {
                    if (e.target !== bar) return;
                    e.preventDefault();
                    const startX = e.clientX, startY = e.clientY;
                    const rect = box.getBoundingClientRect();
                    box.style.left = rect.left + "px";
                    box.style.top = rect.top + "px";
                    box.style.right = "auto";
                    box.style.bottom = "auto";
                    const move = (ev) => {
                        box.style.left = (rect.left + ev.clientX - startX) + "px";
                        box.style.top = (rect.top + ev.clientY - startY) + "px";
                    };
                    const up = () => {
                        window.removeEventListener("mousemove", move);
                        window.removeEventListener("mouseup", up);
                    };
                    window.addEventListener("mousemove", move);
                    window.addEventListener("mouseup", up);
                });
                // If the page yanks our video out of the box (player
                // re-render mid-ad), adopt the best one again rather
                // than sitting empty.
                new MutationObserver(() => {
                    if (floatMutating) return;
                    try {
                        if (floatingVideo && floatingVideo.parentNode !== box) {
                            window.\(installed).floatBest();
                        }
                    } catch (err) { /* page churn */ }
                }).observe(box, { childList: true });
                (document.documentElement || document.body || document).appendChild(box);
                return box;
            };
            const adoptFloat = (v) => {
                try {
                    if (!v || !v.parentNode) return false;
                    if (floatingVideo === v && v.parentNode === floatBox()) return true;
                    floatMutating = true;
                    try { unfloat(); } catch (e) { /* nothing held */ }
                    const box = floatBox() || makeFloatBox();
                    const slot = document.createElement("div");
                    slot.id = floatSlotId;
                    try {
                        const r = v.getBoundingClientRect();
                        if (r && r.width > 0 && r.height > 0) {
                            slot.setAttribute("style", "width:" + r.width + "px;height:" + r.height + "px;");
                        }
                    } catch (e) { /* marker stays collapsed */ }
                    floatingParent = v.parentNode;
                    floatingSlot = slot;
                    floatingCss = v.style ? v.style.cssText : "";
                    floatingParent.insertBefore(slot, v);
                    box.appendChild(v);
                    v.style.width = "100%";
                    v.style.height = "100%";
                    v.style.flex = "1 1 auto";
                    v.style.minHeight = "0";
                    v.style.margin = "0";
                    v.style.background = "#000";
                    floatingVideo = v;
                    return true;
                } catch (e) {
                    return false;
                } finally {
                    floatMutating = false;
                    try { report(); } catch (e) { /* bridge gone */ }
                }
            };
            const unfloat = () => {
                try {
                    const v = floatingVideo;
                    const box = floatBox();
                    if (!v) {
                        if (box) box.remove();
                        return "idle";
                    }
                    floatMutating = true;
                    try {
                        if (floatingSlot && floatingSlot.isConnected && floatingSlot.parentNode) {
                            floatingSlot.parentNode.insertBefore(v, floatingSlot);
                        } else if (document.body) {
                            document.body.appendChild(v);
                        } else {
                            document.documentElement.appendChild(v);
                        }
                        v.style.cssText = floatingCss;
                    } catch (e) { /* restore best-effort */ }
                    try {
                        if (floatingSlot && floatingSlot.parentNode) floatingSlot.remove();
                        if (box) box.remove();
                    } catch (e) { /* chrome gone */ }
                    floatingVideo = null;
                    floatingParent = null;
                    floatingSlot = null;
                    floatingCss = "";
                    return "ok";
                } catch (e) {
                    return "failed";
                } finally {
                    floatMutating = false;
                    try { report(); } catch (e) { /* bridge gone */ }
                }
            };
            window.\(installed) = {
                // Synchronous throughout, so the answer is a plain string
                // the native bridge can always carry.
                enterBest: () => {
                    const i = bestIndex();
                    if (i < 0) return "none";
                    return enterAt(i);
                },
                // The in-page floating fallback: when the system refuses
                // PiP, the best video moves into a draggable box we own.
                // Same-document, so playback, DRM, and adaptive streams
                // keep working — and a swapped element is simply adopted
                // again, which is what kills the silent DAI failures.
                floatBest: () => {
                    const i = bestIndex();
                    if (i < 0) return "none";
                    const v = findLocal()[i];
                    if (!v) return "missing";
                    return adoptFloat(v) ? "ok" : "failed";
                },
                unfloat: () => unfloat(),
                exit: () => {
                    try {
                        if (document.pictureInPictureElement) {
                            document.exitPictureInPicture();
                            return "ok";
                        }
                        const videos = findLocal();
                        for (const v of videos) {
                            try {
                                if (v.webkitPresentationMode === "picture-in-picture"
                                    && typeof v.webkitSetPresentationMode === "function") {
                                    v.webkitSetPresentationMode("inline");
                                    return "ok";
                                }
                            } catch (e) { /* next element */ }
                        }
                        return "idle";
                    } catch (e) {
                        return (e && e.name) || "failed";
                    }
                }
            };
            let last = "";
            // A broadcast from the top frame tells every frame to enter
            // (or exit, float, unfloat) its own best video. Delivery is
            // one-way: promises do not settle back across frame realms, so
            // the call carries no answer — the frame's PiP events report
            // back through the normal channel below. Only the top frame
            // may direct; anything else posting here is the page talking
            // to itself.
            // Listened unconditionally, like the API above: entering must
            // not depend on the report bridge existing.
            window.addEventListener("message", (event) => {
                let command = null;
                try {
                    if (event.source !== window.top) return;
                    command = event.data && event.data.__whateverVideoCommand;
                } catch (e) { return; }
                if (command !== "enter" && command !== "exit"
                    && command !== "float" && command !== "unfloat") return;
                try {
                    if (command === "enter") window.\(installed).enterBest();
                    else if (command === "exit") window.\(installed).exit();
                    else if (command === "float") window.\(installed).floatBest();
                    else window.\(installed).unfloat();
                } catch (e) { /* nothing playing */ }
            });
            // Reporting needs the bridge, but entering does not: the API
            // above is assigned unconditionally so PiP keeps working where
            // the handler is missing.
            const post = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.\(handlerName);
            if (!post) return;
            const report = () => {
                let current;
                try {
                    // Safari's legacy PiP never sets pictureInPictureElement,
                    // so a successful webkit entry would otherwise leave the
                    // toolbar offering enter forever: any element presenting
                    // counts as active too.
                    let webkitPip = false;
                    try {
                        const videos = findLocal();
                        for (const v of videos) {
                            if (v.webkitPresentationMode === "picture-in-picture") {
                                webkitPip = true;
                                break;
                            }
                        }
                    } catch (e) { /* stays false */ }
                    current = JSON.stringify({
                        videos: snapshot(),
                        pip: document.pictureInPictureElement != null || webkitPip,
                        floating: !!document.getElementById(floatId)
                    });
                } catch (e) { return; }
                if (current === last) return;
                last = current;
                try { post.postMessage(JSON.parse(current)); } catch (e) { /* gone */ }
            };
            // Media events do not bubble, so capture at the document.
            const mediaEvents = ["playing", "pause", "emptied", "seeked"];
            for (const name of mediaEvents) {
                document.addEventListener(name, report, true);
            }
            // Entering or leaving PiP changes no media state, so the set
            // above never fires for it: watch the PiP events explicitly to
            // flip the toolbar button between enter and exit.
            for (const name of ["enterpictureinpicture", "leavepictureinpicture"]) {
                document.addEventListener(name, report, true);
            }
            const observer = new MutationObserver(report);
            const watch = () => {
                if (document.documentElement) {
                    observer.observe(document.documentElement, { childList: true, subtree: true });
                }
            };
            watch();
            document.addEventListener("DOMContentLoaded", watch);
            // An autoplaying video may already run on first paint.
            document.addEventListener("DOMContentLoaded", report);
            window.addEventListener("pageshow", report);
        })();
        """
    }

    static var script: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Moves the best video into PiP and answers `"ok"`, `"pending"`,
    /// `"none"`, or `"broadcast"`.
    ///
    /// Asks the top frame's detector first; when it has nothing playing,
    /// broadcasts to every reachable frame and each enters its own best
    /// video. The broadcast is one-way — promises never settle back
    /// across frame realms — so embedded players are driven, not queried:
    /// a player inside an embed is invisible to the top document's
    /// `querySelectorAll`, and cross-origin frames are unreachable any
    /// other way. Prefers Safari's `webkitSetPresentationMode`: it is
    /// synchronous and needs no page gesture, while the standard
    /// `requestPictureInPicture` rejects without transient activation —
    /// and a native toolbar click is not one. Everything here is
    /// synchronous, so the answer is always a plain string: the outcome
    /// itself arrives through the PiP events, which flip the toolbar
    /// button with no poll.
    static func enterPictureInPictureSource() -> String {
        """
        (() => {
            try {
                const api = window.__whateverVideo;
                if (api && typeof api.enterBest === "function") {
                    const answer = api.enterBest();
                    if (answer === "ok" || answer === "pending") return answer;
                }
            } catch (e) { /* top has nothing */ }
            try {
                const broadcast = (w, depth) => {
                    if (depth > 8) return;
                    try { w.postMessage({ __whateverVideoCommand: "enter" }, "*"); } catch (e) {}
                    let n = 0;
                    try { n = w.frames ? w.frames.length : 0; } catch (e) { return; }
                    for (let i = 0; i < n; i++) {
                        try { const c = w.frames[i]; if (c) broadcast(c, depth + 1); } catch (e) {}
                    }
                };
                broadcast(window, 0);
            } catch (e) { /* nothing reachable */ }
            return "broadcast";
        })()
        """
    }

    /// Closes the page's PiP windows and answers `"ok"` or `"idle"`.
    /// Enters nothing: the top frame exits its own session, then every
    /// reachable frame is told to exit, so one press closes all of them
    /// however they were opened. Synchronous like the entry.
    static var exitPictureInPictureSource: String {
        """
        (() => {
            let answer = "idle";
            try {
                const api = window.__whateverVideo;
                if (api && typeof api.exit === "function") answer = api.exit();
            } catch (e) { /* top holds none */ }
            try {
                const broadcast = (w, depth) => {
                    if (depth > 8) return;
                    try { w.postMessage({ __whateverVideoCommand: "exit" }, "*"); } catch (e) {}
                    let n = 0;
                    try { n = w.frames ? w.frames.length : 0; } catch (e) { return; }
                    for (let i = 0; i < n; i++) {
                        try { const c = w.frames[i]; if (c) broadcast(c, depth + 1); } catch (e) {}
                    }
                };
                broadcast(window, 0);
            } catch (e) { /* nothing reachable */ }
            return answer;
        })()
        """
    }

    /// Floats the best video into the page's own draggable box and
    /// answers `"ok"`, `"none"`, or `"broadcast"`.
    ///
    /// Same top-first-then-broadcast shape as the native entry: the top
    /// frame floats its best video, and when it has none every reachable
    /// frame is told to float its own. The box lives in the video's own
    /// document, so playback never crosses a realm — this is the answer
    /// when the system refuses PiP, not a second PiP.
    static func floatPictureInPictureSource() -> String {
        """
        (() => {
            try {
                const api = window.__whateverVideo;
                if (api && typeof api.floatBest === "function") {
                    const answer = api.floatBest();
                    if (answer === "ok") return answer;
                }
            } catch (e) { /* top has nothing */ }
            try {
                const broadcast = (w, depth) => {
                    if (depth > 8) return;
                    try { w.postMessage({ __whateverVideoCommand: "float" }, "*"); } catch (e) {}
                    let n = 0;
                    try { n = w.frames ? w.frames.length : 0; } catch (e) { return; }
                    for (let i = 0; i < n; i++) {
                        try { const c = w.frames[i]; if (c) broadcast(c, depth + 1); } catch (e) {}
                    }
                };
                broadcast(window, 0);
            } catch (e) { /* nothing reachable */ }
            return "broadcast";
        })()
        """
    }

    /// Returns the floated video to its page slot and answers `"ok"` or
    /// `"idle"`. Top frame first, then every reachable frame, like exit.
    static var unfloatPictureInPictureSource: String {
        """
        (() => {
            let answer = "idle";
            try {
                const api = window.__whateverVideo;
                if (api && typeof api.unfloat === "function") answer = api.unfloat();
            } catch (e) { /* top holds none */ }
            try {
                const broadcast = (w, depth) => {
                    if (depth > 8) return;
                    try { w.postMessage({ __whateverVideoCommand: "unfloat" }, "*"); } catch (e) {}
                    let n = 0;
                    try { n = w.frames ? w.frames.length : 0; } catch (e) { return; }
                    for (let i = 0; i < n; i++) {
                        try { const c = w.frames[i]; if (c) broadcast(c, depth + 1); } catch (e) {}
                    }
                };
                broadcast(window, 0);
            } catch (e) { /* nothing reachable */ }
            return answer;
        })()
        """
    }
}

/// Forwards video reports to the owning view.
///
/// The content controller retains its message handlers, so this holds the
/// view weakly; the view holds the relay strongly, and neither direction
/// leaks. One relay per page: the script-list rebuild installs a fresh one
/// alongside the scripts.
final class VideoReportRelay: NSObject, WKScriptMessageHandler {
    weak var view: BrowserWebView?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == VideoDetector.handlerName,
              let view, message.webView === view
        else { return }
        let report = VideoReport.parse(message.body)
        Task { @MainActor [weak view] in
            view?.onVideoReport?(report)
        }
    }
}
