import Foundation

/// §5.5's "which refs are due" rule, as arithmetic.
///
/// **Pure, and holds no clock.** The selection of *candidate* refs is a store
/// query and lives in `SourceRefreshService`; deciding which of them is stale is
/// this, so the rule that actually governs network traffic can be tested without
/// a container, a connector, or a wait.
public enum RefreshPolicy {
    /// §5.5: "on app launch, refresh refs on all non-done tasks older than 30
    /// minutes."
    ///
    /// Not user-configurable. §5.5 states it as a fixed rule, and M4-05's
    /// scheduled pass — which *is* configurable — is the setting the user gets.
    public static let launchStaleness: Duration = .seconds(30 * 60)

    /// The refs in `refs` worth fetching now.
    ///
    /// A ref never fetched is always due: `lastFetchedAt == nil` is the first
    /// observation, and D-169 makes that the pass that seeds the cache.
    ///
    /// **The boundary is strict.** Exactly `olderThan` old is *not* due, so two
    /// passes an exact interval apart do not both fetch. Which side the boundary
    /// falls on matters less than it being pinned by a test in both directions.
    public static func due(
        _ refs: [SourceRefSnapshot], now: Date, olderThan staleness: Duration
    ) -> [SourceRefSnapshot] {
        let cutoff = now.addingTimeInterval(-staleness.seconds)
        return refs.filter { ref in
            guard let fetched = ref.lastFetchedAt else { return true }
            return fetched < cutoff
        }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for arithmetic against `Date`.
    ///
    /// `components` is `(seconds: Int64, attoseconds: Int64)`; the attosecond
    /// term is carried rather than dropped so a sub-second duration — which
    /// every test uses — is not silently truncated to zero.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
