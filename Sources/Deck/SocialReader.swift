import Foundation

/// What columns, threads, profiles and people lists read, whichever network the account is on.
/// Writing stays with each network's client, because likes, follows and posts work differently there.
protocol SocialReader: Sendable {
    func fetchPage(kind: ColumnKind, cursor: String?, limit: Int) async throws -> FeedPage
    func thread(uri: String) async throws -> ThreadContent
    func profile(actor: String) async throws -> Profile
    func profileDetail(actor: String) async throws -> ProfileDetail
    func likers(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?)
    func reposters(of uri: String, cursor: String?) async throws -> (people: [Profile], cursor: String?)
    func quotes(of uri: String, cursor: String?) async throws -> (posts: [PostView], cursor: String?)
    func followers(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?)
    func follows(of actor: String, cursor: String?) async throws -> (people: [Profile], cursor: String?)
    func suggestPeople(matching term: String) async throws -> [Profile]
}

extension SocialReader {
    func fetchPage(kind: ColumnKind, cursor: String?) async throws -> FeedPage {
        try await fetchPage(kind: kind, cursor: cursor, limit: 40)
    }
}

extension XRPCClient: SocialReader {}

/// The social networks an account can belong to.
enum SocialNetwork: String, Codable, CaseIterable, Sendable {
    case bluesky, mastodon

    var label: String {
        switch self {
        case .bluesky: return "Bluesky"
        case .mastodon: return "Mastodon"
        }
    }
}
