import Foundation
import SwiftSoup

/// Allowlist-first sanitizer for untrusted email HTML (spec: `docs/spec/sync.md`
/// HTML isolation). This is a security boundary, not a style pass.
///
/// # Policy
/// The walker is **allowlist-first**: every element and attribute must match
/// ``Allowlist``. Constructs that can initiate a request or run script are
/// removed rather than rewritten, except image URLs which are rewritten to the
/// app-controlled `mailternal-part://` scheme.
///
/// Removed entirely (with children):
/// `script`, `iframe`, `object`, `embed`, `applet`, `form` controls, `link`
/// stylesheets, `base`, `audio`/`video`/`track`/`source`, `use`, `filter`,
/// `foreignObject`, SVG filter primitives, `meta refresh`.
///
/// Stripped:
/// event handlers (`on*`), `srcset`/`imagesrcset`, `@import` and `url()` in
/// CSS (`style` attributes and `<style>` blocks), `javascript:` / `data:`
/// (non-image) / `file:` / custom schemes.
///
/// Rewritten to `mailternal-part://part/<token>`:
/// `cid:` references and `http`/`https` image URLs. Remote images are marked
/// `blockedByDefault` in the returned manifest so the viewer can render
/// placeholders until the user consents. Consent never opens the network to
/// the page — the app fetches those URLs itself through the scheme handler.
///
/// The transformation is deterministic: tokens are a pure function of the
/// reference, attributes are emitted in sorted order, and
/// `sanitize(sanitize(x)) == sanitize(x)`.
public enum HTMLSanitizer: Sendable {
    /// Sanitize `html` and collect a token → reference manifest.
    public static func sanitize(_ html: String) -> SanitizedHTML {
        let document: Document
        do {
            document = try SwiftSoup.parse(html)
        } catch {
            return SanitizedHTML(
                html: "<html><head></head><body></body></html>",
                manifest: ResourceManifest()
            )
        }
        document.outputSettings().prettyPrint(pretty: false)
        var manifest = ResourceManifest()
        do {
            _ = try sanitizeElement(document, manifest: &manifest)
            let serialized = try document.html()
            return SanitizedHTML(html: serialized, manifest: manifest)
        } catch {
            return SanitizedHTML(
                html: "<html><head></head><body></body></html>",
                manifest: ResourceManifest()
            )
        }
    }

    @discardableResult
    private static func sanitizeElement(_ element: Element, manifest: inout ResourceManifest) throws -> Bool {
        let tag = Allowlist.localName(element.tagNameNormal())

        if tag != "#root", Allowlist.dropsSubtree(tag) {
            try element.remove()
            return false
        }

        if tag == "meta", !isAllowedMeta(element) {
            try element.remove()
            return false
        }

        for node in Array(element.getChildNodes()) {
            switch node.nodeName() {
            case "#comment", "#declaration", "#processinginstruction":
                try node.remove()
            default:
                break
            }
        }

        for child in element.getChildNodes().compactMap({ $0 as? Element }) {
            _ = try sanitizeElement(child, manifest: &manifest)
        }

        if tag != "#root", !Allowlist.allows(tag: tag) {
            try element.unwrap()
            return false
        }

        if tag == "#root" {
            return true
        }

        try rewriteAttributes(element, tag: tag, manifest: &manifest)

        if tag == "style" {
            try sanitizeStyleElement(element)
            if element.data().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try element.remove()
                return false
            }
        }

        if tag == "a", !element.hasAttr("href") {
            try element.unwrap()
            return false
        }

        if tag == "img" || tag == "image" {
            let hasSource = element.hasAttr("src") || element.hasAttr("href") || element.hasAttr("xlink:href")
            if !hasSource {
                try element.remove()
                return false
            }
        }

        return true
    }

    private static func isAllowedMeta(_ element: Element) -> Bool {
        if element.hasAttr("http-equiv") { return false }
        return element.hasAttr("charset")
    }

    private static func rewriteAttributes(
        _ element: Element,
        tag: String,
        manifest: inout ResourceManifest
    ) throws {
        guard let attributes = element.getAttributes() else { return }
        let snapshot = attributes.asList().map { ($0.getKey(), $0.getValue()) }
        var kept: [(String, String)] = []
        kept.reserveCapacity(snapshot.count)

        for (rawKey, rawValue) in snapshot {
            let key = rawKey.lowercased()
            if key.hasPrefix("on"), key.count > 2 {
                continue
            }
            if Allowlist.isSrcsetFamily(key) {
                continue
            }
            if key == "ping" || key == "referrerpolicy" || key == "crossorigin"
                || key == "srcdoc" || key == "formaction" || key == "action"
                || key == "target" || key == "download" || key == "contenteditable"
                || key == "tabindex" || key == "accesskey" || key == "autofocus"
                || key == "draggable" || key == "dropzone" {
                continue
            }
            if key.hasPrefix("data-") {
                continue
            }

            if key == "style" {
                let css = CSSSanitizer.sanitize(rawValue)
                if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    kept.append((key, css))
                }
                continue
            }

            if Allowlist.isURLAttribute(key) {
                if let rewritten = rewriteURLAttribute(tag: tag, key: key, value: rawValue, manifest: &manifest) {
                    kept.append((key, rewritten))
                }
                continue
            }

            if Allowlist.allows(attribute: key, on: tag) {
                kept.append((key, rawValue))
            }
        }

        for (key, _) in snapshot {
            try element.removeAttr(key)
        }
        for (key, value) in kept.sorted(by: { $0.0 < $1.0 }) {
            try element.attr(key, value)
        }
    }

    private static func rewriteURLAttribute(
        tag: String,
        key: String,
        value: String,
        manifest: inout ResourceManifest
    ) -> String? {
        let role = urlRole(tag: tag, key: key)
        switch role {
        case .drop:
            return nil
        case .hyperlink:
            switch URLPolicy.classifyHyperlink(value) {
            case .keep(let kept):
                return kept
            case .drop, .rewrite:
                return nil
            }
        case .image:
            switch URLPolicy.classifyImage(value) {
            case .drop:
                return nil
            case .keep(let kept):
                return kept
            case .rewrite(let reference):
                record(reference, in: &manifest)
                return PartURL.url(for: reference).absoluteString
            }
        }
    }

    private enum URLRole {
        case image
        case hyperlink
        case drop
    }

    private static func urlRole(tag: String, key: String) -> URLRole {
        switch (tag, key) {
        case ("a", "href"), ("a", "xlink:href"):
            return .hyperlink
        case ("img", "src"), ("img", "href"), ("img", "xlink:href"):
            return .image
        case ("image", "src"), ("image", "href"), ("image", "xlink:href"):
            return .image
        case (_, "background"), (_, "poster"), (_, "dynsrc"), (_, "lowsrc"):
            return .image
        default:
            return .drop
        }
    }

    private static func record(_ reference: PartReference, in manifest: inout ResourceManifest) {
        let token = PartURL.token(for: reference)
        manifest.entries[token] = ResourceEntry(
            reference: reference,
            blockedByDefault: reference.isRemote
        )
    }

    private static func sanitizeStyleElement(_ element: Element) throws {
        let nodes = element.dataNodes()
        if nodes.isEmpty {
            let css = CSSSanitizer.sanitize(element.data())
            element.empty()
            if !css.isEmpty {
                let data = DataNode(Array(css.utf8), element.getBaseUriUTF8())
                try element.appendChild(data)
            }
            return
        }
        for node in nodes {
            node.setWholeData(CSSSanitizer.sanitize(node.getWholeData()))
        }
    }
}
