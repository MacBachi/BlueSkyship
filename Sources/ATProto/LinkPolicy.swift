import Foundation

/// The one place that decides which addresses from posts may be used. Everything in a post is
/// written by a stranger, and macOS hands other schemes to other apps: Terminal, Shortcuts, Finder.
enum LinkPolicy {
    /// True for a plain web address. Credentials in an address are refused, because
    /// `https://bsky.app@evil.example` looks like one site and goes to another.
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return false }
        return url.user == nil && url.password == nil
    }

    static func webURL(_ raw: String) -> URL? {
        URL(string: raw).flatMap { isWebURL($0) ? $0 : nil }
    }

    /// Pictures and videos are fetched without asking, so only encrypted web addresses qualify.
    static func isSecureMedia(_ url: URL) -> Bool {
        isWebURL(url) && url.scheme?.lowercased() == "https"
    }

    /// bsky.app or a subdomain of it, and not a lookalike such as evilbsky.app.
    static func isBlueskyHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "bsky.app" || host.hasSuffix(".bsky.app")
    }

    /// True if the text names one site and the link goes to another. Text that names no site,
    /// such as "read more", is not misleading in itself.
    static func isMisleading(shown: String, target: URL) -> Bool {
        guard let targetHost = target.host?.lowercased() else { return true }
        let destination = withoutWWW(targetHost)
        return shown.split(whereSeparator: \.isWhitespace).contains { word in
            guard let named = domain(in: word.lowercased()) else { return false }
            return destination != named && !destination.hasSuffix(".\(named)")
        }
    }

    private static func domain(in word: String) -> String? {
        var text = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]<>\"'.,;:!?"))
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        guard let host = text.split(whereSeparator: { "/?#@:".contains($0) }).first.map(String.init),
              host.wholeMatch(of: /[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)*\.\p{L}{2,}/) != nil else { return nil }
        return withoutWWW(host)
    }

    private static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
