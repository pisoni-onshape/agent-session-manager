import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case executionFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .executionFailed(let message),
             .prepareFailed(let message),
             .stepFailed(let message):
            return message
        }
    }
}

enum TranscriptIndexMode {
    case trigram
    case tokenPrefix
}

final class SQLiteSessionStore {
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var transcriptIndexMode: TranscriptIndexMode = .tokenPrefix

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if sqlite3_open(databaseURL.path, &database) != SQLITE_OK {
            throw SQLiteStoreError.openFailed(lastErrorMessage())
        }

        try execute("PRAGMA journal_mode = WAL;")
        try migrate()
    }

    deinit {
        sqlite3_close(database)
    }

    func fetchAll() throws -> [SessionRecord] {
        let sql = """
        SELECT
            source,
            source_session_id,
            workspace_path,
            project_name,
            branch,
            conversation_model,
            started_at,
            updated_at,
            title,
            summary,
            first_user_preview,
            first_assistant_preview,
            raw_transcript_path,
            raw_metadata_path,
            related_plan_path,
            fingerprint,
            resume_kind,
            resume_payload,
            is_newton_project
        FROM sessions
        ORDER BY
            COALESCE(updated_at, started_at, '') DESC,
            project_name ASC,
            title ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        var records: [SessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = SessionSource(rawValue: string(from: statement, column: 0) ?? ""),
                  let resumeKind = ResumeActionKind(rawValue: string(from: statement, column: 16) ?? "") else {
                continue
            }
            records.append(
                SessionRecord(
                    source: source,
                    sourceSessionId: string(from: statement, column: 1) ?? "",
                    workspacePath: string(from: statement, column: 2),
                    projectName: string(from: statement, column: 3) ?? "Unknown Project",
                    branch: string(from: statement, column: 4),
                    conversationModel: string(from: statement, column: 5),
                    startedAt: ISO8601DateCoding.parse(string(from: statement, column: 6)),
                    updatedAt: ISO8601DateCoding.parse(string(from: statement, column: 7)),
                    title: string(from: statement, column: 8) ?? "Untitled Session",
                    summary: string(from: statement, column: 9),
                    firstUserPreview: string(from: statement, column: 10),
                    firstAssistantPreview: string(from: statement, column: 11),
                    rawTranscriptPath: string(from: statement, column: 12),
                    rawMetadataPath: string(from: statement, column: 13),
                    relatedPlanPath: string(from: statement, column: 14),
                    fingerprint: string(from: statement, column: 15) ?? "",
                    resumeKind: resumeKind,
                    resumePayload: string(from: statement, column: 17) ?? "",
                    isNewtonProject: sqlite3_column_int(statement, 18) == 1
                )
            )
        }

        return records
    }

    func replaceAll(
        records: [SessionRecord],
        transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM sessions;")
            try execute("DELETE FROM transcript_entries;")
            try upsert(records: records)
            try insertTranscriptEntries(transcriptEntriesBySessionID)

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func applyIncrementalUpdate(
        records: [SessionRecord],
        removedIDs: [String],
        transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]
    ) throws {
        if records.isEmpty, removedIDs.isEmpty {
            return
        }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let changedIDs = records.map(\.id)
            if !removedIDs.isEmpty {
                try deleteRecords(withIDs: removedIDs, from: "sessions", idColumn: "id")
            }

            try deleteRecords(withIDs: removedIDs + changedIDs, from: "transcript_entries", idColumn: "session_id")
            try upsert(records: records)
            try insertTranscriptEntries(transcriptEntriesBySessionID)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func searchTranscriptEntries(sessionIDs: [String], query: String) throws -> [TranscriptIndexSearchHit] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !sessionIDs.isEmpty else {
            return []
        }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
        let predicate: String?
        let sql: String
        switch transcriptIndexMode {
        case .trigram:
            predicate = escapeLikePattern(normalizedQuery)
            sql = """
            SELECT session_id, entry_index, entry_text
            FROM transcript_entries
            WHERE session_id IN (\(placeholders))
              AND entry_text LIKE '%' || ? || '%' ESCAPE '\\'
            ORDER BY session_id ASC, entry_index ASC;
            """
        case .tokenPrefix:
            predicate = tokenizedFTSQuery(from: normalizedQuery)
            guard predicate != nil else {
                return []
            }
            sql = """
            SELECT session_id, entry_index, entry_text
            FROM transcript_entries
            WHERE session_id IN (\(placeholders))
              AND transcript_entries MATCH ?
            ORDER BY session_id ASC, entry_index ASC;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        for (index, sessionID) in sessionIDs.enumerated() {
            bind(sessionID, to: statement, index: Int32(index + 1))
        }
        bind(predicate, to: statement, index: Int32(sessionIDs.count + 1))

        var hits: [TranscriptIndexSearchHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionRecordID = string(from: statement, column: 0),
                  let text = string(from: statement, column: 2) else {
                continue
            }

            hits.append(
                TranscriptIndexSearchHit(
                    sessionRecordID: sessionRecordID,
                    entryIndex: Int(sqlite3_column_int(statement, 1)),
                    text: text
                )
            )
        }

        return hits
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                source_session_id TEXT NOT NULL,
                workspace_path TEXT,
                project_name TEXT NOT NULL,
                branch TEXT,
                conversation_model TEXT,
                started_at TEXT,
                updated_at TEXT,
                title TEXT NOT NULL,
                summary TEXT,
                first_user_preview TEXT,
                first_assistant_preview TEXT,
                raw_transcript_path TEXT,
                raw_metadata_path TEXT,
                related_plan_path TEXT,
                fingerprint TEXT,
                resume_kind TEXT NOT NULL,
                resume_payload TEXT NOT NULL,
                is_newton_project INTEGER NOT NULL
            );
            """
        )

        let columns = try existingColumnNames(in: "sessions")
        if !columns.contains("conversation_model") {
            try execute("ALTER TABLE sessions ADD COLUMN conversation_model TEXT;")
        }
        if !columns.contains("related_plan_path") {
            try execute("ALTER TABLE sessions ADD COLUMN related_plan_path TEXT;")
        }
        if !columns.contains("fingerprint") {
            try execute("ALTER TABLE sessions ADD COLUMN fingerprint TEXT;")
        }

        transcriptIndexMode = try ensureTranscriptIndex()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.executionFailed(lastErrorMessage())
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ value: Int, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func upsert(records: [SessionRecord]) throws {
        guard !records.isEmpty else { return }

        let insertSQL = """
        INSERT OR REPLACE INTO sessions (
            id,
            source,
            source_session_id,
            workspace_path,
            project_name,
            branch,
            conversation_model,
            started_at,
            updated_at,
            title,
            summary,
            first_user_preview,
            first_assistant_preview,
            raw_transcript_path,
            raw_metadata_path,
            related_plan_path,
            fingerprint,
            resume_kind,
            resume_payload,
            is_newton_project
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            bind(record.id, to: statement, index: 1)
            bind(record.source.rawValue, to: statement, index: 2)
            bind(record.sourceSessionId, to: statement, index: 3)
            bind(record.workspacePath, to: statement, index: 4)
            bind(record.projectName, to: statement, index: 5)
            bind(record.branch, to: statement, index: 6)
            bind(record.conversationModel, to: statement, index: 7)
            bind(ISO8601DateCoding.string(record.startedAt), to: statement, index: 8)
            bind(ISO8601DateCoding.string(record.updatedAt), to: statement, index: 9)
            bind(record.title, to: statement, index: 10)
            bind(record.summary, to: statement, index: 11)
            bind(record.firstUserPreview, to: statement, index: 12)
            bind(record.firstAssistantPreview, to: statement, index: 13)
            bind(record.rawTranscriptPath, to: statement, index: 14)
            bind(record.rawMetadataPath, to: statement, index: 15)
            bind(record.relatedPlanPath, to: statement, index: 16)
            bind(record.fingerprint, to: statement, index: 17)
            bind(record.resumeKind.rawValue, to: statement, index: 18)
            bind(record.resumePayload, to: statement, index: 19)
            sqlite3_bind_int(statement, 20, record.isNewtonProject ? 1 : 0)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteStoreError.stepFailed(lastErrorMessage())
            }
        }
    }

    private func insertTranscriptEntries(_ entriesBySessionID: [String: [TranscriptIndexEntry]]) throws {
        guard !entriesBySessionID.isEmpty else { return }

        let insertSQL = """
        INSERT INTO transcript_entries (
            session_id,
            entry_index,
            entry_text
        ) VALUES (?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        for entries in entriesBySessionID.values {
            for entry in entries {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)

                bind(entry.sessionRecordID, to: statement, index: 1)
                bind(entry.entryIndex, to: statement, index: 2)
                bind(entry.text, to: statement, index: 3)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteStoreError.stepFailed(lastErrorMessage())
                }
            }
        }
    }

    private func string(from statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private func existingColumnNames(in table: String) throws -> Set<String> {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let columnName = string(from: statement, column: 1) {
                columns.insert(columnName)
            }
        }
        return columns
    }

    private func existingVirtualTableSQL(named table: String) throws -> String? {
        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        bind(table, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return string(from: statement, column: 0)
    }

    private func ensureTranscriptIndex() throws -> TranscriptIndexMode {
        if let existingSQL = try existingVirtualTableSQL(named: "transcript_entries")?.lowercased() {
            if existingSQL.contains("tokenize='trigram'") || existingSQL.contains("tokenize=\"trigram\"") {
                return .trigram
            }
            return .tokenPrefix
        }

        do {
            try execute(
                """
                CREATE VIRTUAL TABLE transcript_entries USING fts5(
                    session_id UNINDEXED,
                    entry_index UNINDEXED,
                    entry_text,
                    tokenize='trigram'
                );
                """
            )
            return .trigram
        } catch {
            try execute(
                """
                CREATE VIRTUAL TABLE transcript_entries USING fts5(
                    session_id UNINDEXED,
                    entry_index UNINDEXED,
                    entry_text,
                    tokenize='unicode61 remove_diacritics 1',
                    prefix='2 3 4'
                );
                """
            )
            return .tokenPrefix
        }
    }

    private func deleteRecords(withIDs ids: [String], from table: String, idColumn: String) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let deleteSQL = "DELETE FROM \(table) WHERE \(idColumn) IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, deleteSQL, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in ids.enumerated() {
            bind(id, to: statement, index: Int32(index + 1))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(lastErrorMessage())
        }
    }

    private func tokenizedFTSQuery(from rawQuery: String) -> String? {
        let tokens = rawQuery
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !tokens.isEmpty else {
            return nil
        }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    private func escapeLikePattern(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func lastErrorMessage() -> String {
        if let error = sqlite3_errmsg(database) {
            return String(cString: error)
        }
        return "Unknown SQLite error for \(databaseURL.lastPathComponent)"
    }
}
