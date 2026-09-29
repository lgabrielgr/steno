import Foundation

/// Atlassian's timestamps, parsed. Shared by both APIs (D-202).
///
/// **Two formats, tried in order, because both APIs send the fractional-seconds
/// form and Foundation's default parser rejects it.** Jira's
/// `2026-09-25T18:04:11.123+0000` and Confluence's documented
/// `YYYY-MM-DDTHH:mm:ss.sssZ` both need
/// `.withFractionalSeconds`; a value without the fraction needs it absent, since the
/// option is a requirement rather than a permission. Getting this wrong does not
/// throw — it returns `nil`, and every timestamp silently becoming `nil` would leave
/// the watermark `nil` forever and the window permanently open.
enum AtlassianDate {
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
