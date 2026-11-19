import AppKit
import SwiftUI

/// What a text view needs to show hover cards: whether to ask services, who asks, and how to open a page.
struct IOCHover {
    var live: Bool
    var intel: IOCIntel
}

/// The card that appears while the mouse rests on an IOC or a link: what it is, what the
/// services say about it, and buttons to look further or copy it.
struct IOCHoverCard: View {
    let ioc: IOC
    /// The link the mouse is on, if it is one. Its address is shown in full, like a browser's status bar.
    let link: URL?
    let live: Bool
    let intel: IOCIntel
    let open: @MainActor (URL) -> Void
    let close: @MainActor () -> Void

    @State private var report: IntelReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if live {
                liveSection
            } else {
                Text(tr("Live-Infos sind aus. Einschalten unter ⌘, → IOCs.", "Live info is off. Switch it on under ⌘, → IOCs."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            actions
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
        .task(id: "\(ioc.kind.rawValue):\(ioc.value)") {
            guard live else { return }
            report = await intel.report(for: ioc)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(Color(nsColor: SelectablePostText.iocColor))
                Text(ioc.kind.label + (ioc.wasDefanged ? tr(" · entschärft geschrieben", " · written defanged") : ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let link {
                if let host = link.host {
                    Text(host).font(.headline).lineLimit(1).truncationMode(.middle)
                }
                Text(link.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if link.scheme?.lowercased() == "http" {
                    Label(tr("Unverschlüsselt (http)", "Not encrypted (http)"), systemImage: "lock.open")
                        .font(.caption).foregroundStyle(.orange)
                }
                if ioc.kind != .url {
                    Text(ioc.value).font(.callout.monospaced()).textSelection(.enabled)
                }
            } else {
                Text(ioc.value)
                    .font(.callout.monospaced())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let host = ioc.host, ioc.kind != .domain {
                    Text(tr("Domain: \(host)", "Domain: \(host)")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var liveSection: some View {
        if let report {
            VStack(alignment: .leading, spacing: 6) {
                if let title = report.title {
                    Text(title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if let summary = report.summary {
                    Text(summary)
                        .font(.caption)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !report.facts.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(report.facts) { fact in
                            GridRow {
                                Text(fact.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Circle().fill(color(fact.tone)).frame(width: 7, height: 7)
                                    Text(fact.value).font(.caption).fixedSize(horizontal: false, vertical: true)
                                }
                                .help(fact.source)
                            }
                        }
                    }
                }
                if report.facts.isEmpty, report.summary == nil, report.notes.isEmpty {
                    Text(tr("Keine Angaben gefunden.", "Nothing found.")).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(report.notes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Frage nach …", "Asking…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            let services = IOCLookup.services(for: ioc)
            if !services.isEmpty {
                FlowButtons(items: services.map { service in (service.name, { close(); open(service.url) }) })
            }
            HStack(spacing: 8) {
                if let link {
                    Button(tr("Öffnen", "Open")) { close(); open(link) }
                } else if ioc.mayOpenInBrowser, let url = LinkPolicy.webURL(ioc.kind == .url ? ioc.value : "https://\(ioc.value)") {
                    Button(tr("Im Browser öffnen", "Open in Browser")) { close(); open(url) }
                }
                Button(tr("Kopieren", "Copy")) { copy(link?.absoluteString ?? ioc.value) }
                if [.url, .domain, .ipv4, .email].contains(ioc.kind) {
                    Button(tr("Entschärft kopieren", "Copy Defanged")) { copy(ioc.defanged) }
                }
            }
        }
        .controlSize(.small)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var icon: String {
        switch ioc.kind {
        case .cve: return "exclamationmark.shield"
        case .ipv4, .ipv6: return "network"
        case .domain, .url: return "globe"
        case .email: return "envelope"
        case .md5, .sha1, .sha256, .sha512: return "number"
        }
    }

    private func color(_ tone: IntelTone) -> Color {
        switch tone {
        case .neutral: return .secondary.opacity(0.5)
        case .good: return .green
        case .caution: return .orange
        case .bad: return .red
        }
    }
}

/// Lookup buttons that wrap onto a second line when there are many.
private struct FlowButtons: View {
    let items: [(String, @MainActor () -> Void)]

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 4).map { Array(items[$0..<min($0 + 4, items.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(rows[row].indices, id: \.self) { index in
                        let item = rows[row][index]
                        Button(item.0) { item.1() }
                    }
                }
            }
        }
    }
}
