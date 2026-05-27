import Foundation
import SQLite3

// SQLite C 宏在 Swift 里拿不到，按惯例自己定义。
// SQLITE_TRANSIENT 让 SQLite 内部复制 bind 的字符串/数据，避免 Swift 字符串生命周期问题。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 持有一个 SQLite 连接 + FTS5 虚拟表。所有访问通过 actor 序列化。
actor SearchIndex {

    // MARK: - 公共数据类型

    struct RawHit {
        let projectId: String
        let sessionId: String
        let messageIndex: String
        let kind: String
        let toolName: String?
        let timestamp: Date?
        let snippet: String
        let bm25: Double  // 原始 FTS5 分（FTS5 里负的、绝对值小=更相关）
        let cwd: String?  // 来自 sessions 表 LEFT JOIN
    }

    struct FileFingerprint: Equatable {
        let mtime: Double
        let size: Int64
    }

    struct IndexRecord {
        let index: String
        let kind: String
        let toolName: String?
        let timestamp: Date?
        let text: String
    }

    struct SessionMeta {
        let sessionId: String
        let projectId: String
        let title: String
        let cwd: String?
        let userMessageCount: Int
        let startTime: Date?
        let lastModified: Date
        let isFavorite: Bool
        let tags: [String]
    }

    // MARK: - 生命周期

    private var db: OpaquePointer?
    private let dbPath: String

    init(dbPath: String) {
        self.dbPath = dbPath
        // 打开 + 建表全部内联在这里，避免在 init 里调用 actor-isolated 方法
        let parent = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true
        )
        var localDB: OpaquePointer?
        if sqlite3_open(dbPath, &localDB) != SQLITE_OK {
            print("[SearchIndex] open failed: \(localDB.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "?")")
            return
        }
        self.db = localDB
        sqlite3_exec(localDB, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(localDB, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(localDB, "PRAGMA temp_store=MEMORY", nil, nil, nil)
        var errPtr: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(localDB, Self.schemaSQL, nil, nil, &errPtr) != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "?"
            sqlite3_free(errPtr)
            print("[SearchIndex] schema error: \(msg)")
        }

        // 用 PRAGMA user_version 管 schema 版本，逐步升级。
        var vstmt: OpaquePointer?
        sqlite3_prepare_v2(localDB, "PRAGMA user_version", -1, &vstmt, nil)
        var v: Int32 = 0
        if sqlite3_step(vstmt) == SQLITE_ROW {
            v = sqlite3_column_int(vstmt, 0)
        }
        sqlite3_finalize(vstmt)

        if v < 1 {
            // schema v1：引入 sessions 表，清掉 indexed_files 强制重新索引
            sqlite3_exec(localDB, "DELETE FROM indexed_files", nil, nil, nil)
            print("[SearchIndex] migrated to schema v1")
        }
        if v < 2 {
            // schema v2：sessions 加 is_favorite + tags 列
            // fresh install 时 CREATE 已经包含这两列，ALTER 会失败，吞掉。
            sqlite3_exec(localDB,
                "ALTER TABLE sessions ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0",
                nil, nil, nil
            )
            sqlite3_exec(localDB,
                "ALTER TABLE sessions ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
                nil, nil, nil
            )
            print("[SearchIndex] migrated to schema v2")
        }
        sqlite3_exec(localDB, "PRAGMA user_version = 2", nil, nil, nil)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // 注意 tokenizer：'porter unicode61 remove_diacritics 1'
    //   - unicode61: 按 Unicode 类别切分（标点/空白是分隔符）。
    //   - porter:    在 unicode61 之上做英文 Porter 词干提取（run, running → run）。
    //   - 已知限制: 中文字符默认被当成 "字母"，连续中文会变成一个大 token，
    //               所以中文子串搜索不工作（搜 "这个" 匹配不到 "这个是什么库"）。
    //               目前仅文档化此限制，等真正需要时再换 trigram 或加双索引。
    private static let schemaSQL: String = """
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY,
      project_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      message_index TEXT NOT NULL,
      kind TEXT NOT NULL,
      tool_name TEXT,
      timestamp REAL,
      text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);

    CREATE TABLE IF NOT EXISTS indexed_files (
      url TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      mtime REAL NOT NULL,
      size INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS sessions (
      session_id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL DEFAULT '',
      cwd TEXT,
      user_message_count INTEGER NOT NULL DEFAULT 0,
      start_time REAL,
      last_modified REAL NOT NULL,
      is_favorite INTEGER NOT NULL DEFAULT 0,
      tags TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS idx_sessions_project
      ON sessions(project_id, last_modified DESC);
    CREATE INDEX IF NOT EXISTS idx_sessions_favorite
      ON sessions(is_favorite) WHERE is_favorite = 1;

    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      text,
      content='messages',
      content_rowid='id',
      tokenize='porter unicode61 remove_diacritics 1'
    );

    CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
    END;
    """

    // MARK: - 读：文件指纹

    func fingerprint(for filePath: String) -> FileFingerprint? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "SELECT mtime, size FROM indexed_files WHERE url=?", -1, &stmt, nil
        ) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, filePath, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return FileFingerprint(
            mtime: sqlite3_column_double(stmt, 0),
            size: sqlite3_column_int64(stmt, 1)
        )
    }

    func totalMessageCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - 写：增量入索引

    func upsertSession(
        projectId: String,
        sessionId: String,
        filePath: String,
        fingerprint: FileFingerprint,
        records: [IndexRecord]
    ) {
        exec("BEGIN IMMEDIATE TRANSACTION")
        defer { exec("COMMIT") }

        // 删旧
        do {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(
                db, "DELETE FROM messages WHERE session_id=?", -1, &stmt, nil
            )
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // 插新
        var ins: OpaquePointer?
        let insertSQL = """
        INSERT INTO messages
          (project_id, session_id, message_index, kind, tool_name, timestamp, text)
        VALUES (?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK else {
            print("[SearchIndex] prepare insert failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        for r in records {
            sqlite3_reset(ins)
            sqlite3_bind_text(ins, 1, projectId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 2, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 3, r.index, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(ins, 4, r.kind, -1, SQLITE_TRANSIENT)
            if let tn = r.toolName {
                sqlite3_bind_text(ins, 5, tn, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(ins, 5)
            }
            if let ts = r.timestamp {
                sqlite3_bind_double(ins, 6, ts.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(ins, 6)
            }
            sqlite3_bind_text(ins, 7, r.text, -1, SQLITE_TRANSIENT)
            if sqlite3_step(ins) != SQLITE_DONE {
                print("[SearchIndex] insert step error: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(ins)

        // 记录文件指纹
        var fp: OpaquePointer?
        sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO indexed_files (url, project_id, session_id, mtime, size) VALUES (?,?,?,?,?)",
            -1, &fp, nil
        )
        sqlite3_bind_text(fp, 1, filePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(fp, 2, projectId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(fp, 3, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(fp, 4, fingerprint.mtime)
        sqlite3_bind_int64(fp, 5, fingerprint.size)
        sqlite3_step(fp)
        sqlite3_finalize(fp)
    }

    // MARK: - 查：FTS5 MATCH

    /// 直接把用户输入透传给 FTS5 MATCH。FTS5 语法：
    ///   - `foo bar`        → 隐式 AND
    ///   - `"foo bar"`      → 短语
    ///   - `foo OR bar`     → 或
    ///   - `foo NOT bar`    → 非
    ///   - `foo*`           → 前缀
    ///   - `NEAR(foo bar, 5)` → 邻近
    /// 若语法错误，返回空数组并打印错误。
    func rawSearch(_ query: String, limit: Int = 500) -> [RawHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let sql = """
        SELECT m.project_id, m.session_id, m.message_index, m.kind, m.tool_name, m.timestamp,
               snippet(messages_fts, 0, '⟦', '⟧', '…', 32),
               bm25(messages_fts),
               s.cwd
        FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid
        LEFT JOIN sessions s ON s.session_id = m.session_id
        WHERE messages_fts MATCH ?
        ORDER BY bm25(messages_fts)
        LIMIT ?
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[SearchIndex] prepare search failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [RawHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let projectId = String(cString: sqlite3_column_text(stmt, 0))
            let sessionId = String(cString: sqlite3_column_text(stmt, 1))
            let messageIndex = String(cString: sqlite3_column_text(stmt, 2))
            let kind = String(cString: sqlite3_column_text(stmt, 3))
            let toolName: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 4))
            let timestamp: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let snippet = String(cString: sqlite3_column_text(stmt, 6))
            let bm25 = sqlite3_column_double(stmt, 7)
            let cwd: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : String(cString: sqlite3_column_text(stmt, 8))
            out.append(RawHit(
                projectId: projectId,
                sessionId: sessionId,
                messageIndex: messageIndex,
                kind: kind,
                toolName: toolName,
                timestamp: timestamp,
                snippet: snippet,
                bm25: bm25,
                cwd: cwd
            ))
        }
        return out
    }

    // MARK: - 会话元数据

    func upsertSessionMeta(_ meta: SessionMeta) {
        let sql = """
        INSERT INTO sessions
          (session_id, project_id, title, cwd, user_message_count, start_time, last_modified)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET
          project_id = excluded.project_id,
          title = excluded.title,
          cwd = excluded.cwd,
          user_message_count = excluded.user_message_count,
          start_time = excluded.start_time,
          last_modified = excluded.last_modified
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[SearchIndex] prepare upsertSessionMeta failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        sqlite3_bind_text(stmt, 1, meta.sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, meta.projectId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, meta.title, -1, SQLITE_TRANSIENT)
        if let cwd = meta.cwd {
            sqlite3_bind_text(stmt, 4, cwd, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, Int64(meta.userMessageCount))
        if let st = meta.startTime {
            sqlite3_bind_double(stmt, 6, st.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, meta.lastModified.timeIntervalSince1970)
        if sqlite3_step(stmt) != SQLITE_DONE {
            print("[SearchIndex] upsertSessionMeta step error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static let sessionSelectColumns =
        "session_id, project_id, title, cwd, user_message_count, start_time, last_modified, is_favorite, tags"

    private func readSessionMeta(stmt: OpaquePointer?) -> SessionMeta {
        let sessionId = String(cString: sqlite3_column_text(stmt, 0))
        let pid = String(cString: sqlite3_column_text(stmt, 1))
        let title = String(cString: sqlite3_column_text(stmt, 2))
        let cwd: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let count = Int(sqlite3_column_int64(stmt, 4))
        let st: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let lm = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let fav = sqlite3_column_int(stmt, 7) != 0
        let tagsCSV = String(cString: sqlite3_column_text(stmt, 8))
        let tags = tagsCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return SessionMeta(
            sessionId: sessionId,
            projectId: pid,
            title: title,
            cwd: cwd,
            userMessageCount: count,
            startTime: st,
            lastModified: lm,
            isFavorite: fav,
            tags: tags
        )
    }

    func sessionsForProject(_ projectId: String) -> [SessionMeta] {
        let sql = """
        SELECT \(Self.sessionSelectColumns)
        FROM sessions
        WHERE project_id = ?
        ORDER BY last_modified DESC
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, projectId, -1, SQLITE_TRANSIENT)

        var out: [SessionMeta] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(readSessionMeta(stmt: stmt))
        }
        return out
    }

    func sessionMeta(sessionId: String) -> SessionMeta? {
        let sql = "SELECT \(Self.sessionSelectColumns) FROM sessions WHERE session_id = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSessionMeta(stmt: stmt)
    }

    // MARK: - 用户数据：收藏 + 标签

    func setFavorite(sessionId: String, isFavorite: Bool) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "UPDATE sessions SET is_favorite=? WHERE session_id=?", -1, &stmt, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
        sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    func setTags(sessionId: String, tags: [String]) {
        let csv = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db, "UPDATE sessions SET tags=? WHERE session_id=?", -1, &stmt, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, csv, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - 工具

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errPtr)
        if rc != SQLITE_OK {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errPtr)
            print("[SearchIndex] exec error: \(msg)\nSQL: \(sql.prefix(160))")
            return false
        }
        return true
    }

    private func err(_ where_: String) -> NSError {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no db"
        return NSError(
            domain: "SearchIndex",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "\(where_): \(msg)"]
        )
    }
}
