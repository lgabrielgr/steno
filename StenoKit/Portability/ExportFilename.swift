import Foundation

/// §10.2's filename: `steno-export-2026-08-11.json`.
public enum ExportFilename {
    /// The name for an export taken at `date`.
    ///
    /// **The date is local, not UTC.** A user who exports at 20:00 on the 11th
    /// in PDT should get the 11th; the name exists so a person can find the
    /// file, and one that disagrees with the day they remember is worse than no
    /// date at all. `exportedAt` inside the file stays UTC, which is where
    /// precision and comparability matter.
    ///
    /// An `ISO8601FormatStyle` reduced to its date components, rather than a
    /// `DateFormatter` with a format string: ISO-8601 is Gregorian and
    /// locale-independent by definition, so there is no locale or calendar left
    /// to get wrong — a `DateFormatter` under a non-Gregorian user calendar
    /// would quietly produce a different year.
    ///
    /// Collisions — two exports in one day, or a file already at the path —
    /// belong to whoever writes bytes: M2.5-03's save panel, M2.5-04's
    /// `--output`, M2.5-05's retention.
    public static func forDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let day = date.formatted(
            Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        return "steno-export-\(day).json"
    }
}
