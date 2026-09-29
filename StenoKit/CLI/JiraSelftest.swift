import Foundation

/// The only thing that runs the Jira path against real Atlassian Cloud (D-197).
///
/// **D-138's pattern, applied to §5.2.** `make verify-keychain` exists because
/// §9.4 keeps `make test` out of the Keychain; `make verify-models` exists because
/// it denies outbound networking, which left `URLSessionTransport` and one API's
/// shape unexecuted. Both gaps are open here, and a third with them: the fixtures in
/// this PR were written from Atlassian's OpenAPI document, so until something real
/// disagrees with them, **the fixtures are the wire contract**. This is what makes
/// them answerable.
///
/// It prints what the connector would report — the summary, each change, and the
/// watermark — plus the number of requests and their methods, because "read-only"
/// is a claim worth seeing confirmed against the live API rather than only in a
/// spy's assertions (D-191).
///
/// Run by `make verify-jira ISSUE=PAY-421`. Hidden from `CLIUsage.text`. Every call
/// it makes is a GET, and it never prints the token.
public enum JiraSelftest {
    /// How far back the harness asks, so a real run has something to show.
    ///
    /// **Not `nil`.** A `nil` since means "establish an anchor and report nothing"
    /// (D-188), which is correct for a first observation and useless for a human
    /// checking whether transitions and comments come through.
    static let window: TimeInterval = 30 * 24 * 60 * 60

    public static func run(
        issueKey: String,
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let credential: AtlassianCredential?
        do {
            credential = try credentials.credential()
        } catch {
            out("jira-selftest: FAIL — the Keychain refused: \(String(describing: error))")
            return 1
        }

        guard let credential else {
            // The ordinary state of a machine where nobody has run
            // `make atlassian-login` — an instruction, not a stack trace. Still exit
            // 1: nothing was verified.
            out("jira-selftest: no Atlassian credential is stored. Run `make atlassian-login`.")
            return 1
        }
        guard credential.baseURL != nil else {
            out("jira-selftest: FAIL — the stored site is not an *.atlassian.net host (D19).")
            return 1
        }

        let counter = CountingTransport(wrapping: transport)
        let connector = JiraConnector(
            credentials: credentials, transport: counter, now: now)
        let ref = SourceRefSnapshot(refID: UUID(), kind: .jiraIssue, identifier: issueKey)

        let update: SourceUpdate
        do {
            update = try await connector.fetch(ref, since: now().addingTimeInterval(-window))
        } catch let error as SourceError {
            // `SourceError` carries no free-form string by construction (D-165), so
            // its own sentence is safe to print.
            out(
                "jira-selftest: FAIL — \(error.localizedDescription) [\(error.metricsLabel)]"
            )
            return 1
        } catch {
            out(
                "jira-selftest: FAIL — the connector threw \(String(describing: type(of: error))), which breaks its contract"
            )
            return 1
        }

        report(update, issueKey: issueKey, out: out)

        let methods = counter.methods
        out("  requests  \(methods.count) — \(Set(methods).sorted().joined(separator: ", "))")

        // D5 as a live assertion, not only a unit test: if the live path ever built a
        // write, this is where a human would see it.
        guard CountingTransport.isReadOnly(methods) else {
            out("jira-selftest: FAIL — a non-GET request was issued, which breaks D5")
            return 1
        }

        out("jira-selftest: PASS — \(methods.count) GETs, read-only")
        return 0
    }

    /// What the connector would report, printed for a human to check against their
    /// browser.
    ///
    /// Its own function because the run above is a sequence of guards and this is a
    /// sequence of prints; keeping them together pushed one function past its length
    /// budget, and the split is where the harness stops deciding and starts talking.
    private static func report(
        _ update: SourceUpdate, issueKey: String, out: @escaping @Sendable (String) -> Void
    ) {
        out("jira-selftest: \(issueKey)")
        out("  summary   \(update.summary)")
        if update.changes.isEmpty {
            out("  changes   none in the last 30 days")
        } else {
            for change in update.changes {
                out("  change    \(change.text)")
            }
        }
        for item in update.present {
            out("  present   \(item.text)")
        }
        out("  watermark \(update.watermark.map(String.init(describing:)) ?? "none")")
    }

    /// Blocking entry point for `main()`. See `CLISync`.
    public static func runSynchronously(
        issueKey: String,
        credentials: any AtlassianCredentialStore,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        CLISync.runSynchronously {
            await run(issueKey: issueKey, credentials: credentials, out: out)
        }
    }
}
