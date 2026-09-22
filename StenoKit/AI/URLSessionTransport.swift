import Foundation

/// The one place in this module where Foundation's networking types appear.
///
/// **Deliberately uncovered by `make test`** (D-142). There is no branch here
/// except the `as? HTTPURLResponse` cast, and covering it means a `URLProtocol`
/// stub — a process-global registry, `@unchecked Sendable`, and ordering care
/// under parallel Swift Testing runs — standing between the suite and a file
/// whose only untested behaviour is "Foundation does what Foundation does".
/// If this file grows a branch, that is the moment to pay for the harness.
///
/// **Who closes it: M3-04**, whose task file carries `make verify-models` — a
/// hidden `models-selftest` subcommand on `make verify-keychain`'s pattern
/// (D-138) that runs this adapter against the real API. Until then the first
/// thing to execute this code is a human clicking "Test connection".
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// **No timeout is set on the session**, and that is not an omission.
    /// `URLSessionConfiguration.timeoutIntervalForRequest` is an inactivity
    /// timer that can outlast any budget while bytes trickle; D-144's budget is
    /// a wall clock, and `withDeadline` is what enforces it.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            // Not reachable over HTTPS, and `.network` rather than a crash
            // because §7.4 must be able to degrade on *any* failure.
            throw AIError.network
        }

        return HTTPResponse(
            status: http.statusCode,
            headers: Self.lowercasedHeaders(of: http),
            body: data
        )
    }

    private static func lowercasedHeaders(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (field, value) in response.allHeaderFields {
            guard let name = field as? String, let text = value as? String else { continue }
            result[name.lowercased()] = text
        }
        return result
    }
}
