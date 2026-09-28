import Foundation

/// `Decodable` mirrors of the four REST v3 responses this connector reads.
///
/// **Every field is optional, including ones the API documents as required.** A
/// connector's job under §5.5 is to degrade, and a missing `displayName` on one
/// comment must cost that comment's author rather than the whole fetch — which is
/// what a non-optional field would do, because one `keyNotFound` fails the entire
/// decode. The shapes below are taken from Atlassian's own OpenAPI document
/// (verified 2026-09-26), and the parts this app relies on are asserted against
/// recorded fixtures.
///
/// Only what is read is modelled. A bare issue GET returns every custom field an
/// org has ever defined; `JiraEndpoint.issueFields` asks for four.
struct JiraIssue: Decodable, Equatable {
    let key: String?
    let fields: Fields?

    struct Fields: Decodable, Equatable {
        /// The ticket's title, which Jira calls `summary`.
        let summary: String?
        let status: Status?
        let assignee: JiraUser?
        let updated: String?
    }

    struct Status: Decodable, Equatable {
        let name: String?
    }
}

struct JiraUser: Decodable, Equatable {
    let displayName: String?
}

/// `PageBeanChangelog`. **Has `isLast`**, which `PageOfComments` does not — the
/// asymmetry is real and D-196 depends on it.
struct JiraChangelogPage: Decodable, Equatable {
    let values: [JiraChangelogEntry]?
    let startAt: Int?
    let maxResults: Int?
    let total: Int?
    let isLast: Bool?
}

struct JiraChangelogEntry: Decodable, Equatable {
    /// The dedup key for a transition (D-186).
    let id: String?
    let created: String?
    let author: JiraUser?
    let items: [JiraChangeItem]?
}

struct JiraChangeItem: Decodable, Equatable {
    /// `status`, `assignee`, and everything else this connector ignores.
    let field: String?
    let fieldId: String?
    let fromString: String?

    /// `toString` in the API. **Renamed here**, because `toString` collides with
    /// nothing in Swift but reads as a method, and the coding key below is what
    /// keeps the wire contract.
    let toValue: String?

    enum CodingKeys: String, CodingKey {
        case field
        case fieldId
        case fromString
        case toValue = "toString"
    }
}

/// `PageOfComments`. **No `isLast`** — paging is driven by `startAt + total`.
struct JiraCommentPage: Decodable, Equatable {
    let comments: [JiraComment]?
    let startAt: Int?
    let maxResults: Int?
    let total: Int?
}

struct JiraComment: Decodable, Equatable {
    /// The dedup key for a comment (D-186).
    let id: String?
    let created: String?

    /// An edited comment moves this without moving `created`, which is why the
    /// watermark reads the later of the two (D-195).
    let updated: String?
    let author: JiraUser?

    /// **Atlassian Document Format, not text** — REST v3's one real inconvenience.
    /// `AtlassianDocument` flattens it.
    let body: ADFNode?
}

extension JiraComment {
    /// When this comment last said something new.
    ///
    /// **The later of `created` and `updated`** (D-195): an edit moves `updated`
    /// alone, and an edit is news because the text the user would read out has
    /// changed. One property rather than the same expression in the client's paging
    /// and in `JiraChangeSet` — a fact in two places is wrong in one of them.
    var stamp: Date? {
        [JiraDate.parse(created), JiraDate.parse(updated)].compactMap { $0 }.max()
    }

    /// The raw timestamp string behind `stamp`, for the change id's revision component.
    ///
    /// **The string, not a number derived from it.** A revision built from
    /// `Int(timeIntervalSince1970)` truncates to whole seconds, so two edits inside one
    /// second produce one id and the second is dropped by the service's dedup — the same
    /// defect the revision was added to fix, one layer down. This carries whatever
    /// precision Jira sent, including the fractional seconds it actually sends.
    ///
    /// Computed beside `stamp` so the two cannot disagree about which timestamp wins.
    var revision: String? {
        let candidates = [created, updated].compactMap { raw -> (String, Date)? in
            guard let raw, let parsed = JiraDate.parse(raw) else { return nil }
            return (raw, parsed)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}

/// A remote link — §5.2's "linked PR references".
///
/// **`id` is an `Int` here and a `String` everywhere else in this file.** That is
/// the API's own choice, and it is why `JiraChangeSet` stringifies it rather than
/// pretending the streams agree.
struct JiraRemoteLink: Decodable, Equatable {
    let id: Int?
    let globalId: String?
    let relationship: String?
    let object: RemoteObject?

    struct RemoteObject: Decodable, Equatable {
        let url: String?
        let title: String?
    }
}

/// One Atlassian Document Format node.
///
/// Recursive and permissive: `type` drives the flattening and anything unrecognised
/// contributes its children (D-195), so a node type Atlassian adds next year costs a
/// fragment of a sentence rather than the whole comment.
struct ADFNode: Decodable, Equatable {
    let type: String?
    let text: String?
    let content: [ADFNode]?
    let attrs: Attrs?

    struct Attrs: Decodable, Equatable {
        /// A mention's rendered text, `@Ana`.
        let text: String?
        /// An emoji's `:tada:`.
        let shortName: String?
        /// An inline card's target — often the PR link a stand-up wants.
        let url: String?
    }
}

/// Jira's timestamps, parsed.
///
/// **Two formats, tried in order, because Jira sends the fractional-seconds form
/// and Foundation's default parser rejects it.** `2026-09-25T18:04:11.123+0000` needs
/// `.withFractionalSeconds`; a value without the fraction needs it absent, since the
/// option is a requirement rather than a permission. Getting this wrong does not
/// throw — it returns `nil`, and every timestamp silently becoming `nil` would leave
/// the watermark `nil` forever and the window permanently open.
enum JiraDate {
    /// `nil` for an absent or unparseable value.
    ///
    /// The formatters are built per call rather than held in a `static let`: an
    /// `ISO8601DateFormatter` is not `Sendable`, and D18's twenty tickets make the
    /// allocation irrelevant next to the request that fetched the string.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
