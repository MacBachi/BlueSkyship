import Foundation

/// Turns what people type at sign-in into what the server expects, so a short name is enough.
enum LoginIdentifier {
    static let defaultService = URL(string: "https://bsky.social")!

    /// "peter", "@peter" and a profile link all become "peter.bsky.social". An email stays as it is.
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.host?.hasSuffix("bsky.app") == true {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2, parts[0] == "profile" { text = parts[1] }
        }
        if text.hasPrefix("@") { text.removeFirst() }
        guard !text.isEmpty else { return "" }
        if text.contains("@") || text.hasPrefix("did:") { return text }
        let handle = text.lowercased()
        return handle.contains(".") ? handle : "\(handle).bsky.social"
    }

    /// Finds the server an account lives on, so nobody has to know it. Anything unclear uses the
    /// main Bluesky server, which also signs in every account it hosts.
    static func service(
        for identifier: String,
        using client: XRPCClient,
        directory: URL = URL(string: "https://plc.directory")!
    ) async -> URL {
        guard !identifier.contains("@"), !identifier.hasSuffix(".bsky.social") else { return defaultService }
        guard let did = identifier.hasPrefix("did:") ? identifier : try? await client.resolveHandle(identifier),
              did.hasPrefix("did:plc:") else { return defaultService }

        struct Document: Decodable {
            struct Service: Decodable {
                let id: String
                let serviceEndpoint: String
            }
            let service: [Service]
        }
        guard let (data, status) = try? await client.rawRequest(
            url: directory.appending(path: did), method: "GET", body: nil, headers: [:]
        ), status == 200,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              let endpoint = document.service.first(where: { $0.id.hasSuffix("#atproto_pds") })?.serviceEndpoint,
              let url = URL(string: endpoint), url.scheme == "https", let host = url.host else {
            return defaultService
        }
        // Bluesky's own servers sign in through the main address.
        return host.hasSuffix(".bsky.network") ? defaultService : url
    }
}
