/// The kind of external system a `SourceRef` points at (REQUIREMENTS.md §3.4).
public enum SourceRefKind: String, Codable, CaseIterable, Sendable {
    case jiraIssue
    case confluencePage
    case githubPR
    case url
    case mcpResource
}
