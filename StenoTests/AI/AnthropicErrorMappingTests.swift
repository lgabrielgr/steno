import Foundation
import Testing

@testable import StenoKit

// D-143's table, asserted row by row. §7.4 switches on these, and M3-04 shows
// them, so a status mapped to the wrong case is a sentence in front of the user
// telling them to fix the wrong thing.

private struct StatusCase: Sendable {
    let status: Int
    let expected: AIError
}

private let statusCases: [StatusCase] = [
    StatusCase(status: 401, expected: .invalidCredential),
    StatusCase(status: 403, expected: .invalidCredential),
    StatusCase(status: 400, expected: .invalidRequest),
    StatusCase(status: 404, expected: .invalidRequest),
    StatusCase(status: 413, expected: .invalidRequest),
    StatusCase(status: 422, expected: .invalidRequest),
    StatusCase(status: 429, expected: .rateLimited(retryAfter: nil)),
    StatusCase(status: 500, expected: .providerUnavailable(status: 500)),
    StatusCase(status: 503, expected: .providerUnavailable(status: 503)),
    StatusCase(status: 529, expected: .providerUnavailable(status: 529)),
]

@Test("every mapped status", arguments: statusCases)
private func statusesMapToTheirError(testCase: StatusCase) {
    // Mutation: move 404 into the `default` arm so it becomes
    // `.providerUnavailable`. Red on the 404 row.
    #expect(AnthropicErrors.error(forStatus: testCase.status, headers: [:]) == testCase.expected)
}

@Test("a success is not an error", arguments: [200, 201, 204])
func successesMapToNothing(status: Int) {
    #expect(AnthropicErrors.error(forStatus: status, headers: [:]) == nil)
}

@Test("retry-after is carried when it is integer seconds")
func rateLimitCarriesItsInterval() {
    let error = AnthropicErrors.error(forStatus: 429, headers: ["retry-after": "30"])
    #expect(error == .rateLimited(retryAfter: .seconds(30)))
}

@Test("a retry-after this module cannot read becomes nil, not zero")
func unreadableRetryAfterIsAbsent() {
    // The HTTP-date form is ignored rather than parsed (D-143). `nil` means
    // "use the default backoff"; a zero would mean "retry immediately", which
    // is the opposite of what the header asked for.
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"]) == nil)
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "-5"]) == nil)
    #expect(AnthropicErrors.retryAfter(in: [:]) == nil)
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "0"]) == .seconds(0))
}

@Test("a cancelled request timed out; it is not an offline device")
func cancellationIsATimeout() {
    // The load-bearing row (D-145). `URLError.cancelled` sits in the same
    // domain as the genuine connectivity failures, so mapping the domain — the
    // obvious mapping — tells a user with a working connection that they are
    // offline. Mutation: return `.network` for `.cancelled`. Red.
    #expect(AnthropicErrors.error(forTransport: URLError(.cancelled)) == .timedOut)
    #expect(AnthropicErrors.error(forTransport: CancellationError()) == .timedOut)
}

@Test("genuine connectivity failures are .network")
func connectivityFailuresAreNetwork() {
    #expect(AnthropicErrors.error(forTransport: URLError(.notConnectedToInternet)) == .network)
    #expect(AnthropicErrors.error(forTransport: URLError(.cannotFindHost)) == .network)
    #expect(AnthropicErrors.error(forTransport: URLError(.secureConnectionFailed)) == .network)
}

@Test("an AIError passes through rather than being re-wrapped")
func mappedErrorsSurviveTheMapper() {
    // `send` maps transport throws, and the deadline throws an `AIError`
    // through the same path. Re-wrapping it as `.network` would report a
    // timeout as an offline device.
    #expect(AnthropicErrors.error(forTransport: AIError.timedOut) == .timedOut)
    #expect(AnthropicErrors.error(forTransport: AIError.invalidRequest) == .invalidRequest)
}
