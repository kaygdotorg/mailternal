/// Allowlist-first element/attribute policy for untrusted email HTML.
///
/// Anything not listed is dropped (dangerous tags with their children) or
/// unwrapped (unknown wrappers, preserving already-sanitized descendants).
enum Allowlist: Sendable {
    /// Tags that may remain in the serialized tree.
    static let tags: Set<String> = [
        "#root", "html", "head", "body",
        "meta", "title", "style",
        "div", "span", "p", "br", "hr",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "code", "kbd", "samp", "var",
        "article", "section", "header", "footer", "main", "nav", "aside",
        "figure", "figcaption", "address",
        "ul", "ol", "li", "dl", "dt", "dd",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "colgroup", "col",
        "a", "img",
        "strong", "b", "em", "i", "u", "s", "strike", "del", "ins",
        "mark", "small", "sub", "sup", "abbr", "cite", "q", "dfn", "time",
        "wbr", "bdo", "bdi", "ruby", "rt", "rp",
        "font", "center", "tt", "big", "nobr",
        "details", "summary",
        "svg", "g", "path", "rect", "circle", "ellipse", "line",
        "polyline", "polygon", "text", "tspan", "defs", "clippath",
        "lineargradient", "radialgradient", "stop", "desc", "marker",
        "symbol", "image", "metadata", "view",
    ]

    /// Tags removed with their entire subtree (never unwrapped).
    static let dropSubtree: Set<String> = [
        "script", "iframe", "object", "embed", "applet", "param",
        "link", "base",
        "audio", "video", "track", "source",
        "frame", "frameset", "noframes",
        "template", "canvas",
        "input", "button", "select", "option", "optgroup", "textarea",
        "output", "datalist", "fieldset", "label", "legend",
        "use", "filter", "foreignobject",
        "animate", "animatetransform", "animatemotion", "animatecolor", "set", "mpath",
        "plaintext", "xmp", "listing", "noembed",
        "map", "area",
    ]

    /// Attributes allowed on any remaining element (after URL/CSS handling).
    static let globalAttributes: Set<String> = [
        "id", "class", "title", "lang", "dir", "role",
        "width", "height", "align", "valign",
        "bgcolor", "color",
        "hidden",
        "xmlns",
        "style",
    ]

    /// Additional attributes permitted on specific tags.
    static let extraAttributes: [String: Set<String>] = [
        "a": ["href", "name", "rel"],
        "img": ["src", "alt", "border", "hspace", "vspace", "name"],
        "image": ["href", "src", "xlink:href", "alt", "preserveaspectratio"],
        "font": ["face", "size", "color"],
        "table": ["border", "cellpadding", "cellspacing", "cellborder", "frame", "rules", "summary", "background"],
        "td": ["colspan", "rowspan", "nowrap", "scope", "headers", "axis", "abbr", "border", "background"],
        "th": ["colspan", "rowspan", "nowrap", "scope", "headers", "axis", "abbr", "border", "background"],
        "tr": ["border"],
        "col": ["span"],
        "colgroup": ["span"],
        "ol": ["start", "type", "reversed"],
        "ul": ["type"],
        "li": ["value", "type"],
        "br": ["clear"],
        "hr": ["noshade", "size"],
        "meta": ["charset"],
        "blockquote": ["cite"],
        "q": ["cite"],
        "time": ["datetime"],
        "body": ["background", "link", "vlink", "alink", "text"],
        "svg": ["viewbox", "xmlns:xlink", "preserveaspectratio", "version"],
        "path": ["d", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "transform", "opacity", "fill-opacity", "stroke-opacity"],
        "rect": ["x", "y", "rx", "ry", "fill", "stroke", "stroke-width", "transform", "opacity"],
        "circle": ["cx", "cy", "r", "fill", "stroke", "stroke-width", "transform", "opacity"],
        "ellipse": ["cx", "cy", "rx", "ry", "fill", "stroke", "stroke-width", "transform", "opacity"],
        "line": ["x1", "y1", "x2", "y2", "stroke", "stroke-width", "transform", "opacity"],
        "polyline": ["points", "fill", "stroke", "stroke-width", "transform", "opacity"],
        "polygon": ["points", "fill", "stroke", "stroke-width", "transform", "opacity"],
        "text": ["x", "y", "dx", "dy", "fill", "stroke", "font-size", "font-family", "text-anchor", "transform", "opacity"],
        "tspan": ["x", "y", "dx", "dy", "fill", "font-size", "font-family"],
        "g": ["transform", "fill", "stroke", "opacity"],
        "stop": ["offset", "stop-color", "stop-opacity"],
        "lineargradient": ["x1", "y1", "x2", "y2", "gradientunits", "gradienttransform"],
        "radialgradient": ["cx", "cy", "r", "fx", "fy", "gradientunits", "gradienttransform"],
        "clippath": ["clippathunits"],
        "marker": ["markerwidth", "markerheight", "refx", "refy", "orient", "markerunits"],
        "symbol": ["viewbox", "preserveaspectratio"],
        "view": ["viewbox"],
    ]

    static func localName(_ tag: String) -> String {
        let lowered = tag.lowercased()
        if let colon = lowered.lastIndex(of: ":") {
            return String(lowered[lowered.index(after: colon)...])
        }
        return lowered
    }

    static func allows(tag: String) -> Bool {
        tags.contains(localName(tag))
    }

    static func dropsSubtree(_ tag: String) -> Bool {
        let name = localName(tag)
        if dropSubtree.contains(name) { return true }
        // SVG filter primitives are `fe*` (feBlend, feImage, …). Avoid
        // colliding with fieldset/footer/figure/figcaption.
        if name.hasPrefix("fe"),
           name != "fieldset", name != "footer",
           name != "figure", name != "figcaption" {
            return true
        }
        return false
    }

    static func allows(attribute: String, on tag: String) -> Bool {
        let key = attribute.lowercased()
        if globalAttributes.contains(key) { return true }
        if key.hasPrefix("aria-") { return true }
        let name = localName(tag)
        if extraAttributes[name]?.contains(key) == true { return true }
        return false
    }

    static func isURLAttribute(_ key: String) -> Bool {
        switch key {
        case "src", "href", "xlink:href", "poster", "background",
             "dynsrc", "lowsrc", "longdesc", "cite", "action", "formaction",
             "data", "codebase", "classid", "archive", "icon", "manifest",
             "profile", "usemap":
            return true
        default:
            return false
        }
    }

    static func isSrcsetFamily(_ key: String) -> Bool {
        key == "srcset" || key == "imagesrcset" || key == "imagesizes" || key == "sizes"
    }

    /// Presentation attributes that accept a CSS `<paint>` / `<color>` and
    /// therefore `url()`. Kept only after ``CSSSanitizer/sanitizedPaint(_:)``.
    static let paintAttributes: Set<String> = [
        "fill", "stroke", "stop-color", "flood-color", "lighting-color",
        "color", "bgcolor",
        "marker", "marker-start", "marker-mid", "marker-end",
        "clip-path", "mask", "filter",
        "solid-color", "text-decoration-color", "outline-color", "border-color",
    ]

    static func isPaintAttribute(_ key: String) -> Bool {
        paintAttributes.contains(key)
    }
}
