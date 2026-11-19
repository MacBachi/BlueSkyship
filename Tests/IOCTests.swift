import AppKit
import Foundation
import Testing
@testable import BlueSkyship

struct IOCTests {
    private func kinds(_ text: String) -> [IOCKind] { IOCDetector.find(in: text).map(\.kind) }
    private func values(_ text: String) -> [String] { IOCDetector.find(in: text).map(\.value) }

    @Test func findsHashesByLength() {
        let md5 = "44d88612fea8a8f36de82e1278abb02f"
        let sha1 = "3395856ce81f2b7382dee72602f798b642f14140"
        let sha256 = "275a021bbfb6489e54d471899f7db9d1663fc695ec2fe2a2c4538aabf651fd0f"
        #expect(kinds("Sample \(md5), \(sha1) und \(sha256).") == [.md5, .sha1, .sha256])
    }

    @Test func ignoresLongNumbersAndWordsThatLookHexish() {
        #expect(kinds("Order 12345678901234567890123456789012 shipped") == [])
        #expect(kinds("deadbeef cafe facade") == [])
    }

    @Test func findsEUVDNumbers() {
        let found = IOCDetector.find(in: "Siehe euvd-2025-14093 und CVE-2025-1.")
        #expect(found.map(\.kind) == [.euvd])
        #expect(found.first?.value == "EUVD-2025-14093")
        let ioc = IOC(kind: .euvd, value: "EUVD-2025-14093", range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: ioc).first?.url.absoluteString == "https://euvd.enisa.europa.eu/vulnerability/EUVD-2025-14093")
        let cve = IOC(kind: .cve, value: "CVE-2024-3094", range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: cve).map(\.name).contains("EUVD"))
        let link = URL(string: "https://euvd.enisa.europa.eu/vulnerability/EUVD-2025-14093")!
        #expect(IOCDetector.subject(forLink: link)?.kind == .euvd)
    }

    @Test func findsGHSAIdentifiersLikeGitHubWritesThem() {
        let found = IOCDetector.find(in: "Fixed in GHSA-JFH8-C2JP-5V3Q, not GHSA-abcd-1234-zzzz.")
        #expect(found.map(\.kind) == [.ghsa])
        #expect(found.first?.value == "GHSA-jfh8-c2jp-5v3q")
        let ioc = IOC(kind: .ghsa, value: "GHSA-jfh8-c2jp-5v3q", range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: ioc).map(\.name) == ["GitHub", "OSV", "EUVD"])
        let link = URL(string: "https://github.com/advisories/GHSA-jfh8-c2jp-5v3q")!
        #expect(IOCDetector.subject(forLink: link)?.kind == .ghsa)
        #expect(IOCDetector.containsIOC("See GHSA-jfh8-c2jp-5v3q"))
    }

    @Test func findsCVEsInAnyCase() {
        #expect(values("Patch for cve-2024-3094 and CVE-2021-44228.") == ["CVE-2024-3094", "CVE-2021-44228"])
    }

    @Test func findsPlainAndDefangedIPv4() {
        let found = IOCDetector.find(in: "C2 at 185.220.101[.]4 and 10.0.0.1/24, not 1.2.3.4.5")
        #expect(found.map(\.value) == ["185.220.101.4", "10.0.0.1/24"])
        #expect(found.map(\.wasDefanged) == [true, false])
    }

    @Test func findsIPv6ButNotClockTimes() {
        #expect(kinds("Seen from 2001:db8::ff00:42:8329 at 12:30:45") == [.ipv6])
    }

    @Test func defangedDomainsCountWhateverTheirEnding() {
        let found = IOCDetector.find(in: "Phishing via login-micros0ft[.]support and evil(dot)zip")
        #expect(found.map(\.value) == ["login-micros0ft.support", "evil.zip"])
        #expect(found.allSatisfy { $0.wasDefanged })
    }

    @Test func plainDomainsNeedAKnownEndingSoFileNamesStayText() {
        #expect(values("Siehe heise.de und (cert.at), aber nicht README.md, setup.exe oder z.B. Node.js") == ["heise.de", "cert.at"])
    }

    @Test func defangedURLsBecomeUsableAndKeepTheirPath() {
        let found = IOCDetector.find(in: "Payload: hxxps://evil[.]example[.]com/a/b.php?x=1.")
        #expect(found.count == 1)
        #expect(found.first?.kind == .url)
        #expect(found.first?.value == "https://evil.example.com/a/b.php?x=1")
        #expect(found.first?.host == "evil.example.com")
        #expect(found.first?.mayOpenInBrowser == false)
    }

    @Test func domainInsideAnAddressDoesNotCountTwice() {
        #expect(kinds("https://example.com/path") == [.url])
        #expect(kinds("Mail an abuse[@]example[.]com") == [.email])
    }

    @Test func defangingAndRefangingRoundTrip() {
        #expect(IOCDetector.defang("evil.example.com", kind: .domain) == "evil[.]example[.]com")
        #expect(IOCDetector.defang("https://evil.com/x.php", kind: .url) == "hxxps://evil[.]com/x.php")
        #expect(IOCDetector.refang("hxxps://evil[.]com/x[.]php") == "https://evil.com/x.php")
    }

    @Test func internalLinkCarriesTheIOC() throws {
        let ioc = try #require(IOCDetector.find(in: "evil[.]com").first)
        let url = try #require(IOCDetector.link(for: ioc))
        let back = try #require(IOCDetector.ioc(from: url))
        #expect(back.kind == .domain)
        #expect(back.value == "evil.com")
        #expect(back.wasDefanged)
    }

    @Test func lookupsMatchTheKind() {
        let ip = IOC(kind: .ipv4, value: "1.2.3.4", range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: ip).map(\.name) == ["VirusTotal", "AbuseIPDB", "Shodan", "GreyNoise"])
        let cve = IOC(kind: .cve, value: "CVE-2024-3094", range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: cve).first?.url.absoluteString == "https://nvd.nist.gov/vuln/detail/CVE-2024-3094")
        let hash = IOC(kind: .sha256, value: String(repeating: "ab12", count: 16), range: NSRange(), wasDefanged: false)
        #expect(IOCLookup.services(for: hash).map(\.name).contains("MalwareBazaar"))
    }

    @Test func tooltipSaysWhatItIsAndWhatAClickOffers() {
        let ioc = IOC(kind: .domain, value: "evil.com", range: NSRange(), wasDefanged: true)
        let tip = IOCDetector.tooltip(for: ioc)
        #expect(tip.contains("evil.com"))
        #expect(tip.contains("VirusTotal"))
    }

    @Test func linkTooltipNamesTheDomainLikeABrowser() throws {
        let url = try #require(URL(string: "https://www.example.org/path?q=1"))
        let tip = IOCDetector.tooltip(forLink: url)
        #expect(tip.contains("www.example.org"))
        #expect(tip.contains("https://www.example.org/path?q=1"))
    }

    @MainActor @Test func textViewMarksIOCsButLeavesExistingLinksAlone() throws {
        var text = AttributedString("Hash 44d88612fea8a8f36de82e1278abb02f via example.com")
        let linkRange = try #require(text.range(of: "example.com"))
        text[linkRange].link = URL(string: "https://example.com")
        let result = SelectablePostText.attributed(text, fontSize: 13, color: .labelColor, findsIOCs: true)
        let hashStart = (result.string as NSString).range(of: "44d8").location
        let hashLink = result.attribute(.link, at: hashStart, effectiveRange: nil) as? URL
        #expect(hashLink.flatMap(IOCDetector.ioc(from:))?.kind == .md5)
        #expect(result.attribute(.toolTip, at: hashStart, effectiveRange: nil) != nil)
        let domainStart = (result.string as NSString).range(of: "example.com").location
        #expect((result.attribute(.link, at: domainStart, effectiveRange: nil) as? URL)?.scheme == "https")
    }

    @MainActor @Test func switchedOffMeansNoMarks() {
        let result = SelectablePostText.attributed(
            AttributedString("CVE-2024-3094"), fontSize: 13, color: .labelColor, findsIOCs: false
        )
        #expect(result.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test func filterKeepsOnlyItemsWithRealIOCs() {
        #expect(IOCDetector.containsIOC("Exploit for CVE-2024-3094 published"))
        #expect(IOCDetector.containsIOC("Blocked evil[.]com today"))
        #expect(!IOCDetector.containsIOC("Read https://example.com/news on heise.de"))
    }

    @Test func oldFiltersLoadWithoutTheIOCSwitch() throws {
        let old = #"{"includeTerms":[],"excludeTerms":[],"mediaOnly":false,"hideReposts":false,"hideReplies":false}"#
        let filter = try JSONDecoder().decode(ColumnFilter.self, from: Data(old.utf8))
        #expect(!filter.onlyWithIOCs)
        #expect(ColumnFilter(onlyWithIOCs: true).isActive)
    }
}

@Suite("IOC live info")
struct IOCIntelTests {
    /// Every service on one simulated host, told apart by path.
    private func endpoints(_ host: String) -> IntelEndpoints {
        let base = "https://\(host)"
        return IntelEndpoints(
            nvd: URL(string: "\(base)/nvd")!, epss: URL(string: "\(base)/epss")!, ripe: URL(string: "\(base)/ripe/")!,
            internetDB: URL(string: "\(base)/idb/")!, greyNoise: URL(string: "\(base)/gn/")!, urlscan: URL(string: "\(base)/us/")!,
            circl: URL(string: "\(base)/circl/")!, virusTotal: URL(string: "\(base)/vt/")!, abuseIPDB: URL(string: "\(base)/abuse")!,
            euvd: URL(string: "\(base)/euvd/")!, github: URL(string: "\(base)/gh/")!
        )
    }

    private func ioc(_ kind: IOCKind, _ value: String) -> IOC { IOC(kind: kind, value: value, range: NSRange(), wasDefanged: false) }
    private func json(_ text: String) -> (Int, Data) { (200, Data(text.utf8)) }

    @Test func cveCardShowsScoreExploitationAndEPSS() async {
        StubProtocol.register(host: "cve.intel.test") { request in
            let path = request.url!.path
            if path.hasPrefix("/nvd") {
                return json(#"{"vulnerabilities":[{"cve":{"published":"2021-12-10T10:15:09.143","cisaExploitAdd":"2021-12-10","cisaActionDue":"2021-12-24","cisaVulnerabilityName":"Apache Log4j2 RCE","descriptions":[{"lang":"es","value":"x"},{"lang":"en","value":"JNDI lookups run code."}],"metrics":{"cvssMetricV31":[{"type":"Primary","cvssData":{"baseScore":10.0,"baseSeverity":"CRITICAL"}}]},"weaknesses":[{"description":[{"lang":"en","value":"CWE-502"}]}]}}]}"#)
            }
            if path.hasPrefix("/epss") { return json(#"{"data":[{"cve":"CVE-2021-44228","epss":"0.97","percentile":"0.999"}]}"#) }
            return (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("cve.intel.test"))
        let report = await intel.report(for: ioc(.cve, "CVE-2021-44228"))
        #expect(report.title == "Apache Log4j2 RCE")
        #expect(report.summary == "JNDI lookups run code.")
        let cvss = report.facts.first { $0.label == "CVSS 3.1" }
        #expect(cvss?.value.hasPrefix("10.0") == true)
        #expect(cvss?.tone == .bad)
        #expect(report.facts.first { $0.label == "KEV" }?.tone == .bad)
        #expect(report.facts.first { $0.label == "EPSS" }?.tone == .bad)
        #expect(report.facts.contains { $0.value.contains("CWE-502") })
        #expect(report.notes.isEmpty)
    }

    @Test func ipCardCombinesNetworkPortsAndScannerVerdict() async {
        StubProtocol.register(host: "ip.intel.test") { request in
            let path = request.url!.path
            if path.contains("prefix-overview") { return json(#"{"data":{"resource":"185.220.101.0/24","asns":[{"asn":60729,"holder":"Example Hosting"}]}}"#) }
            if path.contains("maxmind") { return json(#"{"data":{"located_resources":[{"locations":[{"country":"DE","city":"Berlin"}]}]}}"#) }
            if path.hasPrefix("/idb/") { return json(#"{"ports":[22,443],"hostnames":[],"tags":["tor"],"vulns":["CVE-2023-1","CVE-2024-2"]}"#) }
            if path.hasPrefix("/gn/") { return json(#"{"noise":true,"riot":false,"classification":"malicious","name":"unknown","last_seen":"2026-11-18"}"#) }
            return (500, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("ip.intel.test"))
        let report = await intel.report(for: ioc(.ipv4, "185.220.101.4"))
        #expect(report.facts.contains { $0.value.contains("AS60729 Example Hosting") })
        #expect(report.facts.contains { $0.value.contains("Berlin") })
        #expect(report.facts.contains { $0.value.contains("22, 443") })
        #expect(report.facts.first { $0.source == "GreyNoise" }?.tone == .bad)
        #expect(report.notes.contains { $0.contains("VirusTotal") })
    }

    @Test func privateAddressesAreNeverSent() async {
        let seen = SeenRequests()
        StubProtocol.register(host: "private.intel.test") { request in
            seen.add(request)
            return (200, Data("{}".utf8))
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("private.intel.test"))
        for address in ["10.1.2.3", "192.168.0.1", "127.0.0.1", "172.20.0.5", "fe80::1"] {
            let kind: IOCKind = address.contains(":") ? .ipv6 : .ipv4
            let report = await intel.report(for: ioc(kind, address))
            #expect(report.facts.isEmpty)
        }
        #expect(seen.urls.isEmpty)
    }

    @Test func asksOnlyOnceForTheSameIOC() async {
        let seen = SeenRequests()
        StubProtocol.register(host: "cache.intel.test") { request in
            seen.add(request)
            return (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("cache.intel.test"))
        _ = await intel.report(for: ioc(.sha256, String(repeating: "ab12", count: 16)))
        let first = seen.urls.count
        _ = await intel.report(for: ioc(.sha256, String(repeating: "ab12", count: 16)))
        #expect(first == 1)
        #expect(seen.urls.count == first)
    }

    @Test func virusTotalKeyIsSentAndRatesTheFile() async {
        StubProtocol.register(host: "vt.intel.test") { request in
            let path = request.url!.path
            if path.hasPrefix("/vt/files/") {
                guard request.value(forHTTPHeaderField: "x-apikey") == "made-up-key" else { return (401, Data()) } // secret-scan:allow (made-up test value)
                return json(#"{"data":{"attributes":{"meaningful_name":"evil.exe","type_description":"Win32 EXE","last_analysis_stats":{"malicious":40,"suspicious":2,"harmless":0,"undetected":30}}}}"#)
            }
            return (404, Data())
        }
        let intel = IOCIntel(keys: IntelKeys(virusTotal: "made-up-key"), transport: StubProtocol.session(), endpoints: endpoints("vt.intel.test")) // secret-scan:allow (made-up test value)
        let report = await intel.report(for: ioc(.md5, "44d88612fea8a8f36de82e1278abb02f"))
        let rating = report.facts.first { $0.label == "VirusTotal" }
        #expect(rating?.value.contains("40") == true)
        #expect(rating?.tone == .bad)
        #expect(report.facts.contains { $0.value.contains("evil.exe") })
        #expect(!report.notes.contains { $0.contains("⌘,") })
    }

    @Test func aFailingServiceLeavesANoteAndTheRestStillShows() async {
        StubProtocol.register(host: "partial.intel.test") { request in
            if request.url!.path.hasPrefix("/epss") { return json(#"{"data":[{"epss":"0.01","percentile":"0.5"}]}"#) }
            return (429, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("partial.intel.test"))
        let report = await intel.report(for: ioc(.cve, "CVE-2024-3094"))
        #expect(report.facts.contains { $0.label == "EPSS" })
        #expect(report.notes.contains { $0.contains("NVD") })
    }

    private static let euvdItem = #"{"id":"EUVD-2021-34768","description":"JNDI lookups run code.","baseScore":10.0,"baseScoreVersion":"3.1","aliases":"GHSA-jfh8-c2jp-5v3q\nCVE-2021-44228\n","epss":97.5,"exploitedSince":"Dec 10, 2021, 12:00:00 AM","enisaIdProduct":[{"product":{"name":"Apache Log4j2","vendor":{"name":"Apache Software Foundation"}},"product_version":"2.0-beta9 <log4j-core*"}]}"#

    @Test func cveCardNamesItsEUVDEntryAndLinksToIt() async {
        StubProtocol.register(host: "euvd-cve.intel.test") { request in
            let path = request.url!.path
            if path.hasPrefix("/euvd/search") {
                // Full-text search: an entry that only mentions the CVE in its text must not count.
                return json(#"{"total":2,"items":[{"id":"EUVD-2022-1","aliases":"CVE-2021-45046\n","description":"Follow-up to CVE-2021-44228"},"# + Self.euvdItem + "]}")
            }
            return (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("euvd-cve.intel.test"))
        let report = await intel.report(for: ioc(.cve, "CVE-2021-44228"))
        #expect(report.facts.first { $0.label == "EUVD" }?.value == "EUVD-2021-34768")
        #expect(report.facts.contains { $0.value.contains("2021-12-10") && $0.tone == .bad })
        #expect(report.facts.contains { $0.value.contains("Apache Software Foundation Apache Log4j2") })
        #expect(report.links.first?.url.absoluteString == "https://euvd.enisa.europa.eu/vulnerability/EUVD-2021-34768")
        #expect(report.facts.contains { $0.value.contains("GHSA-jfh8-c2jp-5v3q") })
    }

    @Test func cveWithoutEUVDEntrySaysSo() async {
        StubProtocol.register(host: "euvd-none.intel.test") { request in
            request.url!.path.hasPrefix("/euvd/search") ? json(#"{"total":0,"items":[]}"#) : (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("euvd-none.intel.test"))
        let report = await intel.report(for: ioc(.cve, "CVE-2026-1"))
        #expect(report.facts.first { $0.label == "EUVD" }?.tone == .neutral)
        #expect(report.links.isEmpty)
    }

    @Test func euvdNumberShowsItsEntryAndTheCVEBehindIt() async {
        StubProtocol.register(host: "euvd-id.intel.test") { request in
            request.url!.path.hasPrefix("/euvd/enisaid") ? json(Self.euvdItem) : (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("euvd-id.intel.test"))
        let report = await intel.report(for: ioc(.euvd, "EUVD-2021-34768"))
        #expect(report.summary == "JNDI lookups run code.")
        #expect(report.facts.first { $0.label == "CVSS 3.1" }?.tone == .bad)
        #expect(report.facts.first { $0.label == "EPSS" }?.tone == .bad)
        #expect(report.facts.contains { $0.value.contains("CVE-2021-44228") })
        #expect(report.links.map(\.name).contains("NVD"))
        #expect(!report.notes.contains { $0.contains("VirusTotal") })
    }

    @Test func ghsaCardShowsGitHubAdvisoryAndItsEUVDEntry() async {
        StubProtocol.register(host: "ghsa.intel.test") { request in
            let path = request.url!.path
            if path.hasPrefix("/gh/GHSA-jfh8-c2jp-5v3q") {
                return json(##"{"ghsa_id":"GHSA-jfh8-c2jp-5v3q","cve_id":"CVE-2021-44228","html_url":"https://github.com/advisories/GHSA-jfh8-c2jp-5v3q","summary":"Remote code injection in Log4j","description":"# Summary\n**Log4j** runs `JNDI` lookups.","severity":"critical","published_at":"2021-12-10T00:40:56Z","withdrawn_at":null,"vulnerabilities":[{"package":{"ecosystem":"maven","name":"org.apache.logging.log4j:log4j-core"},"vulnerable_version_range":">= 2.13.0, < 2.15.0","first_patched_version":"2.15.0"}],"cvss_severities":{"cvss_v3":{"score":10.0},"cvss_v4":{"score":0.0}},"epss":{"percentage":0.97,"percentile":0.999}}"##)
            }
            if path.hasPrefix("/euvd/search") { return json(#"{"items":["# + Self.euvdItem + "]}") }
            return (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("ghsa.intel.test"))
        let report = await intel.report(for: ioc(.ghsa, "GHSA-jfh8-c2jp-5v3q"))
        #expect(report.title == "Remote code injection in Log4j")
        #expect(report.summary == "Log4j runs JNDI lookups.")
        #expect(report.facts.first { $0.label == "CVSS 3" }?.tone == .bad)
        #expect(report.facts.first { $0.label == "EPSS" }?.tone == .bad)
        #expect(report.facts.contains { $0.value.contains("log4j-core >= 2.13.0, < 2.15.0") && $0.value.contains("2.15.0") })
        #expect(report.facts.first { $0.label == "EUVD" }?.value == "EUVD-2021-34768")
        let names = report.links.map(\.name)
        #expect(names.contains("GitHub"))
        #expect(names.contains("NVD"))
        #expect(names.contains("EUVD-2021-34768"))
        #expect(names.filter { $0 == "NVD" }.count == 1)
        // The advisory itself is not listed again as one of its own aliases.
        #expect(!report.facts.contains { $0.label.contains("bekannt") && $0.value.contains("GHSA") })
        #expect(!report.notes.contains { $0.contains("VirusTotal") })
    }

    @Test func cveCardLinksTheGitHubAdvisoriesItsEUVDEntryNames() async {
        StubProtocol.register(host: "cve-ghsa.intel.test") { request in
            request.url!.path.hasPrefix("/euvd/search") ? json(#"{"items":["# + Self.euvdItem + "]}") : (404, Data())
        }
        let intel = IOCIntel(transport: StubProtocol.session(), endpoints: endpoints("cve-ghsa.intel.test"))
        let report = await intel.report(for: ioc(.cve, "CVE-2021-44228"))
        #expect(report.links.contains { $0.url.absoluteString == "https://github.com/advisories/GHSA-jfh8-c2jp-5v3q" })
    }

    @Test func linksAreAboutTheCVEOrAddressTheyName() throws {
        let nvd = try #require(URL(string: "https://nvd.nist.gov/vuln/detail/CVE-2024-3094"))
        #expect(IOCDetector.subject(forLink: nvd)?.kind == .cve)
        #expect(IOCDetector.subject(forLink: nvd)?.value == "CVE-2024-3094")
        let ip = try #require(URL(string: "http://45.148.10.99/payload"))
        #expect(IOCDetector.subject(forLink: ip)?.kind == .ipv4)
        let plain = try #require(URL(string: "https://www.heise.de/news"))
        #expect(IOCDetector.subject(forLink: plain)?.kind == .url)
        #expect(IOCDetector.subject(forLink: plain)?.host == "www.heise.de")
        let mention = try #require(URL(string: "bskyship://profile?v=did:plc:abc"))
        #expect(PostTextView.subject(of: mention) == nil)
    }

    @MainActor @Test func hoverCardsReplaceTooltips() {
        let text = AttributedString("CVE-2024-3094")
        let withCards = SelectablePostText.attributed(text, fontSize: 13, color: .labelColor, findsIOCs: true, tooltips: false)
        #expect(withCards.attribute(.toolTip, at: 0, effectiveRange: nil) == nil)
        #expect(withCards.attribute(.link, at: 0, effectiveRange: nil) != nil)
    }
}
