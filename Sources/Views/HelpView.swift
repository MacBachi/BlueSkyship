import AppKit
import SwiftUI

struct HelpView: View {
    static let windowID = "help"

    private enum Page: Hashable {
        case tldr, tour
        case topic(String)
    }

    @State private var page: Page? = .tldr

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("TL;DR", systemImage: "bolt").tag(Page.tldr)
                    Label(tr("Geführte Tour", "Guided tour"), systemImage: "map").tag(Page.tour)
                }
                Section(tr("Themen", "Topics")) {
                    ForEach(HelpContent.topics) { topic in
                        Label(topic.title, systemImage: topic.icon).tag(Page.topic(topic.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch page ?? .tldr {
            case .tldr:
                TLDRPage(startTour: { page = .tour })
            case .tour:
                TourPage()
            case .topic(let id):
                if let topic = HelpContent.topics.first(where: { $0.id == id }) {
                    TopicPage(topic: topic)
                }
            }
        }
        .navigationTitle(tr("BlueSkyship-Hilfe", "BlueSkyship Help"))
    }
}

/// Renders the light Markdown of the help texts.
private struct HelpText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BulletList: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").foregroundStyle(.secondary)
                    HelpText(item)
                }
            }
        }
    }
}

private struct TLDRPage: View {
    let startTour: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "TL;DR").font(.largeTitle.weight(.bold))
                BulletList(items: HelpContent.tldr)
                Button(tr("Geführte Tour starten", "Start Guided Tour"), action: startTour)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TopicPage: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(topic.title, systemImage: topic.icon)
                    .font(.title.weight(.bold))
                BulletList(items: topic.bullets)
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TourPage: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openWindow) private var openWindow
    @State private var index = 0

    private var steps: [TourStep] { HelpContent.tour }

    var body: some View {
        let step = steps[min(index, steps.count - 1)]
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Schritt \(index + 1) von \(steps.count)", "Step \(index + 1) of \(steps.count)"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            ProgressView(value: Double(index + 1), total: Double(steps.count))
                .accessibilityHidden(true)
            Label(step.title, systemImage: step.icon)
                .font(.title.weight(.bold))
            HelpText(step.text)
                .font(.title3)
            if let demo = step.demo {
                demoButton(demo)
            }
            Spacer()
            HStack {
                Button(tr("Zurück", "Back")) { index -= 1 }
                    .disabled(index == 0)
                Spacer()
                if index < steps.count - 1 {
                    Button(tr("Weiter", "Next")) { index += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Von vorn", "Start Over")) { index = 0 }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func demoButton(_ demo: TourStep.Demo) -> some View {
        switch demo {
        case .addColumn:
            Button(tr("Spalte hinzufügen zeigen", "Show Add Column")) {
                showMainWindow()
                deck.isAddingColumn = true
            }
        case .favorites:
            Button(tr("Favoriten zeigen", "Show Favorites")) {
                showMainWindow()
                deck.isShowingFavorites = true
            }
        case .compose:
            Button(tr("Composer zeigen", "Show Composer")) {
                showMainWindow()
                deck.startCompose()
            }
        case .settings:
            SettingsLink {
                Text(tr("Einstellungen öffnen", "Open Settings"))
            }
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
    }
}
