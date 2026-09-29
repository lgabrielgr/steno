import Foundation

/// A transport that refuses to be anything but read-only (D5, D-191).
///
/// **Shared by both Atlassian connectors** (D-202). D5 says "Jira/Confluence access,
/// read-only, permanently" — the rule was never Jira's, and Confluence is where a
/// second copy would have drifted first: its only account-id-to-name endpoint is a
/// `POST` that reads, which is exactly the request a connector-local allow-list talks
/// itself into permitting.
///
/// **A trap, not a thrown error.** A mutating request against Atlassian is not a network
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

    /// Whether `method` may leave this app for Atlassian.
    ///
    /// GET only. Not "anything but POST": §5.2's and §5.3's endpoints are all reads, and an
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
                "D5: the Atlassian connectors are read-only, and a \(request.method.rawValue) was built"
            )
        }
        return try await wrapped.send(request)
    }
}
