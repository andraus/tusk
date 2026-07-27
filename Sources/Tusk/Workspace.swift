import SwiftUI
import AppKit
import TuskCore

/// A request to open the Manage-connections modal (optionally preselecting a
/// connection or starting a fresh add).
struct ManageRequest: Identifiable {
    let id = UUID()
    var preselect: String? = nil
    var addNew: Bool = false
}

struct Workspace: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConnectionStore
    @Environment(\.palette) var pal

    @AppStorage("tusk.railWidth") private var railWidth: Double = 250
    @AppStorage("tusk.sidebarWidth") private var sidebarWidth: Double = 248
    @AppStorage("tusk.terminalHeight") private var terminalHeight: Double = 300

    @State private var manageRequest: ManageRequest?

    private func openManage(_ req: ManageRequest) { manageRequest = req }

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                SchemaSidebar(width: CGFloat(sidebarWidth), openManage: openManage)
                ResizeHandle(width: $sidebarWidth, range: 200...480, paneOnLeft: true)
                VStack(spacing: 0) {
                    CenterPane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showTerminal {
                        TerminalResizeBar(height: $terminalHeight, range: 140...640)
                        ClaudeTerminalPanel()
                            .frame(height: CGFloat(terminalHeight))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                ResizeHandle(width: $railWidth, range: 200...520)
                InfoRail(width: CGFloat(railWidth))
            }
        }
        .background(pal.surfaceApp)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $manageRequest) { req in
            ManageConnectionsModal(preselect: req.preselect, addNew: req.addNew)
                .environmentObject(model)
                .environmentObject(store)
                .environment(\.palette, pal)
        }
    }
}

// MARK: - Draggable resize handle (grows the pane to its right)

private struct ResizeHandle: View {
    @Environment(\.palette) var pal
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// true: the resized pane sits to the handle's left (drag right widens it);
    /// false: the pane sits to the handle's right (drag left widens it).
    var paneOnLeft: Bool = false

    @State private var dragStartWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .overlay(
                Rectangle()
                    .fill(hovering ? pal.accent : pal.borderDefault)
                    .frame(width: hovering ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = base }
                        let delta = Double(value.translation.width)
                        let proposed = paneOnLeft ? base + delta : base - delta
                        width = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

// MARK: - Title bar (real macOS window; leaves room for traffic lights)

private struct TitleBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    private var connectedLabel: String {
        let n = model.connectedCount
        return "\(n) connected"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Reserve space for the real macOS traffic lights (hiddenTitleBar).
            Spacer().frame(width: 62)

            HStack(spacing: 7) {
                TuskMark(size: 15)
                Text("Tusk")
                    .font(.ui(13, weight: .semibold))
                    .foregroundColor(pal.textPrimary)
            }

            Spacer()

            // Claude Code terminal toggle
            Button {
                model.toggleTerminal()
            } label: {
                HStack(spacing: 6) {
                    ClaudeMark(size: 13)
                    Text("Claude Code")
                        .font(.ui(12))
                        .foregroundColor(model.showTerminal ? pal.accent : pal.textSecondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .fill(model.showTerminal ? pal.accent.opacity(0.12) : pal.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                        .strokeBorder(model.showTerminal ? pal.accent.opacity(0.35) : pal.borderDefault, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Live connection count (matches the mock's plain "N connected" label).
            HStack(spacing: 6) {
                if model.connectedCount > 0 {
                    Circle().fill(pal.success).frame(width: 6, height: 6)
                }
                Text(connectedLabel)
                    .font(.mono(11))
                    .foregroundColor(pal.textFaint)
            }

            Button {
                model.toggleTheme()
            } label: {
                Image(systemName: model.isDark ? "sun.max" : "moon")
                    .font(.system(size: 13))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(pal.surfacePanel)
        .overlay(Divider().overlay(pal.borderDefault), alignment: .bottom)
        // Vertically center the real macOS traffic lights in this 38pt bar so they
        // line up with the "Tusk" brand mark (they'd otherwise sit ~5pt higher).
        .background(TrafficLightAligner(centerFromTop: 19))
    }
}

// MARK: - Traffic light vertical alignment

/// Repositions the standard window buttons so their vertical center sits
/// `centerFromTop` points below the top of the window, matching a custom-height
/// title bar. Reapplied whenever macOS re-lays the buttons out (resize, key,
/// full-screen transitions).
private struct TrafficLightAligner: NSViewRepresentable {
    let centerFromTop: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(centerFromTop: centerFromTop) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.reposition()
    }

    final class Coordinator {
        let centerFromTop: CGFloat
        private weak var view: NSView?
        private var observers: [NSObjectProtocol] = []

        init(centerFromTop: CGFloat) { self.centerFromTop = centerFromTop }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func attach(to view: NSView) {
            self.view = view
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.reposition()
                }
                observers.append(token)
            }
            DispatchQueue.main.async { [weak self] in self?.reposition() }
        }

        func reposition() {
            guard let window = view?.window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            guard let container = buttons.first?.superview else { return }
            for button in buttons {
                var frame = button.frame
                // Titlebar container's top edge coincides with the window top; place
                // the button's center `centerFromTop` down from there.
                frame.origin.y = container.bounds.height - centerFromTop - frame.height / 2
                button.frame = frame
            }
        }
    }
}

// MARK: - Schema sidebar (multi-connection object tree)

/// A tree row keyed by its full path — "connId|database|schema.relation" — rather
/// than by the object's own name.
///
/// The whole tree is one lazy stack, so every nested `ForEach` in it shares a single
/// identity space. Names alone are not unique across connections: two servers
/// holding the same database ("llamacloud" on staging *and* production) each emit a
/// row identified "llamacloud", SwiftUI treats them as the same row and keeps only
/// one — and the survivor carries the *other* connection's id in its callbacks, so
/// double-clicking a table opens it on the wrong connection. Path keys keep the two
/// subtrees distinct.
private struct TreeKey<Value>: Identifiable {
    let id: String
    let value: Value
}

private struct SchemaSidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: ConnectionStore
    @Environment(\.palette) var pal

    var width: CGFloat = 248
    let openManage: (ManageRequest) -> Void

    @State private var filter = ""
    @State private var collapsedSchemas: Set<String> = []   // keyed "connId.database.schema"
    @State private var pendingDelete: Connection?

    /// Schemas (and their relations) for one database of a session, search-filtered.
    private func groups(_ s: ConnState, _ database: String) -> [(schema: String, relations: [Relation])] {
        guard let relations = s.snapshots[database]?.relations else { return [] }
        var order: [String] = []
        var map: [String: [Relation]] = [:]
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        for r in relations {
            if !q.isEmpty && !r.name.lowercased().contains(q) && !r.schema.lowercased().contains(q) { continue }
            if map[r.schema] == nil { order.append(r.schema); map[r.schema] = [] }
            map[r.schema]?.append(r)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pane header
            HStack(spacing: 6) {
                Text("CONNECTIONS")
                    .font(.ui(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(pal.textFaint)
                Spacer()
                Button { openManage(ManageRequest(addNew: true)) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundColor(pal.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New connection")
                Button { openManage(ManageRequest(preselect: model.selectedConnectionId)) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium)).foregroundColor(pal.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Connection settings")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: Metrics.toolbarHeight)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)

            // Filter
            HStack {
                TuskTextField(placeholder: "Filter objects…", text: $filter, leadingIcon: "magnifyingglass", mono: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)

            // Tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if store.connections.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.connections) { conn in
                            connectionNode(conn)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            // Footer
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundColor(pal.textFaint)
                Text("\(model.connectedCount) connected")
                    .font(.mono(11))
                    .foregroundColor(pal.textMuted)
                if let d = model.selectedDatabase {
                    Text("·").foregroundColor(pal.textFaint)
                    Text(d).font(.mono(11)).foregroundColor(pal.textMuted).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(Divider().overlay(pal.borderSubtle), alignment: .top)
        }
        .frame(width: width)
        .background(pal.surfacePanel)
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.name.isEmpty ? "Untitled" : $0.name)”?" } ?? "Delete connection?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Connection", role: .destructive) {
                if let c = pendingDelete { deleteConnection(c) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the saved connection and its keychain password. Open tabs for it are closed.")
        }
    }

    private func deleteConnection(_ conn: Connection) {
        if model.session(conn.id) != nil { model.disconnect(conn.id) }
        store.remove(conn)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 20)).foregroundColor(pal.textFaint)
            Text("No connections yet").font(.ui(12.5, weight: .medium)).foregroundColor(pal.textSecondary)
            Button { openManage(ManageRequest(addNew: true)) } label: {
                Text("Add a connection").font(.ui(12)).foregroundColor(pal.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 12)
    }

    // MARK: One connection + (if connected) its databases/schemas/relations

    @ViewBuilder private func connectionNode(_ conn: Connection) -> some View {
        let session = model.session(conn.id)
        let status = session?.status ?? "disconnected"
        let connected = status == "connected"
        let expanded = connected && (session?.expanded ?? false)

        ConnectionRow(
            conn: conn,
            status: status,
            selected: model.selectedConnectionId == conn.id && isConnectionInspector,
            expandable: connected,
            expanded: expanded,
            onToggle: { if connected { model.toggleConnection(conn.id) } },
            onSelect: { model.selectConnection(conn.id) },
            onOpen: {
                if connected { model.toggleConnection(conn.id) }
                else if status != "connecting" { connectOrManage(conn) }
            }
        )
        .contextMenu { connectionMenu(conn, connected: connected) }

        if let session, expanded {
            ForEach(session.databases.map { TreeKey(id: "\(conn.id)|\($0)", value: $0) }) { db in
                databaseNode(conn.id, session, db.value)
            }
        }
    }

    private func connectOrManage(_ conn: Connection) {
        if conn.savePassword { model.connect(store.withPassword(conn)) }
        else { openManage(ManageRequest(preselect: conn.id)) }
    }

    @ViewBuilder private func connectionMenu(_ conn: Connection, connected: Bool) -> some View {
        if connected {
            Button { model.disconnect(conn.id) } label: { Label("Disconnect", systemImage: "bolt.horizontal.circle") }
            Button {
                model.openConsole(connectionId: conn.id, database: conn.database)
            } label: { Label("New Query Console", systemImage: "chevron.left.forward.slash.chevron.right") }
            Button { model.refreshSchema() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        } else {
            Button { connectOrManage(conn) } label: { Label("Connect", systemImage: "bolt.horizontal.circle") }
        }
        Divider()
        Button { openManage(ManageRequest(preselect: conn.id)) } label: { Label("Connection settings…", systemImage: "slider.horizontal.3") }
        Button(role: .destructive) { pendingDelete = conn } label: { Label("Delete connection…", systemImage: "trash") }
    }

    /// One database node plus its (lazily-loaded) schemas and relations.
    @ViewBuilder private func databaseNode(_ connId: String, _ s: ConnState, _ dbName: String) -> some View {
        let dbExpanded = s.expandedDatabases.contains(dbName)

        TreeRow(depth: 1, icon: "cylinder.split.1x2", label: dbName,
                trailing: nil,
                selected: model.inspector == .database(connId: connId, name: dbName),
                expandable: true, expanded: dbExpanded,
                onToggle: { model.toggleDatabase(connId, dbName) },
                onSelect: { model.selectDatabase(connId, dbName) },
                onOpen: { model.toggleDatabase(connId, dbName) })
            .contextMenu {
                Button {
                    model.openConsole(connectionId: connId, database: dbName)
                } label: { Label("New Query Console", systemImage: "chevron.left.forward.slash.chevron.right") }
            }

        if dbExpanded {
            if s.loadingDatabases.contains(dbName) {
                inlineRow(depth: 2) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Loading…").font(.ui(12)).foregroundColor(pal.textMuted)
                }
            } else if let err = s.databaseErrors[dbName] {
                inlineRow(depth: 2) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(pal.danger)
                    Text(err).font(.mono(11)).foregroundColor(pal.danger).lineLimit(2)
                }
            } else {
                let schemaGroups = groups(s, dbName)
                ForEach(schemaGroups.map { TreeKey(id: "\(connId)|\(dbName)|\($0.schema)", value: $0) }) { entry in
                    let group = entry.value
                    let key = "\(connId).\(dbName).\(group.schema)"
                    let expanded = !collapsedSchemas.contains(key)
                    TreeRow(depth: 2, icon: "shippingbox", label: group.schema,
                            trailing: "\(group.relations.count)", selected: false,
                            expandable: true, expanded: expanded,
                            onToggle: { toggleSchema(key) },
                            onSelect: { model.selectDatabase(connId, dbName) },
                            onOpen: { toggleSchema(key) })

                    if expanded {
                        ForEach(group.relations.map { TreeKey(id: "\(connId)|\(dbName)|\($0.id)", value: $0) }) { entry in
                            let rel = entry.value
                            TreeRow(depth: 3, icon: rel.kind.iconName, label: rel.name,
                                    trailing: (rel.kind == .table || rel.kind == .partitioned) ? Fmt.rows(rel.estRows) : nil,
                                    selected: model.selectedConnectionId == connId && model.selectedDatabase == dbName && model.selectedRelationID == rel.id,
                                    expandable: false, expanded: false,
                                    muted: rel.kind == .function,
                                    onToggle: {},
                                    onSelect: { model.select(connId, database: dbName, relation: rel) },
                                    onOpen: { model.openTable(connId, database: dbName, relation: rel) })
                                .contextMenu {
                                    Button {
                                        model.openTable(connId, database: dbName, relation: rel)
                                    } label: { Label("Open Table", systemImage: "tablecells") }
                                    Button {
                                        model.openConsole(connectionId: connId, database: dbName,
                                                          seedSQL: "SELECT * FROM \(rel.schema).\(rel.name) LIMIT 100")
                                    } label: { Label("Query Console", systemImage: "chevron.left.forward.slash.chevron.right") }
                                }
                        }
                    }
                }
                if schemaGroups.isEmpty {
                    inlineRow(depth: 2) {
                        Text(filter.isEmpty ? "No tables." : "No matches.")
                            .font(.ui(12)).foregroundColor(pal.textMuted)
                    }
                }
            }
        }
    }

    private var isConnectionInspector: Bool {
        if case .connection = model.inspector { return true }
        return false
    }

    @ViewBuilder private func inlineRow<Content: View>(depth: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(depth) * 14 + 24)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 26)
    }

    private func toggleSchema(_ key: String) {
        if collapsedSchemas.contains(key) { collapsedSchemas.remove(key) } else { collapsedSchemas.insert(key) }
    }
}

// MARK: - Connection row (top-level tree node)

private struct ConnectionRow: View {
    @Environment(\.palette) var pal
    let conn: Connection
    let status: String
    let selected: Bool
    let expandable: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var hovering = false

    private var connected: Bool { status == "connected" }

    var body: some View {
        HStack(spacing: 6) {
            // chevron (only for connected/expandable connections)
            if expandable {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(pal.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            if status == "connecting" {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 8, height: 8)
            } else {
                StatusDot(status: status, size: 8)
            }

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 13))
                .foregroundColor(connected ? pal.accent : pal.textFaint)
                .frame(width: 16)

            Text(conn.name.isEmpty ? "Untitled" : conn.name)
                .font(.ui(13, weight: .semibold))
                .foregroundColor(connected ? pal.textPrimary : pal.textMuted)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(conn.hostPort)
                .font(.mono(10.5))
                .foregroundColor(pal.textFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(selected ? pal.surfaceSelected : (hovering ? pal.surfaceHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(count: 1, perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tree row

private struct TreeRow: View {
    @Environment(\.palette) var pal
    let depth: Int
    let icon: String
    let label: String
    let trailing: String?
    let selected: Bool
    let expandable: Bool
    let expanded: Bool
    var muted: Bool = false
    let onToggle: () -> Void
    let onSelect: () -> Void
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // indentation
            Spacer().frame(width: CGFloat(depth) * 14)

            // chevron
            if expandable {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(pal.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(selected ? pal.accent : pal.textMuted)
                .frame(width: 16)

            Text(label)
                .font(depth == 0 ? .ui(12.5, weight: .semibold) : .ui(12.5))
                .foregroundColor(muted ? pal.textFaint : (selected ? pal.textPrimary : pal.textPrimary))
                .lineLimit(1)

            Spacer(minLength: 4)

            if let trailing {
                Text(trailing)
                    .font(.mono(10.5))
                    .foregroundColor(pal.textFaint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(selected ? pal.surfaceSelected : (hovering ? pal.surfaceHover : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(count: 1, perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Center: welcome / table data

private struct CenterPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    @State private var expanded: ExpandedValue?

    var body: some View {
        VStack(spacing: 0) {
            if model.tabs.isEmpty {
                welcome
            } else {
                tabBar
                Divider().overlay(pal.borderDefault)
                if let tab = model.activeTab {
                    switch tab {
                    case .data(let t):    dataTabView(t)
                    case .console(let c): ConsolePane(console: c).id(c.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.surfaceRaised)
        .overlay { if let e = expanded { CellValueViewer(value: e) { expanded = nil } } }
    }

    @ViewBuilder private func dataTabView(_ tab: DataTab) -> some View {
        contextBar(tab)
        Divider().overlay(pal.borderSubtle)
        content(tab)
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    TabChip(tab: tab,
                            active: tab.id == model.activeTabID,
                            connectionName: model.connection(for: tab.connectionId)?.name ?? "",
                            connectionEnv: model.connection(for: tab.connectionId)?.env ?? "local",
                            onSelect: { model.focusTab(tab.id) },
                            onClose: { model.closeTab(tab.id) })
                }
            }
        }
        .frame(height: Metrics.tabbarHeight)
        .background(pal.surfacePanel)
    }

    private func contextBar(_ tab: DataTab) -> some View {
        HStack(spacing: 8) {
            if let conn = model.connection(for: tab.connectionId) {
                Circle().fill(pal.envColor(conn.env)).frame(width: 7, height: 7)
                Text(conn.name).font(.mono(11.5)).foregroundColor(pal.textMuted)
                Text("/").font(.mono(11.5)).foregroundColor(pal.textFaint)
            }
            Text(tab.relation.schema).font(.mono(11.5)).foregroundColor(pal.textMuted)
            Text("/").font(.mono(11.5)).foregroundColor(pal.textFaint)
            Text(tab.relation.name).font(.mono(11.5, weight: .semibold)).foregroundColor(pal.textPrimary)
            Badge(text: kindLabel(tab.relation.kind), color: pal.textMuted)
            Spacer()
            if !tab.loading && tab.error == nil {
                Badge(text: "\(tab.rows.count) rows", color: pal.textMuted, mono: true)
            }
            Button { model.reloadTab(tab.id) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(pal.textMuted)
                    .frame(width: 26, height: 24)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(pal.surfaceRaised)
    }

    // MARK: Active tab content

    @ViewBuilder private func content(_ tab: DataTab) -> some View {
        if tab.loading {
            center { ProgressView().controlSize(.small); Text("Loading data…").font(.ui(13)).foregroundColor(pal.textMuted) }
        } else if let err = tab.error {
            center { Image(systemName: "exclamationmark.triangle").font(.system(size: 22)).foregroundColor(pal.danger)
                     Text(err).font(.mono(12)).foregroundColor(pal.danger).multilineTextAlignment(.center) }
        } else if tab.columns.isEmpty {
            center { Image(systemName: "tablecells").font(.system(size: 22)).foregroundColor(pal.textFaint)
                     Text("No rows").font(.ui(13)).foregroundColor(pal.textMuted) }
        } else {
            ResultGrid(gridID: tab.id, columns: tab.columns, columnInfos: tab.columnInfos, rows: tab.rows,
                       onExpand: { col, type, val in expanded = ExpandedValue(column: col, type: type, value: val) },
                       onDeleteRow: isDeletable(tab) ? { model.deleteDataTabRow(tab.id, rowIndex: $0) } : nil)
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 34))
                .foregroundColor(pal.accent)
            Text("Welcome to Tusk")
                .font(.ui(17, weight: .semibold))
                .foregroundColor(pal.textPrimary)
            VStack(spacing: 4) {
                Text("Connect a database from the left to browse it.")
                Text("Single-click an object to inspect it; double-click a table to open it.")
            }
            .font(.ui(12.5))
            .foregroundColor(pal.textMuted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func center<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Only base and partitioned tables support row deletes — views/matviews don't.
    private func isDeletable(_ tab: DataTab) -> Bool {
        tab.relation.kind == .table || tab.relation.kind == .partitioned
    }

    private func kindLabel(_ k: DBObjectKind) -> String {
        switch k {
        case .table: return "table"
        case .view: return "view"
        case .matview: return "materialized view"
        case .partitioned: return "partitioned"
        default: return "object"
        }
    }
}

// MARK: - Center: one open tab

private struct TabChip: View {
    @Environment(\.palette) var pal
    let tab: WorkspaceTab
    let active: Bool
    let connectionName: String
    let connectionEnv: String
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var icon: String {
        switch tab {
        case .data(let t):   return t.relation.kind.iconName
        case .console:       return "chevron.left.forward.slash.chevron.right"
        }
    }
    private var label: String {
        switch tab {
        case .data(let t):      return t.relation.name
        case .console(let c):   return c.title.isEmpty ? "Query" : c.title
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            // Which connection this tab belongs to.
            Circle().fill(pal.envColor(connectionEnv)).frame(width: 6, height: 6)
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(active ? pal.accent : pal.textFaint)
            Text(label)
                .font(.ui(12))
                .foregroundColor(active ? pal.textPrimary : pal.textMuted)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(pal.textMuted)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(hovering ? pal.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
            .opacity(hovering || active ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.tabbarHeight)
        .frame(maxWidth: 200)
        .background(active ? pal.surfaceRaised : pal.surfacePanel)
        .overlay(alignment: .top) {
            Rectangle().fill(active ? pal.accent : Color.clear).frame(height: 2)
        }
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(connectionName.isEmpty ? label : "\(connectionName) · \(label)")
    }
}

private struct ColumnRow: View {
    @Environment(\.palette) var pal
    let col: ColumnInfo
    let zebra: Bool

    var body: some View {
        HStack(spacing: 10) {
            // key glyph
            Group {
                if col.isPK {
                    Image(systemName: "key.fill").font(.system(size: 11)).foregroundColor(pal.amber500)
                } else if col.isFK {
                    Image(systemName: "link").font(.system(size: 11)).foregroundColor(pal.textFaint)
                } else {
                    Spacer().frame(width: 12)
                }
            }
            .frame(width: 14)

            Text(col.name)
                .font(.mono(12.5))
                .foregroundColor(pal.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !col.notNull {
                Text("null")
                    .font(.mono(10))
                    .foregroundColor(pal.textFaint)
            }
            TypeBadge(type: col.type)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusSM, style: .continuous)
                .fill(zebra ? pal.surfaceHover.opacity(0.5) : .clear)
        )
    }
}

// MARK: - Right info rail (selection-driven inspector)

private struct InfoRail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.palette) var pal

    let width: CGFloat

    var body: some View {
        Group {
            switch model.inspector {
            case .none:                          emptyInspector
            case .connection(let id):            connectionInspector(id)
            case .database(let connId, let name): databaseInspector(connId, name)
            case .relation:                      tableInspector
            }
        }
        .frame(width: width)
        .background(pal.surfacePanel)
    }

    private var emptyInspector: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right").font(.system(size: 20)).foregroundColor(pal.textFaint)
            Text("Select an object")
                .font(.ui(12.5)).foregroundColor(pal.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Connection

    private func connectionInspector(_ id: String) -> some View {
        let conn = model.connection(for: id)
        let status = model.status(for: id)
        return VStack(alignment: .leading, spacing: 0) {
            railHeader("bolt.horizontal.circle", "Connection", status: status)
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Name", conn?.name ?? "—", mono: false)
                infoRow("Host", conn?.hostPort ?? "—")
                infoRow("User", conn?.user ?? "—")
                infoRow("SSL", conn?.sslMode ?? "—")
                infoRow("Status", status.capitalized, mono: false)
            }
            .padding(14)
            if let err = model.connectErrors[id] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(pal.danger)
                    Text(err).font(.mono(11)).foregroundColor(pal.danger).lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            if let s = model.session(id) {
                sectionLabel("SERVER")
                HStack(spacing: 8) {
                    stat("\(s.databases.count)", "databases")
                }
                .padding(.horizontal, 14)
            }
            Spacer()
        }
    }

    // MARK: Database

    private func databaseInspector(_ connId: String, _ name: String) -> some View {
        let s = model.session(connId)
        let snap = s?.snapshots[name]
        return VStack(alignment: .leading, spacing: 0) {
            railHeader("cylinder.split.1x2", "Database", status: model.status(for: connId))
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Name", name)
                infoRow("Connection", model.connection(for: connId)?.name ?? "—", mono: false)
                infoRow("Server", model.connection(for: connId)?.hostPort ?? "—")
            }
            .padding(14)
            sectionLabel("OVERVIEW")
            if snap == nil && (s?.loadingDatabases.contains(name) ?? false) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Loading…").font(.ui(12)).foregroundColor(pal.textMuted)
                }
                .padding(.horizontal, 14)
            } else {
                HStack(spacing: 8) {
                    stat("\(schemaCount(snap))", "schemas")
                    stat("\(tableCount(snap))", "tables")
                    stat("\(viewCount(snap))", "views")
                }
                .padding(.horizontal, 14)
            }
            Spacer()
        }
    }

    // MARK: Table

    private var tableInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            railHeader("tablecells", "Table", status: model.selectedConnectionId.map { model.status(for: $0) } ?? "disconnected")
            if let rel = model.selectedRelation {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow("Schema", rel.schema)
                    infoRow("Name", rel.name)
                    if rel.kind == .table || rel.kind == .partitioned {
                        infoRow("Est. rows", "~\(Fmt.rows(rel.estRows))")
                    }
                }
                .padding(14)
            }
            HStack {
                Text("COLUMNS")
                    .font(.ui(10, weight: .semibold)).tracking(0.6)
                    .foregroundColor(pal.textFaint)
                Spacer()
                Text("\(model.columns.count)")
                    .font(.mono(11)).foregroundColor(pal.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)

            if model.loadingColumns {
                inlineNote { ProgressView().controlSize(.small).scaleEffect(0.7)
                             Text("Loading columns…").font(.ui(12)).foregroundColor(pal.textMuted) }
            } else if model.columns.isEmpty {
                inlineNote { Text("No columns").font(.ui(12)).foregroundColor(pal.textMuted) }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.columns.enumerated()), id: \.element.id) { idx, col in
                            ColumnRow(col: col, zebra: idx % 2 == 1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Building blocks

    private func railHeader(_ icon: String, _ title: String, status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(pal.textMuted)
            Text(title).font(.ui(13, weight: .semibold)).foregroundColor(pal.textPrimary)
            Spacer()
            StatusDot(status: status, size: 7)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.toolbarHeight)
        .overlay(Divider().overlay(pal.borderSubtle), alignment: .bottom)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.ui(10, weight: .semibold)).tracking(0.6)
            .foregroundColor(pal.textFaint)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }

    @ViewBuilder private func inlineNote<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
        Spacer()
    }

    private func schemaCount(_ snap: DBSnapshot?) -> Int {
        Set(snap?.relations.map { $0.schema } ?? []).count
    }
    private func tableCount(_ snap: DBSnapshot?) -> Int {
        snap?.relations.filter { $0.kind == .table || $0.kind == .partitioned }.count ?? 0
    }
    private func viewCount(_ snap: DBSnapshot?) -> Int {
        snap?.relations.filter { $0.kind == .view || $0.kind == .matview }.count ?? 0
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = true) -> some View {
        HStack {
            Text(label).font(.ui(12)).foregroundColor(pal.textMuted)
            Spacer()
            Text(value)
                .font(mono ? .mono(11.5) : .ui(12, weight: .medium))
                .foregroundColor(pal.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.ui(18, weight: .semibold)).foregroundColor(pal.textPrimary)
            Text(label).font(.ui(10.5)).foregroundColor(pal.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .fill(pal.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMD, style: .continuous)
                .strokeBorder(pal.borderSubtle, lineWidth: 1)
        )
    }
}
