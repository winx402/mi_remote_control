import Foundation

struct CodexSessionList {
    struct Tab: Identifiable {
        let id: String
        let title: String
        let hostTitle: String?
        let project: CodexSessionCatalog.Project?
        let isRemote: Bool
        let entries: [CodexSessions.Entry]
    }

    struct Selection: Equatable {
        var tab = 0
        // nil selects the New Chat action above the sessions.
        var row: Int? = nil
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
        tabs = [recent] + projects
    }

    func entry(at selection: Selection) -> CodexSessions.Entry? {
        guard tabs.indices.contains(selection.tab), let row = selection.row,
              tabs[selection.tab].entries.indices.contains(row) else { return nil }
        return tabs[selection.tab].entries[row]
    }

    func initialSelection(tab: Int, currentKey: String? = nil) -> Selection {
        let entries = tabs[tab].entries
        return Selection(tab: tab, row: entries.firstIndex { $0.identityKey == currentKey } ?? entries.indices.first)
    }

    func moved(_ selection: Selection, key: RemoteKey) -> Selection {
        switch key {
        case .left, .right:
            let next = selection.tab + (key == .left ? -1 : 1)
            return tabs.indices.contains(next) ? initialSelection(tab: next) : selection
        case .up:
            guard let row = selection.row, row > 0 else { return Selection(tab: selection.tab) }
            return Selection(tab: selection.tab, row: row - 1)
        case .down:
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
            return initialSelection(tab: 0, currentKey: currentKey)
        }
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
        guard empty.tabs.count == 1, empty.entry(at: Selection()) == nil,
              list.tabs.count == 4, list.tabs[3].entries.isEmpty, list.tabs[0].entries.map(\.updatedAt) == [14,12,11,10,9,8,7,6,5,4],
              list.tabs[1].entries.count == 12, list.tabs[2].isRemote,
              list.moved(Selection(tab: 0, row: 9), key: .down) == Selection(tab: 0, row: 9),
              list.moved(Selection(tab: 0, row: 9), key: .right) == Selection(tab: 1, row: 0),
              list.entry(at: Selection(tab: 2, row: 0))?.identityKey == remote.identityKey else { return false }
        guard list.moved(Selection(tab: 0, row: 0), key: .up) == Selection(tab: 0),
              list.moved(Selection(tab: 0), key: .down) == Selection(tab: 0, row: 0),
              list.initialSelection(tab: 3).row == nil,
              list.tabs[0].project == nil, list.tabs[2].project?.hostID == "host",
              list.tabs[3].project?.id == "empty",
              list.selection(after: list, prior: Selection(tab: 2), browsed: true, currentKey: nil) == Selection(tab: 2)
        else { return false }
        let earlier = CodexSessions.Entry(id: "extra", name: nil, updatedAt: 15, projectID: "a", projectName: "Alpha")
        let alpha = CodexSessionCatalog.Project(id: "a", name: "Alpha", hostID: nil, roots: [])
        let fresh = Self(entries: local + [remote, earlier], sidebarProjects: [alpha] + sidebar)
        let kept = fresh.selection(after: list, prior: Selection(tab: 2, row: 0), browsed: true, currentKey: nil)
        return kept.tab == 3 && fresh.entry(at: kept)?.identityKey == remote.identityKey
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: remote.identityKey) == Selection(tab: 0, row: 1)
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: local[0].identityKey) == Selection(tab: 0, row: 0)
    }
}
