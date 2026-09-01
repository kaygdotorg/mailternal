import Testing
@testable import MailternalSanitizer

@Test("comment-split url() is stripped")
func cssCommentSplitURL() {
    assertNoRequestBearingCSS("background: u/**/rl(https://evil.example/x.png);")
    assertNoRequestBearingCSS("background: url/**/(https://evil.example/x.png);")
    assertNoRequestBearingCSS("background: u/*x*/rl(/*y*/https://evil.example/x.png);")
}

@Test("comment-split @import is stripped")
func cssCommentSplitImport() {
    let css = #"@im/**/port url("https://evil.example/sheet.css"); p { color: #111; }"#
    let out = CSSSanitizer.sanitize(css)
    assertNoRequestBearingCSS(css)
    #expect(out.lowercased().contains("color"))
}

@Test("comment-split expression() is stripped")
func cssCommentSplitExpression() {
    assertNoRequestBearingCSS("width: exp/**/ression(alert(1));")
    assertNoRequestBearingCSS("width: expression/**/(alert(1));")
}

@Test("hex-escape url() with terminator space is stripped")
func cssEscapeSequenceURL() {
    assertNoRequestBearingCSS(#"background:\75\72\6c(https://evil.example/x.png);"#)
    assertNoRequestBearingCSS(#"background:\75 r\6c(https://evil.example/x.png);"#)
    assertNoRequestBearingCSS(#"background:\75/**/\72\6c(https://evil.example/x.png);"#)
}

@Test("mixed-case url() and @import are stripped")
func cssMixedCaseRequestTokens() {
    assertNoRequestBearingCSS("background: URL(https://evil.example/x.png);")
    assertNoRequestBearingCSS("background: Url(https://evil.example/x.png);")
    assertNoRequestBearingCSS(#"@IMPORT url("https://evil.example/x.css");"#)
    assertNoRequestBearingCSS(#"@Import URL("https://evil.example/x.css");"#)
}

@Test("escaped comment delimiters cannot hide url()")
func cssEscapedCommentDelimiters() {
    // \2f\2a = /*  ;  \2a\2f = */
    assertNoRequestBearingCSS(#"\2f\2a url(https://evil.example/x.png) \2a\2f body { color: #111; }"#)
}

@Test("unclosed comment drops the rest of the stylesheet")
func cssUnclosedCommentFailClosed() {
    let out = CSSSanitizer.sanitize("color: red; /* url(https://evil.example/x.png)")
    #expect(!out.contains("evil.example"))
    #expect(!out.lowercased().contains("url("))
}

@Test("paint policy rejects url() and keeps colors")
func cssPaintPolicy() {
    #expect(CSSSanitizer.sanitizedPaint("url(https://evil.example/x.png)") == nil
        || CSSSanitizer.sanitizedPaint("url(https://evil.example/x.png)") == "none")
    let urlPaint = CSSSanitizer.sanitizedPaint("url(https://evil.example/x.png)")
    #expect(urlPaint != "url(https://evil.example/x.png)")
    #expect(urlPaint == nil || (urlPaint.map { CSSSanitizer.isURLFree($0) && CSSSanitizer.isColorOrPaint($0) } ?? true))
    #expect(!((urlPaint ?? "").contains("evil.example")))
    #expect(CSSSanitizer.sanitizedPaint("u/**/rl(https://evil.example/x.png)") != "u/**/rl(https://evil.example/x.png)")
    #expect(!((CSSSanitizer.sanitizedPaint("u/**/rl(https://evil.example/x.png)") ?? "").contains("evil.example")))
    #expect(CSSSanitizer.sanitizedPaint("#00ff00") == "#00ff00")
    #expect(CSSSanitizer.sanitizedPaint("red") == "red")
    #expect(CSSSanitizer.sanitizedPaint("none") == "none")
    #expect(CSSSanitizer.sanitizedPaint("RGB(1, 2, 3)")?.lowercased().hasPrefix("rgb(") == true)
}

private func assertNoRequestBearingCSS(_ css: String) {
    let out = CSSSanitizer.sanitize(css)
    let lowered = out.lowercased()
    #expect(!lowered.contains("url("), "still had url(): \(out)")
    #expect(!lowered.contains("@import"), "still had @import: \(out)")
    #expect(!lowered.contains("expression("), "still had expression(): \(out)")
    #expect(!out.contains("evil.example"), "still had host: \(out)")
}
