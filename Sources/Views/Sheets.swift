import SwiftUI

struct LoginSheet: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var identifier = ""
    @State private var password = ""
    @State private var authFactorToken = ""
    @State private var serviceText = LoginIdentifier.defaultService.absoluteString
    @State private var showsServer = false
    @State private var needsAuthFactor = false
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var network: SocialNetwork = .bluesky
    @State private var mastodonServer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(network == .bluesky
                ? tr("Bei Bluesky anmelden", "Sign in to Bluesky")
                : tr("Bei Mastodon anmelden", "Sign in to Mastodon"))
                .font(.title2.weight(.semibold))
            Picker(tr("Netzwerk", "Network"), selection: $network) {
                ForEach(SocialNetwork.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: network) { _, _ in errorMessage = nil }
            if network == .mastodon {
                mastodonForm
            } else {
                blueskyForm
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if !RuntimeEnvironment.isUnitTestHost, deck.claimAutomaticAppPasswordsOpen() {
                openURL(DeckStore.appPasswordsURL)
            }
        }
    }

    private var mastodonServerURL: URL? { MastodonAuth.serverURL(from: mastodonServer) }

    @ViewBuilder
    private var mastodonForm: some View {
        Form {
            TextField(tr("Server", "Server"), text: $mastodonServer, prompt: Text("mastodon.social"))
                .onSubmit(loginMastodon)
        }
        Text(tr("Die Anmeldung öffnet die Seite deines Servers im Browser. Dort gibst du dein Passwort ein und erlaubst der App den Zugriff. Die App bekommt dein Passwort nie zu sehen und speichert nur den Zugangsschlüssel im Schlüsselbund.", "Sign-in opens your server's page in the browser. Enter your password there and allow the app access. The app never sees your password and only keeps the access key in the Keychain."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(tr("Im Browser anmelden", "Sign In in Browser"), action: loginMastodon)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || mastodonServerURL == nil)
        }
    }

    private func loginMastodon() {
        guard let server = mastodonServerURL, !isWorking else {
            errorMessage = tr("Bitte den Namen deines Servers eingeben, etwa mastodon.social.", "Please enter your server's name, such as mastodon.social.")
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let isFirst = deck.accounts.firstMastodon == nil
                let session = try await MastodonAuth.signIn(server: server)
                let account = try await deck.accounts.addMastodon(session)
                deck.didLogin(account, isFirstAccount: isFirst)
                dismiss()
            } catch is CancellationError {
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var blueskyForm: some View {
            Form {
                TextField(tr("Name oder E-Mail", "Name or email"), text: $identifier, prompt: Text(tr("Dein Bluesky-Name", "Your Bluesky name")))
                if showsNormalizedName {
                    Text(tr("Anmeldung als @\(normalizedIdentifier)", "Signing in as @\(normalizedIdentifier)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField(tr("App-Passwort", "App password"), text: $password, prompt: Text("xxxx-xxxx-xxxx-xxxx"))
                if needsAuthFactor {
                    TextField(tr("Code aus der E-Mail", "Code from the email"), text: $authFactorToken)
                }
                if showsServer {
                    TextField("Server", text: $serviceText)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Bitte ein App-Passwort verwenden, nicht dein Hauptpasswort. Die App speichert nur die Sitzungstoken im Schlüsselbund, nie das Passwort.", "Please use an app password, not your main password. The app only stores session tokens in the Keychain, never the password."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: DeckStore.appPasswordsURL) {
                    Label(tr("App-Passwort bei Bluesky erstellen", "Create App Password on Bluesky"), systemImage: "arrow.up.right.square")
                        .font(.callout)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if !showsServer {
                    Button(tr("Eigener Server …", "Own Server…")) { showsServer = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(tr("Nur nötig, wenn die automatische Erkennung deinen Server nicht findet.", "Only needed if automatic detection does not find your server."))
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Anmelden", "Sign In"), action: login)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || identifier.isEmpty || password.isEmpty)
            }
    }

    private var normalizedIdentifier: String { LoginIdentifier.normalized(identifier) }

    /// Shows what a short name becomes, once there is something to show.
    private var showsNormalizedName: Bool {
        let typed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return !typed.isEmpty && !typed.contains("@") && normalizedIdentifier != typed.lowercased()
    }

    private func login() {
        let typedServer = serviceText.trimmingCharacters(in: .whitespaces)
        guard let chosenServer = URL(string: typedServer), chosenServer.scheme == "https", chosenServer.host != nil else {
            errorMessage = tr("Der Server muss eine https-Adresse sein.", "The server must be an https address.")
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            let isFirstAccount = deck.accounts.firstBluesky == nil
            let name = normalizedIdentifier
            // A server someone typed in wins. Otherwise the app finds it by itself.
            let service = chosenServer == LoginIdentifier.defaultService
                ? await LoginIdentifier.service(for: name, using: deck.accounts.publicClient)
                : chosenServer
            do {
                let account = try await deck.accounts.login(
                    identifier: name,
                    password: password,
                    authFactorToken: authFactorToken.isEmpty ? nil : authFactorToken,
                    service: service
                )
                deck.didLogin(account, isFirstAccount: isFirstAccount)
                password = ""
                dismiss()
            } catch let error as XRPCError where error.code == "AuthFactorTokenRequired" {
                needsAuthFactor = true
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct AddColumnSheet: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.dismiss) private var dismiss

    private enum Choice: String, CaseIterable, Identifiable {
        case home, notifications, mentions, ownPosts, likes, bookmarks, messages, search, author, saved, link
        case localTimeline, federatedTimeline, mastodonList
        var id: String { rawValue }
        var requiresAccount: Bool { ![.author, .link].contains(self) }

        static func available(on network: SocialNetwork) -> [Choice] {
            switch network {
            case .bluesky: return [.home, .notifications, .mentions, .ownPosts, .likes, .bookmarks, .messages, .search, .author, .saved, .link]
            case .mastodon: return [.home, .notifications, .mentions, .localTimeline, .federatedTimeline, .mastodonList, .ownPosts, .likes, .bookmarks, .messages, .search, .author]
            }
        }
        var label: String {
            switch self {
            case .home: return "Home"
            case .notifications: return tr("Mitteilungen", "Notifications")
            case .mentions: return tr("Erwähnungen", "Mentions")
            case .ownPosts: return tr("Meine Posts", "My Posts")
            case .likes: return tr("Meine Likes", "My Likes")
            case .bookmarks: return tr("Lesezeichen", "Bookmarks")
            case .messages: return tr("Direktnachrichten", "Direct Messages")
            case .search: return tr("Suche", "Search")
            case .author: return tr("Profil", "Profile")
            case .saved: return tr("Gespeicherter Feed", "Saved feed")
            case .link: return tr("Feed oder Liste per Link", "Feed or list by link")
            case .localTimeline: return tr("Lokal (dein Server)", "Local (your server)")
            case .federatedTimeline: return tr("Föderiert (alle bekannten Server)", "Federated (all known servers)")
            case .mastodonList: return tr("Liste", "List")
            }
        }
    }

    @State private var choice: Choice = .author
    @State private var accountDID: String?
    @State private var input = ""
    @State private var savedFeeds: [SavedFeed] = []
    @State private var selectedFeed: SavedFeed?
    @State private var mastodonLists: [Mastodon.List] = []
    @State private var selectedList: Mastodon.List?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var accounts: [Account] { deck.accounts.accounts }
    private var network: SocialNetwork { deck.accounts.network(of: accountDID) ?? .bluesky }
    private var choices: [Choice] { Choice.available(on: network) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Spalte hinzufügen", "Add Column")).font(.title2.weight(.semibold))
            Form {
                Picker(tr("Konto", "Account"), selection: $accountDID) {
                    if choice == .search, !accounts.isEmpty {
                        Text(deck.hasBothNetworks
                            ? tr("Alle Netzwerke (gemischt)", "All networks (mixed)")
                            : tr("Automatisch", "Automatic")).tag(String?.none)
                    } else if !choice.requiresAccount {
                        Text(tr("Ohne Konto (öffentlich)", "No account (public)")).tag(String?.none)
                    }
                    ForEach(accounts) { Text("@\($0.handle) · \($0.resolvedNetwork.label)").tag(String?.some($0.did)) }
                }
                Picker(tr("Typ", "Type"), selection: $choice) {
                    ForEach(choices) { Text($0.label).tag($0) }
                }
                inputField
            }
            if choice == .author {
                PersonSuggestions(term: input, accountDID: accountDID) { input = $0.handle }
            }
            if choice.requiresAccount, accounts.isEmpty {
                Text(tr("Dieser Spaltentyp braucht ein Konto.", "This column type needs an account."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if choice.requiresAccount, accounts.isEmpty {
                    Button(tr("Anmelden", "Sign In")) {
                        dismiss()
                        deck.isLoggingIn = true
                    }
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(tr("Abbrechen", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Hinzufügen", "Add"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !isComplete)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            accountDID = accounts.first?.did
            if !accounts.isEmpty { choice = .home }
        }
        .onChange(of: choice) { _, new in
            errorMessage = nil
            if new == .search, deck.hasBothNetworks {
                // A search finds the most when it looks at both networks.
                accountDID = nil
            } else if new.requiresAccount, accountDID == nil {
                accountDID = accounts.first?.did
            }
        }
        .onChange(of: accountDID) { _, _ in
            // Each network offers different columns.
            if !choices.contains(choice) { choice = .home }
        }
        .task(id: "\(choice.rawValue)#\(accountDID ?? "")") {
            if choice == .mastodonList, let client = deck.accounts.mastodon(for: accountDID) {
                do {
                    mastodonLists = try await client.lists()
                    selectedList = mastodonLists.first
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
                return
            }
            guard choice == .saved, let client = deck.accounts.client(for: accountDID) else { return }
            do {
                savedFeeds = try await client.savedFeeds()
                selectedFeed = savedFeeds.first
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var inputField: some View {
        switch choice {
        case .home, .notifications, .mentions, .ownPosts, .likes, .bookmarks, .messages, .localTimeline, .federatedTimeline:
            EmptyView()
        case .search:
            TextField(tr("Suchbegriff", "Search term"), text: $input, prompt: Text(tr("#swiftui oder Stichwort", "#swiftui or keyword")))
        case .author:
            TextField("Handle", text: $input, prompt: Text(network == .mastodon ? "name@mastodon.social" : "name.bsky.social"))
        case .mastodonList:
            Picker(tr("Liste", "List"), selection: $selectedList) {
                if mastodonLists.isEmpty { Text(tr("Keine gefunden", "None found")).tag(Mastodon.List?.none) }
                ForEach(mastodonLists) { Text($0.title).tag(Mastodon.List?.some($0)) }
            }
        case .link:
            TextField("Link", text: $input, prompt: Text("https://bsky.app/profile/…/feed/…"))
        case .saved:
            Picker("Feed", selection: $selectedFeed) {
                if savedFeeds.isEmpty { Text(tr("Keine gefunden", "None found")).tag(SavedFeed?.none) }
                ForEach(savedFeeds) { Text($0.name).tag(SavedFeed?.some($0)) }
            }
        }
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isComplete: Bool {
        if choice.requiresAccount, accountDID == nil, !(choice == .search && !accounts.isEmpty) { return false }
        switch choice {
        case .home, .notifications, .mentions, .ownPosts, .likes, .bookmarks, .messages, .localTimeline, .federatedTimeline: return true
        case .search, .author, .link: return !trimmedInput.isEmpty
        case .saved: return selectedFeed != nil
        case .mastodonList: return selectedList != nil
        }
    }

    private func add() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let kind = try await resolveKind()
                deck.openColumn(kind: kind, accountDID: accountDID)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveKind() async throws -> ColumnKind {
        switch choice {
        case .home: return .home
        case .notifications: return .notifications
        case .mentions: return .mentions
        case .ownPosts:
            guard let accountDID else { throw URLError(.userAuthenticationRequired) }
            return .ownPosts(actor: accountDID)
        case .likes:
            guard let accountDID else { throw URLError(.userAuthenticationRequired) }
            return .likes(actor: accountDID)
        case .bookmarks: return .bookmarks
        case .messages: return .messages
        case .search: return .search(query: trimmedInput)
        case .localTimeline: return .localTimeline
        case .federatedTimeline: return .federatedTimeline
        case .mastodonList:
            guard let selectedList else { throw URLError(.badURL) }
            return .list(uri: selectedList.id, name: selectedList.title)
        case .author where network == .mastodon:
            var handle = trimmedInput.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            // A local name gets the server, so the column also works from other accounts.
            if !handle.contains("@"), let own = accountDID?.split(separator: "@").last { handle += "@\(own)" }
            let profile = try await deck.reader(for: accountDID).profile(actor: handle)
            return .author(actor: profile.handle)
        case .author:
            let handle = trimmedInput.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            // Validates the handle now instead of showing a broken column.
            let profile = try await (deck.accounts.client(for: accountDID) ?? deck.accounts.publicClient).profile(actor: handle)
            return .author(actor: profile.handle)
        case .saved:
            guard let selectedFeed else { throw URLError(.badURL) }
            return .feed(uri: selectedFeed.uri, name: selectedFeed.name)
        case .link:
            guard var link = FeedLink.parse(trimmedInput) else {
                throw XRPCError(status: 0, code: nil, message: tr("Das ist kein Link auf einen Bluesky-Feed oder eine Liste.", "That is not a link to a Bluesky feed or list."))
            }
            let client = deck.accounts.client(for: accountDID) ?? deck.accounts.publicClient
            if let authority = link.authority, !authority.hasPrefix("did:") {
                link = link.replacingAuthority(with: try await client.resolveHandle(authority))
            }
            switch link {
            case .feed(let uri): return .feed(uri: uri, name: try await client.feedName(uri: uri))
            case .list(let uri): return .list(uri: uri, name: try await client.listName(uri: uri))
            }
        }
    }
}
