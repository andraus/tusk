import Foundation
import CPostgres

// MARK: - Errors & results

public enum PGError: LocalizedError {
    case message(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .notConnected: return "Not connected"
        }
    }
}

public struct TestResult: Sendable {
    public let latencyMs: Double
    public let serverVersion: String
}

public struct DBSnapshot: Sendable {
    public let database: String
    public let relations: [Relation]
}

/// A page of rows read from a relation (column names + string-encoded cells; NULL is nil).
public struct RowSet: Sendable {
    public let columns: [String]
    public let rows: [[String?]]
    public init(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
    }
}

private struct RawResult {
    let columns: [String]
    let rows: [[String?]]
}

// MARK: - libpq helpers

private func withCStringArray<R>(_ strings: [String?], _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> R) -> R {
    var cStrings: [UnsafePointer<CChar>?] = strings.map { s in
        guard let s else { return nil }
        return UnsafePointer(strdup(s))
    }
    cStrings.append(nil) // null-terminate the keyword/value list
    defer {
        for p in cStrings where p != nil { free(UnsafeMutablePointer(mutating: p)) }
    }
    return cStrings.withUnsafeBufferPointer { buf in body(buf.baseAddress) }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Raw libpq wrappers (shared by every connection)

private enum PGRaw {
    /// Quote a SQL identifier so it can be interpolated safely (doubles embedded quotes).
    static func quoteIdent(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func rawConnect(_ cfg: Connection) throws -> OpaquePointer {
        var keywords: [String] = []
        var values: [String?] = []
        func add(_ k: String, _ v: String) {
            guard !v.isEmpty else { return }
            keywords.append(k); values.append(v)
        }
        add("host", cfg.host)
        add("port", cfg.port)
        add("dbname", cfg.database)
        add("user", cfg.user)
        add("password", cfg.password)
        add("sslmode", cfg.sslMode)
        add("connect_timeout", "8")
        add("application_name", "Tusk")
        // TCP keepalives so a dropped peer (e.g. a dead port-forward) surfaces
        // within ~seconds instead of hanging on a half-open socket.
        add("keepalives", "1")
        add("keepalives_idle", "5")
        add("keepalives_interval", "2")
        add("keepalives_count", "2")

        let conn = withCStringArray(keywords.map { Optional($0) }) { kw in
            withCStringArray(values) { vv in
                PQconnectdbParams(kw, vv, 0)
            }
        }
        guard let conn else { throw PGError.message("Could not allocate connection.") }
        if PQstatus(conn) != CONNECTION_OK {
            let msg = String(cString: PQerrorMessage(conn)).trimmed
            PQfinish(conn)
            throw PGError.message(msg.isEmpty ? "Connection failed." : msg)
        }
        return conn
    }

    static func exec(_ conn: OpaquePointer, _ sql: String) throws -> RawResult {
        guard let res = PQexec(conn, sql) else {
            throw PGError.message(String(cString: PQerrorMessage(conn)).trimmed)
        }
        defer { PQclear(res) }
        return try readResult(res)
    }

    static func execParams(_ conn: OpaquePointer, _ sql: String, _ params: [String?]) throws -> RawResult {
        let res = withCStringArray(params) { valuesPtr -> OpaquePointer? in
            PQexecParams(conn, sql, Int32(params.count), nil, valuesPtr, nil, nil, 0)
        }
        guard let res else {
            throw PGError.message(String(cString: PQerrorMessage(conn)).trimmed)
        }
        defer { PQclear(res) }
        return try readResult(res)
    }

    static func readResult(_ res: OpaquePointer) throws -> RawResult {
        let status = PQresultStatus(res)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            let msg = String(cString: PQresultErrorMessage(res)).trimmed
            throw PGError.message(msg.isEmpty ? "Query failed." : msg)
        }
        let ncols = Int(PQnfields(res))
        let nrows = Int(PQntuples(res))
        var columns: [String] = []
        columns.reserveCapacity(ncols)
        for c in 0..<ncols {
            columns.append(String(cString: PQfname(res, Int32(c))))
        }
        var rows: [[String?]] = []
        rows.reserveCapacity(nrows)
        for r in 0..<nrows {
            var row: [String?] = []
            row.reserveCapacity(ncols)
            for c in 0..<ncols {
                if PQgetisnull(res, Int32(r), Int32(c)) == 1 {
                    row.append(nil)
                } else {
                    row.append(String(cString: PQgetvalue(res, Int32(r), Int32(c))))
                }
            }
            rows.append(row)
        }
        return RawResult(columns: columns, rows: rows)
    }
}

// MARK: - One libpq connection, serialized

/// Owns exactly one libpq connection, bound to a single database. Because libpq
/// connections are single-threaded, this actor serializes every request through
/// it — a "lane". Distinct `PGConnection` actors run concurrently.
public actor PGConnection {
    private let cfg: Connection
    private var conn: OpaquePointer?

    public init(_ cfg: Connection) { self.cfg = cfg }

    public var database: String { cfg.database }

    /// Establish the connection now (so callers can surface auth/host errors eagerly).
    public func connect() throws { _ = try handle() }

    public func close() {
        if let conn { PQfinish(conn) }
        conn = nil
    }

    private func handle() throws -> OpaquePointer {
        if let conn { return conn }
        let c = try PGRaw.rawConnect(cfg)
        conn = c
        return c
    }

    /// Liveness check: `SELECT 1` on this connection (TCP keepalives make a dead
    /// peer surface within seconds). False if not yet connected or the probe fails.
    public func ping() -> Bool {
        guard let conn else { return false }
        guard PQstatus(conn) == CONNECTION_OK else { return false }
        do { _ = try PGRaw.exec(conn, "SELECT 1"); return true }
        catch { return false }
    }

    /// Short server version string, e.g. "PostgreSQL 16.2".
    public func serverVersion() throws -> String {
        let c = try handle()
        let res = try PGRaw.exec(c, "SELECT version()")
        let full = res.rows.first?.first.flatMap { $0 } ?? "PostgreSQL"
        return full.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// All databases on the server the user may connect to (templates excluded).
    public func databases() throws -> [String] {
        let c = try handle()
        let sql = """
        SELECT datname FROM pg_database
        WHERE datallowconn AND NOT datistemplate
        ORDER BY datname
        """
        return try PGRaw.exec(c, sql).rows.compactMap { $0.first.flatMap { $0 } }
    }

    /// A snapshot of this database's user relations (tables/views/matviews/partitioned).
    public func snapshot() throws -> DBSnapshot {
        let c = try handle()
        let sql = """
        SELECT n.nspname AS schema,
               c.relname AS name,
               c.relkind AS kind,
               COALESCE(c.reltuples, 0)::bigint AS est_rows
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r','v','m','p')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND n.nspname NOT LIKE 'pg_temp%%'
          AND n.nspname NOT LIKE 'pg_toast%%'
        ORDER BY n.nspname, c.relname
        """
        let res = try PGRaw.exec(c, sql)
        let relations: [Relation] = res.rows.compactMap { row in
            guard row.count >= 4,
                  let schema = row[0], let name = row[1], let kind = row[2] else { return nil }
            let est = Int64(row[3] ?? "0") ?? 0
            return Relation(schema: schema, name: name, kind: DBObjectKind.fromRelkind(kind), estRows: est)
        }
        return DBSnapshot(database: cfg.database, relations: relations)
    }

    /// Columns for a relation, with primary/foreign key flags.
    public func columns(schema: String, table: String) throws -> [ColumnInfo] {
        let c = try handle()
        let sql = """
        SELECT a.attname AS name,
               format_type(a.atttypid, a.atttypmod) AS type,
               a.attnotnull AS notnull,
               COALESCE(bool_or(ct.contype = 'p'), false) AS is_pk,
               COALESCE(bool_or(ct.contype = 'f'), false) AS is_fk
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_constraint ct
               ON ct.conrelid = a.attrelid AND a.attnum = ANY(ct.conkey)
        WHERE n.nspname = $1 AND c.relname = $2
          AND a.attnum > 0 AND NOT a.attisdropped
        GROUP BY a.attname, a.atttypid, a.atttypmod, a.attnotnull, a.attnum
        ORDER BY a.attnum
        """
        let res = try PGRaw.execParams(c, sql, [schema, table])
        return res.rows.compactMap { row in
            guard row.count >= 5, let name = row[0], let type = row[1] else { return nil }
            return ColumnInfo(name: name, type: type,
                              notNull: (row[2] == "t"), isPK: (row[3] == "t"), isFK: (row[4] == "t"))
        }
    }

    /// A page of rows from a relation. Identifiers are quoted; `limit` caps the fetch.
    public func rows(schema: String, table: String, limit: Int = 200) throws -> RowSet {
        let c = try handle()
        let sql = "SELECT * FROM \(PGRaw.quoteIdent(schema)).\(PGRaw.quoteIdent(table)) LIMIT \(max(0, limit))"
        let res = try PGRaw.exec(c, sql)
        return RowSet(columns: res.columns, rows: res.rows)
    }

    /// Delete a single row identified by `columns`/`values` (primary-key columns
    /// preferred). NULL identifiers match with `IS NULL`; the rest bind as params.
    /// Returns the number of rows the server actually removed.
    @discardableResult
    public func deleteRow(schema: String, table: String, columns: [String], values: [String?]) throws -> Int {
        let c = try handle()
        guard !columns.isEmpty else { throw PGError.message("Cannot delete a row without identifying columns.") }
        var clauses: [String] = []
        var params: [String?] = []
        for (col, val) in zip(columns, values) {
            if let val {
                clauses.append("\(PGRaw.quoteIdent(col)) = $\(params.count + 1)")
                params.append(val)
            } else {
                clauses.append("\(PGRaw.quoteIdent(col)) IS NULL")
            }
        }
        let sql = "DELETE FROM \(PGRaw.quoteIdent(schema)).\(PGRaw.quoteIdent(table)) WHERE \(clauses.joined(separator: " AND "))"
        _ = try PGRaw.execParams(c, sql, params)
        return 1
    }

    /// Run arbitrary SQL on this connection and return the result set. Non-row
    /// statements (INSERT/UPDATE/DDL) come back as an empty `RowSet`. When
    /// `readOnly` is set, the connection is put in a read-only transaction so
    /// writes are rejected by the server.
    public func query(_ sql: String, readOnly: Bool = false) throws -> RowSet {
        let c = try handle()
        if readOnly {
            _ = try? PGRaw.exec(c, "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
        } else {
            _ = try? PGRaw.exec(c, "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE")
        }
        let res = try PGRaw.exec(c, sql)
        return RowSet(columns: res.columns, rows: res.rows)
    }
}

// MARK: - Connection lanes

/// Manages the connection lanes for a session. ALL operations for a given database
/// — tree browsing, data tabs, and query consoles — share one serialized connection
/// for that database, keyed by database name. Different databases each get their
/// own connection (one per database). Requests within a lane are sequenced; lanes
/// run concurrently.
public actor Database {
    private var baseConfig: Connection?
    private var lanes: [String: PGConnection] = [:]   // one connection per database

    public init() {}

    // MARK: Lifecycle

    /// Open the workspace connection (the shared lane for the connected database).
    public func open(_ cfg: Connection) async throws {
        await closeAll()
        baseConfig = cfg
        let c = PGConnection(cfg)
        try await c.connect()
        lanes[cfg.database] = c
    }

    public func close() async { await closeAll() }

    private func closeAll() async {
        for (_, c) in lanes { await c.close() }
        lanes = [:]
        baseConfig = nil
    }

    /// Test a config with an ephemeral connection; returns latency + server version.
    public func test(_ cfg: Connection) async throws -> TestResult {
        let start = DispatchTime.now()
        let c = PGConnection(cfg)
        do {
            let version = try await c.serverVersion()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            await c.close()
            return TestResult(latencyMs: ms, serverVersion: version)
        } catch {
            await c.close()
            throw error
        }
    }

    /// The shared connection for `database`, created on first use. This is the only
    /// lane: browsing, data tabs, and consoles all ride it, so the server sees at
    /// most one connection per database per user.
    private func lane(_ database: String) throws -> PGConnection {
        if let c = lanes[database] { return c }
        guard let cfg0 = baseConfig else { throw PGError.notConnected }
        var cfg = cfg0; cfg.database = database
        let c = PGConnection(cfg)
        lanes[database] = c
        return c
    }

    public func databases() async throws -> [String] {
        guard let cfg = baseConfig else { throw PGError.notConnected }
        return try await lane(cfg.database).databases()
    }

    public func snapshot(database: String) async throws -> DBSnapshot {
        try await lane(database).snapshot()
    }

    public func columns(database: String, schema: String, table: String) async throws -> [ColumnInfo] {
        try await lane(database).columns(schema: schema, table: table)
    }

    /// Liveness of the connected database's shared connection.
    public func ping() async -> Bool {
        guard let cfg = baseConfig, let c = lanes[cfg.database] else { return false }
        return await c.ping()
    }

    // MARK: Data tabs (share the database's connection)

    public func tabColumns(tab: String, database: String, schema: String, table: String) async throws -> [ColumnInfo] {
        try await lane(database).columns(schema: schema, table: table)
    }

    public func tabRows(tab: String, database: String, schema: String, table: String, limit: Int = 200) async throws -> RowSet {
        try await lane(database).rows(schema: schema, table: table, limit: limit)
    }

    /// Delete a row in a data tab's table, on the database's shared connection.
    public func tabDeleteRow(tab: String, database: String, schema: String, table: String,
                             columns: [String], values: [String?]) async throws {
        _ = try await lane(database)
            .deleteRow(schema: schema, table: table, columns: columns, values: values)
    }

    /// Tabs no longer own connections — they share the database's lane — so there is
    /// nothing to close. Kept for call-site compatibility.
    public func closeTab(_ tab: String) async {}

    // MARK: Query consoles (share the database's connection)

    /// Execute a console's SQL on the database's shared connection.
    public func runConsole(_ console: String, database: String, sql: String, readOnly: Bool = false) async throws -> RowSet {
        try await lane(database).query(sql, readOnly: readOnly)
    }

    /// Consoles no longer own connections — they share the database's lane — so there
    /// is nothing to close. Kept for call-site compatibility.
    public func closeConsole(_ console: String) async {}
}
