import Foundation

/// The seam every network call in this module goes through (D-142).
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

    /// Lowercased field names. HTTP header names are case-insensitive, and a
    /// test that asserted `X-Api-Key` against a provider that sent `x-api-key`
    /// would fail for a reason that is not a defect.
    public let headers: [String: String]

    public let body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// One inbound response, reduced to what this module reads.
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int

    /// Lowercased field names, for the reason `HTTPRequest.headers` gives.
    public let headers: [String: String]

    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}
