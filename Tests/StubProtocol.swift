import Foundation
@testable import BlueSkyship

/// Serves canned responses by host, so tests running in parallel do not see each other's traffic.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// URLSession moves `httpBody` into a stream before the protocol sees it.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { Self.handlers[host] }
        let (status, data) = handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class StubResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [(Int, Data)]

    init(_ responses: [(Int, Data)]) {
        remaining = responses
    }

    func next() -> (Int, Data) {
        lock.withLock { remaining.isEmpty ? (500, Data()) : remaining.removeFirst() }
    }
}

final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class SavedSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Session] = []
    var values: [Session] { lock.withLock { stored } }
    func append(_ session: Session) { lock.withLock { stored.append(session) } }
}

final class CapturedBody: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? { lock.withLock { stored } }
    func set(_ data: Data?) { lock.withLock { stored = data } }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ call: String) { lock.withLock { stored.append(call) } }
}

final class BodyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data?] = []
    var values: [Data?] { lock.withLock { stored } }
    /// Returns the position, so a stub can answer each call differently.
    @discardableResult func append(_ data: Data?) -> Int {
        lock.withLock {
            stored.append(data)
            return stored.count - 1
        }
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, Data?)] = []
    var names: [String] { lock.withLock { entries.map(\.0) } }
    var bodies: [Data?] { lock.withLock { entries.map(\.1) } }
    func append(_ name: String, _ body: Data?) { lock.withLock { entries.append((name, body)) } }
}

extension XRPCClient {
    /// For checking headers with a stub whose body is not a count.
    func unreadNotificationCountIgnoringBody() async throws -> Bool {
        struct Empty: Decodable, Sendable {}
        let _: Empty = try await get("app.bsky.notification.getUnreadCount")
        return true
    }
}
