import Foundation

/// The only way `KeychainCredentialStore` gets executed before M3-04 builds a
/// Settings pane.
///
/// **This exists because of a gap D-134 opens deliberately.** No automated test
/// touches the real Keychain — `make test` uses `InMemoryCredentialStore` so it
/// never writes into the developer's login keychain — and no UI reads it until
/// M3-04. Without this, not one line of the real store would run in this PR or
/// the two after it, and this repo has twice found that the unexecuted path is
/// where the defects are.
///
/// Run by `make verify-keychain`, which invokes the signed binary. Hidden from
/// `CLIUsage.text`: it is a verification harness, not a feature.
///
/// The logic is here and takes a `CredentialStore`, so the *sequence* is
/// testable against the in-memory double while the binary supplies the real one.
public enum KeychainSelftest {
    /// A provider id no real provider uses, so a developer running this can
    /// never overwrite the key they actually rely on.
    public static let providerID = "selftest"

    /// Store, read, store again, read again, delete, confirm gone.
    ///
    /// **Two writes, not one.** The second is what exercises D-135's
    /// `errSecDuplicateItem` → `SecItemUpdate` fallback — the one sequence the
    /// pure query tests cannot reach, and the one whose failure mode is a user
    /// who changes their API key and silently keeps using the old one.
    public static func run(
        store: any CredentialStore,
        out: (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        let first = Credential.apiKey("selftest-first-\(UUID().uuidString)")
        let second = Credential.apiKey("selftest-second-\(UUID().uuidString)")

        // **Every exit path, not just the happy one.** The explicit delete below
        // is part of what this harness verifies, so it stays — but a mismatch or
        // a throw before it would return early and strand a credential-shaped
        // item in the real Keychain, at exactly the moment someone is
        // investigating why the Keychain is misbehaving. Deleting what is
        // already gone succeeds, so this costs the passing run nothing.
        // Raised by Copilot on PR #33.
        defer { try? store.delete(for: providerID) }

        do {
            try store.store(first, for: providerID)
            let readBack = try store.credential(for: providerID)
            guard readBack == first else {
                out("keychain-selftest: FAIL — first read returned \(describe(readBack))")
                return 1
            }

            try store.store(second, for: providerID)
            let overwritten = try store.credential(for: providerID)
            guard overwritten == second else {
                out("keychain-selftest: FAIL — overwrite returned \(describe(overwritten))")
                return 1
            }

            try store.delete(for: providerID)
            guard try store.credential(for: providerID) == nil else {
                out("keychain-selftest: FAIL — item survived delete")
                return 1
            }
        } catch {
            out("keychain-selftest: FAIL — \(error)")
            return 1
        }

        out("keychain-selftest: PASS — store, overwrite, read and delete all succeeded")
        return 0
    }

    /// **Never prints the stored value.** A harness that dumped the credential
    /// on failure would write an API key to a terminal and a scrollback buffer,
    /// which is the thing §8 exists to prevent — and the failure it reports is
    /// about identity, not contents.
    private static func describe(_ credential: Credential?) -> String {
        guard let credential else { return "nothing" }
        return "a \(credential.kind.rawValue) credential that did not match"
    }
}
