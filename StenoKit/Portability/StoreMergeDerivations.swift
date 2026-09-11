import Foundation

// The two fields §10.1 says to recompute rather than compare: a task's
// status group, and a project's stand-up clock. Split from `StoreMerge.swift`
// because they are the only rules with a source outside the record being
// merged — the event log and the report set — and because the file was over
// SwiftLint's length limit with them in it.

// MARK: - TaskItem: a derived status group, and a clock-governed remainder

extension StoreMerge {
    /// What the log says a task's status is, and why.
    private struct StatusResolution {
        let status: Status
        let statusChangedAt: Date
        let completedAt: Date?

        /// Set when the newest `statusChanged` event could not be read and the
        /// cached field was used instead.
        let unparsedEventID: UUID?
    }

    static func mergeTasks(
        _ local: [ExportedTask], _ incoming: [ExportedTask], events: [ExportedEvent]
    ) throws -> ([ExportedTask], [UUID]) {
        let mineByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let theirsByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        var merged: [ExportedTask] = []
        var unparsed: [UUID] = []

        for id in Set(mineByID.keys).union(theirsByID.keys) {
            let mine = mineByID[id]
            let theirs = theirsByID[id]
            let base = try resolveGovernedTask(mine, theirs)
            let resolved = try resolveStatus(mine: mine, theirs: theirs, id: id, events: events)
            if let unparsedID = resolved.unparsedEventID { unparsed.append(unparsedID) }

            merged.append(
                ExportedTask(
                    id: id, title: base.title, projectID: base.projectID, status: resolved.status,
                    createdAt: base.createdAt, statusChangedAt: resolved.statusChangedAt,
                    completedAt: resolved.completedAt, isArchived: base.isArchived,
                    modifiedAt: base.modifiedAt))
        }

        return (merged, unparsed.sorted { $0.uuidString < $1.uuidString })
    }

    /// §10.1's "later `modifiedAt` wins", applied to the whole record.
    ///
    /// §10.1 names only `title`, but there is exactly one `modifiedAt` per record
    /// and every mutator that touches a governed field stamps it — `rename`,
    /// `move`, `setArchived`. Resolving those fields independently would need
    /// clocks the model does not have. `setStatus` deliberately does not stamp
    /// `modifiedAt`, which is what makes the status group separable at all.
    private static func resolveGovernedTask(
        _ mine: ExportedTask?, _ theirs: ExportedTask?
    ) throws -> ExportedTask {
        switch (mine, theirs) {
        case (.some(let mine), .none):
            return mine
        case (.none, .some(let theirs)):
            return theirs
        case (.some(let mine), .some(let theirs)):
            guard mine.createdAt == theirs.createdAt else {
                throw ImportError.inconsistentRecord(
                    detail: "Task \"\(mine.title)\" was created at two different times.")
            }
            if theirs.modifiedAt > mine.modifiedAt { return theirs }
            if mine.modifiedAt > theirs.modifiedAt { return mine }
            // A tie on the governing clock means the two were last edited at the
            // same instant, so they must agree. Validating rather than assuming
            // is what makes returning `mine` commutative.
            guard mine.title == theirs.title, mine.projectID == theirs.projectID,
                mine.isArchived == theirs.isArchived
            else {
                throw ImportError.inconsistentRecord(
                    detail:
                        "Task \"\(mine.title)\" was edited differently at the same instant on "
                        + "both Macs.")
            }
            return mine
        case (.none, .none):
            throw ImportError.malformed(detail: "A task id appeared with no record behind it.")
        }
    }

    /// §10.1: derive from the newest `statusChanged` event across **both** sets.
    ///
    /// All three fields come from one place, so they cannot disagree with each
    /// other, and the arithmetic reproduces `TaskItem.setStatus` exactly —
    /// including a task that went done → todo → done, where `completedAt` must
    /// be the latest completion and not the first.
    private static func resolveStatus(
        mine: ExportedTask?, theirs: ExportedTask?, id: UUID, events: [ExportedEvent]
    ) throws -> StatusResolution {
        // Redacted events count. §3.3 makes `isRedacted` a visibility flag —
        // "hidden from summaries; row retained" — and a status cache is not a
        // summary. Excluding them would let a redaction silently revert a task's
        // status, which is a mutation of the log by the back door.
        let newest =
            events
            .filter { $0.taskID == id && $0.kind == .statusChanged }
            .max { lhs, rhs in
                (ExportDocument.wireString(lhs.timestamp), lhs.id.uuidString)
                    < (ExportDocument.wireString(rhs.timestamp), rhs.id.uuidString)
            }

        guard let newest else {
            // The task never transitioned, so there is nothing in the log to
            // derive from and the field's own clock is the best available.
            return try cachedStatus(mine: mine, theirs: theirs, unparsedEventID: nil)
        }
        guard let transition = StatusTransition(eventBody: newest.body) else {
            return try cachedStatus(mine: mine, theirs: theirs, unparsedEventID: newest.id)
        }

        return StatusResolution(
            status: transition.into,
            statusChangedAt: newest.timestamp,
            completedAt: transition.into == .done ? newest.timestamp : nil,
            unparsedEventID: nil)
    }

    /// The fallback: later `statusChangedAt` wins on the cached field.
    private static func cachedStatus(
        mine: ExportedTask?, theirs: ExportedTask?, unparsedEventID: UUID?
    ) throws -> StatusResolution {
        let winner: ExportedTask
        switch (mine, theirs) {
        case (.some(let mine), .none):
            winner = mine
        case (.none, .some(let theirs)):
            winner = theirs
        case (.some(let mine), .some(let theirs)):
            if theirs.statusChangedAt > mine.statusChangedAt {
                winner = theirs
            } else if mine.statusChangedAt > theirs.statusChangedAt {
                winner = mine
            } else {
                guard mine.status == theirs.status, mine.completedAt == theirs.completedAt else {
                    throw ImportError.inconsistentRecord(
                        detail:
                            "Task \"\(mine.title)\" changed to two different statuses at the same "
                            + "instant, and the log does not say which.")
                }
                winner = mine
            }
        case (.none, .none):
            throw ImportError.malformed(detail: "A task id appeared with no record behind it.")
        }

        return StatusResolution(
            status: winner.status, statusChangedAt: winner.statusChangedAt,
            completedAt: winner.completedAt, unparsedEventID: unparsedEventID)
    }
}

// MARK: - Project: a derived clock, and a clock-governed remainder

extension StoreMerge {
    static func mergeProjects(
        _ local: [ExportedProject], _ incoming: [ExportedProject], reports: [ExportedReport]
    ) throws -> [ExportedProject] {
        let mineByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let theirsByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })

        return try Set(mineByID.keys).union(theirsByID.keys).map { id in
            let base = try resolveGovernedProject(mineByID[id], theirsByID[id])
            // Applied to every project in the union, including ones the incoming
            // file never mentions. For those the report set is unchanged, so by
            // the invariant `LastStandupClockTests` pins this is a no-op — and if
            // it is not, the local store was already inconsistent and this
            // repairs it. Applying it selectively would need a case analysis to
            // prove commutativity; applying it uniformly needs none.
            return ExportedProject(
                id: base.id, name: base.name, colorHex: base.colorHex,
                jiraProjectKeys: base.jiraProjectKeys, isArchived: base.isArchived,
                sortOrder: base.sortOrder,
                lastStandupAt: LastStandupClock.value(forProjectID: id, in: reports),
                reportCadence: base.reportCadence, staleThresholdDays: base.staleThresholdDays,
                modifiedAt: base.modifiedAt)
        }
    }

    private static func resolveGovernedProject(
        _ mine: ExportedProject?, _ theirs: ExportedProject?
    ) throws -> ExportedProject {
        switch (mine, theirs) {
        case (.some(let mine), .none):
            return mine
        case (.none, .some(let theirs)):
            return theirs
        case (.some(let mine), .some(let theirs)):
            if theirs.modifiedAt > mine.modifiedAt { return theirs }
            if mine.modifiedAt > theirs.modifiedAt { return mine }
            guard governedFieldsAgree(mine, theirs) else {
                throw ImportError.inconsistentRecord(
                    detail:
                        "Project \"\(mine.name)\" was edited differently at the same instant on "
                        + "both Macs.")
            }
            return mine
        case (.none, .none):
            throw ImportError.malformed(detail: "A project id appeared with no record behind it.")
        }
    }

    /// Everything `modifiedAt` governs. `lastStandupAt` is absent deliberately —
    /// it is derived, and `StandupUndoService` moves it without stamping.
    private static func governedFieldsAgree(
        _ mine: ExportedProject, _ theirs: ExportedProject
    ) -> Bool {
        mine.name == theirs.name && mine.colorHex == theirs.colorHex
            && mine.jiraProjectKeys == theirs.jiraProjectKeys
            && mine.isArchived == theirs.isArchived && mine.sortOrder == theirs.sortOrder
            && mine.reportCadence == theirs.reportCadence
            && mine.staleThresholdDays == theirs.staleThresholdDays
    }
}
