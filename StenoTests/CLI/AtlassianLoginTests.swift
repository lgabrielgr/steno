import Foundation
import Testing

@testable import StenoKit

/// D-197: the credential-planting harness, driven by scripted input.

/// A reader that answers from a list, so the whole sequence runs without a terminal.
private final class ScriptedInput {
    private var lines: [String]
    private let secret: String?
    private(set) var secretPrompts: [String] = []

    init(lines: [String], secret: String? = "atlassian-token-value") {
        self.lines = lines
        self.secret = secret
    }

    func readLine() -> String? {
        lines.isEmpty ? nil : lines.removeFirst()
    }

    func readSecret(_ prompt: String) -> String? {
        secretPrompts.append(prompt)
        return secret
    }
}

private func run(
    _ input: ScriptedInput, store: InMemoryAtlassianStore
) -> (code: Int32, output: [String]) {
    var printed: [String] = []
    let code = AtlassianLogin.run(
        store: store, out: { printed.append($0) }, readLine: input.readLine,
        readSecret: input.readSecret)
    return (code, printed)
}

@Test("the happy path stores one credential for both Atlassian APIs")
func theHappyPathStores() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["acme.atlassian.net", "leo@example.com", "2027-03-01"])

    let result = run(input, store: store)

    #expect(result.code == 0)
    let stored = try #require(try store.credential())
    #expect(stored.site == "acme.atlassian.net")
    #expect(stored.email == "leo@example.com")
    #expect(stored.apiToken == "atlassian-token-value")
    #expect(stored.expiresAt == AtlassianLogin.fullDate("2027-03-01"))
}

@Test("§8: the token is read without echo and never printed back")
func thetokenIsNeverPrinted() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["acme.atlassian.net", "leo@example.com", ""])

    let result = run(input, store: store)

    #expect(result.code == 0)
    // It was asked for through the secret reader, not the plain one — the plain reader's
    // lines are consumed in order, so a mix-up here would also break the date above.
    #expect(input.secretPrompts.count == 1)
    #expect(input.secretPrompts.first?.contains("not echoed") == true)
    // And nothing printed carries it. This is the assertion that would fail if a
    // "stored: …" confirmation ever grew helpful.
    #expect(result.output.contains { $0.contains("atlassian-token-value") } == false)
}

@Test("D19: a site that is not Atlassian Cloud is refused before anything is stored")
func anonCloudSiteIsRefused() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["evil.com", "leo@example.com", ""])

    let result = run(input, store: store)

    #expect(result.code == 1)
    // Refused *here*, rather than discovered when the token has already been sent
    // somewhere (D-190): nothing reaches the store at all.
    #expect(try store.credential() == nil)
    #expect(result.output.contains { $0.contains("not an *.atlassian.net host") })
}

@Test("a blank expiry date is allowed, and means no warning is possible")
func ablankExpiryIsAllowed() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["acme.atlassian.net", "leo@example.com", ""])

    #expect(run(input, store: store).code == 0)
    // §5.2 asks the user to record it; a user who has not must still be able to fetch,
    // which is also why the 401 path never depends on this value (D-192).
    #expect(try store.credential()?.expiresAt == nil)
}

@Test("an expiry date that is not a date is refused rather than stored as nil")
func anUnparseableExpiryIsRefused() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["acme.atlassian.net", "leo@example.com", "next March"])

    let result = run(input, store: store)

    // Silently storing `nil` would leave the user believing they had recorded an expiry
    // and the app unable to warn them — the exact failure §5.2 calls scheduled.
    #expect(result.code == 1)
    #expect(try store.credential() == nil)
    #expect(result.output.contains { $0.contains("not a YYYY-MM-DD date") })
}

@Test("an empty token is refused")
func anEmptyTokenIsRefused() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(
        lines: ["acme.atlassian.net", "leo@example.com", ""], secret: "")

    #expect(run(input, store: store).code == 1)
    #expect(try store.credential() == nil)
}

@Test("a missing email is refused")
func amissingEmailIsRefused() throws {
    let store = InMemoryAtlassianStore()
    let input = ScriptedInput(lines: ["acme.atlassian.net", "   "])

    #expect(run(input, store: store).code == 1)
    #expect(try store.credential() == nil)
}

@Test("a store that refuses the write is reported, not swallowed")
func astoreFailureIsReported() throws {
    struct Refused: Error {}
    // **This test used to accept either exit code**, which made it unfalsifiable: a
    // regression that printed "stored" after a failed write would have passed it. Raised by
    // Copilot in review of PR #43. Now the double throws from `store`, and both the code and
    // the message are asserted.
    let store = InMemoryAtlassianStore(writeError: Refused())
    let input = ScriptedInput(lines: ["acme.atlassian.net", "leo@example.com", ""])

    let result = run(input, store: store)

    #expect(result.code == 1)
    #expect(result.output.contains { $0.contains("FAIL") })
    #expect(result.output.contains { $0.contains("stored leo@example.com") } == false)
    #expect(try store.credential() == nil)
}

@Test("the expiry date is parsed in UTC, not in the machine's region")
func theExpiryIsParsedInUTC() throws {
    // A `DateFormatter` with a format string would need a POSIX locale set by hand, and
    // forgetting that is how a date parser starts depending on where the laptop is.
    let parsed = try #require(AtlassianLogin.fullDate("2027-03-01"))
    #expect(parsed == Date(timeIntervalSince1970: 1_803_859_200))
}
