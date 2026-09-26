import OSLog

/// Logging entry point.
///
/// The subsystem is fixed by REQUIREMENTS.md §9.1 and lives here so it is
/// written once.
///
/// `Logger` writes to the unified log, never to stdio — so this output does not
/// appear in the terminal even under `make run`, whose visible launch line is a
/// separate `print`. To watch it, in another terminal:
///
///     log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
public enum Log {
    public static let subsystem = "com.lgabrielgr.steno"

    public static let app = Logger(subsystem: subsystem, category: "app")

    /// The report path (FR-4).
    ///
    /// Its own category so a clamped window can be found without reading every
    /// `app` line. **Clamping is the only thing this category emits today** —
    /// `ReportGatherer.warnIfClamped` is its single call site, and an empty
    /// window is silent because it is a normal outcome, not an anomaly:
    ///
    ///     /usr/bin/log show --last 1h --info --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "report"'
    ///
    /// Spell out `/usr/bin/log` — zsh has a `log` builtin that shadows it.
    public static let report = Logger(subsystem: subsystem, category: "report")

    /// The AI layer (§7, §8).
    ///
    /// Its own category so an AI call can be found without reading every `app`
    /// line, and because §8 governs this output specifically: metadata only —
    /// token counts, latency, model — and never a prompt or a draft. Everything
    /// written here goes through `AIMetricsLog.record`, which is the only
    /// emitter; there is no payload-logging path in this codebase to find.
    ///
    ///     /usr/bin/log show --last 1h --info --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "ai"'
    ///
    /// Spell out `/usr/bin/log` — zsh has a `log` builtin that shadows it. And
    /// `--info`, or `info`-level lines are filtered out and the command returns
    /// nothing at all.
    /// Named `aiLayer` rather than `ai` because SwiftLint's `identifier_name`
    /// rejects a two-character name. The *category* stays `ai` — it is what
    /// the `log show` predicate above matches on.
    public static let aiLayer = Logger(subsystem: subsystem, category: "ai")

    /// The source layer (§5).
    ///
    /// Its own category so a refresh pass can be found without reading every
    /// `app` line, and because §5.5's launch pass is deliberately invisible in the
    /// UI (D-176) — this is the only place it reports what it did:
    ///
    ///     /usr/bin/log show --last 1h --info --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "sources"'
    ///
    /// Spell out `/usr/bin/log` — zsh has a `log` builtin that shadows it. And
    /// `--info`, or `info`-level lines are filtered out and the command returns
    /// nothing at all.
    ///
    /// **Counts and connector ids only.** A ticket summary, a comment body and an
    /// assignee name are all external content about the user's work, which §8
    /// keeps out of the log; `SourceError` carries no free-form string so that
    /// this stays true by construction rather than by care at each call site.
    public static let sources = Logger(subsystem: subsystem, category: "sources")

    /// Intervals around the capture path.
    ///
    /// §1.1 makes capture latency a P0 functional requirement and §13 requires
    /// it measured rather than assumed. `CapturePerformanceTests` is the
    /// automated gate; this is how the same path is measured *in the running
    /// app*, where GUI automation is unavailable:
    ///
    ///     /usr/bin/log show --last 5m --signpost --predicate \
    ///       'subsystem == "com.lgabrielgr.steno" AND category == "capture"'
    ///
    /// Two things that recipe gets wrong if you shorten it. Spell out
    /// `/usr/bin/log` — zsh has a `log` builtin that shadows it and fails with
    /// "too many arguments". And `--signpost`, not `--info`: intervals are
    /// signpost records, so `--info` returns nothing at all.
    ///
    /// M1-03 and M1-04 must each show they did not regress it.
    public static let captureSignposter = OSSignposter(
        subsystem: subsystem, category: "capture")
}
