import XCTest

final class PartFetchRoutingTests: XCTestCase {
    func testRoutesRemoteHTTPAwayFromIMAP() {
        XCTAssertEqual(
            PartFetchRouting.route("https://cdn.example/a.png"),
            .remote(URL(string: "https://cdn.example/a.png")!)
        )
        XCTAssertEqual(
            PartFetchRouting.route("http://cdn.example/a.png"),
            .remote(URL(string: "http://cdn.example/a.png")!)
        )
        XCTAssertEqual(PartFetchRouting.route("cid:photo@mail"), .imap("cid:photo@mail"))
        XCTAssertEqual(PartFetchRouting.route("1.2"), .imap("1.2"))
        XCTAssertEqual(PartFetchRouting.route("1.2.HEADER"), .imap("1.2.HEADER"))
        XCTAssertNil(PartFetchRouting.route(""))
        XCTAssertNil(PartFetchRouting.route("   "))
    }

    func testDispatchNeverCallsIMAPForRemoteReference() async throws {
        var imapParts: [String] = []
        var remoteURLs: [URL] = []
        let remote = try await PartFetchRouting.dispatch(
            reference: "https://evil.example/pixel.png",
            imap: { part in
                imapParts.append(part)
                return (Data(), "application/octet-stream")
            },
            remote: { url in
                remoteURLs.append(url)
                return (Data([0x89, 0x50]), "image/png")
            }
        )
        XCTAssertTrue(imapParts.isEmpty)
        XCTAssertEqual(remoteURLs.map(\.absoluteString), ["https://evil.example/pixel.png"])
        XCTAssertEqual(remote.mimeType, "image/png")

        let inline = try await PartFetchRouting.dispatch(
            reference: "cid:photo@mail",
            imap: { part in
                imapParts.append(part)
                return (Data([1]), "image/jpeg")
            },
            remote: { url in
                remoteURLs.append(url)
                return (Data(), "image/png")
            }
        )
        XCTAssertEqual(imapParts, ["cid:photo@mail"])
        XCTAssertEqual(remoteURLs.count, 1)
        XCTAssertEqual(inline.mimeType, "image/jpeg")
    }

    func testDeclaredImageMIMERejectsNonImages() {
        let image = HTTPURLResponse(
            url: URL(string: "https://example.com/a.png")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png; charset=binary"]
        )!
        XCTAssertEqual(RemoteImageFetch.declaredImageMIME(image), "image/png")
        let html = HTTPURLResponse(
            url: URL(string: "https://example.com/a.png")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        XCTAssertNil(RemoteImageFetch.declaredImageMIME(html))
    }
}
