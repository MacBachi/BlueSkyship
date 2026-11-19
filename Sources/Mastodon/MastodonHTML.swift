import Foundation

/// Turns the HTML of a Mastodon post into plain text plus facets, the form Bluesky posts already
/// have, so both are shown by the same code under the same link rules.
///
/// This is deliberately a small reader of its own rather than an HTML renderer. Every post is written
/// by a stranger, and a renderer would load pictures, styles or worse. Here only text survives; tags
/// are reduced to line breaks, and a link only becomes clickable as one of three things: a web address
/// that `LinkPolicy` accepts, a hashtag, or a mention of an account the server itself named.
enum MastodonHTML {
    struct Result: Equatable {
        var text: String
        var facets: [Facet]
    }

    /// `domain` completes local accounts, which the server names without one.
    /// `hidesQuoteFallback` drops the "RE: …" line servers add for apps that cannot show quotes.
    static func parse(
        _ html: String, mentions: [Mastodon.Mention] = [], domain: String = "", hidesQuoteFallback: Bool = false
    ) -> Result {
        var reader = Reader(mentions: mentions, domain: domain)
        reader.hidesQuoteFallback = hidesQuoteFallback
        reader.read(html)
        return reader.finish()
    }

    /// For profile descriptions, where only the words matter.
    static func plainText(_ html: String) -> String {
        parse(html).text
    }

    /// The full address of an account, with the server for local ones.
    static func fullAcct(_ acct: String, domain: String) -> String {
        acct.contains("@") || domain.isEmpty ? acct : "\(acct)@\(domain)"
    }

    private struct OpenLink {
        let href: String
        let classes: Set<String>
        let start: Int
    }

    private struct Reader {
        let mentions: [Mastodon.Mention]
        let domain: String
        var text = ""
        var facets: [Facet] = []
        var link: OpenLink?
        /// Text inside `<span class="invisible">`: the part of a long address Mastodon hides.
        var hiddenDepth = 0
        var openSpans: [Bool] = []
        var ellipsisDepth: [Bool] = []
        var skipUntil: String?
        var preDepth = 0
        var hidesQuoteFallback = false

        init(mentions: [Mastodon.Mention], domain: String) {
            self.mentions = mentions
            self.domain = domain
        }

        mutating func read(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<", Self.startsTag(html[html.index(after: index)...]),
                   let close = html[index...].firstIndex(of: ">") {
                    handleTag(String(html[html.index(after: index)..<close]))
                    index = html.index(after: close)
                } else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    // A lone "<" without a closing ">" is just a character.
                    let end = next == index ? html.index(after: index) : next
                    appendText(String(html[index..<end]))
                    index = end
                }
            }
        }

        /// "a < b" is text; only "<p", "</p" and "<!--" open a tag.
        static func startsTag(_ rest: Substring) -> Bool {
            guard let first = rest.first else { return false }
            return first.isLetter || first == "/" || first == "!"
        }

        mutating func handleTag(_ raw: String) {
            var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("!") || body.hasPrefix("?") { return }
            let isClosing = body.hasPrefix("/")
            if isClosing { body.removeFirst() }
            if body.hasSuffix("/") { body.removeLast() }
            let name = body.prefix { !$0.isWhitespace }.lowercased()

            if let skip = skipUntil {
                if isClosing, name == skip { skipUntil = nil }
                return
            }

            switch (name, isClosing) {
            case ("script", false), ("style", false), ("template", false), ("iframe", false), ("object", false):
                skipUntil = name
            case ("br", _):
                append("\n")
            case ("p", false) where hidesQuoteFallback && Self.attributes(of: body)["class"]?.contains("quote-inline") == true:
                skipUntil = "p"
            case ("p", false), ("blockquote", false), ("pre", false), ("ul", false), ("ol", false), ("h1", false),
                 ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                if name == "pre" { preDepth += 1 }
                startBlock()
            case ("pre", true):
                preDepth = max(0, preDepth - 1)
            case ("li", false):
                if !text.isEmpty, !text.hasSuffix("\n") { append("\n") }
                append("• ")
            case ("a", false):
                let attributes = Self.attributes(of: body)
                closeLink()
                link = OpenLink(
                    href: attributes["href"] ?? "",
                    classes: Set((attributes["class"] ?? "").split(separator: " ").map(String.init)),
                    start: text.utf8.count
                )
            case ("a", true):
                closeLink()
            case ("span", false):
                let classes = Set((Self.attributes(of: body)["class"] ?? "").split(separator: " ").map(String.init))
                let hides = classes.contains("invisible")
                openSpans.append(hides)
                ellipsisDepth.append(classes.contains("ellipsis"))
                if hides { hiddenDepth += 1 }
            case ("span", true):
                if let hides = openSpans.popLast(), hides { hiddenDepth -= 1 }
                if ellipsisDepth.popLast() == true { append("…") }
            default:
                break
            }
        }

        mutating func startBlock() {
            guard !text.isEmpty else { return }
            while text.hasSuffix(" ") { text.removeLast() }
            if text.hasSuffix("\n\n") { return }
            append(text.hasSuffix("\n") ? "\n" : "\n\n")
        }

        mutating func appendText(_ raw: String) {
            guard skipUntil == nil, hiddenDepth == 0 else { return }
            var decoded = Self.decodeEntities(raw)
            if preDepth == 0 {
                // HTML treats line breaks in the source as spaces.
                decoded = decoded.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
                if text.isEmpty || text.hasSuffix("\n") {
                    decoded = String(decoded.drop { $0 == " " })
                }
            }
            append(decoded)
        }

        mutating func append(_ string: String) {
            text += string
        }

        mutating func closeLink() {
            guard let open = link else { return }
            link = nil
            let end = text.utf8.count
            guard end > open.start else { return }
            let shown = String(decoding: Array(text.utf8)[open.start..<end], as: UTF8.self)
            if let feature = feature(for: open, shown: shown) {
                facets.append(Facet(byteStart: open.start, byteEnd: end, feature: feature))
            }
        }

        func feature(for link: OpenLink, shown: String) -> Facet.Feature? {
            // Mastodon marks hashtags as "mention hashtag", so the hashtag check comes first.
            if link.classes.contains("hashtag") {
                let tag = String(shown.drop { $0 == "#" })
                return MastodonTag.isValid(tag) ? .tag(tag) : nil
            }
            if link.classes.contains("mention") || link.classes.contains("u-url"),
               let mention = mentions.first(where: { $0.url == link.href }) {
                return .mention(did: MastodonHTML.fullAcct(mention.acct, domain: domain))
            }
            return LinkPolicy.webURL(link.href).map { .link($0.absoluteString) }
        }

        mutating func finish() -> Result {
            closeLink()
            // Trailing breaks only take space; facets never reach into them because links end on text.
            var trimmed = text
            while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
            let limit = trimmed.utf8.count
            let kept = facets.filter { $0.index.byteEnd <= limit }
            return Result(text: trimmed, facets: kept)
        }

        /// Reads `name="value"` pairs. Unquoted and single-quoted values count too.
        static func attributes(of tag: String) -> [String: String] {
            var result: [String: String] = [:]
            let pattern = #/([a-zA-Z_:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/#
            for match in tag.matches(of: pattern) {
                let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
                result[match.output.1.lowercased()] = decodeEntities(String(value))
            }
            return result
        }

        static func decodeEntities(_ string: String) -> String {
            guard string.contains("&") else { return string }
            var result = ""
            var index = string.startIndex
            while index < string.endIndex {
                if string[index] == "&",
                   let semicolon = string[index...].prefix(12).firstIndex(of: ";") {
                    let entity = String(string[string.index(after: index)..<semicolon])
                    if let decoded = decode(entity: entity) {
                        result.append(decoded)
                        index = string.index(after: semicolon)
                        continue
                    }
                }
                result.append(string[index])
                index = string.index(after: index)
            }
            return result
        }

        /// Named entities beyond the five that XML knows: Latin-1 (umlauts, ß, accents) and common typography.
        /// The soft hyphen is left out, since it is invisible.
        static let namedEntities: [String: UInt32] = [
            "iexcl": 0xA1,
            "cent": 0xA2,
            "pound": 0xA3,
            "curren": 0xA4,
            "yen": 0xA5,
            "brvbar": 0xA6,
            "sect": 0xA7,
            "uml": 0xA8,
            "copy": 0xA9,
            "ordf": 0xAA,
            "laquo": 0xAB,
            "not": 0xAC,
            "reg": 0xAE,
            "macr": 0xAF,
            "deg": 0xB0,
            "plusmn": 0xB1,
            "sup2": 0xB2,
            "sup3": 0xB3,
            "acute": 0xB4,
            "micro": 0xB5,
            "para": 0xB6,
            "middot": 0xB7,
            "cedil": 0xB8,
            "sup1": 0xB9,
            "ordm": 0xBA,
            "raquo": 0xBB,
            "frac14": 0xBC,
            "frac12": 0xBD,
            "frac34": 0xBE,
            "iquest": 0xBF,
            "Agrave": 0xC0,
            "Aacute": 0xC1,
            "Acirc": 0xC2,
            "Atilde": 0xC3,
            "Auml": 0xC4,
            "Aring": 0xC5,
            "AElig": 0xC6,
            "Ccedil": 0xC7,
            "Egrave": 0xC8,
            "Eacute": 0xC9,
            "Ecirc": 0xCA,
            "Euml": 0xCB,
            "Igrave": 0xCC,
            "Iacute": 0xCD,
            "Icirc": 0xCE,
            "Iuml": 0xCF,
            "ETH": 0xD0,
            "Ntilde": 0xD1,
            "Ograve": 0xD2,
            "Oacute": 0xD3,
            "Ocirc": 0xD4,
            "Otilde": 0xD5,
            "Ouml": 0xD6,
            "times": 0xD7,
            "Oslash": 0xD8,
            "Ugrave": 0xD9,
            "Uacute": 0xDA,
            "Ucirc": 0xDB,
            "Uuml": 0xDC,
            "Yacute": 0xDD,
            "THORN": 0xDE,
            "szlig": 0xDF,
            "agrave": 0xE0,
            "aacute": 0xE1,
            "acirc": 0xE2,
            "atilde": 0xE3,
            "auml": 0xE4,
            "aring": 0xE5,
            "aelig": 0xE6,
            "ccedil": 0xE7,
            "egrave": 0xE8,
            "eacute": 0xE9,
            "ecirc": 0xEA,
            "euml": 0xEB,
            "igrave": 0xEC,
            "iacute": 0xED,
            "icirc": 0xEE,
            "iuml": 0xEF,
            "eth": 0xF0,
            "ntilde": 0xF1,
            "ograve": 0xF2,
            "oacute": 0xF3,
            "ocirc": 0xF4,
            "otilde": 0xF5,
            "ouml": 0xF6,
            "divide": 0xF7,
            "oslash": 0xF8,
            "ugrave": 0xF9,
            "uacute": 0xFA,
            "ucirc": 0xFB,
            "uuml": 0xFC,
            "yacute": 0xFD,
            "thorn": 0xFE,
            "yuml": 0xFF,
            "OElig": 0x152,
            "oelig": 0x153,
            "Scaron": 0x160,
            "scaron": 0x161,
            "Yuml": 0x178,
            "Zcaron": 0x17D,
            "zcaron": 0x17E,
            "fnof": 0x192,
            "circ": 0x2C6,
            "tilde": 0x2DC,
            "ensp": 0x2002,
            "emsp": 0x2003,
            "thinsp": 0x2009,
            "ndash": 0x2013,
            "mdash": 0x2014,
            "lsquo": 0x2018,
            "rsquo": 0x2019,
            "sbquo": 0x201A,
            "ldquo": 0x201C,
            "rdquo": 0x201D,
            "bdquo": 0x201E,
            "dagger": 0x2020,
            "Dagger": 0x2021,
            "bull": 0x2022,
            "hellip": 0x2026,
            "permil": 0x2030,
            "prime": 0x2032,
            "Prime": 0x2033,
            "lsaquo": 0x2039,
            "rsaquo": 0x203A,
            "euro": 0x20AC,
            "trade": 0x2122,
            "larr": 0x2190,
            "uarr": 0x2191,
            "rarr": 0x2192,
            "darr": 0x2193,
            "harr": 0x2194,
            "minus": 0x2212,
            "le": 0x2264,
            "ge": 0x2265,
            "ne": 0x2260,
            "infin": 0x221E,
            "asymp": 0x2248,
            "alpha": 0x3B1,
            "beta": 0x3B2,
            "gamma": 0x3B3,
            "delta": 0x3B4,
            "pi": 0x3C0,
            "mu": 0x3BC,
            "Omega": 0x3A9,
        ]

        static func decode(entity: String) -> String? {
            switch entity {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos", "#39": return "'"
            case "nbsp": return " "
            default: break
            }
            // Feeds write umlauts and typographic marks as named entities, such as &ouml; or &ndash;.
            if let named = namedEntities[entity] { return String(Character(Unicode.Scalar(named)!)) }
            let value: UInt32?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                value = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                value = UInt32(entity.dropFirst())
            } else {
                value = nil
            }
            // Control characters and invisible direction marks could disguise text, so they stay out.
            guard let value, value >= 0x20, !(0x7F...0x9F).contains(value),
                  !(0x202A...0x202E).contains(value), !(0x2066...0x2069).contains(value),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }
}

enum MastodonTag {
    /// Mastodon hashtags are letters, digits, underscores and joiners. Anything else is not a tag.
    static func isValid(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= 100 && tag.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "\u{200C}" || $0 == "\u{B7}"
        }
    }
}
