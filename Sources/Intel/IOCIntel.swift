import Foundation

/// How a fact reads: harmless, worth a look, or bad.
enum IntelTone: Sendable {
    case neutral, good, caution, bad
}

struct IntelFact: Hashable, Sendable, Identifiable {
    var id: String { source + label }
    let source: String
    let label: String
    let value: String
    var tone: IntelTone = .neutral
}

/// What the services said about one IOC.
struct IntelReport: Sendable {
    var title: String?
    var summary: String?
    var facts: [IntelFact] = []
    /// Services that failed or need a key. Shown small, below the facts.
    var notes: [String] = []
    /// Pages the answers point to, such as the EUVD entry that belongs to a CVE.
    var links: [IOCLookup.Service] = []
}

/// Keys for services that rate without charge but only for registered users. Optional.
struct IntelKeys: Codable, Equatable, Sendable {
    var virusTotal = ""
    var abuseIPDB = ""

    var isEmpty: Bool { virusTotal.isEmpty && abuseIPDB.isEmpty }
}

/// Where the services live. Tests point these at simulated servers.
struct IntelEndpoints: Sendable {
    var nvd = URL(string: "https://services.nvd.nist.gov/rest/json/cves/2.0")!
    var epss = URL(string: "https://api.first.org/data/v1/epss")!
    var ripe = URL(string: "https://stat.ripe.net/data/")!
    var internetDB = URL(string: "https://internetdb.shodan.io/")!
    var greyNoise = URL(string: "https://api.greynoise.io/v3/community/")!
    var urlscan = URL(string: "https://urlscan.io/api/v1/search/")!
    var circl = URL(string: "https://hashlookup.circl.lu/lookup/")!
    var virusTotal = URL(string: "https://www.virustotal.com/api/v3/")!
    var abuseIPDB = URL(string: "https://api.abuseipdb.com/api/v2/check")!
    var euvd = URL(string: "https://euvdservices.enisa.europa.eu/api/")!
    var github = URL(string: "https://api.github.com/advisories/")!
}

/// Asks public services about an IOC while the mouse rests on it. Each answer is kept for a few hours,
/// so moving the mouse back and forth does not ask again.
actor IOCIntel {
    private let transport: URLSession
    private let endpoints: IntelEndpoints
    private var keys: IntelKeys
    private var cache: [String: (date: Date, report: IntelReport)] = [:]
    private var running: [String: Task<IntelReport, Never>] = [:]
    static let keepFor: TimeInterval = 6 * 3600

    init(keys: IntelKeys = IntelKeys(), transport: URLSession = .shared, endpoints: IntelEndpoints = IntelEndpoints()) {
        self.keys = keys
        self.transport = transport
        self.endpoints = endpoints
    }

    func setKeys(_ new: IntelKeys) {
        guard new != keys else { return }
        keys = new
        cache.removeAll()
    }

    func report(for ioc: IOC) async -> IntelReport {
        let key = "\(ioc.kind.rawValue):\(ioc.value)"
        if let hit = cache[key], Date().timeIntervalSince(hit.date) < Self.keepFor { return hit.report }
        if let task = running[key] { return await task.value }
        let lookup = Lookup(transport: transport, endpoints: endpoints, keys: keys)
        let task = Task { await lookup.report(for: ioc) }
        running[key] = task
        let report = await task.value
        running[key] = nil
        cache[key] = (Date(), report)
        return report
    }
}

/// One round of questions. Every service is asked at the same time; one that fails leaves a note.
private struct Lookup: Sendable {
    let transport: URLSession
    let endpoints: IntelEndpoints
    let keys: IntelKeys

    typealias Part = @Sendable () async -> IntelReport

    func report(for ioc: IOC) async -> IntelReport {
        var parts: [Part] = []
        switch ioc.kind {
        case .cve:
            parts = [{ await nvd(ioc.value) }, { await epss(ioc.value) }, { await euvd(alias: ioc.value) }]
        case .ghsa:
            parts = [{ await github(ioc.value) }, { await euvd(alias: ioc.value) }]
        case .euvd:
            parts = [{ await euvd(id: ioc.value) }]
        case .ipv4, .ipv6:
            let address = ioc.value.split(separator: "/").first.map(String.init) ?? ioc.value
            if IPRanges.isPrivate(address) {
                return IntelReport(notes: [tr("Privates oder reserviertes Netz. Dazu gibt es nichts nachzuschlagen.", "Private or reserved network. There is nothing to look up.")])
            }
            parts = [{ await ripe(address) }, { await internetDB(address) }, { await greyNoise(address) }]
            if !keys.abuseIPDB.isEmpty { parts.append { await abuseIPDB(address) } }
            if !keys.virusTotal.isEmpty { parts.append { await virusTotal(path: "ip_addresses/\(address)") } }
        case .domain, .email, .url:
            guard let host = ioc.host else { return IntelReport() }
            if let ip = IOCDetector.find(in: host).first, ip.kind == .ipv4 || ip.kind == .ipv6 {
                return await report(for: IOC(kind: ip.kind, value: host, range: NSRange(), wasDefanged: false))
            }
            parts = [{ await urlscan(host) }]
            if !keys.virusTotal.isEmpty {
                if ioc.kind == .url {
                    let id = Data(ioc.value.utf8).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                    parts.append { await virusTotal(path: "urls/\(id)") }
                }
                parts.append { await virusTotal(path: "domains/\(host)") }
            }
        case .md5, .sha1, .sha256, .sha512:
            if ioc.kind != .sha512 { parts.append { await circl(kind: ioc.kind, hash: ioc.value) } }
            if !keys.virusTotal.isEmpty { parts.append { await virusTotal(path: "files/\(ioc.value)") } }
        }

        var report = IntelReport()
        await withTaskGroup(of: (Int, IntelReport).self) { group in
            for (index, part) in parts.enumerated() { group.addTask { (index, await part()) } }
            var pieces: [(Int, IntelReport)] = []
            for await piece in group { pieces.append(piece) }
            for (_, piece) in pieces.sorted(by: { $0.0 < $1.0 }) {
                report.title = report.title ?? piece.title
                report.summary = report.summary ?? piece.summary
                report.facts += piece.facts
                report.notes += piece.notes
                report.links += piece.links.filter { link in !report.links.contains { $0.url == link.url } }
            }
        }
        if keys.virusTotal.isEmpty, ioc.kind != .cve, ioc.kind != .euvd, ioc.kind != .ghsa {
            report.notes.append(tr("Für eine Bewertung durch VirusTotal einen kostenlosen Schlüssel unter ⌘, → IOCs eintragen.",
                                   "For a VirusTotal rating, enter a free key under ⌘, → IOCs."))
        }
        return report
    }

    // MARK: Fetching

    private enum Answer {
        case found([String: Any])
        case notFound
        case failed(String)
    }

    private func get(_ url: URL, headers: [String: String] = [:], service: String) async -> Answer {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BlueSkyship (IOC lookup)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await transport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            if status == 404 { return .notFound }
            if status == 401 || status == 403 {
                return .failed(tr("\(service) lehnt die Abfrage ab (Schlüssel prüfen oder später erneut).", "\(service) refused the request (check the key or try later)."))
            }
            if status == 429 { return .failed(tr("\(service) lässt gerade keine weiteren Abfragen zu.", "\(service) allows no more requests right now.")) }
            guard (200..<300).contains(status),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed(tr("\(service) antwortet mit Fehler \(status).", "\(service) answered with error \(status)."))
            }
            return .found(object)
        } catch {
            return .failed(tr("\(service) ist nicht erreichbar.", "\(service) cannot be reached."))
        }
    }

    private func url(_ base: URL, path: String = "", query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: path.isEmpty ? base : base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private func failed(_ answer: Answer) -> IntelReport? {
        if case .failed(let note) = answer { return IntelReport(notes: [note]) }
        return nil
    }

    // MARK: Vulnerabilities

    private func nvd(_ cve: String) async -> IntelReport {
        let answer = await get(url(endpoints.nvd, query: ["cveId": cve]), service: "NVD")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer,
              let entry = (body["vulnerabilities"] as? [[String: Any]])?.first?["cve"] as? [String: Any] else {
            return IntelReport(notes: [tr("NVD kennt \(cve) noch nicht.", "NVD does not know \(cve) yet.")])
        }
        var report = IntelReport()
        report.title = entry["cisaVulnerabilityName"] as? String
        let descriptions = entry["descriptions"] as? [[String: Any]] ?? []
        report.summary = (descriptions.first { $0["lang"] as? String == "en" } ?? descriptions.first)?["value"] as? String

        let metrics = entry["metrics"] as? [String: Any] ?? [:]
        for (key, name) in [("cvssMetricV40", "CVSS 4.0"), ("cvssMetricV31", "CVSS 3.1"), ("cvssMetricV30", "CVSS 3.0"), ("cvssMetricV2", "CVSS 2.0")] {
            let list = metrics[key] as? [[String: Any]] ?? []
            guard let metric = list.first(where: { $0["type"] as? String == "Primary" }) ?? list.first,
                  let data = metric["cvssData"] as? [String: Any],
                  let score = (data["baseScore"] as? NSNumber)?.doubleValue else { continue }
            let severity = (data["baseSeverity"] as? String) ?? (metric["baseSeverity"] as? String) ?? ""
            report.facts.append(IntelFact(source: "NVD", label: name, value: "\(String(format: "%.1f", score)) \(Self.severityName(severity))", tone: Self.tone(severity: severity)))
            break
        }
        if let added = entry["cisaExploitAdd"] as? String {
            var value = tr("wird ausgenutzt, gelistet seit \(added)", "exploited, listed since \(added)")
            if let due = entry["cisaActionDue"] as? String { value += tr(" · Frist \(due)", " · due \(due)") }
            report.facts.append(IntelFact(source: "CISA", label: "KEV", value: value, tone: .bad))
        } else {
            report.facts.append(IntelFact(source: "CISA", label: "KEV", value: tr("nicht gelistet", "not listed")))
        }
        if let published = (entry["published"] as? String)?.prefix(10) {
            report.facts.append(IntelFact(source: "NVD", label: tr("Veröffentlicht", "Published"), value: String(published)))
        }
        let weaknesses = (entry["weaknesses"] as? [[String: Any]] ?? [])
            .flatMap { $0["description"] as? [[String: Any]] ?? [] }
            .compactMap { $0["value"] as? String }
            .filter { $0.hasPrefix("CWE-") }
        if !weaknesses.isEmpty {
            report.facts.append(IntelFact(source: "NVD", label: tr("Schwäche", "Weakness"), value: Array(Set(weaknesses)).sorted().prefix(3).joined(separator: ", ")))
        }
        return report
    }

    private func epss(_ cve: String) async -> IntelReport {
        let answer = await get(url(endpoints.epss, query: ["cve": cve]), service: "EPSS")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer, let row = (body["data"] as? [[String: Any]])?.first,
              let probability = Double(row["epss"] as? String ?? ""), let percentile = Double(row["percentile"] as? String ?? "") else {
            return IntelReport()
        }
        let tone: IntelTone = probability >= 0.5 ? .bad : probability >= 0.1 ? .caution : .neutral
        let value = tr(
            "\(Self.percent(probability)) Wahrscheinlichkeit der Ausnutzung in 30 Tagen · Perzentil \(Self.percent(percentile))",
            "\(Self.percent(probability)) chance of exploitation within 30 days · percentile \(Self.percent(percentile))"
        )
        return IntelReport(facts: [IntelFact(source: "FIRST", label: "EPSS", value: value, tone: tone)])
    }

    // MARK: European Vulnerability Database (ENISA)

    /// The EUVD entry that names this CVE or GHSA among its aliases. The search is by full text,
    /// so only an exact alias counts.
    private func euvd(alias cve: String) async -> IntelReport {
        let answer = await get(url(endpoints.euvd, path: "search", query: ["text": cve, "size": "10"]), service: "EUVD")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer,
              let item = (body["items"] as? [[String: Any]] ?? []).first(where: { Self.aliases(of: $0).contains { $0.caseInsensitiveCompare(cve) == .orderedSame } }) else {
            return IntelReport(facts: [IntelFact(source: "ENISA", label: "EUVD", value: tr("kein Eintrag", "no entry"))])
        }
        return Self.euvdReport(item, alias: cve)
    }

    private func euvd(id: String) async -> IntelReport {
        let answer = await get(url(endpoints.euvd, path: "enisaid", query: ["id": id]), service: "EUVD")
        if let failure = failed(answer) { return failure }
        guard case .found(let item) = answer, item["id"] != nil else {
            return IntelReport(notes: [tr("Die EUVD kennt \(id) nicht.", "The EUVD does not know \(id).")])
        }
        return Self.euvdReport(item, alias: nil)
    }

    static func aliases(of item: [String: Any]) -> [String] {
        (item["aliases"] as? String ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// For a CVE or GHSA, NVD or GitHub already give the score and description, so the EUVD adds its
    /// own number, exploitation and product. For an EUVD number, its entry is all there is.
    static func euvdReport(_ item: [String: Any], alias: String?) -> IntelReport {
        let forCVE = alias != nil
        var report = IntelReport()
        let id = item["id"] as? String ?? ""
        if let page = URL(string: "https://euvd.enisa.europa.eu/vulnerability/\(id)") {
            report.links.append(IOCLookup.Service(name: id, url: page))
        }
        report.facts.append(IntelFact(source: "ENISA", label: "EUVD", value: id))
        report.summary = item["description"] as? String
        if !forCVE, let score = (item["baseScore"] as? NSNumber)?.doubleValue, score > 0 {
            let version = item["baseScoreVersion"] as? String ?? ""
            let severity = score >= 9 ? "CRITICAL" : score >= 7 ? "HIGH" : score >= 4 ? "MEDIUM" : "LOW"
            report.facts.append(IntelFact(source: "ENISA", label: "CVSS \(version)", value: "\(String(format: "%.1f", score)) \(severityName(severity))", tone: tone(severity: severity)))
        }
        if let since = item["exploitedSince"] as? String, !since.isEmpty {
            report.facts.append(IntelFact(source: "ENISA", label: tr("Ausgenutzt", "Exploited"), value: tr("laut EUVD seit \(euvdDate(since))", "per EUVD since \(euvdDate(since))"), tone: .bad))
        }
        if !forCVE, let epss = (item["epss"] as? NSNumber)?.doubleValue {
            let tone: IntelTone = epss >= 50 ? .bad : epss >= 10 ? .caution : .neutral
            report.facts.append(IntelFact(source: "ENISA", label: "EPSS", value: percent(epss / 100), tone: tone))
        }
        let products = (item["enisaIdProduct"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let product = entry["product"] as? [String: Any], let name = product["name"] as? String else { return nil }
            let vendor = (product["vendor"] as? [String: Any])?["name"] as? String
            let version = (entry["product_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return [vendor.flatMap { name.hasPrefix($0) ? nil : $0 }, name, version].compactMap { $0 }.joined(separator: " ")
        }
        if !products.isEmpty {
            report.facts.append(IntelFact(source: "ENISA", label: tr("Produkt", "Product"), value: Array(NSOrderedSet(array: products)).compactMap { $0 as? String }.prefix(3).joined(separator: "; ")))
        }
        let others = aliases(of: item).filter { $0.caseInsensitiveCompare(alias ?? "") != .orderedSame }
        for ghsa in others where ghsa.uppercased().hasPrefix("GHSA-") {
            if let page = URL(string: "https://github.com/advisories/\(IOCDetector.normalizedGHSA(ghsa))") {
                report.links.append(IOCLookup.Service(name: IOCDetector.normalizedGHSA(ghsa), url: page))
            }
        }
        if !others.isEmpty {
            report.facts.append(IntelFact(source: "ENISA", label: tr("Auch bekannt als", "Also known as"), value: others.prefix(4).joined(separator: ", ")))
            if !(alias?.uppercased().hasPrefix("CVE-") ?? false), let cve = others.first(where: { $0.uppercased().hasPrefix("CVE-") }),
               let nvd = URL(string: "https://nvd.nist.gov/vuln/detail/\(cve)") {
                report.links.append(IOCLookup.Service(name: "NVD", url: nvd))
            }
        }
        return report
    }

    // MARK: GitHub Advisory Database

    private func github(_ ghsa: String) async -> IntelReport {
        let answer = await get(
            url(endpoints.github, path: ghsa), headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
            service: "GitHub"
        )
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer else {
            return IntelReport(notes: [tr("GitHub kennt \(ghsa) nicht.", "GitHub does not know \(ghsa).")])
        }
        var report = IntelReport()
        report.title = body["summary"] as? String
        report.summary = (body["description"] as? String).map { Self.plainMarkdown($0) }
        if let page = (body["html_url"] as? String).flatMap(URL.init(string:)) {
            report.links.append(IOCLookup.Service(name: "GitHub", url: page))
        }
        let severity = (body["severity"] as? String ?? "").uppercased()
        let scores = body["cvss_severities"] as? [String: Any] ?? [:]
        let v4 = ((scores["cvss_v4"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue ?? 0
        let v3 = ((scores["cvss_v3"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue
            ?? ((body["cvss"] as? [String: Any])?["score"] as? NSNumber)?.doubleValue ?? 0
        if v4 > 0 || v3 > 0 {
            let label = v4 > 0 ? "CVSS 4.0" : "CVSS 3"
            report.facts.append(IntelFact(source: "GitHub", label: label, value: "\(String(format: "%.1f", v4 > 0 ? v4 : v3)) \(Self.severityName(severity))", tone: Self.tone(severity: severity)))
        } else if !severity.isEmpty {
            report.facts.append(IntelFact(source: "GitHub", label: tr("Schweregrad", "Severity"), value: Self.severityName(severity), tone: Self.tone(severity: severity)))
        }
        if let epss = body["epss"] as? [String: Any], let probability = (epss["percentage"] as? NSNumber)?.doubleValue {
            let tone: IntelTone = probability >= 0.5 ? .bad : probability >= 0.1 ? .caution : .neutral
            var value = Self.percent(probability)
            if let percentile = (epss["percentile"] as? NSNumber)?.doubleValue { value += tr(" · Perzentil \(Self.percent(percentile))", " · percentile \(Self.percent(percentile))") }
            report.facts.append(IntelFact(source: "GitHub", label: "EPSS", value: value, tone: tone))
        }
        if let cve = body["cve_id"] as? String, !cve.isEmpty {
            report.facts.append(IntelFact(source: "GitHub", label: "CVE", value: cve))
            if let nvd = URL(string: "https://nvd.nist.gov/vuln/detail/\(cve)") { report.links.append(IOCLookup.Service(name: "NVD", url: nvd)) }
        }
        let packages = (body["vulnerabilities"] as? [[String: Any]] ?? []).compactMap { entry -> String? in
            guard let package = entry["package"] as? [String: Any], let name = package["name"] as? String else { return nil }
            var text = name
            if let ecosystem = package["ecosystem"] as? String { text = "\(ecosystem) \(text)" }
            if let range = entry["vulnerable_version_range"] as? String, !range.isEmpty { text += " \(range)" }
            if let fixed = entry["first_patched_version"] as? String, !fixed.isEmpty { text += tr(" → behoben in \(fixed)", " → fixed in \(fixed)") }
            return text
        }
        if !packages.isEmpty {
            let shown = packages.prefix(3).joined(separator: "; ") + (packages.count > 3 ? " … (+\(packages.count - 3))" : "")
            report.facts.append(IntelFact(source: "GitHub", label: tr("Pakete", "Packages"), value: shown))
        }
        if let published = (body["published_at"] as? String)?.prefix(10) {
            report.facts.append(IntelFact(source: "GitHub", label: tr("Veröffentlicht", "Published"), value: String(published)))
        }
        if let withdrawn = (body["withdrawn_at"] as? String)?.prefix(10) {
            report.facts.append(IntelFact(source: "GitHub", label: tr("Zurückgezogen", "Withdrawn"), value: String(withdrawn), tone: .caution))
        }
        return report
    }

    /// GitHub descriptions are Markdown. The card shows plain text, so headings and emphasis go.
    static func plainMarkdown(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            // Headings such as "### Impact" say nothing on their own in a short card.
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .map { line in
                String(line).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The EUVD writes dates like "Dec 10, 2021, 12:00:00 AM".
    static func euvdDate(_ text: String) -> String {
        let reader = DateFormatter()
        reader.locale = Locale(identifier: "en_US_POSIX")
        reader.timeZone = TimeZone(identifier: "UTC")
        reader.dateFormat = "MMM d, yyyy, h:mm:ss a"
        guard let date = reader.date(from: text.replacingOccurrences(of: "\u{202F}", with: " ")) else { return text }
        let writer = DateFormatter()
        writer.locale = Locale(identifier: "en_US_POSIX")
        writer.timeZone = TimeZone(identifier: "UTC")
        writer.dateFormat = "yyyy-MM-dd"
        return writer.string(from: date)
    }

    static func severityName(_ severity: String) -> String {
        switch severity.uppercased() {
        case "CRITICAL": return tr("kritisch", "critical")
        case "HIGH": return tr("hoch", "high")
        case "MEDIUM": return tr("mittel", "medium")
        case "LOW": return tr("niedrig", "low")
        default: return severity.lowercased()
        }
    }

    static func tone(severity: String) -> IntelTone {
        switch severity.uppercased() {
        case "CRITICAL", "HIGH": return .bad
        case "MEDIUM": return .caution
        case "LOW", "NONE": return .good
        default: return .neutral
        }
    }

    static func percent(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(0...1)).locale(Localizer.shared.locale)) + " %"
    }

    // MARK: IP addresses

    private func ripe(_ address: String) async -> IntelReport {
        async let prefix = get(url(endpoints.ripe, path: "prefix-overview/data.json", query: ["resource": address]), service: "RIPEstat")
        async let geo = get(url(endpoints.ripe, path: "maxmind-geo-lite/data.json", query: ["resource": address]), service: "RIPEstat")
        let (prefixAnswer, geoAnswer) = await (prefix, geo)
        if let failure = failed(prefixAnswer) { return failure }
        var report = IntelReport()
        if case .found(let body) = prefixAnswer, let data = body["data"] as? [String: Any] {
            let asns = (data["asns"] as? [[String: Any]] ?? []).compactMap { asn -> String? in
                guard let number = asn["asn"] as? NSNumber else { return nil }
                return "AS\(number) \(asn["holder"] as? String ?? "")".trimmingCharacters(in: .whitespaces)
            }
            var value = asns.isEmpty ? tr("nicht im Internet angekündigt", "not announced on the internet") : asns.joined(separator: ", ")
            if let resource = data["resource"] as? String, resource != address { value += " · \(resource)" }
            report.facts.append(IntelFact(source: "RIPEstat", label: tr("Netz", "Network"), value: value))
        }
        if case .found(let body) = geoAnswer,
           let location = ((body["data"] as? [String: Any])?["located_resources"] as? [[String: Any]])?.first
               .flatMap({ ($0["locations"] as? [[String: Any]])?.first }),
           let country = location["country"] as? String, !country.isEmpty {
            let name = Localizer.shared.locale.localizedString(forRegionCode: country) ?? country
            let city = (location["city"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            report.facts.append(IntelFact(source: "RIPEstat", label: tr("Standort", "Location"), value: [city, name].compactMap { $0 }.joined(separator: ", ")))
        }
        return report
    }

    private func internetDB(_ address: String) async -> IntelReport {
        let answer = await get(url(endpoints.internetDB, path: address), service: "Shodan")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer else {
            return IntelReport(facts: [IntelFact(source: "Shodan", label: tr("Dienste", "Services"), value: tr("keine offenen Ports bekannt", "no open ports known"))])
        }
        var report = IntelReport()
        let ports = (body["ports"] as? [NSNumber] ?? []).map(\.stringValue)
        if !ports.isEmpty {
            report.facts.append(IntelFact(source: "Shodan", label: tr("Offene Ports", "Open ports"), value: Self.list(ports, limit: 8)))
        }
        let hostnames = body["hostnames"] as? [String] ?? []
        if !hostnames.isEmpty {
            report.facts.append(IntelFact(source: "Shodan", label: tr("Hostnamen", "Hostnames"), value: Self.list(hostnames, limit: 3)))
        }
        let vulns = body["vulns"] as? [String] ?? []
        if !vulns.isEmpty {
            report.facts.append(IntelFact(source: "Shodan", label: tr("Schwachstellen", "Vulnerabilities"), value: "\(vulns.count): " + Self.list(vulns.sorted().reversed(), limit: 3), tone: .caution))
        }
        let tags = body["tags"] as? [String] ?? []
        if !tags.isEmpty {
            let risky = tags.contains { ["malware", "c2", "compromised", "tor", "proxy", "vpn", "scanner"].contains($0.lowercased()) }
            report.facts.append(IntelFact(source: "Shodan", label: tr("Merkmale", "Tags"), value: Self.list(tags, limit: 5), tone: risky ? .caution : .neutral))
        }
        return report
    }

    private func greyNoise(_ address: String) async -> IntelReport {
        let answer = await get(url(endpoints.greyNoise, path: address), service: "GreyNoise")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer else {
            return IntelReport(facts: [IntelFact(source: "GreyNoise", label: "GreyNoise", value: tr("nicht beim Scannen gesehen", "not seen scanning"))])
        }
        let classification = (body["classification"] as? String ?? "").lowercased()
        let name = (body["name"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        let value: String
        let tone: IntelTone
        if body["riot"] as? Bool == true {
            value = tr("bekannter harmloser Dienst", "known harmless service") + (name.map { ": \($0)" } ?? "")
            tone = .good
        } else if classification == "malicious" {
            value = tr("bösartig", "malicious") + (name.map { " · \($0)" } ?? "")
            tone = .bad
        } else if classification == "benign" {
            value = tr("harmlos", "benign") + (name.map { " · \($0)" } ?? "")
            tone = .good
        } else if body["noise"] as? Bool == true {
            value = tr("scannt das Internet, Absicht unklar", "scans the internet, intent unclear")
            tone = .caution
        } else {
            value = tr("nicht beim Scannen gesehen", "not seen scanning")
            tone = .neutral
        }
        var fact = IntelFact(source: "GreyNoise", label: "GreyNoise", value: value, tone: tone)
        if let seen = body["last_seen"] as? String, tone != .neutral {
            fact = IntelFact(source: fact.source, label: fact.label, value: fact.value + tr(" · zuletzt \(seen)", " · last \(seen)"), tone: tone)
        }
        return IntelReport(facts: [fact])
    }

    private func abuseIPDB(_ address: String) async -> IntelReport {
        let answer = await get(
            url(endpoints.abuseIPDB, query: ["ipAddress": address, "maxAgeInDays": "90"]),
            headers: ["Key": keys.abuseIPDB], service: "AbuseIPDB"
        )
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer, let data = body["data"] as? [String: Any],
              let score = (data["abuseConfidenceScore"] as? NSNumber)?.intValue else { return IntelReport() }
        let reports = (data["totalReports"] as? NSNumber)?.intValue ?? 0
        let tone: IntelTone = score >= 50 ? .bad : score > 0 ? .caution : .good
        var facts = [IntelFact(source: "AbuseIPDB", label: "AbuseIPDB", value: tr("\(score) % Missbrauch · \(reports) Meldungen in 90 Tagen", "\(score) % abuse · \(reports) reports in 90 days"), tone: tone)]
        let usage = [data["usageType"] as? String, data["isp"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !usage.isEmpty { facts.append(IntelFact(source: "AbuseIPDB", label: tr("Betreiber", "Operator"), value: usage.joined(separator: " · "))) }
        return IntelReport(facts: facts)
    }

    // MARK: Domains, addresses, files

    private func urlscan(_ host: String) async -> IntelReport {
        let answer = await get(url(endpoints.urlscan, query: ["q": "page.domain:\(host)", "size": "1"]), service: "urlscan.io")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer else { return IntelReport() }
        let total = (body["total"] as? NSNumber)?.intValue ?? 0
        guard total > 0, let latest = (body["results"] as? [[String: Any]])?.first else {
            return IntelReport(facts: [IntelFact(source: "urlscan.io", label: "urlscan.io", value: tr("noch nie gescannt", "never scanned"), tone: .caution)])
        }
        let page = latest["page"] as? [String: Any] ?? [:]
        let time = ((latest["task"] as? [String: Any])?["time"] as? String).map { String($0.prefix(10)) } ?? ""
        let more = body["has_more"] as? Bool == true ? "+" : ""
        var facts = [IntelFact(source: "urlscan.io", label: "urlscan.io", value: tr("\(total)\(more) Scans, zuletzt \(time)", "\(total)\(more) scans, last \(time)"))]
        let where_ = [page["ip"] as? String, page["country"] as? String, page["asnname"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        if !where_.isEmpty { facts.append(IntelFact(source: "urlscan.io", label: tr("Server", "Server"), value: where_.joined(separator: " · "))) }
        if let age = (page["apexDomainAgeDays"] as? NSNumber)?.intValue {
            facts.append(IntelFact(source: "urlscan.io", label: tr("Domain-Alter", "Domain age"), value: tr("\(age) Tage", "\(age) days"), tone: age < 30 ? .caution : .neutral))
        }
        return IntelReport(facts: facts)
    }

    private func circl(kind: IOCKind, hash: String) async -> IntelReport {
        let answer = await get(url(endpoints.circl, path: "\(kind.rawValue)/\(hash.uppercased())"), service: "CIRCL")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer else {
            return IntelReport(facts: [IntelFact(source: "CIRCL", label: tr("Bekannte Datei", "Known file"), value: tr("nicht in der Liste harmloser Dateien", "not in the list of harmless files"))])
        }
        let product = (body["ProductCode"] as? [String: Any])?["ProductName"] as? String
        let name = [body["FileName"] as? String, product].compactMap { $0 }.joined(separator: " · ")
        return IntelReport(facts: [IntelFact(source: "CIRCL", label: tr("Bekannte Datei", "Known file"), value: tr("harmlos bekannt", "known harmless") + (name.isEmpty ? "" : ": \(name)"), tone: .good)])
    }

    private func virusTotal(path: String) async -> IntelReport {
        let answer = await get(url(endpoints.virusTotal, path: path), headers: ["x-apikey": keys.virusTotal], service: "VirusTotal")
        if let failure = failed(answer) { return failure }
        guard case .found(let body) = answer,
              let attributes = (body["data"] as? [String: Any])?["attributes"] as? [String: Any],
              let stats = attributes["last_analysis_stats"] as? [String: Any] else {
            return IntelReport(facts: [IntelFact(source: "VirusTotal", label: "VirusTotal", value: tr("unbekannt", "unknown"))])
        }
        let count = { (name: String) in (stats[name] as? NSNumber)?.intValue ?? 0 }
        let malicious = count("malicious")
        let suspicious = count("suspicious")
        let total = ["malicious", "suspicious", "harmless", "undetected"].map(count).reduce(0, +)
        let tone: IntelTone = malicious > 2 ? .bad : (malicious + suspicious) > 0 ? .caution : .good
        var value = tr("\(malicious) von \(total) Scannern bösartig", "\(malicious) of \(total) scanners malicious")
        if suspicious > 0 { value += tr(", \(suspicious) verdächtig", ", \(suspicious) suspicious") }
        var facts = [IntelFact(source: "VirusTotal", label: "VirusTotal" + (path.hasPrefix("urls/") ? " (URL)" : ""), value: value, tone: tone)]
        if let name = attributes["meaningful_name"] as? String {
            let type = attributes["type_description"] as? String
            facts.append(IntelFact(source: "VirusTotal", label: tr("Datei", "File"), value: [name, type].compactMap { $0 }.joined(separator: " · ")))
        }
        return IntelReport(facts: facts)
    }

    private static func list<S: Sequence>(_ items: S, limit: Int) -> String where S.Element == String {
        let all = Array(items)
        let shown = all.prefix(limit).joined(separator: ", ")
        return all.count > limit ? shown + " … (+\(all.count - limit))" : shown
    }
}

/// Addresses that only mean something inside one network. Asking about them would only reveal them.
enum IPRanges {
    static func isPrivate(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            switch (bytes[0], bytes[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127): return true
            case (224...255, _): return true
            default: return false
            }
        }
        let lower = address.lowercased()
        return lower == "::1" || lower == "::" || lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd") || lower.hasPrefix("ff")
    }
}

/// The keys are passwords in all but name, so they live in the Keychain.
enum IntelKeychain {
    private static let service = "dev.blueskyship.intel"
    private static let account = "keys"

    static func save(_ keys: IntelKeys) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !keys.isEmpty, let data = try? JSONEncoder().encode(keys) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> IntelKeys {
        guard !RuntimeEnvironment.isUnitTestHost else { return IntelKeys() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return IntelKeys() }
        return (try? JSONDecoder().decode(IntelKeys.self, from: data)) ?? IntelKeys()
    }
}
