import Foundation

/// The only way `URLSessionTransport` and the live `/v1/models` shape get
/// executed by anything but a user in a Settings pane (D-161).
///
/// **D-138's answer, applied to the network.** `make verify-keychain` exists
/// because §9.4 keeps `make test` out of the real Keychain, which left
/// `KeychainCredentialStore` unexecuted for two milestones. The same two gaps
/// were open here after M3-02:
///
/// - `URLSessionTransport` has no automated test at all (D-143). Its only
///   untested behaviour is "Foundation does what Foundation does", so a
///   `URLProtocol` harness was judged not worth its cost — but that left the
///   real adapter first executed by a human, in the pane they were trying to
///   configure.
/// - `/v1/models`'s shape was confirmed by hand once, on 2026-09-22. A renamed
///   field a year from now fails *silently*: the paging guards turn it into a
///   short list rather than an error, and `ModelRanking` dedupes by id, so
///   nothing complains. Printing the ranked list is also how D-141's ordering
///   gets checked against what the API actually returns rather than against
///   what `ModelRanking`'s unit tests assume.
///
/// Run by `make verify-models`, which invokes the signed binary. Hidden from
/// `CLIUsage.text`: it is a verification harness, not a feature.
///
/// **It never prints the credential, on any path.** `AIError` carries no
/// free-form string by construction (D-132), so its own description is safe to
/// print; anything else is reported by type name only.
///
/// Unlike `KeychainSelftest`, this reads the **real** provider id: there is no
/// way to ask Anthropic a question with a sentinel key, and every call this
/// makes is a read.
public enum ModelsSelftest {
    /// Fetch the ranked list and print it.
    ///
    /// - Returns: `0` when models came back, `1` for every other outcome —
    ///   including an empty list, which is legitimate for the *protocol*
    ///   (§7.1: "a key with access to nothing") but means this harness verified
    ///   nothing.
    ///
    /// **`nonisolated` and it must stay that way.** `runSynchronously` blocks
    /// the calling thread — which for `steno models-selftest` is the main
    /// thread — while this runs on the cooperative pool. An actor-isolated
    /// hop to `@MainActor` inside here would deadlock that bridge.
    public static func run(
        provider: any AIProvider,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) async -> Int32 {
        let models: [AIModel]
        do {
            models = try await provider.availableModels()
        } catch AIError.notConfigured {
            // Not a failure of the network path: it is the ordinary state of a
            // machine where nobody has set a key, and the message is the
            // instruction. Still exit 1 — nothing was verified.
            out(
                "models-selftest: no key is stored for \(provider.id). "
                    + "Add one in Settings › AI, then run this again.")
            return 1
        } catch {
            out("models-selftest: FAIL — \(describe(error))")
            return 1
        }

        guard !models.isEmpty else {
            out("models-selftest: FAIL — \(provider.displayName) returned no models.")
            return 1
        }

        out(
            "models-selftest: PASS — \(models.count) model(s) from \(provider.displayName), "
                + "in the order the picker shows them.")
        for (index, model) in models.enumerated() {
            // Element zero is what M3-04's picker preselects (D-141, D-159), so
            // it is marked: the point of this list is to check that ordering
            // against the live API, and an unmarked list makes the reader count
            // rows.
            out("  \(model.id)  —  \(model.displayName)" + (index == 0 ? "   [default]" : ""))
        }
        return 0
    }

    /// The same run, for a caller that cannot `await`.
    ///
    /// `CLIEntry.run` is synchronous and `@MainActor`, because `StenoMain.main`
    /// must `exit()` with the code rather than return into SwiftUI's generated
    /// `main`. Making that path `async` would mean an `NSApplication`-free way
    /// to drive a run loop from `main()`, which is a far larger change than one
    /// verification harness justifies.
    public static func runSynchronously(
        provider: any AIProvider,
        out: @escaping @Sendable (String) -> Void = CLIOutput.standardOut
    ) -> Int32 {
        let box = ExitCode()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await run(provider: provider, out: out)
            finished.signal()
        }
        finished.wait()
        return box.value
    }

    /// What is safe to print about a thrown error.
    ///
    /// An `AIError` describes itself without quoting a payload — no case of it
    /// carries a free-form `String` (D-132) — so its own sentence is printed.
    /// Anything else is a provider defect (`AIProvider`'s contract is that only
    /// `AIError` escapes) and could be a `DecodingError` quoting a response
    /// body, so only its type name is printed (§8).
    private static func describe(_ error: any Error) -> String {
        guard let aiError = error as? AIError else {
            return "the provider threw \(String(describing: type(of: error))), which is a defect"
        }
        return "\(aiError.localizedDescription) [\(aiError.metricsLabel)]"
    }

    /// A box the detached task writes and the waiting thread reads.
    ///
    /// `@unchecked Sendable` with no lock: the semaphore is the ordering. The
    /// write happens before `signal()` and the read after `wait()`, which is
    /// the same happens-before a lock would establish.
    private final class ExitCode: @unchecked Sendable {
        var value: Int32 = 1
    }
}
