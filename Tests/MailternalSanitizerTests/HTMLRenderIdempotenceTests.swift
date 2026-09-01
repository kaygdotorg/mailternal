import Testing
@testable import MailternalSanitizer

@Test("identical html hashes deterministically")
func htmlHashIsStable() {
    let html = "<p>Hello</p>"
    #expect(HTMLRenderIdempotence.hash(html) == HTMLRenderIdempotence.hash(html))
    #expect(HTMLRenderIdempotence.hash(html) != HTMLRenderIdempotence.hash("<p>Hello!</p>"))
}

@Test("first render always loads")
func firstRenderLoads() {
    let next = HTMLRenderIdempotence.identity(html: "<p>a</p>", remoteAllowed: false)
    #expect(HTMLRenderIdempotence.action(displayed: nil, next: next) == .load)
}

@Test("same html and remoteAllowed skips loadHTMLString")
func unchangedIdentitySkips() {
    let identity = HTMLRenderIdempotence.identity(html: "<p>a</p>", remoteAllowed: false)
    #expect(HTMLRenderIdempotence.action(displayed: identity, next: identity) == .skip)
    // SwiftUI updateNSView churn: same pair again.
    let again = HTMLRenderIdempotence.identity(html: "<p>a</p>", remoteAllowed: false)
    #expect(HTMLRenderIdempotence.action(displayed: identity, next: again) == .skip)
}

@Test("html change loads even if remoteAllowed is unchanged")
func htmlChangeLoads() {
    let displayed = HTMLRenderIdempotence.identity(html: "<p>a</p>", remoteAllowed: false)
    let next = HTMLRenderIdempotence.identity(html: "<p>b</p>", remoteAllowed: false)
    #expect(HTMLRenderIdempotence.action(displayed: displayed, next: next) == .load)
}

@Test("remote-consent change loads via its own identity, not a fresh html render")
func remoteConsentChangeLoads() {
    let html = "<p>a</p>"
    let displayed = HTMLRenderIdempotence.identity(html: html, remoteAllowed: false)
    // Representable still calls render() first with the current (old) remote flag.
    let renderTick = HTMLRenderIdempotence.identity(html: html, remoteAllowed: false)
    #expect(HTMLRenderIdempotence.action(displayed: displayed, next: renderTick) == .skip)
    // setRemoteImagesAllowed(true) then changes the identity.
    let consented = HTMLRenderIdempotence.identity(html: html, remoteAllowed: true)
    #expect(HTMLRenderIdempotence.action(displayed: displayed, next: consented) == .load)
}

@Test("toggling remote allowed back to the displayed pair skips")
func remoteConsentIdempotent() {
    let html = "<p>a</p>"
    let displayed = HTMLRenderIdempotence.identity(html: html, remoteAllowed: true)
    let same = HTMLRenderIdempotence.identity(html: html, remoteAllowed: true)
    #expect(HTMLRenderIdempotence.action(displayed: displayed, next: same) == .skip)
}
