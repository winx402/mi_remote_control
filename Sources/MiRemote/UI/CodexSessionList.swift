import Foundation

struct CodexSessionList {
    enum Tool: CaseIterable { case updateCodex }
    static let recentTab = 1

    struct Tab: Identifiable {
        var isTools: Bool { id == "tools" }
        var isRecent: Bool { id == "recent" }
        var isProjectless: Bool { id == "projectless" }

        let id: String
        let title: String
        let hostTitle: String?
        let project: CodexSessionCatalog.Project?
        let isRemote: Bool
        let entries: [CodexSessions.Entry]
    }

    struct Selection: Equatable {
        enum Item: Equatable { case dot, newChat, row(Int) }
        let tab: Int
        let item: Item

        var row: Int? {
            if case let .row(index) = item { return index }
            return nil
        }

        init(tab: Int = CodexSessionList.recentTab, row: Int? = nil) {
            self.tab = tab
            self.item = row.map(Item.row) ?? .newChat
        }

        private init(dotIn tab: Int) { self.tab = tab; self.item = .dot }
        static let dot = Selection(dotIn: CodexSessionList.recentTab)
    }

    let tabs: [Tab]

    init(entries: [CodexSessions.Entry], sidebarProjects: [CodexSessionCatalog.Project] = []) {
        let newest = CodexSessions.sorted(entries)
        let recent = Tab(id: "recent", title: "最近", hostTitle: nil, project: nil, isRemote: false,
                         entries: Array(newest.prefix(10)))
        let rows = Dictionary(grouping: newest, by: \.groupID)
        let projects = sidebarProjects.map { project in
            let entries = rows[project.groupID] ?? []
            let host = project.hostName ?? entries.first?.hostName
            return Tab(id: project.groupID, title: project.name,
                       hostTitle: project.hostID == nil ? "本机" : host,
                       project: project, isRemote: project.hostID != nil, entries: entries)
        }
        let tools = Tab(id: "tools", title: "功能", hostTitle: nil, project: nil, isRemote: false, entries: [])
        let projectGroups = Set(sidebarProjects.map(\.groupID))
        let projectless = Tab(id: "projectless", title: "无项目", hostTitle: nil, project: nil,
                              isRemote: false, entries: newest.filter { !projectGroups.contains($0.groupID) })
        tabs = [tools, recent, projectless] + projects
    }

    func entry(at selection: Selection) -> CodexSessions.Entry? {
        guard tabs.indices.contains(selection.tab), let row = selection.row,
              tabs[selection.tab].entries.indices.contains(row) else { return nil }
        return tabs[selection.tab].entries[row]
    }

    func initialSelection(tab: Int, currentKey: String? = nil) -> Selection {
        if tabs[tab].isTools { return Selection(tab: tab, row: 0) }
        let entries = tabs[tab].entries
        if let current = entries.firstIndex(where: { $0.identityKey == currentKey }) {
            return Selection(tab: tab, row: current)
        }
        return tabs[tab].isRecent ? .dot : Selection(tab: tab, row: entries.indices.first)
    }

    func moved(_ selection: Selection, key: RemoteKey) -> Selection {
        if tabs[selection.tab].isTools, key == .up || key == .down {
            let row = CodexSessions.movedIndex(selection.row ?? 0, delta: key == .up ? -1 : 1, count: Tool.allCases.count)
            return Selection(tab: selection.tab, row: row)
        }
        switch key {
        case .left, .right:
            let next = selection.tab + (key == .left ? -1 : 1)
            return tabs.indices.contains(next) ? initialSelection(tab: next) : selection
        case .up:
            if tabs[selection.tab].isRecent, selection.row == nil { return .dot }
            guard let row = selection.row, row > 0 else { return Selection(tab: selection.tab) }
            return Selection(tab: selection.tab, row: row - 1)
        case .down:
            if selection.item == .dot { return Selection(tab: selection.tab) }
            let rows = tabs[selection.tab].entries
            guard !rows.isEmpty else { return Selection(tab: selection.tab) }
            return Selection(tab: selection.tab, row: min((selection.row ?? -1) + 1, rows.count - 1))
        default: return selection
        }
    }

    /// Preserve a browsed project and thread (or its New Chat action) across catalog updates.
    func selection(after previous: Self, prior: Selection, browsed: Bool, currentKey: String?) -> Selection {
        guard browsed, previous.tabs.indices.contains(prior.tab),
              let tab = tabs.firstIndex(where: { $0.id == previous.tabs[prior.tab].id }) else {
            return initialSelection(tab: Self.recentTab, currentKey: currentKey)
        }
        if prior.item == .dot, tabs[tab].isRecent { return .dot }
        if tabs[tab].isTools { return Selection(tab: tab, row: prior.row ?? 0) }
        guard let oldRow = prior.row, !tabs[tab].entries.isEmpty else { return Selection(tab: tab) }
        let key = previous.entry(at: prior)?.identityKey
        let rows = tabs[tab].entries
        return Selection(tab: tab, row: rows.firstIndex { $0.identityKey == key } ?? min(oldRow, rows.count - 1))
    }

    static func currentIndex(in snapshot: CodexSessions.Snapshot) -> Int? {
        guard let key = snapshot.currentIdentityKey else { return nil }
        return snapshot.entries.firstIndex { $0.identityKey == key }
    }

    static func selfCheck() -> Bool {
        let empty = Self(entries: [])
        let local = (1...12).map { index in
            CodexSessions.Entry(id: String(index), name: nil, updatedAt: Double(index), projectID: "p", projectName: "Beta")
        }
        let remote = CodexSessions.Entry(id: "12", name: nil, updatedAt: 14, hostID: "host", hostName: "Remote", projectID: "p", projectName: "Beta")
        let localProject = CodexSessionCatalog.Project(id: "p", name: "Beta", hostID: nil, roots: [])
        let remoteProject = CodexSessionCatalog.Project(id: "p", name: "Beta", hostID: "host", roots: [])
        let emptyProject = CodexSessionCatalog.Project(id: "empty", name: "Empty", hostID: nil, roots: [])
        let sidebar = [localProject, remoteProject, emptyProject]
        let historical = CodexSessions.Entry(id: "old-folder", name: nil, updatedAt: 0, projectID: "cwd:/old", projectName: "Old")
        let list = Self(entries: local + [remote, historical], sidebarProjects: sidebar)
        guard empty.tabs.count == 3, empty.entry(at: Selection()) == nil,
              list.tabs.count == 6, list.tabs[5].entries.isEmpty, list.tabs[1].entries.map(\.updatedAt) == [14,12,11,10,9,8,7,6,5,4],
              list.tabs[3].entries.count == 12, list.tabs[4].isRemote,
              list.moved(Selection(tab: 1, row: 9), key: .down) == Selection(tab: 1, row: 9),
              list.moved(Selection(tab: 1, row: 9), key: .right) == Selection(tab: 2, row: 0),
              list.entry(at: Selection(tab: 4, row: 0))?.identityKey == remote.identityKey else { return false }
        guard list.moved(Selection(tab: 1, row: 0), key: .up) == Selection(tab: 1),
              list.moved(Selection(tab: 1), key: .down) == Selection(tab: 1, row: 0),
              list.initialSelection(tab: 5).row == nil,
              list.tabs[1].project == nil, list.tabs[4].project?.hostID == "host",
              list.tabs[5].project?.id == "empty",
              list.selection(after: list, prior: Selection(tab: 4), browsed: true, currentKey: nil) == Selection(tab: 4)
        else { return false }
        let tools = list.moved(Selection(), key: .left)
        guard list.tabs[Selection().tab].isRecent, list.tabs[tools.tab].isTools, tools.row == 0,
              list.moved(tools, key: .down) == tools, list.moved(tools, key: .right).tab == Self.recentTab,
              list.selection(after: list, prior: tools, browsed: true, currentKey: nil) == tools else { return false }
        let unassigned = (0..<15).map {
            CodexSessions.Entry(id: "unassigned-\($0)", name: nil, updatedAt: Double($0),
                                hostID: $0.isMultiple(of: 2) ? nil : "remote")
        }
        let all = Self(entries: local + unassigned + [historical], sidebarProjects: sidebar)
        guard all.tabs[2].isProjectless, all.tabs[2].entries.count == 16,
              all.tabs[2].entries.first?.id == "unassigned-14",
              all.tabs[2].entries.contains(where: { $0.id == historical.id }),
              !all.tabs[2].entries.contains(where: { $0.projectID == "p" }),
              all.tabs[2].project == nil, all.tabs[1].entries.count == 10 else { return false }
        let earlier = CodexSessions.Entry(id: "extra", name: nil, updatedAt: 15, projectID: "a", projectName: "Alpha")
        let alpha = CodexSessionCatalog.Project(id: "a", name: "Alpha", hostID: nil, roots: [])
        let fresh = Self(entries: local + [remote, earlier], sidebarProjects: [alpha] + sidebar)
        let kept = fresh.selection(after: list, prior: Selection(tab: 4, row: 0), browsed: true, currentKey: nil)
        return kept.tab == 5 && fresh.entry(at: kept)?.identityKey == remote.identityKey
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: remote.identityKey) == Selection(tab: 1, row: 1)
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: local[0].identityKey) == .dot
            && list.moved(Selection(tab: Self.recentTab), key: .up) == .dot
            && list.moved(.dot, key: .up) == .dot
            && list.moved(.dot, key: .down) == Selection(tab: Self.recentTab)
            && fresh.selection(after: list, prior: .dot, browsed: true, currentKey: remote.identityKey) == .dot
            && empty.initialSelection(tab: Self.recentTab) == .dot
    }
}
