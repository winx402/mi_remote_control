import Foundation

/// 浮层的项目顺序与遥控导航共用同一份扁平索引，组标题不占可选位置。
struct CodexSessionList {
    struct Group: Identifiable {
        let id: String
        let title: String
        let hostTitle: String
        let isRemote: Bool
        let entries: [CodexSessions.Entry]
        let startIndex: Int
    }

    let groups: [Group]
    let entries: [CodexSessions.Entry]

    init(entries: [CodexSessions.Entry]) {
        let grouped = Dictionary(grouping: entries, by: \.groupID)
        let ordered = grouped.values.map { CodexSessions.sorted($0) }.sorted { lhs, rhs in
            let left = lhs.first!
            let right = rhs.first!
            return left.updatedAt == right.updatedAt ? left.groupID < right.groupID : left.updatedAt > right.updatedAt
        }
        var groups: [Group] = []
        var flattened: [CodexSessions.Entry] = []
        for group in ordered {
            guard let first = group.first else { continue }
            groups.append(Group(id: first.groupID, title: first.groupTitle, hostTitle: first.hostTitle,
                                isRemote: first.isRemote, entries: group, startIndex: flattened.count))
            flattened.append(contentsOf: group)
        }
        self.groups = groups
        self.entries = flattened
    }

    static func grouped(_ snapshot: CodexSessions.Snapshot) -> CodexSessions.Snapshot {
        var result = snapshot
        result.entries = Self(entries: snapshot.entries).entries
        return result
    }

    func movedIndex(_ index: Int, key: RemoteKey) -> Int {
        guard !entries.isEmpty else { return 0 }
        let index = min(max(index, 0), entries.count - 1)
        switch key {
        case .up: return max(0, index - 1)
        case .down: return min(entries.count - 1, index + 1)
        case .left, .right:
            guard let groupIndex = groups.lastIndex(where: { $0.startIndex <= index }) else { return index }
            let target = groupIndex + (key == .left ? -1 : 1)
            return groups.indices.contains(target) ? groups[target].startIndex : index
        default: return index
        }
    }

    static func currentIndex(in snapshot: CodexSessions.Snapshot) -> Int? {
        guard let key = snapshot.currentIdentityKey else { return nil }
        return snapshot.entries.firstIndex { $0.identityKey == key }
    }

    static func selfCheck() -> Bool {
        let localA = CodexSessions.Entry(id: "local-a", name: "本机会话 A", updatedAt: 9,
                                        projectID: "one", projectName: "同名项目")
        let localB = CodexSessions.Entry(id: "local-b", name: "本机会话 B", updatedAt: 2,
                                        projectID: "one", projectName: "同名项目")
        let remote = CodexSessions.Entry(id: "local-a", name: "远程会话", updatedAt: 8,
                                        hostID: "remote", hostName: "远程电脑", projectID: "one", projectName: "同名项目")
        let other = CodexSessions.Entry(id: "other", name: "另一项目", updatedAt: 7,
                                       projectID: "two", projectName: "另一项目")
        let list = Self(entries: [other, localB, remote, localA])
        guard list.groups.count == 3, list.entries.map(\.identityKey) == [localA, localB, remote, other].map(\.identityKey),
              list.groups.map(\.startIndex) == [0, 2, 3], list.groups[1].isRemote,
              list.movedIndex(1, key: .down) == 2, list.movedIndex(2, key: .up) == 1,
              list.movedIndex(1, key: .right) == 2, list.movedIndex(2, key: .right) == 3,
              list.movedIndex(3, key: .left) == 2, list.movedIndex(2, key: .left) == 0,
              list.movedIndex(1, key: .left) == 1, list.movedIndex(3, key: .right) == 3,
              list.movedIndex(0, key: .up) == 0, list.movedIndex(3, key: .down) == 3,
              Self(entries: []).movedIndex(4, key: .right) == 0 else { return false }
        var current = CodexSessions.Snapshot(entries: list.entries, currentID: remote.id)
        current.currentIdentityKey = remote.identityKey
        guard Self.currentIndex(in: current) == 2 else { return false }
        // 新页面插入/组排序变化时，以宿主与会话身份保留用户正在浏览的行。
        let newest = CodexSessions.Entry(id: "newest", name: "新会话", updatedAt: 12,
                                        projectID: "two", projectName: "另一项目")
        var loaded = Self.grouped(CodexSessions.Snapshot(entries: list.entries + [newest], currentID: remote.id))
        loaded.currentIdentityKey = remote.identityKey
        let selected = loaded.selection(after: current, index: 1, userMoved: true)
        let anchored = loaded.selection(after: current, index: 1, userMoved: false)
        return loaded.entries[selected].identityKey == localB.identityKey
            && loaded.entries[anchored].identityKey == remote.identityKey
            && Self.currentIndex(in: CodexSessions.Snapshot(entries: list.entries)) == nil
    }
}
