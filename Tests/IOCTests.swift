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
