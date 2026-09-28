import Foundation

/// A transport that refuses to be anything but read-only (D5, D-191).
///
/// **A trap, not a thrown error.** A mutating request against Jira is not a network
/// condition to degrade around — §5.5's degradation exists for the network, and
/// turning this into a `SourceError` would make D5 a silent fallback that a caching
/// path would paper over. D5 is permanent and this is code that must not ship.
///
/// The rule is `isAllowed`, separately testable, because a test cannot survive the
/// trap itself: asserting the predicate is how "every request is a GET" stays
/// verified without a test process that dies to prove it.
struct ReadOnlyTransport: HTTPTransport {
    let wrapped: any HTTPTransport

    init(wrapping wrapped: any HTTPTransport) {
        self.wrapped = wrapped
    }

    /// Whether `method` may leave this app for Jira.
    ///
    /// GET only. Not "anything but POST": §5.2's endpoints are all reads, and an
    /// allow-list is what keeps a future `HTTPRequest.Method` case from being
    /// permitted by omission.
    static func isAllowed(_ method: HTTPRequest.Method) -> Bool {
        method == .get
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.isAllowed(request.method) else {
            // The method, and deliberately not the URL: this message reaches a crash
            // log, and the URL carries a ticket key.
            preconditionFailure(
                "D5: the Jira connector is read-only, and a \(request.method.rawValue) was built")
        }
        return try await wrapped.send(request)
    }
}
