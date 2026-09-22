import Foundation

/// The seam every network call in this module goes through (D-143).
///
/// **One method over plain values, rather than a `URLSession` the provider
/// holds.** `make test` denies outbound IP entirely (§9.4, D-012), so a
/// provider that reached for `URLSession` directly could not be tested at all.
/// This is the same shape `CredentialStore` uses so tests never touch the login
/// keychain, and `StubFilePanels` uses so tests never open an `NSOpenPanel`.
///
/// **Values, not `URLRequest`/`HTTPURLResponse`.** Foundation's networking
/// types are classes whose `Sendable` status is a poor thing to bet a Swift 6
/// module on, and — more usefully — error mapping over `(status, headers)` is a
/// pure function, which is what makes `AnthropicErrors` a table test rather
/// than a fixture exercise.
public protocol HTTPTransport: Sendable {
    /// **Must be cancellation-aware.** `withDeadline` enforces D-145's budget by
    /// cancelling this call and returning, but Swift cancellation is
    /// cooperative and a task group waits for its children: an implementation
    /// that ignores cancellation keeps the deadline blocked past its budget,
    /// and §7.4's fallback is what arrives late. `URLSession` honours it;
    /// anything built on blocking I/O must check `Task.isCancelled` (PR #35
    /// review).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// One outbound request, fully described.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let method: Method
    public let url: URL

    /// Lowercased field names — **enforced by the initializer, not promised by
    /// this comment.** HTTP header names are case-insensitive, and a test that
    /// asserted `X-Api-Key` against a provider that sent `x-api-key` would fail
    /// for a reason that is not a defect.
    public let headers: [String: String]

    public let body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = HTTPHeaders.normalized(headers)
        self.body = body
    }
}

/// One inbound response, reduced to what this module reads.
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int

    /// Lowercased field names, for the reason `HTTPRequest.headers` gives, and
    /// enforced here for a sharper one: `AnthropicErrors` looks `retry-after`
    /// up by that exact key, so a transport returning `Retry-After` would
    /// silently lose the server's retry interval and fall back to the default
    /// backoff — a wrong wait with nothing to notice it (PR #35 review).
    public let headers: [String: String]

    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = HTTPHeaders.normalized(headers)
        self.body = body
    }
}

/// Where the lowercasing actually happens.
///
/// A free function rather than a rule each initializer restates: the promise
/// "these keys are lowercased" was a doc comment on two types and true of
/// neither, which is the defect class this repo keeps meeting.
enum HTTPHeaders {
    /// Lowercased keys. A collision — `Retry-After` and `retry-after` in one
    /// dictionary — keeps the last value, which is what HTTP means by treating
    /// the two as the same header.
    static func normalized(_ headers: [String: String]) -> [String: String] {
        guard headers.contains(where: { $0.key != $0.key.lowercased() }) else { return headers }
        return Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { _, last in last }
    }
}
