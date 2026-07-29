import SwiftUI
import TuskCore

/// One open table in the center pane. `id` is "connectionId|database|schema.name".
struct DataTab: Identifiable, Equatable {
    let id: String
    let connectionId: String
    let database: String
    let relation: Relation
    var columns: [String] = []
    var columnInfos: [ColumnInfo] = []      // for header type badges / key glyphs
    var rows: [[String?]] = []
    var loading: Bool = true
    var error: String? = nil

    /// Column metadata keyed by name (type badge + PK/FK glyphs in the grid header).
    func info(for column: String) -> ColumnInfo? { columnInfos.first { $0.name == column } }

    static func makeID(connectionId: String, database: String, relationID: String) -> String {
        "\(connectionId)|\(database)|\(relationID)"
    }
}

/// Everything scoped to one open (or opening) connection: its own libpq manager,
/// browsed database(s), loaded schema snapshots, and tree-expansion state. Tusk
/// holds one of these per *connected* connection, keyed by connection id in
/// `AppModel.sessions` — several may be live at once.
struct ConnState {
    var connection: Connection
    let db: Database
    var status: String = "connecting"          // connecting / connected / error
    var expanded: Bool = true                   // connection node open in the tree
    var databases: [String] = []
    var snapshots: [String: DBSnapshot] = [:]
    var expandedDatabases: Set<String> = []
    var loadingDatabases: Set<String> = []
    var databaseErrors: [String: String] = [:]
    var columnCache: [String: [ColumnInfo]] = [:]   // keyed "database|schema.table"
    var prefetchedColumnDBs: Set<String> = []
}

@MainActor
final class AppModel: ObservableObject {
    @Published var isDark: Bool = false

    // Live connections, keyed by connection id. A connection appears here only while
    // it is connecting/connected/errored; disconnected connections live in the
    // `ConnectionStore` alone and render in the tree straight from there.
    @Published var sessions: [String: ConnState] = [:]
    @Published var connectErrors: [String: String] = [:]     // last connect failure, per connection id
    private var healthTasks: [String: Task<Void, Never>] = [:]

    // Embedded Claude Code terminal (bottom-docked panel).
    @Published var showTerminal = false
    let terminal = TerminalController()

    func toggleTerminal() { showTerminal.toggle() }

    /// What the right-hand inspector rail is describing. Driven by single-clicks in the tree.
    enum Inspector: Equatable {
        case none
        case connection(String)                 // connection id
        case database(connId: String, name: String)
        case relation
    }
    @Published var inspector: Inspector = .none

    // Current selection across all connections (drives the inspector + query seeds).
    @Published var selectedConnectionId: String?
    @Published var selectedDatabase: String?
    @Published var selectedRelationID: String?      // "schema.name" within selectedDatabase
    @Published var columns: [ColumnInfo] = []       // selected relation's columns (inspector)
    @Published var loadingColumns = false

    // Open tabs shown in the center pane: table data (double-click) or query consoles.
    // A single global list mixing tabs from every connection — each tab carries its
    // own connection id.
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeTabID: String?

    private var persistTask: Task<Void, Never>?

    /// Set once at launch; lets the tree/modal enumerate all configured connections
    /// and the MCP provider reach any of them.
    weak var connectionStore: ConnectionStore?

    /// MCP server hosting Tusk's live connections over the app's unix socket.
    private var mcpServer: MCPSocketServer?
    private var servicesStarted = false

    private let connectedIdsKey = "tusk.connectedIds.v1"

    var palette: Palette { Palette(isDark: isDark) }

    func toggleTheme() { isDark.toggle() }

    // MARK: Session lookups

    func session(_ id: String) -> ConnState? { sessions[id] }
    func db(for id: String) -> Database? { sessions[id]?.db }
    func status(for id: String) -> String { sessions[id]?.status ?? "disconnected" }
    func isConnected(_ id: String) -> Bool { sessions[id]?.status == "connected" }
    var connectedCount: Int { sessions.values.filter { $0.status == "connected" }.count }

    /// The connection's config, whether it is live (session) or just saved (store).
    func connection(for id: String) -> Connection? {
        sessions[id]?.connection ?? connectionStore?.connections.first { $0.id == id }
    }

    /// Mutate one session in place (triggers SwiftUI updates via the `sessions` dict).
    private func mutate(_ id: String, _ f: (inout ConnState) -> Void) {
        guard var s = sessions[id] else { return }
        f(&s)
        sessions[id] = s
    }

    // MARK: App services

    /// Start the always-on services once (the MCP socket server). Safe to call repeatedly.
    func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        startMCPServer()
    }

    private func startMCPServer() {
        guard let store = connectionStore, mcpServer == nil else { return }
        let provider = AppTuskProvider(model: self, store: store)
        let server = MCPSocketServer(provider: provider)
        do {
            try server.start()
            mcpServer = server
        } catch {
            // Non-fatal: the GUI keeps working even if the socket can't be hosted.
            NSLog("Tusk: failed to start MCP server: \(error.localizedDescription)")
        }
    }

    /// Reconnect the connections that were open when the app last quit (only those
    /// with a saved keychain password can reconnect silently).
    func restoreSession(store: ConnectionStore) {
        let ids = (UserDefaults.standard.array(forKey: connectedIdsKey) as? [String]) ?? []
        for id in ids {
            guard let conn = store.connections.first(where: { $0.id == id }), conn.savePassword else { continue }
            connect(store.withPassword(conn))
        }
    }

    private func persistConnectedIds() {
        let ids = sessions.filter { $0.value.status == "connected" }.map { $0.key }
        UserDefaults.standard.set(ids, forKey: connectedIdsKey)
    }

    /// Probe a config with an ephemeral connection (the Manage modal's "Test").
    func testConnection(_ cfg: Connection) async throws -> TestResult {
        try await Database().test(cfg)
    }

    // MARK: Connect / disconnect

    /// Open `conn` as a new live session (keeping any other live connections). If it
    /// is already connecting/connected, just focus it.
    func connect(_ conn: Connection) {
        if let s = sessions[conn.id], s.status == "connected" || s.status == "connecting" {
            selectConnection(conn.id)
            return
        }
        let database = Database()
        sessions[conn.id] = ConnState(connection: conn, db: database, status: "connecting", expanded: true)
        connectErrors[conn.id] = nil
        Task {
            do {
                try await database.open(conn)
                let snap = try await database.snapshot(database: conn.database)
                mutate(conn.id) {
                    $0.status = "connected"
                    $0.databases = [conn.database]
                    $0.snapshots = [conn.database: snap]
                    $0.expandedDatabases = [conn.database]
                    $0.databaseErrors = [:]
                }
                selectedConnectionId = conn.id
                selectedDatabase = conn.database
                inspector = .connection(conn.id)
                restoreConsoles(for: conn.id)
                prefetchColumns(connId: conn.id, database: conn.database)
                startHealthMonitor(conn.id)
                persistConnectedIds()
            } catch {
                await database.close()
                sessions[conn.id] = nil
                connectErrors[conn.id] = error.localizedDescription
                persistConnectedIds()
            }
        }
    }

    /// Tear down one connection: persist + drop its consoles, close its lanes, remove
    /// its tabs, and forget the session. Other connections are untouched.
    func disconnect(_ connId: String) {
        guard let s = sessions[connId] else { return }
        healthTasks[connId]?.cancel()
        healthTasks[connId] = nil
        // Persist all consoles (incl. this connection's) so they restore on reconnect.
        flushConsolePersist()
        let db = s.db
        let removed = tabs.filter { $0.connectionId == connId }
        for t in removed {
            if t.asConsole != nil { Task { await db.closeConsole(t.id) } }
            else { Task { await db.closeTab(t.id) } }
        }
        tabs.removeAll { $0.connectionId == connId }
        Task { await db.close() }
        sessions[connId] = nil
        connectErrors[connId] = nil
        persistConnectedIds()

        if selectedConnectionId == connId {
            selectedConnectionId = nil
            selectedDatabase = nil
            selectedRelationID = nil
            columns = []
            inspector = .none
        }
        if let active = activeTabID, !tabs.contains(where: { $0.id == active }) {
            if let next = tabs.first { focusTab(next.id) } else { activeTabID = nil }
        }
    }

    /// Poll one connection's browse lane and reflect liveness in its session status.
    private func startHealthMonitor(_ id: String) {
        healthTasks[id]?.cancel()
        healthTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let db = self.sessions[id]?.db else { return }
                let ok = await db.ping()
                if Task.isCancelled { return }
                self.mutate(id) { $0.status = ok ? "connected" : "error" }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Refresh the loaded schema snapshots of every connected session.
    func refreshSchema() {
        for (id, s) in sessions where s.status == "connected" {
            let db = s.db
            let loaded = Array(s.snapshots.keys)
            Task {
                for d in loaded {
                    if let snap = try? await db.snapshot(database: d) {
                        mutate(id) { $0.snapshots[d] = snap }
                    }
                }
            }
        }
    }

    // MARK: Tree expansion

    /// Toggle a connection's top-level node (connected connections only).
    func toggleConnection(_ connId: String) {
        mutate(connId) { $0.expanded.toggle() }
    }

    /// Toggle a database node; load its schema on first expand.
    func toggleDatabase(_ connId: String, _ database: String) {
        guard let s = sessions[connId] else { return }
        if s.expandedDatabases.contains(database) {
            mutate(connId) { $0.expandedDatabases.remove(database) }
        } else {
            mutate(connId) { $0.expandedDatabases.insert(database) }
            loadDatabase(connId, database)
        }
    }

    private func loadDatabase(_ connId: String, _ database: String) {
        guard let s = sessions[connId], s.snapshots[database] == nil, !s.loadingDatabases.contains(database) else { return }
        let db = s.db
        mutate(connId) { $0.loadingDatabases.insert(database); $0.databaseErrors[database] = nil }
        Task {
            do {
                let snap = try await db.snapshot(database: database)
                mutate(connId) { $0.snapshots[database] = snap }
            } catch {
                mutate(connId) { $0.databaseErrors[database] = error.localizedDescription }
            }
            mutate(connId) { $0.loadingDatabases.remove(database) }
        }
    }

    // MARK: Inspector selection (single-click)

    /// Single-click a connection node: describe the connection in the inspector.
    func selectConnection(_ connId: String) {
        inspector = .connection(connId)
        selectedConnectionId = connId
        selectedRelationID = nil
    }

    /// Single-click a database node: describe the database (loading its snapshot for stats).
    func selectDatabase(_ connId: String, _ database: String) {
        inspector = .database(connId: connId, name: database)
        selectedConnectionId = connId
        selectedDatabase = database
        selectedRelationID = nil
        loadDatabase(connId, database)
    }

    /// Single-click a relation: describe it (its columns) in the inspector.
    func select(_ connId: String, database: String, relation: Relation) {
        inspector = .relation
        selectedConnectionId = connId
        selectedDatabase = database
        selectedRelationID = relation.id
        loadingColumns = true
        columns = []
        guard let db = sessions[connId]?.db else { loadingColumns = false; return }
        let token = selectionToken
        Task {
            do {
                let cols = try await db.columns(database: database, schema: relation.schema, table: relation.name)
                mutate(connId) { $0.columnCache["\(database)|\(relation.schema).\(relation.name)"] = cols }
                if selectionToken == token { columns = cols }
            } catch {
                if selectionToken == token { columns = [] }
            }
            loadingColumns = false
        }
    }

    // MARK: Table tabs (double-click)

    /// Double-click a relation: select it, and open (or focus) a data tab for it.
    func openTable(_ connId: String, database: String, relation: Relation) {
        select(connId, database: database, relation: relation)
        let id = DataTab.makeID(connectionId: connId, database: database, relationID: relation.id)
        activeTabID = id
        if tabs.contains(where: { $0.id == id }) { return }   // already open — just focus it
        tabs.append(.data(DataTab(id: id, connectionId: connId, database: database, relation: relation)))
        scheduleConsolePersist()
        loadRows(for: id, connId: connId, database: database, relation: relation)
    }

    /// Switch to an already-open tab and sync the inspector to its subject.
    func focusTab(_ id: String) {
        activeTabID = id
        switch tabs.first(where: { $0.id == id }) {
        case .data(let t):
            select(t.connectionId, database: t.database, relation: t.relation)
        case .console(let c):
            inspector = .database(connId: c.connectionId, name: c.database)
            selectedConnectionId = c.connectionId
            selectedDatabase = c.database
            selectedRelationID = nil
        case nil:
            break
        }
        scheduleConsolePersist()   // remember the selected console for restore
    }

    func closeTab(_ id: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        let connId = closing.connectionId
        tabs.remove(at: idx)
        if let db = sessions[connId]?.db {
            Task {
                if closing.asConsole != nil { await db.closeConsole(id) } else { await db.closeTab(id) }
            }
        }
        if closing.asConsole != nil { ConsoleStore.remove(id: id) }
        scheduleConsolePersist()
        if activeTabID == id {
            let next = tabs[safe: idx] ?? tabs[safe: idx - 1]
            if let next { focusTab(next.id) } else { activeTabID = nil }
        }
    }

    /// Reload the rows for a data tab (e.g. the toolbar refresh button).
    func reloadTab(_ id: String) {
        guard case .data(let tab)? = tabs.first(where: { $0.id == id }) else { return }
        loadRows(for: id, connId: tab.connectionId, database: tab.database, relation: tab.relation)
    }

    private func loadRows(for id: String, connId: String, database: String, relation: Relation) {
        guard let db = sessions[connId]?.db else { return }
        updateDataTab(id) { $0.loading = true; $0.error = nil; $0.columns = []; $0.rows = [] }
        Task {
            do {
                let cols = try await db.tabColumns(tab: id, database: database, schema: relation.schema, table: relation.name)
                let set = try await db.tabRows(tab: id, database: database, schema: relation.schema, table: relation.name, limit: 200)
                mutate(connId) { $0.columnCache["\(database)|\(relation.schema).\(relation.name)"] = cols }
                updateDataTab(id) {
                    $0.columnInfos = cols
                    $0.columns = set.columns
                    $0.rows = set.rows
                    $0.loading = false
                }
                scheduleConsolePersist()
            } catch {
                updateDataTab(id) { $0.error = error.localizedDescription; $0.loading = false }
                scheduleConsolePersist()
            }
        }
    }

    /// Delete row `rowIndex` from a data tab's table. Identifies the row by its
    /// primary-key columns when the table has one, else by all column values.
    /// On success the row is removed from the tab locally (optimistic).
    func deleteDataTabRow(_ id: String, rowIndex: Int) {
        guard case .data(let tab)? = tabs.first(where: { $0.id == id }),
              rowIndex >= 0, rowIndex < tab.rows.count,
              let db = sessions[tab.connectionId]?.db else { return }
        let row = tab.rows[rowIndex]

        let pkNames = tab.columnInfos.filter { $0.isPK }.map { $0.name }
        let keyColumns = pkNames.isEmpty ? tab.columns : pkNames
        var columns: [String] = []
        var values: [String?] = []
        for name in keyColumns {
            guard let idx = tab.columns.firstIndex(of: name), idx < row.count else { continue }
            columns.append(name)
            values.append(row[idx])
        }
        guard !columns.isEmpty else {
            updateDataTab(id) { $0.error = "Cannot delete: no primary key or columns to identify the row." }
            return
        }

        Task {
            do {
                try await db.tabDeleteRow(tab: id, database: tab.database,
                                          schema: tab.relation.schema, table: tab.relation.name,
                                          columns: columns, values: values)
                updateDataTab(id) {
                    if rowIndex < $0.rows.count, $0.rows[rowIndex] == row { $0.rows.remove(at: rowIndex) }
                    $0.error = nil
                }
                scheduleConsolePersist()
            } catch {
                updateDataTab(id) { $0.error = error.localizedDescription }
                scheduleConsolePersist()
            }
        }
    }

    /// Mutate a data tab in place if it still exists (it may have been closed mid-load).
    private func updateDataTab(_ id: String, _ mutate: (inout DataTab) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), case .data(var t) = tabs[idx] else { return }
        mutate(&t)
        tabs[idx] = .data(t)
    }

    /// Mutate a console in place if it still exists.
    private func updateConsole(_ id: String, _ mutate: (inout QueryConsole) -> Void) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), case .console(var c) = tabs[idx] else { return }
        mutate(&c)
        tabs[idx] = .console(c)
    }

    private var selectionToken: String {
        "\(selectedConnectionId ?? "")|\(selectedDatabase ?? "")|\(selectedRelationID ?? "")"
    }

    var activeTab: WorkspaceTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeConsole: QueryConsole? { activeTab?.asConsole }
    func console(_ id: String) -> QueryConsole? { tabs.first { $0.id == id }?.asConsole }
    var consoles: [QueryConsole] { tabs.compactMap { $0.asConsole } }

    // MARK: Query consoles

    /// Open a new query console bound to `database` on `connectionId` (defaulting to
    /// the selected connection). Seeds the buffer with `seedSQL` and focuses the tab.
    @discardableResult
    func openConsole(connectionId: String? = nil, database: String, seedSQL: String? = nil) -> String {
        let connId = connectionId ?? selectedConnectionId ?? ""
        let id = QueryConsole.newID()
        let sql = seedSQL ?? ""
        let console = QueryConsole(id: id, connectionId: connId, database: database,
                                   title: QueryConsole.deriveTitle(sql: sql), sql: sql)
        tabs.append(.console(console))
        activeTabID = id
        inspector = .database(connId: connId, name: database)
        selectedConnectionId = connId
        selectedDatabase = database
        selectedRelationID = nil
        ConsoleStore.writeSQL(id: id, sql: sql)
        flushConsolePersist()
        prefetchColumns(connId: connId, database: database)
        return id
    }

    /// Replace a console's SQL buffer (human keystrokes or an MCP edit). Updates the
    /// derived title and mirrors to disk (debounced).
    func setConsoleSQL(_ id: String, sql: String) {
        updateConsole(id) { $0.sql = sql; $0.title = QueryConsole.deriveTitle(sql: sql) }
        scheduleConsolePersist()
    }

    /// Toggle a console's read-only posture (writes rejected by the server).
    func setConsoleReadOnly(_ id: String, _ readOnly: Bool) {
        updateConsole(id) { $0.readOnly = readOnly }
        scheduleConsolePersist()
    }

    /// Run a console's SQL on its dedicated lane (UI Run button).
    func runConsole(_ id: String) {
        Task { await runConsoleAwait(id, byClaude: false) }
    }

    /// Run and await completion — used by MCP so it can return the results.
    func runConsoleAwait(_ id: String, byClaude: Bool) async {
        guard let c = console(id), let db = sessions[c.connectionId]?.db else { return }
        updateConsole(id) { $0.running = true; $0.error = nil; $0.lastRunByClaude = byClaude }
        let start = DispatchTime.now()
        do {
            let set = try await db.runConsole(id, database: c.database, sql: c.sql, readOnly: c.readOnly)
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            updateConsole(id) {
                $0.columns = set.columns; $0.rows = set.rows
                $0.running = false; $0.error = nil; $0.elapsedMs = ms
            }
            scheduleConsolePersist()
        } catch {
            updateConsole(id) { $0.running = false; $0.error = error.localizedDescription; $0.elapsedMs = nil }
            scheduleConsolePersist()
        }
    }

    /// The schema data a console completes against, for `database` on `connId`.
    func schemaIndex(connId: String, database: String) -> SchemaIndex {
        var idx = SchemaIndex()
        guard let s = sessions[connId] else { return idx }
        if let snap = s.snapshots[database] {
            idx.tables = snap.relations.map { .init(name: $0.name, schema: $0.schema, kind: $0.kind.rawValue) }
        }
        for (key, cols) in s.columnCache where key.hasPrefix("\(database)|") {
            let qualified = String(key.dropFirst(database.count + 1))   // "schema.table"
            let mapped = cols.map { SchemaIndex.Col(name: $0.name, type: $0.type, pk: $0.isPK, fk: $0.isFK) }
            idx.columnsByTable[qualified.lowercased()] = mapped
            if let dot = qualified.firstIndex(of: ".") {
                let bare = String(qualified[qualified.index(after: dot)...])
                idx.columnsByTable[bare.lowercased()] = mapped
            }
        }
        return idx
    }

    /// Warm the column cache for a database (background) so dot-completion works.
    private func prefetchColumns(connId: String, database: String) {
        guard let s = sessions[connId], !s.prefetchedColumnDBs.contains(database),
              let snap = s.snapshots[database] else { return }
        let db = s.db
        mutate(connId) { $0.prefetchedColumnDBs.insert(database) }
        let targets = Array(snap.relations.prefix(150))   // cap: huge schemas load lazily via selection
        Task {
            for rel in targets {
                let key = "\(database)|\(rel.schema).\(rel.name)"
                if sessions[connId]?.columnCache[key] != nil { continue }
                if let cols = try? await db.columns(database: database, schema: rel.schema, table: rel.name) {
                    mutate(connId) { $0.columnCache[key] = cols }
                }
            }
        }
    }

    // MARK: Console persistence (write-through, debounced)

    private func scheduleConsolePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushConsolePersist()
        }
    }

    private func flushConsolePersist() {
        let cs = consoles
        for c in cs { ConsoleStore.writeSQL(id: c.id, sql: c.sql) }
        ConsoleStore.writeIndex(tabs: tabs, selected: activeTabID)
    }

    private func restoreConsoles(for connectionId: String) {
        let (restored, selected) = ConsoleStore.restore(connectionId: connectionId)
        guard !restored.isEmpty else { return }
        for tab in restored where !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        if activeTabID == nil, let selected { activeTabID = selected }
    }

    // MARK: Selection helpers

    var selectedSession: ConnState? { selectedConnectionId.flatMap { sessions[$0] } }

    var selectedSnapshot: DBSnapshot? {
        guard let d = selectedDatabase, let s = selectedSession else { return nil }
        return s.snapshots[d]
    }

    var selectedRelation: Relation? {
        selectedSnapshot?.relations.first { $0.id == selectedRelationID }
    }
}

extension WorkspaceTab {
    /// The connection a tab belongs to (every tab is connection-scoped).
    var connectionId: String {
        switch self {
        case .data(let t): return t.connectionId
        case .console(let c): return c.connectionId
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
