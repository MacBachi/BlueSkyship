import Foundation
import Observation
import Security

/// Session tokens live in the Keychain, one item per account. Passwords are never stored.
enum SessionKeychain {
    private static let service = "dev.blueskyship.session"

    static func save(_ session: Session) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query = baseQuery(did: session.did)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(did: String) -> Session? {
        var query = baseQuery(did: did)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func delete(did: String) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        SecItemDelete(baseQuery(did: did) as CFDictionary)
    }

    private static func baseQuery(did: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: did,
        ]
    }
}

/// The Mastodon token, one item per account, apart from Bluesky's sessions.
enum MastodonKeychain {
    private static let service = "dev.blueskyship.mastodon"

    static func save(_ session: MastodonSession) {
        guard !RuntimeEnvironment.isUnitTestHost, let data = try? JSONEncoder().encode(session) else { return }
        let query = baseQuery(acct: session.acct)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(acct: String) -> MastodonSession? {
        var query = baseQuery(acct: acct)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MastodonSession.self, from: data)
    }

    static func delete(acct: String) {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        SecItemDelete(baseQuery(acct: acct) as CFDictionary)
    }

    private static func baseQuery(acct: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
    }
}

struct Account: Codable, Identifiable, Hashable, Sendable {
    /// A DID for Bluesky, the full address `name@server` for Mastodon.
    let did: String
    var handle: String
    var displayName: String?
    var avatar: String?
    /// Missing in accounts saved before Mastodon support, which are all Bluesky.
    var network: SocialNetwork?
    var id: String { did }
    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }
    var resolvedNetwork: SocialNetwork { network ?? .bluesky }
    var isMastodon: Bool { resolvedNetwork == .mastodon }
}

@MainActor
@Observable
final class AccountStore {
    private static let defaultsKey = "accounts.v1"

    private(set) var accounts: [Account] = []
    private var clients: [String: XRPCClient] = [:]
    private var mastodonClients: [String: MastodonClient] = [:]

    /// Reads public data without an account.
    let publicClient = XRPCClient(service: XRPCClient.publicService)

    init() {
        guard !RuntimeEnvironment.isUnitTestHost,
              let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([Account].self, from: data) else { return }
        for account in stored {
            if account.isMastodon {
                guard let session = MastodonKeychain.load(acct: account.did) else { continue }
                accounts.append(account)
                mastodonClients[account.did] = MastodonClient(session: session)
            } else {
                guard let session = SessionKeychain.load(did: account.did) else { continue }
                accounts.append(account)
                clients[account.did] = Self.makeClient(service: session.service, session: session)
            }
        }
    }

    #if DEBUG
    /// Signs in a simulated account for automated tests. Stores nothing.
    func installForTesting(_ account: Account, client: XRPCClient) {
        accounts.append(account)
        clients[account.did] = client
    }

    func installForTesting(_ account: Account, mastodon client: MastodonClient) {
        accounts.append(account)
        mastodonClients[account.did] = client
    }
    #endif

    /// The Bluesky client of an account. Nil for Mastodon accounts, which have their own.
    func client(for did: String?) -> XRPCClient? {
        guard let did else { return nil }
        return clients[did]
    }

    func mastodon(for did: String?) -> MastodonClient? {
        guard let did else { return nil }
        return mastodonClients[did]
    }

    /// Whatever reads for this account, on either network.
    func reader(for did: String?) -> (any SocialReader)? {
        client(for: did) ?? mastodon(for: did)
    }

    func network(of did: String?) -> SocialNetwork? {
        accounts.first { $0.did == did }?.resolvedNetwork
    }

    var firstBluesky: Account? { accounts.first { !$0.isMastodon } }
    var firstMastodon: Account? { accounts.first { $0.isMastodon } }

    /// An account that can read this Mastodon person: preferably one on the same server.
    func mastodonAccount(forActor actor: String) -> Account? {
        let server = actor.split(separator: "@").last.map(String.init)?.lowercased()
        return accounts.first { $0.isMastodon && $0.did.lowercased().hasSuffix("@\(server ?? "")") } ?? firstMastodon
    }

    func addMastodon(_ session: MastodonSession) async throws -> Account {
        let client = MastodonClient(session: session)
        let me = try await client.verifyCredentials()
        let account = Account(
            did: session.acct, handle: session.acct,
            displayName: me.display_name?.isEmpty == false ? me.display_name : me.username,
            avatar: me.avatar_static ?? me.avatar, network: .mastodon
        )
        MastodonKeychain.save(session)
        accounts.removeAll { $0.did == account.did }
        accounts.append(account)
        mastodonClients[account.did] = client
        persist()
        return account
    }

    func login(identifier: String, password: String, authFactorToken: String?, service: URL) async throws -> Account {
        let client = Self.makeClient(service: service, session: nil)
        let session = try await client.login(
            identifier: identifier, password: password, authFactorToken: authFactorToken
        )
        let profile = try? await client.profile(actor: session.did)
        let account = Account(
            did: session.did, handle: session.handle,
            displayName: profile?.displayName, avatar: profile?.avatar, network: .bluesky
        )
        accounts.removeAll { $0.did == account.did }
        accounts.append(account)
        clients[account.did] = client
        persist()
        return account
    }

    /// Keeps name and picture current, and fills them in where only the handle is known.
    func refreshDetails() async {
        for account in accounts {
            guard let client = reader(for: account.did),
                  let profile = try? await client.profile(actor: account.did),
                  let index = accounts.firstIndex(where: { $0.did == account.did }) else { continue }
            accounts[index].handle = profile.handle
            accounts[index].displayName = profile.displayName
            accounts[index].avatar = profile.avatar
        }
        persist()
    }

    func logout(did: String) async {
        if let client = clients[did] {
            // Best effort: the local sign-out must succeed even when offline.
            _ = try? await client.revokeSession()
        }
        if let mastodon = mastodonClients[did] {
            await mastodon.revokeToken()
            MastodonKeychain.delete(acct: did)
        }
        SessionKeychain.delete(did: did)
        clients[did] = nil
        mastodonClients[did] = nil
        accounts.removeAll { $0.did == did }
        persist()
    }

    /// Tests run in the same container as the real app, and must never replace its list of accounts.
    private func persist() {
        guard !RuntimeEnvironment.isUnitTestHost else { return }
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func makeClient(service: URL, session: Session?) -> XRPCClient {
        XRPCClient(service: service, session: session, onSessionChange: { SessionKeychain.save($0) })
    }
}

extension XRPCClient {
    /// `deleteSession` authenticates with the refresh token rather than the access token.
    func revokeSession() async throws {
        guard let session else { return }
        var request = URLRequest(url: try Self.url(service: service, nsid: "com.atproto.server.deleteSession", query: []))
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.refreshJwt)", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: request)
    }
}
