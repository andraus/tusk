import Foundation
import TuskCore

// MARK: - Query console model

/// A SQL query console open in the center pane. Its SQL buffer is the source of
/// truth in memory; a `.sql` file under `TuskPaths.consolesDir` is a durable
/// mirror so consoles survive relaunch. Each console runs on its own dedicated
/// connection lane (keyed by `id`) bound to `database`.
struct QueryConsole: Identifiable, Equatable {
    let id: String                 // UUID string; also the .sql filename stem
    let connectionId: String       // the connection this console belongs to
    let database: String           // database name the console runs against
    var title: String
    var sql: String

    // Latest run
    var columns: [String] = []
    var rows: [[String?]] = []
    var running: Bool = false
    var error: String? = nil
    var elapsedMs: Int? = nil
    var lastRunByClaude: Bool = false   // attribution: the last run was triggered over MCP
    var readOnly: Bool = false          // when set, the lane runs in a read-only transaction

    static func newID() -> String { UUID().uuidString }

    /// A short human title from the SQL, else "Query".
    static func deriveTitle(sql: String) -> String {
        let firstLine = sql.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "Query" }
        return String(firstLine.prefix(28))
    }
}

// MARK: - Workspace tab (a tab is either table data or a query console)

/// One tab in the center pane. `DataTab` (a table opened by double-click) and
/// `QueryConsole` are distinct value types; this enum lets them share the tab bar
/// without either pretending to be the other.
enum WorkspaceTab: Identifiable, Equatable {
    case data(DataTab)
    case console(QueryConsole)

    var id: String {
        switch self {
        case .data(let t): return t.id
        case .console(let c): return c.id
        }
    }

    var asConsole: QueryConsole? {
        if case .console(let c) = self { return c }
        return nil
    }

    var asData: DataTab? {
        if case .data(let t) = self { return t }
        return nil
    }
}

// MARK: - On-disk persistence

/// A restore-index entry describing one open console (its buffer lives in `<id>.sql`).
private struct PersistedColumnInfo: Codable {
    let name: String
    let type: String
    let notNull: Bool
    let isPK: Bool
    let isFK: Bool
}

private struct WorkspaceIndexEntry: Codable {
    let kind: String
    let id: String
    let connectionId: String
    let database: String

    var title: String?
    var readOnly: Bool?
    var columns: [String]?
    var rows: [[String?]]?
    var error: String?
    var elapsedMs: Int?
    var lastRunByClaude: Bool?

    var relationSchema: String?
    var relationName: String?
    var relationKind: String?
    var relationEstRows: Int64?
    var columnInfos: [PersistedColumnInfo]?
}

private struct WorkspaceIndex: Codable {
    var selected: String?
    var tabs: [WorkspaceIndexEntry]
}

// The pre-workspace format, retained so existing query tabs migrate on first launch.
private struct LegacyConsoleIndexEntry: Codable {
    let id: String
    let connectionId: String
    let database: String
    let title: String
    var readOnly: Bool = false
}

private struct LegacyConsoleIndex: Codable {
    var selected: String?
    var consoles: [LegacyConsoleIndexEntry] = []
}

/// File-backed persistence for query consoles. All I/O is best-effort: a failure
/// to write never blocks the console (it keeps working in memory this session),
/// it only forfeits restore — same posture as the MCP-socket start.
enum ConsoleStore {
    static var dir: URL { URL(fileURLWithPath: TuskPaths.consolesDir, isDirectory: true) }
    static func fileURL(id: String) -> URL { dir.appendingPathComponent("\(id).sql") }
    private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Write one console's SQL buffer to its `.sql` file.
    static func writeSQL(id: String, sql: String) {
        ensureDir()
        do { try sql.data(using: .utf8)?.write(to: fileURL(id: id), options: .atomic) }
        catch { NSLog("Tusk: couldn't persist console \(id): \(error.localizedDescription)") }
    }

    /// Remove a console's `.sql` file (on close).
    static func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(id: id))
    }

    /// Persist all open tabs, their latest data/results, order, and selection.
    static func writeIndex(tabs: [WorkspaceTab], selected: String?) {
        ensureDir()
        let entries = tabs.map { tab -> WorkspaceIndexEntry in
            switch tab {
            case .console(let c):
                return WorkspaceIndexEntry(
                    kind: "console", id: c.id, connectionId: c.connectionId, database: c.database,
                    title: c.title, readOnly: c.readOnly, columns: c.columns, rows: c.rows,
                    error: c.error, elapsedMs: c.elapsedMs, lastRunByClaude: c.lastRunByClaude
                )
            case .data(let t):
                return WorkspaceIndexEntry(
                    kind: "data", id: t.id, connectionId: t.connectionId, database: t.database,
                    columns: t.columns, rows: t.rows, error: t.error,
                    relationSchema: t.relation.schema, relationName: t.relation.name,
                    relationKind: t.relation.kind.rawValue, relationEstRows: t.relation.estRows,
                    columnInfos: t.columnInfos.map {
                        PersistedColumnInfo(name: $0.name, type: $0.type, notNull: $0.notNull,
                                            isPK: $0.isPK, isFK: $0.isFK)
                    }
                )
            }
        }
        let idx = WorkspaceIndex(
            selected: selected,
            tabs: entries
        )
        do { try JSONEncoder().encode(idx).write(to: indexURL, options: .atomic) }
        catch { NSLog("Tusk: couldn't persist workspace index: \(error.localizedDescription)") }
    }

    /// Restore tabs saved for one connection. Query buffers remain in their `.sql`
    /// files so upgrades from the original console-only format are lossless.
    static func restore(connectionId: String) -> (tabs: [WorkspaceTab], selected: String?) {
        guard let data = try? Data(contentsOf: indexURL) else { return ([], nil) }
        if let idx = try? JSONDecoder().decode(WorkspaceIndex.self, from: data) {
            let restored = idx.tabs.compactMap { entry -> WorkspaceTab? in
                guard entry.connectionId == connectionId else { return nil }
                if entry.kind == "console" {
                    let sql = (try? String(contentsOf: fileURL(id: entry.id), encoding: .utf8)) ?? ""
                    return .console(QueryConsole(
                        id: entry.id, connectionId: entry.connectionId, database: entry.database,
                        title: entry.title ?? QueryConsole.deriveTitle(sql: sql), sql: sql,
                        columns: entry.columns ?? [], rows: entry.rows ?? [], running: false,
                        error: entry.error, elapsedMs: entry.elapsedMs,
                        lastRunByClaude: entry.lastRunByClaude ?? false, readOnly: entry.readOnly ?? false
                    ))
                }
                guard entry.kind == "data", let schema = entry.relationSchema,
                      let name = entry.relationName else { return nil }
                let relation = Relation(
                    schema: schema, name: name,
                    kind: DBObjectKind(rawValue: entry.relationKind ?? "") ?? .table,
                    estRows: entry.relationEstRows ?? 0
                )
                return .data(DataTab(
                    id: entry.id, connectionId: entry.connectionId, database: entry.database,
                    relation: relation, columns: entry.columns ?? [],
                    columnInfos: (entry.columnInfos ?? []).map {
                        ColumnInfo(name: $0.name, type: $0.type, notNull: $0.notNull,
                                   isPK: $0.isPK, isFK: $0.isFK)
                    },
                    rows: entry.rows ?? [], loading: false, error: entry.error
                ))
            }
            let selected = restored.contains(where: { $0.id == idx.selected }) ? idx.selected : restored.first?.id
            return (restored, selected)
        }

        guard let idx = try? JSONDecoder().decode(LegacyConsoleIndex.self, from: data) else {
            return ([], nil)
        }
        var restored: [WorkspaceTab] = []
        for entry in idx.consoles where entry.connectionId == connectionId {
            let sql = (try? String(contentsOf: fileURL(id: entry.id), encoding: .utf8)) ?? ""
            restored.append(.console(QueryConsole(id: entry.id, connectionId: entry.connectionId,
                                                   database: entry.database, title: entry.title,
                                                   sql: sql, readOnly: entry.readOnly)))
        }
        let selected = restored.contains(where: { $0.id == idx.selected }) ? idx.selected : restored.first?.id
        return (restored, selected)
    }
}
