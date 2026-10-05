import Foundation

/// The only thing that runs FR-6's Integrations pane against real Atlassian Cloud
/// and the real Keychain (D-220).
///
/// **It exists because the pane's whole point is telling four failures apart, and
/// `make test` cannot check any of them against the wire.** The suite denies
/// outbound networking (§9.4, D-012) and stays out of the Keychain (D-134), so
/// whether a nonexistent Atlassian subdomain produces `.siteNotFound` rather than
/// `.network` depends on which `URLError` the real resolver returns — a fact no
/// double can establish, and the one D-217 turns into a sentence the user reads.
///
/// **It does not drive `IntegrationsSettingsModel`, and cannot** (Copilot, PR #45).
/// An earlier version of this comment, and D-220, claimed it did. It reads
/// `AtlassianCredentialStore.credential()` directly and builds the two connectors
/// itself. The model is `@MainActor`, and `CLISync.runSynchronously` blocks the main
/// thread on a semaphore while the work runs on the cooperative pool — so a hop to
/// the main actor inside that work deadlocks the bridge, which `CLISync`'s own
/// documentation states as a requirement on its callers.
///
/// What it therefore verifies is the real store's `credential()` read, the real
/// `baseURL` validation, both connectors' `testConnection()` against the live API,
/// and §5.2's expiry arithmetic. The model's `load()`, `saveCredential()` and
/// `resolvedToken()` are covered by `IntegrationsSettingsModelTests` against a
/// double, and their Keychain round trip is covered by `make atlassian-login`
/// writing a credential this harness then reads — which is the pairing that closes
/// the gap, rather than one harness doing both.
///
/// Run by `make verify-integrations`. Hidden from `CLIUsage.text`: it is a
/// verification harness, not a feature. **Nothing it prints contains the token, on
/// any path** — it reports the email, the site and the expiry, which §5.2 treats as
/// configuration rather than secrets.
public enum IntegrationsSelftest {
    /// A subdomain that does not exist, for the `.siteNotFound` probe.
    ///
    /// **Shaped correctly on purpose.** `AtlassianCredential.cloudHost` accepts it,
    /// so it reaches the resolver — which is the whole point: a site refused locally
    /// proves nothing about the mapping D-217 added.
    static let unresolvableSite = "steno-selftest-no-such-site.atlassian.net"

    /// A host that is not Atlassian Cloud at all, for the local-refusal probe.
    static let foreignSite = "example.com"

    public static func run(
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let credential: AtlassianCredential?
        do {
            credential = try credentials.credential()
        } catch {
            // **Narrowed, not interpolated** (Copilot, PR #45). An arbitrary error
            // describes itself by quoting the value it choked on, which here is the
            // credential — so this file's "the token never appears on any path"
            // guarantee depended on a store that happens not to throw one.
            out(
                "integrations-selftest: FAIL — the Keychain refused: \(KeychainErrorDetail.of(error))"
            )
            return 1
        }
        guard let credential else {
            // The ordinary state of a machine where nobody has configured Atlassian
            // — an instruction, not a stack trace. Still exit 1: nothing was
            // verified.
            out(
                "integrations-selftest: no Atlassian credential is stored. "
                    + "Run `make atlassian-login`, or save one in Settings → Integrations.")
            return 1
        }
        guard credential.baseURL != nil else {
            out(
                "integrations-selftest: FAIL — the stored site is not an *.atlassian.net host "
                    + "(D19).")
            return 1
        }

        report(credential, now: now(), out: out)

        var failures = 0
        failures += await reportConnections(
            credential: credential, transport: transport, now: now, out: out)
        failures += await reportSiteProbe(
            credential: credential, transport: transport, now: now, out: out)
        failures += reportLocalRefusal(credential: credential, out: out)

        if failures > 0 {
            out("integrations-selftest: FAIL — \(failures) check(s) did not hold.")
            return 1
        }
        out("integrations-selftest: OK")
        return 0
    }

    /// What is stored, and what §5.2's warning makes of it. **Never the token.**
    private static func report(
        _ credential: AtlassianCredential, now: Date, out: (String) -> Void
    ) {
        out("stored credential: \(credential.email) at \(credential.site)")
        guard let expiresAt = credential.expiresAt else {
            out("expiry: none recorded, so §5.2's warning cannot fire (D-192)")
            return
        }
        let days = AtlassianTokenExpiry.daysRemaining(expiresAt: expiresAt, now: now)
        let warns = AtlassianTokenExpiry.shouldWarn(expiresAt: expiresAt, now: now)
        out("expiry: \(days) day(s) remaining, warning \(warns ? "due" : "not due")")
    }

    /// FR-6's per-integration test, against the live site, for every connector that
    /// ships.
    private static func reportConnections(
        credential: AtlassianCredential,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date,
        out: @escaping @Sendable (String) -> Void
    ) async -> Int {
        let store = FixedCredentialStore(credential)
        var failures = 0
        for connector in Self.connectors(credentials: store, transport: transport, now: now) {
            let started = Date()
            do {
                try await connector.testConnection()
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                out("\(connector.id): reached in \(elapsed)ms")
            } catch let error as SourceError {
                // `SourceError` carries no free-form string by construction (D-165),
                // so its own sentence is safe to print.
                out("\(connector.id): FAIL — \(error.localizedDescription) [\(error.metricsLabel)]")
                failures += 1
            } catch {
                out(
                    "\(connector.id): FAIL — threw \(String(describing: type(of: error))), "
                        + "which breaks the SourceConnector contract")
                failures += 1
            }
        }
        return failures
    }

    /// **D-217's probe, and the reason this harness exists.**
    ///
    /// A site that is shaped correctly and does not exist must report
    /// `.siteNotFound`, not `.network`. Which `URLError` the resolver returns is the
    /// fact under test, and only a real resolver can supply it.
    private static func reportSiteProbe(
        credential: AtlassianCredential,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date,
        out: @escaping @Sendable (String) -> Void
    ) async -> Int {
        let probe = AtlassianCredential(
            site: Self.unresolvableSite, email: credential.email,
            // **The stored token is not sent to a host that is not the user's site.**
            // A placeholder is enough: the request never gets past DNS, and if it
            // somehow did, it must not carry a working credential.
            apiToken: "selftest-not-a-real-token", expiresAt: nil)
        let store = FixedCredentialStore(probe)

        guard
            let connector = Self.connectors(
                credentials: store, transport: transport, now: now
            ).first
        else { return 1 }

        do {
            try await connector.testConnection()
            out("site probe \(Self.unresolvableSite): FAIL — it answered, which cannot be right")
            return 1
        } catch SourceError.siteNotFound {
            out("site probe \(Self.unresolvableSite): siteNotFound (D-217)")
            return 0
        } catch let error as SourceError {
            out(
                "site probe \(Self.unresolvableSite): FAIL — reported "
                    + "\(error.metricsLabel), so a mistyped site still reads as something else")
            return 1
        } catch {
            out(
                "site probe \(Self.unresolvableSite): FAIL — \(String(describing: type(of: error)))"
            )
            return 1
        }
    }

    /// A host that is not Atlassian Cloud must be refused **before** any request
    /// (D-190, D19): this credential travels as HTTP Basic.
    private static func reportLocalRefusal(
        credential: AtlassianCredential, out: (String) -> Void
    ) -> Int {
        let foreign = AtlassianCredential(
            site: Self.foreignSite, email: credential.email,
            apiToken: "selftest-not-a-real-token", expiresAt: nil)
        guard foreign.baseURL == nil else {
            out("site probe \(Self.foreignSite): FAIL — it produced a usable base URL")
            return 1
        }
        out("site probe \(Self.foreignSite): refused locally, no request sent")
        return 0
    }

    /// The connectors `StenoApp` registers, over a fixed credential.
    private static func connectors(
        credentials: any AtlassianCredentialStore,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date
    ) -> [any SourceConnector] {
        [
            JiraConnector(credentials: credentials, transport: transport, now: now),
            ConfluenceConnector(credentials: credentials, transport: transport, now: now),
        ]
    }

    public static func runSynchronously(
        credentials: any AtlassianCredentialStore,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        CLISync.runSynchronously {
            await run(credentials: credentials, out: out)
        }
    }
}

/// A store that answers with one credential and ignores writes.
///
/// **So a probe can use a different site without touching the Keychain.** The
/// `.siteNotFound` check needs a connector pointed at a host that does not exist,
/// and writing that into the user's Keychain to achieve it would be a harness that
/// breaks the thing it verifies.
struct FixedCredentialStore: AtlassianCredentialStore {
    /// Named `fixed` rather than `credential`: a stored property of that name and
    /// the protocol's `credential()` requirement are a redeclaration.
    let fixed: AtlassianCredential?

    init(_ fixed: AtlassianCredential?) {
        self.fixed = fixed
    }

    func store(_ credential: AtlassianCredential) throws {}
    func credential() throws -> AtlassianCredential? { fixed }
    func delete() throws {}
}
