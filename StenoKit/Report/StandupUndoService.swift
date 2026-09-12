import Foundation
import OSLog
import SwiftData

/// FR-4.1's undo: the one place a stand-up is taken back.
///
/// A sibling of `StandupService`, not a method on it. That type's `init`
/// carries a clipboard seam undo has no use for, its own doc comment declares
/// it "the one place the stand-up clock advances", and D-044 records that the
/// two guard on different things — `StandupService` on project identity, this
/// on report recency. `NoteService.redact` is not an option either: it guards
/// on `EventKind.isUserAuthored`, which is `false` for `standupReported`, so it
/// refuses exactly the events FR-4.1 must redact and refuses by returning
/// `false` rather than throwing (D-044, D-045).
///
/// **No `now`, and no clipboard.** Undo reads every timestamp it needs out of
/// the report being undone, so it has no clock to inject; and the markdown is
/// already in the user's paste buffer and may already be in Slack, so restoring
/// the previous clipboard contents is neither one of FR-4.1's three effects nor
/// something the store could verify.
@MainActor
public struct StandupUndoService {
    private let context: ModelContext
    /// Injected for `StandupService`'s reason: a real `ModelContext` cannot be
    /// made to fail its save on demand, and the rollback is the path that most
    /// needs a test.
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.save = save
    }

    /// The report `project` could undo right now, or `nil`.
    ///
    /// **One query answers both of FR-4.1's rules.** "Undo applies only to the
    /// most recent report" falls out of the sort and the limit — an older
    /// report is never the row returned. "And only while it is the most recent"
    /// falls out of that being evaluated here, at call time, rather than
    /// cached when the report was written. A report already undone yields
    /// `nil`, so undo is not itself undoable — matching `Event.redact()`, which
    /// is one-way by design and names this requirement as the reason there is
    /// no `unredact()`.
    ///
    /// **A `generatedAt` tie cannot be broken and does not need to be.**
    /// `SortDescriptor` has no secondary key available — `UUID` is not
    /// `Comparable`, the wall `EventQueries.timeline` documents for its own tie
    /// case — but two Copies stamped at the same instant are unreachable:
    /// `StandupDraftModel.canCopy` is `false` once `phase` leaves `.editing`,
    /// and a second report needs a second sheet.
    ///
    /// `throws` rather than returning `nil` on a failed fetch: this is the
    /// gate on whether an action is offered, and D-018's rule is that a failed
    /// read must never be presented as an empty store.
    public func undoableReport(for project: Project) throws -> StandupReport? {
        let projectID = project.id
        let descriptor = FetchDescriptor<StandupReport>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.generatedAt, order: .reverse)]
        )
        let reports = try context.fetch(descriptor)
        guard let newest = reports.first else { return nil }

        // **The tie-break is what M2.5-02 made necessary.** This used to take
        // `fetchLimit = 1` off a sort keyed only on `generatedAt`. On one machine
        // two reports cannot share that instant — `StandupService` stamps it from
        // one `now()` per Copy — but a merge unions the reports of two machines,
        // and two Macs can produce a report in the same millisecond. The sort
        // then has an unspecified order among equals, so *which* report Undo
        // offers would depend on store order, and the two machines could disagree
        // after converging on an identical record set.
        //
        // `uuidString` because `UUID` is not `Comparable`, and the same tie-break
        // D-092 uses for every exported array, so the two orders agree.
        let tied = reports.filter { $0.generatedAt == newest.generatedAt }
        let chosen = tied.min { $0.id.uuidString < $1.id.uuidString } ?? newest
        return chosen.isUndone ? nil : chosen
    }

    /// Reverse all three of Copy's store effects, atomically. Returns how many
    /// events were redacted.
    ///
    /// Steps 3–5 are field writes into a single `ModelContext` committed by a
    /// single `save`, so "a failure partway must not leave the clock restored
    /// with the events still live" is a property of the transaction boundary
    /// rather than of careful ordering — `StandupService.commit`'s argument.
    /// It binds harder here: the compensating write for a redaction would be an
    /// `unredact()` that §3.3 does not permit to exist.
    ///
    /// **`report` is passed in rather than resolved from `project`.** Resolving
    /// it here would be one fewer parameter and would turn "undo is unavailable
    /// once a newer report exists" from a refusal the caller can see into a
    /// silent substitution of a *different* report — reversing a window the
    /// user never asked about. The explicit pair also mirrors
    /// `commit(_:of:for:)`, so the two halves of FR-4 step 7 read alike.
    @discardableResult
    public func undo(_ report: StandupReport, for project: Project) throws -> Int {
        // 1. The pair must describe the same project. `StandupService.commit`
        //    guards its own pair, and `NoteService.correct` before it: a
        //    mismatch would restore one project's clock out of another
        //    project's window, which is what D16 forbids.
        guard report.projectID == project.id else {
            throw StandupUndoError.reportBelongsToAnotherProject
        }

        // 2. Recency, through the same query the UI gates on, so a menu item
        //    that went stale between a reload and a click cannot undo a report
        //    that has since stopped being the most recent. One comparison
        //    covers both refusals — a newer report exists, or this one is
        //    already undone — because the query folds them together.
        guard try undoableReport(for: project)?.id == report.id else {
            throw StandupUndoError.reportIsNoLongerUndoable
        }

        let events = try standupReportedEvents(of: report)

        // 3. The report is retained and marked, never deleted (§3.5, FR-4.1).
        report.markUndone()

        // 4. Redaction, never deletion (§3.3). There are no exceptions to this
        //    anywhere in the system and this is the feature that looks most
        //    like one.
        for event in events { event.redact() }

        // 5. The clock goes back to where Copy found it. §3.5 defines
        //    `windowStart` as the previous `lastStandupAt`, so no separate
        //    "previous value" field is needed — and D-067's clamp is what makes
        //    this safe, because a report can never carry a `windowStart` later
        //    than its own `windowEnd`.
        //
        //    On a project's *first* report the pre-Copy value was `nil` and
        //    this restores a frozen "24h before Prepare ran" instead. That is
        //    the better of the two: restoring `nil` would make the next Prepare
        //    compute a *sliding* 24h window, silently losing everything between
        //    the original cutoff and the new one. A superset keeps FR-4.1's
        //    promise that undo loses nothing; a sliding window breaks it.
        project.lastStandupAt = report.windowStart

        // 6. One save for all of it. On failure the context returns to where it
        //    started and the caller is told nothing happened.
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }

        // 7. After the save, never before: an observer that reloads must not
        //    read a context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

        // A count, never event bodies — `ReportGatherer` logs dates and never
        // task content, for the same reason.
        Log.app.info("undid a stand-up, redacting \(events.count, privacy: .public) events")
        return events.count
    }

    /// The `standupReported` events this particular report appended.
    ///
    /// **The payload decides; the timestamp only narrows.** D-079 gave the
    /// events a `reportID` precisely so undo would not have to match on
    /// `timestamp == report.generatedAt` — which works today only because
    /// `StandupService` stamps both from one `now()`, a coincidence it is free
    /// to stop honouring, and whose loss would break undo silently. Neither
    /// `kind` nor `payload` is expressible in a `#Predicate`, so the fetch
    /// bounds and this filters.
    ///
    /// `windowEnd` rather than `generatedAt` as the bound, per D-066: the two
    /// are equal only by that same coincidence, and `windowEnd` is the earlier
    /// of them, so it stays correct if they ever diverge.
    private func standupReportedEvents(of report: StandupReport) throws -> [Event] {
        try context.fetch(EventQueries.notRedacted(atOrAfter: report.windowEnd))
            .filter {
                $0.kind == .standupReported
                    && StandupReportedPayload.decoded(from: $0.payload)?.reportID == report.id
            }
    }
}

/// Why an undo was refused before it wrote anything.
public enum StandupUndoError: Error, Equatable {
    /// The report and the project disagree — see `undo`'s first guard.
    case reportBelongsToAnotherProject

    /// A newer report exists for this project, or this one is already undone.
    /// FR-4.1: "once a newer report exists, the older window is history."
    case reportIsNoLongerUndoable
}
