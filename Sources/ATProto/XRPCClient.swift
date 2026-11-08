import Foundation

struct Session: Codable, Hashable, Sendable {
    let did: String
    var handle: String
    var accessJwt: String
    var refreshJwt: String
    var service: URL
}

struct XRPCError: LocalizedError, Sendable {
    let status: Int
    let code: String?
    let message: String?

    var errorDescription: String? {
        switch (status, code) {
        case (429, _): return tr("Rate-Limit erreicht. Bitte kurz warten.", "Rate limit reached. Please wait a moment.")
        case (_, "AuthenticationRequired"): return tr("Anmeldung erforderlich oder fehlgeschlagen.", "Sign-in required or failed.")
        case (_, "AuthFactorTokenRequired"): return tr("Bestätigungscode aus der E-Mail erforderlich.", "Confirmation code from the email required.")
        case (_, "SessionExpired"): return tr("Sitzung abgelaufen. Bitte neu anmelden.", "Session expired. Please sign in again.")
        default: return message ?? code ?? tr("Serverfehler (\(status))", "Server error (\(status))")
        }
    }

    var isExpiredToken: Bool {
        code == "ExpiredToken" || status == 401
    }

    /// The server's words for an app password without the direct messages permission.
    var isMissingChatPermission: Bool {
        let text = message?.lowercased() ?? ""
        return text.contains("token scope") || text.contains("token method")
    }

    /// Exactly what the server said, for places where the cause matters.
    var diagnostic: String {
        ["HTTP \(status)", code, message].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Minimal XRPC transport. Handles bearer auth and refreshes an expired session exactly once,
/// even when several columns hit the expiry at the same moment (refresh tokens are single-use).
actor XRPCClient {
    static let publicService = URL(string: "https://public.api.bsky.app")!

    let service: URL
    private(set) var session: Session?
    private let transport: URLSession
    private let onSessionChange: @Sendable (Session) -> Void
    private var refreshTask: Task<Session, any Error>?
    private var accountServer: URL?

    init(
        service: URL,
        session: Session? = nil,
        transport: URLSession = .shared,
        onSessionChange: @escaping @Sendable (Session) -> Void = { _ in }
    ) {
        self.service = service
        self.session = session
        self.transport = transport
        self.onSessionChange = onSessionChange
    }

    func get<Response: Decodable & Sendable>(
        _ nsid: String,
        query: [(String, String?)] = [],
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await send(method: "GET", nsid: nsid, query: query, body: nil)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ nsid: String,
        body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await send(method: "POST", nsid: nsid, query: [], body: try Self.encode(body))
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// For procedures whose response body we do not care about.
    func postIgnoringResponse<Body: Encodable & Sendable>(_ nsid: String, body: Body) async throws {
        _ = try await send(method: "POST", nsid: nsid, query: [], body: try Self.encode(body))
    }

    /// Sends raw bytes, as `com.atproto.repo.uploadBlob` expects, and decodes the response.
    func upload<Response: Decodable & Sendable>(
        _ nsid: String,
        data: Data,
        contentType: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let response = try await send(method: "POST", nsid: nsid, query: [], body: data, contentType: contentType)
        return try JSONDecoder().decode(Response.self, from: response)
    }

    /// For the video service, which is not this client's server and uses its own short-lived token.
    func rawRequest(url: URL, method: String, body: Data?, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Exchanges credentials for a session. The password is used for this call only and is never stored.
    func login(identifier: String, password: String, authFactorToken: String?) async throws -> Session {
        struct Body: Encodable, Sendable {
            let identifier: String
            let password: String
            let authFactorToken: String?
        }
        struct Response: Decodable, Sendable {
            let did: String
            let handle: String
            let accessJwt: String
            let refreshJwt: String
        }
        let body = Body(identifier: identifier, password: password, authFactorToken: authFactorToken)
        let (data, status) = try await perform(
            method: "POST", nsid: "com.atproto.server.createSession", query: [],
            body: try Self.encode(body), bearer: nil
        )
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let newSession = Session(
            did: response.did, handle: response.handle,
            accessJwt: response.accessJwt, refreshJwt: response.refreshJwt, service: service
        )
        session = newSession
        onSessionChange(newSession)
        return newSession
    }

    // MARK: - Internals

    private func send(
        method: String, nsid: String, query: [(String, String?)], body: Data?,
        contentType: String = "application/json"
    ) async throws -> Data {
        let tokenUsed = session?.accessJwt
        let (data, status) = try await perform(
            method: method, nsid: nsid, query: query, body: body, bearer: tokenUsed, contentType: contentType
        )
        if (200..<300).contains(status) { return data }

        let failure = Self.error(status: status, data: data)
        guard session != nil, failure.isExpiredToken else { throw failure }

        // Another request may have refreshed while this one was in flight.
        let current = session?.accessJwt
        let token: String?
        if current != tokenUsed {
            token = current
        } else {
            token = try await refreshedSession().accessJwt
        }
        let (retryData, retryStatus) = try await perform(
            method: method, nsid: nsid, query: query, body: body, bearer: token, contentType: contentType
        )
        guard (200..<300).contains(retryStatus) else { throw Self.error(status: retryStatus, data: retryData) }
        return retryData
    }

    private func refreshedSession() async throws -> Session {
        if let refreshTask { return try await refreshTask.value }
        guard let current = session else {
            throw XRPCError(status: 401, code: "AuthenticationRequired", message: nil)
        }
        let task = Task<Session, any Error> { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: Session) async throws -> Session {
        struct Response: Decodable {
            let did: String
            let handle: String
            let accessJwt: String
            let refreshJwt: String
        }
        let (data, status) = try await perform(
            method: "POST", nsid: "com.atproto.server.refreshSession", query: [],
            body: nil, bearer: current.refreshJwt
        )
        guard (200..<300).contains(status) else {
            throw XRPCError(status: status, code: "SessionExpired", message: nil)
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let updated = Session(
            did: response.did, handle: response.handle,
            accessJwt: response.accessJwt, refreshJwt: response.refreshJwt, service: current.service
        )
        session = updated
        onSessionChange(updated)
        return updated
    }

    /// Chat goes to the server the account lives on, as in Bluesky's own app, which may not be the
    /// address used to sign in. If that server cannot be found, the sign-in address remains the best guess.
    private func chatServer() async -> URL {
        if let accountServer { return accountServer }
        struct RepoInfo: Decodable {
            struct DidDoc: Decodable {
                struct Service: Decodable {
                    let id: String
                    let serviceEndpoint: String
                }
                let service: [Service]
            }
            let didDoc: DidDoc
        }
        guard let did = session?.did,
              let (data, status) = try? await perform(
                  method: "GET", nsid: "com.atproto.repo.describeRepo", query: [("repo", did)], body: nil, bearer: nil
              ), status == 200,
              let info = try? JSONDecoder().decode(RepoInfo.self, from: data),
              let endpoint = info.didDoc.service.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let url = URL(string: endpoint), url.scheme == "https", url.host != nil else { return service }
        accountServer = url
        return url
    }

    private func perform(
        method: String, nsid: String, query: [(String, String?)], body: Data?, bearer: String?,
        contentType: String = "application/json"
    ) async throws -> (Data, Int) {
        let target = nsid.hasPrefix("chat.bsky.") ? await chatServer() : service
        var request = URLRequest(url: try Self.url(service: target, nsid: nsid, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        // Chat is a separate Bluesky service that the account's server forwards to.
        if nsid.hasPrefix("chat.bsky.") {
            request.setValue("did:web:api.bsky.chat#bsky_chat", forHTTPHeaderField: "atproto-proxy")
        }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func url(service: URL, nsid: String, query: [(String, String?)]) throws -> URL {
        var components = URLComponents(
            url: service.appending(path: "xrpc/\(nsid)"), resolvingAgainstBaseURL: false
        )
        let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty {
            components?.queryItems = items
            // URLComponents leaves "+" alone, but servers read it as a space.
            let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            components?.percentEncodedQuery = encoded
        }
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    private static func encode<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    private static func error(status: Int, data: Data) -> XRPCError {
        struct Payload: Decodable {
            let error: String?
            let message: String?
        }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        return XRPCError(status: status, code: payload?.error, message: payload?.message)
    }
}
