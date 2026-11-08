import Foundation

/// Bluesky facets address text by UTF-8 byte offset, not by character. All conversions live here.
enum RichText {
    static let internalScheme = "bskyship"

    // MARK: Rendering

    static func attributed(text: String, facets: [Facet]?) -> AttributedString {
        let bytes = Array(text.utf8)
        let sorted = (facets ?? []).sorted { $0.index.byteStart < $1.index.byteStart }
        var result = AttributedString()
        var position = 0

        for facet in sorted {
            let start = facet.index.byteStart
            let end = facet.index.byteEnd
            // Skip facets that overlap or lie outside the text; other clients do produce them.
            guard start >= position, start < end, end <= bytes.count else { continue }
            result += AttributedString(String(decoding: bytes[position..<start], as: UTF8.self))
            var run = AttributedString(String(decoding: bytes[start..<end], as: UTF8.self))
            if let url = facet.features.lazy.compactMap(linkURL).first {
                run.link = url
            }
            result += run
            position = end
        }
        result += AttributedString(String(decoding: bytes[position...], as: UTF8.self))
        return result
    }

    private static func linkURL(_ feature: Facet.Feature) -> URL? {
        switch feature {
        case .link(let uri):
            return URL(string: uri)
        case .mention(let did):
            return internalURL(host: "profile", value: did)
        case .tag(let tag):
            return internalURL(host: "tag", value: tag)
        case .unknown:
            return nil
        }
    }

    /// The DID behind a mention link, if this URL is one.
    static func mentionedDID(in url: URL) -> String? {
        guard url.scheme == internalScheme, url.host == "profile" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "v" }?.value
    }

    /// For text without facets, such as a profile description: only web links become clickable.
    static func linkifiedPlainText(_ text: String) -> AttributedString {
        let facets = detectFacets(in: text).compactMap { item -> Facet? in
            guard case .link(let uri) = item.kind else { return nil }
            return Facet(byteStart: item.byteStart, byteEnd: item.byteEnd, feature: .link(uri))
        }
        return attributed(text: text, facets: facets)
    }

    private static func internalURL(host: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = internalScheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "v", value: value)]
        return components.url
    }

    // MARK: Detection when composing

    private static let urlPattern = try! NSRegularExpression(pattern: #"(?:^|(?<=[\s(]))(https?://\S+)"#)
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s(]))@([a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)+)"#
    )
    private static let tagPattern = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))#([^\s#]+)"#)
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?\"'")

    /// A mention found in text, not yet resolved to a DID.
    struct Detected: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case link(String)
            case handle(String)
            case tag(String)
        }
        let byteStart: Int
        let byteEnd: Int
        let kind: Kind
    }

    static func detectFacets(in text: String) -> [Detected] {
        var found: [Detected] = []
        let whole = NSRange(text.startIndex..., in: text)

        for match in urlPattern.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            var value = String(text[range])
            value = trimTrailing(value)
            if value.hasSuffix(")"), !value.contains("(") { value.removeLast() }
            let start = byteOffset(of: range.lowerBound, in: text)
            found.append(Detected(byteStart: start, byteEnd: start + value.utf8.count, kind: .link(value)))
        }
        for match in mentionPattern.matches(in: text, range: whole) {
            guard let full = Range(match.range, in: text), let handle = Range(match.range(at: 1), in: text) else { continue }
            let start = byteOffset(of: full.lowerBound, in: text)
            let end = byteOffset(of: full.upperBound, in: text)
            found.append(Detected(byteStart: start, byteEnd: end, kind: .handle(String(text[handle]))))
        }
        for match in tagPattern.matches(in: text, range: whole) {
            guard let full = Range(match.range, in: text), let tagRange = Range(match.range(at: 1), in: text) else { continue }
            let tag = trimTrailing(String(text[tagRange]))
            guard !tag.isEmpty, tag.count <= 64, !tag.allSatisfy(\.isNumber) else { continue }
            let start = byteOffset(of: full.lowerBound, in: text)
            // "#" plus the tag without trailing punctuation.
            found.append(Detected(byteStart: start, byteEnd: start + 1 + tag.utf8.count, kind: .tag(tag)))
        }
        return found.sorted { $0.byteStart < $1.byteStart }
    }

    /// Converts detections to facets. A handle that does not resolve stays plain text.
    static func resolveMentions(
        in detected: [Detected],
        resolver: @Sendable (String) async -> String?
    ) async -> [Facet] {
        var facets: [Facet] = []
        for item in detected {
            switch item.kind {
            case .link(let uri):
                facets.append(Facet(byteStart: item.byteStart, byteEnd: item.byteEnd, feature: .link(uri)))
            case .tag(let tag):
                facets.append(Facet(byteStart: item.byteStart, byteEnd: item.byteEnd, feature: .tag(tag)))
            case .handle(let handle):
                if let did = await resolver(handle) {
                    facets.append(Facet(byteStart: item.byteStart, byteEnd: item.byteEnd, feature: .mention(did: did)))
                }
            }
        }
        return facets
    }

    private static func trimTrailing(_ value: String) -> String {
        var result = value
        while let last = result.unicodeScalars.last, trailingPunctuation.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    private static func byteOffset(of index: String.Index, in text: String) -> Int {
        text.utf8.distance(from: text.startIndex, to: index)
    }
}
