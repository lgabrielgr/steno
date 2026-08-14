import OSLog

/// Logging entry point.
///
/// The subsystem is fixed by REQUIREMENTS.md §9.1 and lives here so it is
/// written once. To watch a detached run (§9.2):
///
///     log stream --predicate 'subsystem == "com.lgabrielgr.steno"'
enum Log {
    static let subsystem = "com.lgabrielgr.steno"

    static let app = Logger(subsystem: subsystem, category: "app")
}
