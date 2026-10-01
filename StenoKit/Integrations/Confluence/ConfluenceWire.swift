import Foundation

/// `Decodable` mirrors of the four responses this connector reads.
///
/// **Every field is optional, including ones the API documents as required**, for the
/// reason `JiraWire` states: §5.5's job is to degrade, and one missing `displayName`
/// must cost that editor's name rather than the whole fetch — which is what a
/// non-optional field would do, because one `keyNotFound` fails the entire decode.
///
/// The shapes are taken from Atlassian's own OpenAPI document
/// (`openapi-v2.v3.json`, `info.version` 2.0.0, verified 2026-09-29), and only what is
/// read is modelled. Notably absent: `body`. `ConfluenceEndpoint.page` never sends
/// `body-format`, so a page's text is not asked for — and it could not be decoded here
/// if it arrived anyway (§8).

/// `GET /wiki/api/v2/pages/{id}`.
struct ConfluencePage: Decodable, Equatable {
    let id: String?
    let title: String?

    /// The current version, which arrives because `include-version` defaults to `true`.
    let version: ConfluenceVersion?

    let links: Links?

    /// `AbstractPageLinks`: `webui`, `editui`, `tinyui` — **and no `base`**, which a
    /// versions page's `_links` does have. That asymmetry is why `SourceUpdate.url` is
    /// built from the credential's own host rather than from the response.
    struct Links: Decodable, Equatable {
        /// Relative, and rooted at the Confluence site rather than the Cloud host:
        /// `/spaces/ENG/pages/12345/Payments+Migration+Plan`.
        let webui: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, version
        case links = "_links"
    }
}

/// `Version` in the v2 schema — the same object whether it arrives on a page or in a
/// versions list. It carries these five fields and nothing else.
struct ConfluenceVersion: Decodable, Equatable {
    /// The version number, which is the delta's dedup key (D-203).
    let number: Int?

    /// When this version was published, `"YYYY-MM-DDTHH:mm:ss.sssZ"`. The watermark
    /// source, and the only timestamp §5.3's "last-modified" can mean.
    let createdAt: String?

    /// What the editor typed in "What did you change?", when they typed anything.
    let message: String?

    /// Confluence's "don't notify watchers" checkbox. Reported, not filtered (D-203).
    let minorEdit: Bool?

    /// **An account id, not a name.** Resolving it is a second request (D-201).
    let authorId: String?

    /// `createdAt` as a `Date`, or `nil` when it is absent or unparseable.
    var stamp: Date? { AtlassianDate.parse(createdAt) }
}

/// `MultiEntityResult<Version>` from `GET /wiki/api/v2/pages/{id}/versions`.
struct ConfluenceVersionPage: Decodable, Equatable {
    let results: [ConfluenceVersion]?
    let links: Links?

    /// `MultiEntityLinks`.
    struct Links: Decodable, Equatable {
        /// *"The relative URL for the next set of results, using a cursor query
        /// parameter. This property will not be present if there is no additional data
        /// available."* — which is how the walk learns it is over.
        ///
        /// **Never sent as-is** (D-205): `ConfluenceEndpoint.cursor(inNext:)` takes the
        /// cursor out of it and the request is rebuilt against the configured host.
        let next: String?

        /// Base URL of the Confluence site. Present here, absent on a single page's
        /// links, and unused: the app knows its own site from the credential, and a
        /// base URL taken from a response is a base URL a response can change.
        let base: String?
    }

    private enum CodingKeys: String, CodingKey {
        case results
        case links = "_links"
    }
}

/// `GET /wiki/rest/api/user?accountId=…`, reduced to the one field D-201 wants.
///
/// The real response also carries an email address, a time zone, a personal space and a
/// permissions block. None of it is modelled, so none of it is decoded or retained
/// (§8).
struct ConfluenceUser: Decodable, Equatable {
    let displayName: String?
}

/// `GET /wiki/api/v2/spaces?limit=1`, for `testConnection()` only.
///
/// **The body is not read for content, only for shape.** An account with no visible
/// space answers `{"results": []}`, which is a 200 and therefore a working credential —
/// FR-6 asks whether the integration is reachable and authorised, not whether the user
/// can see anything in particular.
struct ConfluenceSpacePage: Decodable, Equatable {
    let results: [Space]?

    struct Space: Decodable, Equatable {
        let id: String?
    }
}
