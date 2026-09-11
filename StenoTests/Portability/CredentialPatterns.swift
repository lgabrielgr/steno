import Foundation

/// §10.3's scanner: known credential markers, looked for in export output.
///
/// **Test infrastructure, not production code, and deliberately so.** §10.3
/// asks for an assertion about the output, not a runtime guard. A scanner
/// shipped in `StenoKit` with no caller is an invitation to wire it into the
/// write path, where it would become a filter on user content — and if the user
/// pastes a token into a note, the export containing it is *correct*. §10.3
/// governs credentials the app holds, which per §8 live in Keychain and never
/// reach SwiftData.
///
/// Literal prefixes rather than regular expressions or entropy analysis. These
/// are the vendor markers a leaked token is recognisable by, a substring search
/// has no pattern to get subtly wrong, and the test that matters is the
/// positive control — see `ExportSecretsTests`.
struct CredentialPattern {
    let name: String
    let marker: String
}

enum CredentialPatterns {
    static let all: [CredentialPattern] = [
        CredentialPattern(name: "Anthropic API key", marker: "sk-ant-"),
        CredentialPattern(name: "OpenAI API key", marker: "sk-proj-"),
        CredentialPattern(name: "Atlassian API token", marker: "ATATT"),
        CredentialPattern(name: "GitHub personal access token", marker: "ghp_"),
        CredentialPattern(name: "Slack bot token", marker: "xoxb-"),
        CredentialPattern(name: "Slack user token", marker: "xoxp-"),
        CredentialPattern(name: "AWS access key ID", marker: "AKIA"),
        CredentialPattern(name: "HTTP bearer credential", marker: "Bearer "),
    ]

    /// The names of every pattern found in `text`.
    static func matches(in text: String) -> [String] {
        all.filter { text.contains($0.marker) }.map(\.name)
    }
}
