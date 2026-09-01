import Foundation
import GRDB

extension MailStore {
    /// Opens the first live generation for a folder, or returns the existing live
    /// generation when `uidValidity` matches. A changed UIDVALIDITY must go through
    /// `createReplacementGeneration`.
    public func openLiveGeneration(
        folder: FolderID,
        uidValidity: UInt32,
        baselineUID: IMAPUID?
    ) async throws -> MailboxGeneration {
        try await write { db in
            _ = try MailStore.requireActiveFolder(db, folder)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT id, uid_validity FROM generations WHERE folder_id = ? AND state = ?",
                arguments: [folder.rawValue, GenerationState.live.rawValue]
            ) {
                let existingUV: Int64 = existing["uid_validity"]
                if existingUV != Int64(uidValidity) {
                    throw MailStoreError.uidValidityMismatch
                }
                return MailboxGeneration(folder: folder, uidValidity: uidValidity)
            }
            if let existingID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM generations WHERE folder_id = ? AND uid_validity = ?",
                arguments: [folder.rawValue, Int64(uidValidity)]
            ) {
                try db.execute(
                    sql: "UPDATE generations SET state = ? WHERE id = ?",
                    arguments: [GenerationState.live.rawValue, existingID]
                )
                try db.execute(
                    sql: "UPDATE folders SET live_generation_id = ? WHERE id = ?",
                    arguments: [existingID, folder.rawValue]
                )
                return MailboxGeneration(folder: folder, uidValidity: uidValidity)
            }
            try MailStore.insertGeneration(
                db,
                folder: folder,
                uidValidity: uidValidity,
                state: .live,
                baselineUID: baselineUID,
                makeLive: true
            )
            return MailboxGeneration(folder: folder, uidValidity: uidValidity)
        }
    }

    /// Starts a replacement generation. The live snapshot stays readable until
    /// `activateReplacementGeneration` switches the folder pointer atomically.
    public func createReplacementGeneration(
        folder: FolderID,
        uidValidity: UInt32,
        baselineUID: IMAPUID?
    ) async throws -> MailboxGeneration {
        try await write { db in
            _ = try MailStore.requireActiveFolder(db, folder)
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT id, uid_validity FROM generations WHERE folder_id = ? AND state = ?",
                arguments: [folder.rawValue, GenerationState.replacement.rawValue]
            ) {
                let existingUV: Int64 = existing["uid_validity"]
                if existingUV == Int64(uidValidity) {
                    return MailboxGeneration(folder: folder, uidValidity: uidValidity)
                }
                // A later UIDVALIDITY bump abandons the in-progress replacement.
                let existingID: Int64 = existing["id"]
                try db.execute(
                    sql: "UPDATE generations SET state = ? WHERE id = ?",
                    arguments: [GenerationState.retiring.rawValue, existingID]
                )
            }
            if try Int.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM generations WHERE folder_id = ? AND uid_validity = ?)",
                arguments: [folder.rawValue, Int64(uidValidity)]
            ) == 1 {
                throw MailStoreError.replacementAlreadyExists
            }
            try MailStore.insertGeneration(
                db,
                folder: folder,
                uidValidity: uidValidity,
                state: .replacement,
                baselineUID: baselineUID,
                makeLive: false
            )
            return MailboxGeneration(folder: folder, uidValidity: uidValidity)
        }
    }

    /// Atomically: old live → retiring, replacement → live, folder pointer swap,
    /// stale seen-queue ops for the prior UIDVALIDITY dropped.
    public func activateReplacementGeneration(folder: FolderID) async throws {
        try await write { db in
            let folderRow = try MailStore.requireActiveFolder(db, folder)
            guard let replacementID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM generations WHERE folder_id = ? AND state = ?",
                arguments: [folder.rawValue, GenerationState.replacement.rawValue]
            ) else {
                throw MailStoreError.noReplacementGeneration
            }
            let liveID: Int64? = folderRow["live_generation_id"]
            if let liveID, liveID != replacementID {
                try db.execute(
                    sql: "UPDATE generations SET state = ? WHERE id = ?",
                    arguments: [GenerationState.retiring.rawValue, liveID]
                )
            }
            try db.execute(
                sql: "UPDATE generations SET state = ? WHERE id = ?",
                arguments: [GenerationState.live.rawValue, replacementID]
            )
            try db.execute(
                sql: "UPDATE folders SET live_generation_id = ? WHERE id = ?",
                arguments: [replacementID, folder.rawValue]
            )
            try MailStore.dropStaleSeen(db, folder: folder)
        }
    }

    /// Deletes retired-generation messages (and their FTS rows via triggers) in
    /// bounded batches. Returns the number of message rows removed this call.
    public func cleanupRetiredGenerations(batchSize: Int = 200) async throws -> Int {
        let limit = max(1, batchSize)
        try Task.checkCancellation()
        return try await write { db in
            guard let genID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM generations WHERE state = ? ORDER BY id LIMIT 1",
                arguments: [GenerationState.retiring.rawValue]
            ) else {
                return 0
            }
            try db.execute(
                sql: """
                    DELETE FROM messages WHERE id IN (
                        SELECT id FROM messages WHERE generation_id = ? LIMIT ?
                    )
                    """,
                arguments: [genID, limit]
            )
            let deleted = db.changesCount
            let remaining = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE generation_id = ?",
                arguments: [genID]
            ) ?? 0
            if remaining == 0 {
                try db.execute(sql: "DELETE FROM generations WHERE id = ?", arguments: [genID])
            }
            return deleted
        }
    }

    public func liveGeneration(for folder: FolderID) async throws -> MailboxGeneration? {
        try await read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT g.uid_validity
                    FROM folders f
                    JOIN generations g ON g.id = f.live_generation_id
                    WHERE f.id = ?
                    """,
                arguments: [folder.rawValue]
            ) else { return nil }
            let uv: Int64 = row["uid_validity"]
            return MailboxGeneration(folder: folder, uidValidity: UInt32(uv))
        }
    }

    public func fetchSyncState(for generation: MailboxGeneration) async throws -> FolderSyncState? {
        try await read { db in
            guard let genID = try MailStore.generationID(db, generation) else { return nil }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM sync_state WHERE generation_id = ?",
                arguments: [genID]
            ) else { return nil }
            return MailStore.syncState(from: row, generation: generation)
        }
    }

    public func saveSyncState(_ state: FolderSyncState) async throws {
        try await write { db in
            let genID = try MailStore.requireGenerationID(db, state.generation)
            try db.execute(
                sql: """
                    INSERT INTO sync_state (
                        generation_id, delta_path, highest_modseq, backfill_phase,
                        low_water_uid, baseline_uid, progress, halted_through
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(generation_id) DO UPDATE SET
                        delta_path = excluded.delta_path,
                        highest_modseq = excluded.highest_modseq,
                        backfill_phase = excluded.backfill_phase,
                        low_water_uid = excluded.low_water_uid,
                        baseline_uid = excluded.baseline_uid,
                        progress = excluded.progress,
                        halted_through = excluded.halted_through
                    """,
                arguments: [
                    genID,
                    state.deltaPath.rawValue,
                    state.highestModseq.map { Int64(bitPattern: $0) },
                    state.backfillPhase.rawValue,
                    state.lowWaterUID.map { Int64($0.rawValue) },
                    state.baselineUID.map { Int64($0.rawValue) },
                    state.progress,
                    state.haltedThrough.map(\.timeIntervalSince1970),
                ]
            )
        }
    }

    static func insertGeneration(
        _ db: Database,
        folder: FolderID,
        uidValidity: UInt32,
        state: GenerationState,
        baselineUID: IMAPUID?,
        makeLive: Bool
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO generations (folder_id, uid_validity, state, created_at)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                folder.rawValue,
                Int64(uidValidity),
                state.rawValue,
                Date().timeIntervalSince1970,
            ]
        )
        let genID = db.lastInsertedRowID
        try db.execute(
            sql: """
                INSERT INTO sync_state (generation_id, delta_path, backfill_phase, baseline_uid)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                genID,
                DeltaPath.basic.rawValue,
                BackfillPhase.idle.rawValue,
                baselineUID.map { Int64($0.rawValue) },
            ]
        )
        if makeLive {
            try db.execute(
                sql: "UPDATE folders SET live_generation_id = ? WHERE id = ?",
                arguments: [genID, folder.rawValue]
            )
        }
    }

    static func generationID(_ db: Database, _ generation: MailboxGeneration) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM generations WHERE folder_id = ? AND uid_validity = ?",
            arguments: [generation.folder.rawValue, Int64(generation.uidValidity)]
        )
    }

    static func requireGenerationID(_ db: Database, _ generation: MailboxGeneration) throws -> Int64 {
        guard let id = try generationID(db, generation) else {
            throw MailStoreError.generationNotFound
        }
        return id
    }

    static func generationRow(_ db: Database, id: Int64) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM generations WHERE id = ?", arguments: [id]) else {
            throw MailStoreError.generationNotFound
        }
        return row
    }

    static func syncState(from row: Row, generation: MailboxGeneration) -> FolderSyncState {
        let modseq: Int64? = row["highest_modseq"]
        let low: Int64? = row["low_water_uid"]
        let baseline: Int64? = row["baseline_uid"]
        let halted: Double? = row["halted_through"]
        return FolderSyncState(
            generation: generation,
            deltaPath: DeltaPath(rawValue: row["delta_path"]) ?? .basic,
            highestModseq: modseq.map { UInt64(bitPattern: $0) },
            backfillPhase: BackfillPhase(rawValue: row["backfill_phase"]) ?? .idle,
            lowWaterUID: low.map { IMAPUID(rawValue: UInt32($0)) },
            baselineUID: baseline.map { IMAPUID(rawValue: UInt32($0)) },
            progress: row["progress"],
            haltedThrough: halted.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
