import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Signing in to Mastodon with OAuth. The password is typed on the server's own page in the browser;
/// the app never sees it and only keeps the token the server hands back.
enum MastodonAuth {
    static let redirectURI = "blueskyship://oauth"
    static let callbackScheme = "blueskyship"
    static let scopes = "read write follow"

    /// Accepts `mastodon.social`, `https://mastodon.social/@anna` or `@anna@mastodon.social`.
    static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("@") { text.removeFirst() }
        if !text.contains("://"), let at = text.lastIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        if !text.contains("://") { text = "https://\(text)" }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host,
              host.contains("."), url.user == nil, url.password == nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        return components.url
    }

    struct PKCE {
        let verifier: String
        let challenge: String

        init() {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            verifier = Self.base64URL(Data(bytes))
            challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    static func register(at client: MastodonClient) async throws -> Mastodon.Application {
        try await client.post("api/v1/apps", form: [
            ("client_name", "BlueSkyship"),
            ("redirect_uris", redirectURI),
            ("scopes", scopes),
            ("website", "https://github.com/MacBachi/BlueSkyship"),
        ])
    }

    static func authorizeURL(server: URL, clientID: String, pkce: PKCE, state: String) -> URL? {
        var components = URLComponents(url: server.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    /// The code from the callback, only if it answers this sign-in and no other.
    static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw XRPCError(status: 0, code: nil, message: error == "access_denied"
                ? tr("Anmeldung abgelehnt.", "Sign-in was declined.")
                : error)
        }
        guard callback.scheme == callbackScheme,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw XRPCError(status: 0, code: nil, message: tr("Die Antwort des Servers passt nicht zu dieser Anmeldung.", "The server's answer does not match this sign-in."))
        }
        return code
    }

    static func token(at client: MastodonClient, code: String, application: Mastodon.Application, pkce: PKCE) async throws -> String {
        let token: Mastodon.Token = try await client.post("oauth/token", form: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", application.client_id),
            ("client_secret", application.client_secret),
            ("redirect_uri", redirectURI),
            ("scope", scopes),
            ("code_verifier", pkce.verifier),
        ])
        return token.access_token
    }

    /// The whole sign-in: register the app, let the person sign in on the server's page, and fetch who they are.
    @MainActor
    static func signIn(server: URL, transport: URLSession = .shared) async throws -> MastodonSession {
        let anonymous = MastodonClient(server: server, transport: transport)
        let application = try await register(at: anonymous)
        let pkce = PKCE()
        let state = UUID().uuidString
        guard let url = authorizeURL(server: server, clientID: application.client_id, pkce: pkce, state: state) else {
            throw URLError(.badURL)
        }
        let callback = try await WebSignIn().start(url: url)
        let code = try code(from: callback, state: state)
        let accessToken = try await token(at: anonymous, code: code, application: application, pkce: pkce)
        return try await completeSession(
            server: server, accessToken: accessToken, application: application, transport: transport
        )
    }

    /// With a token in hand: who is this, and what does the server call itself.
    static func completeSession(
        server: URL, accessToken: String, application: Mastodon.Application, transport: URLSession = .shared
    ) async throws -> MastodonSession {
        let provisional = MastodonSession(
            server: server, domain: server.host ?? "", accountID: "", acct: "",
            accessToken: accessToken, clientID: application.client_id, clientSecret: application.client_secret
        )
        let client = MastodonClient(session: provisional, transport: transport)
        let account = try await client.verifyCredentials()
        let domain = (try? await client.instanceInfo().domain) ?? server.host ?? ""
        return MastodonSession(
            server: server, domain: domain, accountID: account.id,
            acct: MastodonHTML.fullAcct(account.acct, domain: domain),
            accessToken: accessToken, clientID: application.client_id, clientSecret: application.client_secret
        )
    }
}

/// Shows the server's sign-in page in a browser sheet and waits for it to send the person back.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: MastodonAuth.callbackScheme,
                completionHandler: Self.completion(for: continuation)
            )
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: URLError(.cannotOpenFile))
            }
        }
    }

    /// macOS calls this from a background queue, so it must not belong to the main actor.
    /// A handler written inline here would, and Swift stops the app when it runs elsewhere.
    nonisolated static func completion(
        for continuation: CheckedContinuation<URL, any Error>
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callback, error in
            if let callback {
                continuation.resume(returning: callback)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error ?? URLError(.cancelled))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}
