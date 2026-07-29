import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let transcriptIndexSchemaVersion = "chat-only-v2"

enum SQLiteStoreError: LocalizedError {
    case openFailed(code: Int32, message: String)
    case executionFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(_, let message),
             .executionFailed(_, let message),
             .prepareFailed(_, let message),
             .stepFailed(_, let message):
            return message
        }
    }

    var resultCode: Int32 {
        switch self {
        case .openFailed(let code, _),
             .executionFailed(let code, _),
             .prepareFailed(let code, _),
             .stepFailed(let code, _):
            return code
        }
    }

    var isTransientLockContention: Bool {
        SQLiteContentionPolicy.isTransientLock(code: resultCode)
    }
}

struct SQLiteErrorDetails {
    let code: Int32
    let message: String
}

enum SQLiteContentionPolicy {
    static let catalogBusyTimeoutMilliseconds: Int32 = 500
    static let externalReadBusyTimeoutMilliseconds: Int32 = 75
    static let externalReadRetryDelayNanoseconds: UInt64 = 50_000_000
    static let externalReadMaxAttempts = 3

    static func isTransientLock(code: Int32) -> Bool {
        switch code & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return true
        default:
            return false
        }
    }
}

func sqliteErrorDetails(
    for database: OpaquePointer?,
    defaultCode: Int32 = SQLITE_ERROR,
    fallbackMessage: String
) -> SQLiteErrorDetails {
    let code = database.map(sqlite3_extended_errcode) ?? defaultCode
    let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? fallbackMessage
    return SQLiteErrorDetails(code: code, message: message)
}

func withSQLiteContentionRetry<T>(
    maxAttempts: Int = SQLiteContentionPolicy.externalReadMaxAttempts,
    retryDelayNanoseconds: UInt64 = SQLiteContentionPolicy.externalReadRetryDelayNanoseconds,
    _ operation: () throws -> T
) throws -> T {
    precondition(maxAttempts > 0, "maxAttempts must be at least 1")

    var attempt = 0
    while true {
        do {
            return try operation()
        } catch let error as SQLiteStoreError where error.isTransientLockContention && attempt + 1 < maxAttempts {
            attempt += 1
            if retryDelayNanoseconds > 0 {
                Thread.sleep(forTimeInterval: TimeInterval(retryDelayNanoseconds) / 1_000_000_000)
            }
        } catch {
            throw error
        }
    }
}

public enum RefreshFailurePresentation {
    public static var busyDatabaseMessage: String {
        "Refresh skipped because a session database was busy. The catalog is still showing the previous successful snapshot."
    }

    public static func message(for error: Error) -> String? {
        if let sqliteError = error as? SQLiteStoreError, sqliteError.isTransientLockContention {
            return busyDatabaseMessage
        }

        let normalizedMessage = error.localizedDescription.lowercased()
        guard normalizedMessage.contains("database is locked")
            || normalizedMessage.contains("database table is locked")
            || normalizedMessage.contains("database is busy") else {
            return nil
        }
        return busyDatabaseMessage
    }
}

enum TranscriptIndexMode {
    case trigram
    case tokenPrefix
}

final class SQLiteSessionStore {
    private struct BulkWritePragmaSnapshot {
        let synchronous: Int32
        let cacheSize: Int32
    }

    private let databaseURL: URL
    private var database: OpaquePointer?
    private var transcriptIndexMode: TranscriptIndexMode = .tokenPrefix

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let openResult = sqlite3_open(databaseURL.path, &database)
        if openResult != SQLITE_OK {
            let details = sqliteErrorDetails(
                for: database,
                defaultCode: openResult,
                fallbackMessage: "Unknown SQLite open error for \(databaseURL.lastPathComponent)"
            )
            throw SQLiteStoreError.openFailed(code: details.code, message: details.message)
        }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, SQLiteContentionPolicy.catalogBusyTimeoutMilliseconds)

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
            throw prepareError()
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

    func fetchStarredSessionIDs() throws -> Set<String> {
        let sql = """
        SELECT session_id
        FROM session_preferences
        WHERE is_starred = 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        var sessionIDs: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let sessionID = string(from: statement, column: 0) {
                sessionIDs.insert(sessionID)
            }
        }

        return sessionIDs
    }

    func setSessionStarred(_ isStarred: Bool, for sessionID: String) throws {
        let sql: String
        if isStarred {
            sql = """
            INSERT INTO session_preferences (session_id, is_starred)
            VALUES (?, 1)
            ON CONFLICT(session_id) DO UPDATE SET is_starred = excluded.is_starred;
            """
        } else {
            sql = "DELETE FROM session_preferences WHERE session_id = ?;"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(sessionID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw stepError()
        }
    }

    func fetchExclusions() throws -> [SessionCatalogExclusion] {
        let sql = """
        SELECT kind, source, source_session_id, project_name, branch, created_at
        FROM catalog_exclusions
        ORDER BY kind ASC, project_name ASC, branch ASC, source_session_id ASC;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        var exclusions: [SessionCatalogExclusion] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawKind = string(from: statement, column: 0),
                  let kind = SessionCatalogExclusionKind(rawValue: rawKind) else {
                continue
            }

            exclusions.append(
                SessionCatalogExclusion(
                    kind: kind,
                    source: string(from: statement, column: 1).flatMap(SessionSource.init(rawValue:)),
                    sourceSessionId: string(from: statement, column: 2),
                    projectName: string(from: statement, column: 3),
                    branch: string(from: statement, column: 4),
                    createdAt: ISO8601DateCoding.parse(string(from: statement, column: 5)) ?? .distantPast
                )
            )
        }

        return exclusions
    }

    func upsertExclusion(_ exclusion: SessionCatalogExclusion) throws {
        let sql = """
        INSERT INTO catalog_exclusions (
            id,
            kind,
            source,
            source_session_id,
            project_name,
            branch,
            created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind,
            source = excluded.source,
            source_session_id = excluded.source_session_id,
            project_name = excluded.project_name,
            branch = excluded.branch,
            created_at = excluded.created_at;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(exclusion.id, to: statement, index: 1)
        bind(exclusion.kind.rawValue, to: statement, index: 2)
        bind(exclusion.source?.rawValue, to: statement, index: 3)
        bind(exclusion.sourceSessionId, to: statement, index: 4)
        bind(exclusion.projectName, to: statement, index: 5)
        bind(exclusion.branch, to: statement, index: 6)
        bind(ISO8601DateCoding.string(exclusion.createdAt), to: statement, index: 7)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw stepError()
        }
    }

    func removeExclusion(id: String) throws {
        try deleteRecords(withIDs: [id], from: "catalog_exclusions", idColumn: "id")
    }

    func updateTitle(for sessionID: String, newTitle: String) throws {
        let sql = "UPDATE sessions SET title = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(newTitle, to: statement, index: 1)
        bind(sessionID, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw stepError()
        }
    }

    func replaceAll(
        records: [SessionRecord],
        transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]
    ) throws {
        try withBulkWritePragmas {
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
    }

    func applyIncrementalUpdate(
        records: [SessionRecord],
        removedIDs: [String],
        transcriptEntriesBySessionID: [String: [TranscriptIndexEntry]] = [:]
    ) throws {
        if records.isEmpty, removedIDs.isEmpty {
            return
        }

        try withBulkWritePragmas {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let transcriptSessionIDs = Array(Set(removedIDs + transcriptEntriesBySessionID.keys))
                if !removedIDs.isEmpty {
                    try deleteRecords(withIDs: removedIDs, from: "sessions", idColumn: "id")
                }

                if !transcriptSessionIDs.isEmpty {
                    try deleteRecords(withIDs: transcriptSessionIDs, from: "transcript_entries", idColumn: "session_id")
                }
                try upsert(records: records)
                try insertTranscriptEntries(transcriptEntriesBySessionID)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func searchTranscriptEntries(
        sessionIDs: [String],
        query: String,
        scope: TranscriptSearchScope = .all
    ) throws -> [TranscriptIndexSearchHit] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, !sessionIDs.isEmpty else {
            return []
        }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
        let predicate: String?
        let sql: String
        let scopeFilter: String
        switch scope {
        case .all:
            scopeFilter = ""
        case .transcript:
            scopeFilter = "\n  AND entry_index >= 0"
        case .plan:
            scopeFilter = "\n  AND entry_index < 0"
        }
        switch transcriptIndexMode {
        case .trigram:
            predicate = escapeLikePattern(normalizedQuery)
            sql = """
            SELECT session_id, entry_index, entry_text
            FROM transcript_entries
            WHERE session_id IN (\(placeholders))
              AND entry_text LIKE '%' || ? || '%' ESCAPE '\\'
            \(scopeFilter)
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
            \(scopeFilter)
            ORDER BY session_id ASC, entry_index ASC;
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
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

    func indexedSessionIDs(for sessionIDs: [String]) throws -> Set<String> {
        guard !sessionIDs.isEmpty else {
            return []
        }

        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ", ")
        let sql = """
        SELECT DISTINCT session_id
        FROM transcript_entries
        WHERE session_id IN (\(placeholders));
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, sessionID) in sessionIDs.enumerated() {
            bind(sessionID, to: statement, index: Int32(index + 1))
        }

        var indexedIDs: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let sessionID = string(from: statement, column: 0) {
                indexedIDs.insert(sessionID)
            }
        }

        return indexedIDs
    }

    func removeSessions(withIDs sessionIDs: [String]) throws {
        guard !sessionIDs.isEmpty else { return }

        try withBulkWritePragmas {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try deleteRecords(withIDs: sessionIDs, from: "sessions", idColumn: "id")
                try deleteRecords(withIDs: sessionIDs, from: "transcript_entries", idColumn: "session_id")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
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
        try execute(
            """
            CREATE TABLE IF NOT EXISTS catalog_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS session_preferences (
                session_id TEXT PRIMARY KEY,
                is_starred INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS catalog_exclusions (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                source TEXT,
                source_session_id TEXT,
                project_name TEXT,
                branch TEXT,
                created_at TEXT NOT NULL
            );
            """
        )
        try execute("CREATE INDEX IF NOT EXISTS catalog_exclusions_kind_idx ON catalog_exclusions(kind);")
        try execute("CREATE INDEX IF NOT EXISTS catalog_exclusions_project_idx ON catalog_exclusions(project_name);")

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
        try resetTranscriptIndexIfNeeded()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw executionError()
        }
    }

    private func withBulkWritePragmas<T>(_ body: () throws -> T) throws -> T {
        let snapshot = try BulkWritePragmaSnapshot(
            synchronous: pragmaInt32(named: "synchronous"),
            cacheSize: pragmaInt32(named: "cache_size")
        )

        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA cache_size = -32768;")

        do {
            let result = try body()
            try restoreBulkWritePragmas(snapshot)
            return result
        } catch {
            let operationError = error
            do {
                try restoreBulkWritePragmas(snapshot)
            } catch {
                throw SQLiteStoreError.executionFailed(
                    code: SQLITE_ERROR,
                    message: "Bulk write failed with: \(operationError.localizedDescription). Failed to restore SQLite PRAGMAs: \(error.localizedDescription)"
                )
            }
            throw operationError
        }
    }

    private func restoreBulkWritePragmas(_ snapshot: BulkWritePragmaSnapshot) throws {
        try execute("PRAGMA synchronous = \(snapshot.synchronous);")
        try execute("PRAGMA cache_size = \(snapshot.cacheSize);")
    }

    private func pragmaInt32(named name: String) throws -> Int32 {
        let sql = "PRAGMA \(name);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw stepError(fallbackMessage: "Failed to query PRAGMA \(name) for \(databaseURL.lastPathComponent)")
        }
        return sqlite3_column_int(statement, 0)
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
            throw prepareError()
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
                throw stepError()
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
            throw prepareError()
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
                    throw stepError()
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
            throw prepareError()
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
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(table, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return string(from: statement, column: 0)
    }

    private func metadataValue(forKey key: String) throws -> String? {
        let sql = "SELECT value FROM catalog_metadata WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return string(from: statement, column: 0)
    }

    private func setMetadataValue(_ value: String, forKey key: String) throws {
        let sql = """
        INSERT INTO catalog_metadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        bind(key, to: statement, index: 1)
        bind(value, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw stepError()
        }
    }

    private func resetTranscriptIndexIfNeeded() throws {
        let existingVersion = try metadataValue(forKey: "transcript_index_schema_version")
        guard existingVersion != transcriptIndexSchemaVersion else {
            return
        }
        try execute("DELETE FROM transcript_entries;")
        try setMetadataValue(transcriptIndexSchemaVersion, forKey: "transcript_index_schema_version")
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
            throw prepareError()
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in ids.enumerated() {
            bind(id, to: statement, index: Int32(index + 1))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw stepError()
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

    private func executionError(defaultCode: Int32 = SQLITE_ERROR, fallbackMessage: String? = nil) -> SQLiteStoreError {
        let details = lastErrorDetails(defaultCode: defaultCode, fallbackMessage: fallbackMessage)
        return SQLiteStoreError.executionFailed(code: details.code, message: details.message)
    }

    private func prepareError(defaultCode: Int32 = SQLITE_ERROR, fallbackMessage: String? = nil) -> SQLiteStoreError {
        let details = lastErrorDetails(defaultCode: defaultCode, fallbackMessage: fallbackMessage)
        return SQLiteStoreError.prepareFailed(code: details.code, message: details.message)
    }

    private func stepError(defaultCode: Int32 = SQLITE_ERROR, fallbackMessage: String? = nil) -> SQLiteStoreError {
        let details = lastErrorDetails(defaultCode: defaultCode, fallbackMessage: fallbackMessage)
        return SQLiteStoreError.stepFailed(code: details.code, message: details.message)
    }

    private func lastErrorDetails(defaultCode: Int32 = SQLITE_ERROR, fallbackMessage: String? = nil) -> SQLiteErrorDetails {
        sqliteErrorDetails(
            for: database,
            defaultCode: defaultCode,
            fallbackMessage: fallbackMessage ?? "Unknown SQLite error for \(databaseURL.lastPathComponent)"
        )
    }
}
