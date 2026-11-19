import Foundation

/// Signs of an attack that security people pass around: addresses, hashes, vulnerability numbers.
/// Everything here works on the text alone. Nothing is looked up until someone picks a service.
enum IOCKind: String, CaseIterable, Sendable {
    case url, email, ipv4, ipv6, domain, md5, sha1, sha256, sha512, cve, euvd, ghsa

    var label: String {
        switch self {
        case .url: return tr("Adresse (URL)", "Address (URL)")
        case .email: return tr("E-Mail-Adresse", "Email address")
        case .ipv4: return tr("IPv4-Adresse", "IPv4 address")
        case .ipv6: return tr("IPv6-Adresse", "IPv6 address")
        case .domain: return tr("Domain", "Domain")
        case .md5: return tr("MD5-Hash", "MD5 hash")
        case .sha1: return tr("SHA-1-Hash", "SHA-1 hash")
        case .sha256: return tr("SHA-256-Hash", "SHA-256 hash")
        case .sha512: return tr("SHA-512-Hash", "SHA-512 hash")
        case .cve: return tr("Schwachstelle (CVE)", "Vulnerability (CVE)")
        case .euvd: return tr("Schwachstelle (EUVD)", "Vulnerability (EUVD)")
        case .ghsa: return tr("Sicherheitshinweis (GHSA)", "Security advisory (GHSA)")
        }
    }

    var isHash: Bool { [.md5, .sha1, .sha256, .sha512].contains(self) }
}

struct IOC: Hashable, Sendable {
    let kind: IOCKind
    /// The usable form: `evil[.]com` becomes `evil.com`, `hxxps` becomes `https`.
    let value: String
    /// Where it stands in the text, in UTF-16 units as `NSString` counts them.
    let range: NSRange
    /// Written so that nobody opens it by accident, such as `evil[.]com`.
    let wasDefanged: Bool

    /// The safe way to pass it on: dots in brackets, `hxxp` instead of `http`.
    var defanged: String { IOCDetector.defang(value, kind: kind) }

    /// The domain inside an address or email, for looking that up on its own.
    var host: String? {
        switch kind {
        case .url: return URL(string: value)?.host?.lowercased()
        case .email: return value.split(separator: "@").last.map { $0.lowercased() }
        case .domain: return value
        default: return nil
        }
    }

    /// Opening a defanged address would undo what its author did on purpose.
    var mayOpenInBrowser: Bool {
        !wasDefanged && (kind == .url || kind == .domain)
    }
}

enum IOCDetector {
    // MARK: Patterns

    private static let dot = #"(?:\.|\[\.\]|\(\.\)|\{\.\}|\[dot\]|\(dot\))"#
    private static let label = #"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"#
    private static let octet = #"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"#

    private static let urlPattern = regex(
        #"(?<![\w])(?:h(?:tt|xx|XX)ps?|fxp|ftp|sftp)(?::|\[:\])//[^\s<>"'`]+"#, caseInsensitive: true
    )
    private static let emailPattern = regex(
        #"(?<![\w.%+-])[A-Za-z0-9._%+-]{1,64}(?:@|\[@\]|\[at\]|\(at\))\#(label)(?:\#(dot)\#(label))*\#(dot)[A-Za-z]{2,24}(?![\w-])"#
    )
    private static let ipv4Pattern = regex(
        #"(?<![\w.])\#(octet)(?:\#(dot)\#(octet)){3}(?:/(?:3[0-2]|[12]?\d))?(?![\w]|\.\d|\[\.\]\d)"#
    )
    private static let ipv6Candidate = regex(#"(?<![\w:.])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![\w:])"#)
    private static let domainPattern = regex(
        #"(?<![\w.@/\-])\#(label)(?:\#(dot)\#(label))*\#(dot)[A-Za-z]{2,24}(?![\w-]|\.\w|\[\.\]\w)"#
    )
    private static let hashPattern = regex(#"(?<![\w])(?:[0-9A-Fa-f]{128}|[0-9A-Fa-f]{64}|[0-9A-Fa-f]{40}|[0-9A-Fa-f]{32})(?![\w])"#)
    private static let cvePattern = regex(#"(?<![\w-])CVE-\d{4}-\d{4,7}(?![\w])"#, caseInsensitive: true)
    /// GitHub writes these with a reduced alphabet that leaves out letters easily confused with digits.
    private static let ghsaPattern = regex(#"(?<![\w-])GHSA(?:-[23456789cfghjmpqrvwx]{4}){3}(?![\w-])"#, caseInsensitive: true)
    private static let euvdPattern = regex(#"(?<![\w-])EUVD-\d{4}-\d{1,7}(?![\w])"#, caseInsensitive: true)
    private static let defangMarks = regex(#"\[\.\]|\(\.\)|\{\.\}|\[dot\]|\(dot\)|\[:\]|\[@\]|\[at\]|\(at\)|hxxp|fxp"#, caseInsensitive: true)

    /// Endings that a plain word like `index.html` also has. Written as a domain without brackets,
    /// only these count, so that file names and abbreviations stay text.
    static let knownTopLevelDomains: Set<String> = [
        "com", "net", "org", "info", "biz", "io", "co", "me", "tv", "xyz", "top", "online", "site", "club",
        "shop", "app", "dev", "cloud", "tech", "store", "live", "pro", "icu", "buzz", "vip", "work", "link",
        "click", "ws", "to", "ly", "gg", "ai", "onion", "cyou", "rest", "lol", "mobi", "name", "gov", "edu",
        "mil", "int", "asia", "tk", "ml", "ga", "cf", "gq", "pw", "su", "space", "website", "fun", "today",
        "news", "blog", "email", "help", "support", "services", "network", "systems", "digital", "media",
        "world", "life", "best", "monster", "quest", "sbs", "bond", "cfd", "beauty", "hair", "skin", "makeup",
        "de", "at", "ch", "li", "uk", "fr", "nl", "eu", "it", "es", "pl", "se", "no", "fi", "dk", "be", "cz",
        "sk", "hu", "ro", "bg", "gr", "pt", "ie", "lu", "us", "ca", "au", "nz", "jp", "kr", "cn", "hk", "tw",
        "in", "br", "mx", "ar", "cl", "tr", "ua", "by", "kz", "ru", "ir", "il", "za", "ng", "eg", "sa", "ae",
        "lt", "lv", "ee", "si", "hr", "ba", "ge", "am", "fm", "st", "vn", "th", "id", "my", "sg", "ph", "pk",
    ]

    private static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    // MARK: Finding

    private final class Found: NSObject {
        let iocs: [IOC]
        init(_ iocs: [IOC]) { self.iocs = iocs }
    }

    /// Columns redraw often, and the same texts come round again and again.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Found> = {
        let cache = NSCache<NSString, Found>()
        cache.countLimit = 2_000
        return cache
    }()

    /// Every IOC in the text, in reading order, none overlapping another.
    static func find(in text: String) -> [IOC] {
        guard !text.isEmpty else { return [] }
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.iocs }
        let found = scan(text)
        cache.setObject(Found(found), forKey: key)
        return found
    }

    /// For the column filter. Ordinary web addresses and domains do not count, or nearly every
    /// post with a link would; written defanged, they do.
    static func containsIOC(_ text: String) -> Bool {
        find(in: text).contains { $0.wasDefanged || ($0.kind != .url && $0.kind != .domain) }
    }

    private static func scan(_ text: String) -> [IOC] {
        let string = text as NSString
        let whole = NSRange(location: 0, length: string.length)
        var taken = IndexSet()
        var result: [IOC] = []

        func add(_ kind: IOCKind, _ range: NSRange, value: String) {
            let span = range.location..<(range.location + range.length)
            guard range.length > 0, !taken.intersects(integersIn: span) else { return }
            taken.insert(integersIn: span)
            let raw = string.substring(with: range)
            let defanged = defangMarks.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) != nil
            result.append(IOC(kind: kind, value: value, range: range, wasDefanged: defanged))
        }

        // Longer things first, so the domain inside an address does not count on its own.
        for match in urlPattern.matches(in: text, range: whole) {
            let range = trimmedURLRange(match.range, in: string)
            let value = refang(string.substring(with: range))
            guard let url = URL(string: value), url.host?.isEmpty == false else { continue }
            add(.url, range, value: value)
        }
        for match in emailPattern.matches(in: text, range: whole) {
            add(.email, match.range, value: refang(string.substring(with: match.range)).lowercased())
        }
        for match in cvePattern.matches(in: text, range: whole) {
            add(.cve, match.range, value: string.substring(with: match.range).uppercased())
        }
        for match in euvdPattern.matches(in: text, range: whole) {
            add(.euvd, match.range, value: string.substring(with: match.range).uppercased())
        }
        for match in ghsaPattern.matches(in: text, range: whole) {
            add(.ghsa, match.range, value: normalizedGHSA(string.substring(with: match.range)))
        }
        for match in hashPattern.matches(in: text, range: whole) {
            let value = string.substring(with: match.range)
            // A long number is not a hash, and neither is a run of one repeated sign.
            guard value.contains(where: \.isLetter), value.contains(where: \.isNumber), Set(value).count > 4 else { continue }
            let kind: IOCKind = switch value.count {
            case 32: .md5
            case 40: .sha1
            case 64: .sha256
            default: .sha512
            }
            add(kind, match.range, value: value.lowercased())
        }
        for match in ipv4Pattern.matches(in: text, range: whole) {
            add(.ipv4, match.range, value: refang(string.substring(with: match.range)))
        }
        for match in ipv6Candidate.matches(in: text, range: whole) {
            let value = string.substring(with: match.range)
            guard isIPv6(value) else { continue }
            add(.ipv6, match.range, value: value.lowercased())
        }
        for match in domainPattern.matches(in: text, range: whole) {
            let raw = string.substring(with: match.range)
            let value = refang(raw).lowercased()
            let wasDefanged = value != raw.lowercased()
            guard let ending = value.split(separator: ".").last.map(String.init),
                  wasDefanged || knownTopLevelDomains.contains(ending) else { continue }
            add(.domain, match.range, value: value)
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    /// Closing punctuation after an address belongs to the sentence, not the address.
    private static func trimmedURLRange(_ range: NSRange, in string: NSString) -> NSRange {
        var length = range.length
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}\"'")
        while length > 0 {
            let character = string.character(at: range.location + length - 1)
            guard let scalar = Unicode.Scalar(character), trailing.contains(scalar) else { break }
            let piece = string.substring(with: NSRange(location: range.location, length: length))
            // Keep brackets that the address opened itself, and the defanged dot `[.]`.
            if scalar == ")" && piece.filter({ $0 == "(" }).count >= piece.filter({ $0 == ")" }).count { break }
            if scalar == "]" && piece.hasSuffix("[.]") { break }
            length -= 1
        }
        return NSRange(location: range.location, length: length)
    }

    private static func isIPv6(_ value: String) -> Bool {
        guard value.contains(where: \.isHexDigit), value.filter({ $0 == ":" }).count >= 2 else { return false }
        var address = in6_addr()
        return inet_pton(AF_INET6, value, &address) == 1
    }

    /// `GHSA-` in capitals, the rest in small letters, as GitHub writes it.
    static func normalizedGHSA(_ text: String) -> String {
        "GHSA" + text.dropFirst(4).lowercased()
    }

    // MARK: Converting

    /// Undoes the usual ways of writing an IOC so that nobody opens it by accident.
    static func refang(_ text: String) -> String {
        var result = text
        for (written, meant) in [
            ("[.]", "."), ("(.)", "."), ("{.}", "."), ("[dot]", "."), ("(dot)", "."),
            ("[:]", ":"), ("[@]", "@"), ("[at]", "@"), ("(at)", "@"),
        ] {
            result = result.replacingOccurrences(of: written, with: meant, options: .caseInsensitive)
        }
        for (written, meant) in [("hxxps://", "https://"), ("hxxp://", "http://"), ("fxp://", "ftp://")] where result.lowercased().hasPrefix(written) {
            result = meant + result.dropFirst(written.count)
        }
        return result
    }

    static func defang(_ value: String, kind: IOCKind) -> String {
        switch kind {
        case .domain, .ipv4:
            return value.replacingOccurrences(of: ".", with: "[.]")
        case .email:
            return value.replacingOccurrences(of: "@", with: "[@]").replacingOccurrences(of: ".", with: "[.]")
        case .url:
            guard var components = URLComponents(string: value), let host = components.host else { return value }
            components.scheme = components.scheme.map { $0.replacingOccurrences(of: "http", with: "hxxp") }
            let start = components.string ?? value
            return start.replacingOccurrences(of: host, with: host.replacingOccurrences(of: ".", with: "[.]"))
        default:
            return value
        }
    }

    // MARK: Inside the app's text

    /// Turns an IOC into an internal link, so a click on it can offer the lookup services.
    static func link(for ioc: IOC) -> URL? {
        var components = URLComponents()
        components.scheme = RichText.internalScheme
        components.host = "ioc"
        components.queryItems = [
            URLQueryItem(name: "k", value: ioc.kind.rawValue),
            URLQueryItem(name: "v", value: ioc.value),
            URLQueryItem(name: "d", value: ioc.wasDefanged ? "1" : "0"),
        ]
        return components.url
    }

    /// The IOC behind a link made by `link(for:)`.
    static func ioc(from url: URL) -> IOC? {
        guard url.scheme == RichText.internalScheme, url.host == "ioc",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let kind = items.first(where: { $0.name == "k" })?.value.flatMap(IOCKind.init(rawValue:)),
              let value = items.first(where: { $0.name == "v" })?.value else { return nil }
        let defanged = items.first { $0.name == "d" }?.value == "1"
        return IOC(kind: kind, value: value, range: NSRange(location: 0, length: 0), wasDefanged: defanged)
    }

    /// What a web link is about: a CVE or hash named in its address, the IP address it goes to,
    /// or else the address itself.
    static func subject(forLink url: URL) -> IOC? {
        guard LinkPolicy.isWebURL(url) else { return nil }
        let text = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let whole = NSRange(location: 0, length: (text as NSString).length)
        if let match = cvePattern.firstMatch(in: text, range: whole) {
            return IOC(kind: .cve, value: (text as NSString).substring(with: match.range).uppercased(), range: NSRange(), wasDefanged: false)
        }
        if let match = euvdPattern.firstMatch(in: text, range: whole) {
            return IOC(kind: .euvd, value: (text as NSString).substring(with: match.range).uppercased(), range: NSRange(), wasDefanged: false)
        }
        if let match = ghsaPattern.firstMatch(in: text, range: whole) {
            return IOC(kind: .ghsa, value: normalizedGHSA((text as NSString).substring(with: match.range)), range: NSRange(), wasDefanged: false)
        }
        if let match = hashPattern.firstMatch(in: text, range: whole) {
            let value = (text as NSString).substring(with: match.range).lowercased()
            let kind: IOCKind = value.count == 32 ? .md5 : value.count == 40 ? .sha1 : value.count == 64 ? .sha256 : .sha512
            if value.contains(where: \.isLetter), value.contains(where: \.isNumber) {
                return IOC(kind: kind, value: value, range: NSRange(), wasDefanged: false)
            }
        }
        if let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) {
            var v4 = in_addr()
            if inet_pton(AF_INET, host, &v4) == 1 { return IOC(kind: .ipv4, value: host, range: NSRange(), wasDefanged: false) }
            if isIPv6(host) { return IOC(kind: .ipv6, value: host.lowercased(), range: NSRange(), wasDefanged: false) }
        }
        return IOC(kind: .url, value: url.absoluteString, range: NSRange(), wasDefanged: false)
    }

    /// What hovering shows: what it is, its usable form, and what a click offers.
    static func tooltip(for ioc: IOC) -> String {
        var lines = [ioc.kind.label + (ioc.wasDefanged ? tr(" · entschärft geschrieben", " · written defanged") : "")]
        lines.append(ioc.value)
        if let host = ioc.host, ioc.kind != .domain { lines.append(tr("Domain: \(host)", "Domain: \(host)")) }
        let names = IOCLookup.services(for: ioc).map(\.name)
        if !names.isEmpty {
            lines.append(tr("Klicken: \(names.joined(separator: ", ")) …", "Click: \(names.joined(separator: ", "))…"))
        }
        return lines.joined(separator: "\n")
    }

    /// What hovering over an ordinary link shows, much like a browser's status bar.
    static func tooltip(forLink url: URL) -> String {
        guard let host = url.host?.lowercased() else { return url.absoluteString }
        var lines = [tr("Domain: \(host)", "Domain: \(host)"), url.absoluteString]
        if url.scheme?.lowercased() == "http" { lines.append(tr("Unverschlüsselt (http)", "Not encrypted (http)")) }
        return lines.joined(separator: "\n")
    }
}

/// Websites that tell more about an IOC. Opening one sends the IOC there, so it happens only on a click.
enum IOCLookup {
    struct Service: Hashable, Sendable {
        let name: String
        let url: URL
    }

    static func services(for ioc: IOC) -> [Service] {
        let value = ioc.value
        let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        let query = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        var list: [(String, String)]
        switch ioc.kind {
        case .ipv4, .ipv6:
            let address = value.split(separator: "/").first.map(String.init) ?? value
            list = [
                ("VirusTotal", "https://www.virustotal.com/gui/ip-address/\(address)"),
                ("AbuseIPDB", "https://www.abuseipdb.com/check/\(address)"),
                ("Shodan", "https://www.shodan.io/host/\(address)"),
                ("GreyNoise", "https://viz.greynoise.io/ip/\(address)"),
            ]
        case .domain:
            list = domainServices(value)
        case .url:
            list = [("VirusTotal", "https://www.virustotal.com/gui/search/\(query)")]
            if let host = ioc.host { list += domainServices(host).filter { $0.0 != "VirusTotal" } }
        case .email:
            list = ioc.host.map(domainServices) ?? []
        case .md5, .sha1, .sha256, .sha512:
            list = [("VirusTotal", "https://www.virustotal.com/gui/file/\(value)")]
            if ioc.kind != .sha512 {
                let prefix = ioc.kind.rawValue
                list.append(("MalwareBazaar", "https://bazaar.abuse.ch/browse.php?search=\(prefix)%3A\(value)"))
            }
            list.append(("Hybrid Analysis", "https://www.hybrid-analysis.com/search?query=\(value)"))
        case .cve:
            list = [
                ("NVD", "https://nvd.nist.gov/vuln/detail/\(encoded)"),
                ("CVE.org", "https://www.cve.org/CVERecord?id=\(query)"),
                ("EUVD", "https://euvd.enisa.europa.eu/search?text=\(query)"),
                ("CISA KEV", "https://www.cisa.gov/known-exploited-vulnerabilities-catalog?search_api_fulltext=\(query)"),
            ]
        case .euvd:
            list = [("EUVD", "https://euvd.enisa.europa.eu/vulnerability/\(encoded)")]
        case .ghsa:
            list = [
                ("GitHub", "https://github.com/advisories/\(encoded)"),
                ("OSV", "https://osv.dev/vulnerability/\(encoded)"),
                ("EUVD", "https://euvd.enisa.europa.eu/search?text=\(query)"),
            ]
        }
        return list.compactMap { name, address in URL(string: address).map { Service(name: name, url: $0) } }
    }

    private static func domainServices(_ domain: String) -> [(String, String)] {
        [
            ("VirusTotal", "https://www.virustotal.com/gui/domain/\(domain)"),
            ("urlscan.io", "https://urlscan.io/domain/\(domain)"),
            ("crt.sh", "https://crt.sh/?q=\(domain)"),
        ]
    }
}
