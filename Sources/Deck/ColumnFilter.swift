import Foundation

/// Per-column filter. Runs only on this Mac and changes nothing on the Bluesky account.
struct ColumnFilter: Codable, Hashable, Sendable {
    /// Show an item if it contains any of these. Empty means no restriction.
    var includeTerms: [String] = []
    /// Hide an item if it contains any of these. Beats `includeTerms`.
    var excludeTerms: [String] = []
    var mediaOnly = false
    var hideReposts = false
    var hideReplies = false

    var isActive: Bool {
        !includeTerms.isEmpty || !excludeTerms.isEmpty || mediaOnly || hideReposts || hideReplies
    }

    func apply(_ items: [ColumnItem]) -> [ColumnItem] {
        guard isActive else { return items }
        let includes = includeTerms.map(Term.init)
        let excludes = excludeTerms.map(Term.init)
        return items.filter { item in
            if mediaOnly, !item.hasMedia { return false }
            if hideReposts, item.isRepost { return false }
            if hideReplies, item.isReply { return false }
            guard !includes.isEmpty || !excludes.isEmpty else { return true }

            let text = Self.fold(item.searchableText)
            let handle = Self.fold(item.authorHandle.map { "@\($0)" } ?? "")
            if excludes.contains(where: { $0.matches(text: text, handle: handle) }) { return false }
            return includes.isEmpty || includes.contains { $0.matches(text: text, handle: handle) }
        }
    }

    /// Splits user input at commas and line breaks. Phrases with spaces stay together.
    static func parseTerms(_ input: String) -> [String] {
        var seen = Set<String>()
        return input
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert(fold($0)).inserted }
    }

    static func foldForSearch(_ string: String) -> String {
        fold(string)
    }

    fileprivate static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private struct Term {
        let folded: String
        /// `@name` looks at the author rather than the text, so "bsky" does not match every handle.
        let targetsHandle: Bool

        init(_ raw: String) {
            folded = ColumnFilter.fold(raw)
            targetsHandle = folded.hasPrefix("@")
        }

        func matches(text: String, handle: String) -> Bool {
            if targetsHandle, handle == folded { return true }
            return Self.contains(term: folded, in: text)
        }

        /// Whole-word match, so "art" does not hide "party". Only applies to ASCII word characters:
        /// languages without spaces between words, and emoji, match anywhere.
        private static func contains(term: String, in text: String) -> Bool {
            guard !term.isEmpty else { return false }
            var searchStart = text.startIndex
            while let range = text.range(of: term, range: searchStart..<text.endIndex) {
                let leftOK = !isWordCharacter(term.first)
                    || range.lowerBound == text.startIndex
                    || !isWordCharacter(text[text.index(before: range.lowerBound)])
                let rightOK = !isWordCharacter(term.last)
                    || range.upperBound == text.endIndex
                    || !isWordCharacter(text[range.upperBound])
                if leftOK, rightOK { return true }
                searchStart = range.upperBound
            }
            return false
        }

        private static func isWordCharacter(_ character: Character?) -> Bool {
            guard let character, character.isASCII else { return false }
            return character.isLetter || character.isNumber
        }
    }
}

extension ColumnItem {
    /// For searching while typing: parts of words count, so results appear from the first letters on.
    /// Every word has to appear, in the text or in the author's name.
    func matchesSearch(_ term: String) -> Bool {
        let words = ColumnFilter.foldForSearch(term).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let author: Profile? = {
            switch self {
            case .post(let item): return item.post.author
            case .notification(let item): return item.raw.author
            }
        }()
        let haystack = ColumnFilter.foldForSearch(
            [searchableText, author?.bestName ?? "", author?.handle ?? ""].joined(separator: "\n")
        )
        return words.allSatisfy { haystack.contains($0) }
    }

    /// The post this item shows, if any. A follow notification has none.
    var displayedPost: PostView? {
        switch self {
        case .post(let item): return item.post
        case .notification(let item): return item.post
        }
    }

    var authorHandle: String? {
        switch self {
        case .post(let item): return item.post.author.handle
        case .notification(let item): return item.raw.author.handle
        }
    }

    var isRepost: Bool {
        switch self {
        case .post(let item): return item.reason?.by != nil
        case .notification(let item): return item.raw.reason == "repost"
        }
    }

    var isReply: Bool {
        switch self {
        case .post(let item): return item.post.record.reply != nil
        case .notification(let item): return item.raw.reason == "reply"
        }
    }

    var hasMedia: Bool {
        displayedPost?.embed?.hasMedia ?? false
    }

    /// Everything a reader sees as text, including link targets, link cards, quotes and image descriptions.
    var searchableText: String {
        guard let post = displayedPost else { return "" }
        var parts = [post.record.text]
        for facet in post.record.facets ?? [] {
            for case .link(let uri) in facet.features { parts.append(uri) }
        }
        post.embed?.collectSearchableText(into: &parts)
        return parts.joined(separator: "\n")
    }
}

extension Embed {
    var hasMedia: Bool {
        switch self {
        case .images, .video: return true
        case .quoteWithMedia(_, let media): return media.hasMedia
        case .external, .quote, .recordCard, .unknown: return false
        }
    }

    func collectSearchableText(into parts: inout [String]) {
        switch self {
        case .images(let images):
            parts += images.compactMap(\.alt)
        case .external(let link):
            parts.append(link.uri)
            parts += [link.title, link.description].compactMap { $0 }
        case .video(let video):
            if let alt = video.alt { parts.append(alt) }
        case .quote(let quoted):
            if let quoted { parts.append(quoted.value.text) }
        case .quoteWithMedia(let quoted, let media):
            if let quoted { parts.append(quoted.value.text) }
            media.collectSearchableText(into: &parts)
        case .recordCard(let card):
            parts.append(card.title)
            if let description = card.description { parts.append(description) }
        case .unknown:
            break
        }
    }
}
