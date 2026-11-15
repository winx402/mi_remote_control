import Foundation

struct CodexSessionList {
    struct Tab: Identifiable {
        let id: String
        let title: String
        let hostTitle: String?
        let isRemote: Bool
        let entries: [CodexSessions.Entry]
    }

    struct Selection: Equatable {
        var tab = 0
        var row = 0
    }

    let tabs: [Tab]

    init(entries: [CodexSessions.Entry]) {
        let newest = CodexSessions.sorted(entries)
        let recent = Tab(id: "recent", title: "最近", hostTitle: nil, isRemote: false,
                         entries: Array(newest.prefix(10)))
        let projects = Dictionary(grouping: newest, by: \.groupID).compactMap { id, rows -> Tab? in
            guard let first = rows.first else { return nil }
            return Tab(id: id, title: first.groupTitle, hostTitle: first.hostTitle,
                       isRemote: first.isRemote, entries: rows)
        }.sorted { lhs, rhs in
            let names = lhs.title.localizedStandardCompare(rhs.title)
            if names != .orderedSame { return names == .orderedAscending }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            let hosts = (lhs.hostTitle ?? "").localizedStandardCompare(rhs.hostTitle ?? "")
            return hosts == .orderedSame ? lhs.id < rhs.id : hosts == .orderedAscending
        }
        tabs = [recent] + projects
    }

    func entry(at selection: Selection) -> CodexSessions.Entry? {
        guard tabs.indices.contains(selection.tab), tabs[selection.tab].entries.indices.contains(selection.row) else { return nil }
        return tabs[selection.tab].entries[selection.row]
    }

    func moved(_ selection: Selection, key: RemoteKey) -> Selection {
        switch key {
        case .left, .right:
            let next = selection.tab + (key == .left ? -1 : 1)
            return tabs.indices.contains(next) ? Selection(tab: next) : selection
        case .up, .down:
            return Selection(tab: selection.tab, row: CodexSessions.movedIndex(selection.row, delta: key == .up ? -1 : 1,
                                                                                 count: tabs[selection.tab].entries.count))
        default: return selection
        }
    }

    /// Preserve a browsed project and thread across asynchronous catalog updates.
    func selection(after previous: Self, prior: Selection, browsed: Bool, currentKey: String?) -> Selection {
        guard browsed, previous.tabs.indices.contains(prior.tab),
              let tab = tabs.firstIndex(where: { $0.id == previous.tabs[prior.tab].id }) else {
            return Selection(tab: 0, row: tabs[0].entries.firstIndex { $0.identityKey == currentKey } ?? 0)
        }
        let key = previous.entry(at: prior)?.identityKey
        let rows = tabs[tab].entries
        let row = rows.firstIndex { $0.identityKey == key } ?? min(prior.row, max(0, rows.count - 1))
        return Selection(tab: tab, row: row)
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
        let list = Self(entries: local + [remote])
        guard empty.tabs.count == 1, empty.entry(at: Selection()) == nil,
              list.tabs.count == 3, list.tabs[0].entries.map(\.updatedAt) == [14,12,11,10,9,8,7,6,5,4],
              list.tabs[1].entries.count == 12, list.tabs[2].isRemote,
              list.moved(Selection(tab: 0, row: 9), key: .down) == Selection(tab: 0, row: 9),
              list.moved(Selection(tab: 0, row: 9), key: .right) == Selection(tab: 1),
              list.entry(at: Selection(tab: 2))?.identityKey == remote.identityKey else { return false }
        let earlier = CodexSessions.Entry(id: "extra", name: nil, updatedAt: 15, projectID: "a", projectName: "Alpha")
        let fresh = Self(entries: local + [remote, earlier])
        let kept = fresh.selection(after: list, prior: Selection(tab: 2), browsed: true, currentKey: nil)
        return kept.tab == 3 && fresh.entry(at: kept)?.identityKey == remote.identityKey
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: remote.identityKey) == Selection(tab: 0, row: 1)
            && fresh.selection(after: empty, prior: Selection(), browsed: false, currentKey: local[0].identityKey) == Selection()
    }
}
