import Foundation

@testable import StenoKit

/// The D-143 test double: an `HTTPTransport` that answers from a script.
///
/// **Recording the request is half its job.** `make test` denies outbound IP
/// (§9.4, D-012), so this is the only way to assert what the provider *sent* —
/// that the body carries exactly D-142's five keys, that the schema arrives as
/// the value M3-03 authored, that `x-api-key` is present, and that no request
/// is made at all when the credential store is empty.
///
/// An `actor` for the reason `StubAIProvider` is one: `HTTPTransport` is
/// `Sendable`, `send` is `async`, and `Mutex` needs macOS 15 where this
/// project's floor is 14 (D2).
actor StubHTTPTransport: HTTPTransport {
    /// One scripted answer.
    enum Answer: Sendable {
        case respond(HTTPResponse)
        case fail(any Error)
    }

    private var answers: [Answer]

    /// Returned once the script runs out, so a test that under-scripts fails
    /// with a clear 500 rather than an index-out-of-range crash.
    private let fallback: Answer

    /// Held before answering, so a caller's deadline can be exercised.
    private let delay: Duration?

    /// Every request this transport was asked to send, in order.
    private(set) var received: [HTTPRequest] = []

    init(
        answers: [Answer] = [],
        fallback: Answer = .respond(HTTPResponse(status: 500)),
        delay: Duration? = nil
    ) {
        self.answers = answers
        self.fallback = fallback
        self.delay = delay
    }

    /// The common case: one successful JSON body.
    static func returning(_ json: String, status: Int = 200) -> StubHTTPTransport {
        StubHTTPTransport(answers: [
            .respond(HTTPResponse(status: status, body: Data(json.utf8)))
        ])
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Recorded **before** it can fail or hang, so a test of a failing
        // transport can still assert what reached it.
        received.append(request)

        if let delay {
            try await Task.sleep(for: delay)
        }

        let answer = answers.isEmpty ? fallback : answers.removeFirst()
        switch answer {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }
}
