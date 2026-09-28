import Darwin
import Foundation

/// How an Atlassian credential gets stored before M4-04 builds the Settings pane
/// (D-197).
///
/// **This exists because of a gap M4-02 would otherwise leave open.** The connector
/// is the first real `SourceConnector`, and nothing in this PR could store a
/// credential for it: `make test` uses a double (D-134), and FR-6's pane is two
/// tasks away. Without this, the whole Jira path would ship having never spoken to
/// Atlassian, and the recorded fixtures would be the only description of the wire.
///
/// Run by `make atlassian-login`, which invokes the signed binary. Hidden from
/// `CLIUsage.text`: it is a verification harness, not a feature.
///
/// **The token is read from stdin with echo disabled, never from an argument.** A
/// flag value lands in `ps` output and in shell history, which is exactly what §8
/// keeps tokens out of. Nothing here prints the token back, on any path.
public enum AtlassianLogin {
    /// Prompt, validate, store.
    ///
    /// Every reader is injected so the whole sequence is testable without a
    /// terminal: the real one reads stdin, and a test hands it scripted answers.
    ///
    /// - Returns: `0` once stored, `1` for any input this cannot act on.
    public static func run(
        store: any AtlassianCredentialStore,
        out: (String) -> Void = CLIOutput.standardOut,
        readLine: () -> String? = { Swift.readLine(strippingNewline: true) },
        readSecret: (String) -> String? = TerminalSecret.read(prompt:)
    ) -> Int32 {
        out("atlassian-login: stores one credential for Jira and Confluence (§5.3).")

        out("site (acme.atlassian.net):")
        guard let site = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !site.isEmpty
        else {
            out("atlassian-login: FAIL — no site given.")
            return 1
        }
        guard AtlassianCredential.cloudHost(in: site) != nil else {
            // D19 and D-190: the app talks to Atlassian Cloud, and this credential
            // travels as HTTP Basic — so a site that is not `*.atlassian.net` is
            // refused here rather than discovered when the token has already been
            // sent somewhere else.
            out("atlassian-login: FAIL — \"\(site)\" is not an *.atlassian.net host (D19).")
            return 1
        }

        out("email:")
        guard let email = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !email.isEmpty
        else {
            out("atlassian-login: FAIL — no email given.")
            return 1
        }

        guard let token = readSecret("api token (not echoed):"), !token.isEmpty else {
            out("atlassian-login: FAIL — no token given.")
            return 1
        }

        out("expires (YYYY-MM-DD, blank if you didn't record it):")
        let expiryText = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expiresAt: Date?
        if expiryText.isEmpty {
            // Allowed, and §5.2's warning simply cannot fire — which is one reason
            // the 401 path never depends on this value (D-192).
            expiresAt = nil
        } else if let parsed = fullDate(expiryText) {
            expiresAt = parsed
        } else {
            out("atlassian-login: FAIL — \"\(expiryText)\" is not a YYYY-MM-DD date.")
            return 1
        }

        do {
            try store.store(
                AtlassianCredential(
                    site: site, email: email, apiToken: token, expiresAt: expiresAt))
        } catch {
            out("atlassian-login: FAIL — \(String(describing: error))")
            return 1
        }

        let expiryNote = expiresAt.map { " expiring \(fullDateText($0))" } ?? " with no expiry date"
        out("atlassian-login: stored \(email) at \(site)\(expiryNote).")
        return 0
    }

    /// `YYYY-MM-DD` as a `Date`, or `nil`.
    ///
    /// `ISO8601DateFormatter` with `.withFullDate` rather than a `DateFormatter` with
    /// a format string: the second needs a POSIX locale set by hand, and forgetting
    /// that is how a date parser starts depending on the machine's region.
    static func fullDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    private static func fullDateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

/// Reading a secret from a terminal without echoing it.
///
/// **Not `getpass`.** That is the obvious answer and it silently truncates at
/// `_PASSWORD_LEN` (128 bytes); an Atlassian API token is longer than that, so the
/// user would store a mangled token and spend the afternoon debugging 401s. This
/// disables echo around `readLine()`, which has no length limit.
public enum TerminalSecret {
    /// Prompt on stdout, read one line with echo disabled, restore the terminal.
    ///
    /// When stdin is not a terminal — `echo … | steno atlassian-login`, or a test —
    /// `tcgetattr` fails and the line is read normally. That is the honest behaviour:
    /// there is no echo to disable on a pipe.
    public static func read(prompt: String) -> String? {
        print(prompt)

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }

        var quiet = original
        quiet.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else {
            return Swift.readLine(strippingNewline: true)
        }
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }

        return Swift.readLine(strippingNewline: true)
    }
}
