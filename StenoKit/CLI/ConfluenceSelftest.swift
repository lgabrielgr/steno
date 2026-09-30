import Foundation

/// The only thing that runs the Confluence path against real Atlassian Cloud (D-197).
///
/// **`JiraSelftest`'s twin, for the same three gaps.** `make test` denies outbound
/// networking (§9.4) and stays out of the Keychain, which leaves `URLSessionTransport`
/// and this API's real shape unexecuted — and the fixtures in this PR were written from
/// Atlassian's OpenAPI document, so until something real disagrees with them, **the
/// fixtures are the wire contract**. This is what makes them answerable.
///
/// It prints what the connector would report — the summary, each version line, and the
/// watermark — plus the number of requests and their methods, because "read-only" is a
/// claim worth seeing confirmed against the live API rather than only in a spy's
/// assertions (D-191).
///
/// Run by `make verify-confluence PAGE=12345`. Hidden from `CLIUsage.text`. Every call
/// it makes is a GET, and it never prints the token.
public enum ConfluenceSelftest {
    /// How far back the harness asks, so a real run has something to show.
    ///
    /// **Not `nil`.** A `nil` since means "establish an anchor and report nothing"
    /// (D-188), which is correct for a first observation and useless for a human
    /// checking whether the version delta comes through.
    static let window: TimeInterval = 30 * 24 * 60 * 60

    public static func run(
        pageID: String,
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let credential: AtlassianCredential?
        do {
            credential = try credentials.credential()
        } catch {
            out("confluence-selftest: FAIL — the Keychain refused: \(String(describing: error))")
            return 1
        }

        guard let credential else {
            // The ordinary state of a machine where nobody has run
            // `make atlassian-login` — an instruction, not a stack trace. Still exit 1:
            // nothing was verified.
            out(
                "confluence-selftest: no Atlassian credential is stored. Run `make atlassian-login`."
            )
            return 1
        }
        guard let base = credential.baseURL else {
            out("confluence-selftest: FAIL — the stored site is not an *.atlassian.net host (D19).")
            return 1
        }
        guard ConfluenceEndpoint.isValidPageID(pageID) else {
            // Caught here rather than spent on a request the API would answer 400 to,
            // and said plainly: a page id is the number in the URL, which is the part
            // people most often paste something else in place of.
            out("confluence-selftest: FAIL — \"\(pageID)\" is not a page id (digits only).")
            return 1
        }

        let counter = CountingTransport(wrapping: transport)
        let connector = ConfluenceConnector(
            credentials: credentials, transport: counter, now: now)
        // **Built from `baseURL`, not from `site`.** `AtlassianCredential.site` keeps what
        // the user typed and accepts a pasted URL with a path, so interpolating it
        // produced values like `https://https://acme.atlassian.net/jira/…/wiki/pages/123`
        // — which the harness would then print as the page's URL whenever `_links.webui`
        // was absent. `baseURL` is the validated, normalized form, and this function
        // already refused to continue without it. Raised by Copilot in review of PR #44.
        let ref = SourceRefSnapshot(
            refID: UUID(), kind: .confluencePage, identifier: pageID,
            url: "\(base.absoluteString)/wiki/pages/\(pageID)")

        let update: SourceUpdate
        do {
            update = try await connector.fetch(ref, since: now().addingTimeInterval(-window))
        } catch let error as SourceError {
            // `SourceError` carries no free-form string by construction (D-165), so its
            // own sentence is safe to print.
            out("confluence-selftest: FAIL — \(error.localizedDescription) [\(error.metricsLabel)]")
            return 1
        } catch {
            out(
                "confluence-selftest: FAIL — the connector threw \(String(describing: type(of: error))), which breaks its contract"
            )
            return 1
        }

        report(update, pageID: pageID, out: out)

        let methods = counter.methods
        out("  requests  \(methods.count) — \(Set(methods).sorted().joined(separator: ", "))")

        // D5 as a live assertion, not only a unit test: if the live path ever built a
        // write, this is where a human would see it. It is also the check that would
        // catch a future name lookup reaching for `POST /users-bulk` (D-201).
        guard CountingTransport.isReadOnly(methods) else {
            out("confluence-selftest: FAIL — a non-GET request was issued, which breaks D5")
            return 1
        }

        out("confluence-selftest: PASS — \(methods.count) GETs, read-only")
        return 0
    }

    /// What the connector would report, printed for a human to check against their
    /// browser.
    private static func report(
        _ update: SourceUpdate, pageID: String, out: @escaping @Sendable (String) -> Void
    ) {
        out("confluence-selftest: page \(pageID)")
        out("  summary   \(update.summary)")
        if update.changes.isEmpty {
            out("  changes   no new versions in the last 30 days")
        } else {
            for change in update.changes {
                out("  change    \(change.text)")
            }
        }
        out("  url       \(update.url?.absoluteString ?? "none")")
        out("  watermark \(update.watermark.map(String.init(describing:)) ?? "none")")
        // Printed because a short walk means the oldest versions in the window went
        // unread, and a human comparing this against their browser needs to know that
        // before concluding the delta is wrong.
        //
        // **It does not name the page cap**, because `isWindowCapped` is equally true for
        // a cursor that did not advance and for a `next` with no usable cursor (D-213).
        // Naming one cause in a verification harness would send a reader looking for a
        // long page history that may not be the problem; the log carries the specific
        // reason. Raised by Copilot in review of PR #44.
        if update.isWindowCapped {
            out(
                "  partial   yes — the version walk ended early; the watermark is held at the floor"
            )
        }
    }

    /// Blocking entry point for `main()`. See `CLISync`.
    public static func runSynchronously(
        pageID: String,
        credentials: any AtlassianCredentialStore,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        CLISync.runSynchronously {
            await run(pageID: pageID, credentials: credentials, out: out)
        }
    }
}
