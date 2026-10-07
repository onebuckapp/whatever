import Foundation
import Testing
@testable import Whatever

/// Download history decoding: the JSON contract with the store service.
/// Unknown states and id-less rows are skipped rather than misrendered, so a
/// future core can extend states without old app builds showing nonsense.
struct DownloadsModelTests {
    private func payload(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: rows)
    }

    private func row(id: String = "dl-1", state: String = "done") -> [String: Any] {
        [
            "id": id,
            "sourceURL": "https://example.com/a.zip",
            "filename": "a.zip",
            "destinationPath": "/Users/test/Downloads/a.zip",
            "bytesExpected": 1000,
            "bytesReceived": 1000,
            "state": state,
            "errorText": "",
            "startedAt": 1_700_000_100,
            "finishedAt": 1_700_000_200,
        ]
    }

    @Test("rows decode with dates and states")
    func decodesRows() {
        let items = DownloadItem.decodeList(payload([row()]))
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.id == "dl-1")
        #expect(item.filename == "a.zip")
        #expect(item.state == .done)
        #expect(item.bytesExpected == 1000)
        #expect(item.startedAt == Date(timeIntervalSince1970: 1_700_000_100))
    }

    @Test("unknown states and id-less rows are skipped")
    func skipsUnknownRows() {
        let items = DownloadItem.decodeList(payload([
            row(id: "ok"),
            row(id: "future", state: "streaming"),
            ["sourceURL": "https://example.com/x"],
        ]))
        #expect(items.map(\.id) == ["ok"])
    }

    @Test("progress fraction only while determinate")
    func fractionRules() {
        let running = DownloadItem.decodeList(payload([row(id: "r", state: "in-progress")]))[0]
        #expect(running.fraction == 1)
        let indeterminate = DownloadItem.decodeList(payload([row(id: "u", state: "done")]))[0]
        #expect(indeterminate.fraction == nil)
    }

    @Test("badge center counts unseen until opened")
    @MainActor
    func badgeCenter() {
        let center = DownloadsBadgeCenter()
        #expect(center.unseenCount == 0)
        center.noteFinished(id: "a")
        center.noteFinished(id: "a")
        center.noteFinished(id: "b")
        #expect(center.unseenCount == 2)
        center.markAllSeen()
        #expect(center.unseenCount == 0)
    }

    @Test("attachment disposition downloads even renderable MIME types")
    func attachmentRule() {
        func response(mime: String, disposition: String?) -> URLResponse {
            var headers: [String: String] = ["Content-Type": mime]
            if let disposition {
                headers["Content-Disposition"] = disposition
            }
            return HTTPURLResponse(
                url: URL(string: "https://example.com/photo.jpg")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
        }
        // The Unsplash case: a viewable image the server says to save.
        #expect(NavigationController.servesAttachment(
            response(mime: "image/jpeg", disposition: "attachment; filename=\"photo.jpg\"")))
        // Inline renderables flow through.
        #expect(!NavigationController.servesAttachment(
            response(mime: "image/jpeg", disposition: nil)))
        #expect(!NavigationController.servesAttachment(
            response(mime: "text/html", disposition: "inline")))
        // Non-HTTP responses never count as attachments.
        #expect(!NavigationController.servesAttachment(
            URLResponse(
                url: URL(string: "file:///tmp/a.pdf")!,
                mimeType: "application/pdf",
                expectedContentLength: 10,
                textEncodingName: nil
            )))
    }
}
