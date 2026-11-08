import Foundation
import CoreGraphics

/// Pure geometry over an AX snapshot. Coordinates use AX's top-left origin (positive Y is down).
/// Scroll containers are region anchors, never activation targets.
enum AppNavigationGeometry {
    static func target(currentID: Int?, direction: RemoteKey, nodes: [AppNavigationNode]) -> Int? {
        let controls = cleaned(nodes).filter { $0.kind != .scrollArea }
        guard !controls.isEmpty else { return nil }
        let current = controls.first { $0.id == currentID }
        guard let axis = Axis(direction) else { return current?.id }
        // Entering selection establishes a real target; it does not also consume a movement step.
        guard let current else {
            return controls.filter(\.focused).sorted(by: readingOrder).first?.id
                ?? controls.sorted(by: readingOrder).first?.id
        }

        let source = current.frame
        let candidates = controls.compactMap { node -> Candidate? in
            guard node.id != current.id else { return nil }
            let primary = axis.primaryCenter(node.frame) - axis.primaryCenter(source)
            let forward = primary * axis.sign
            guard forward > 0 else { return nil }
            let cross = abs(axis.crossCenter(node.frame) - axis.crossCenter(source))
            let crossOverlap = min(axis.crossMax(source), axis.crossMax(node.frame))
                - max(axis.crossMin(source), axis.crossMin(node.frame))
            let inBeam = crossOverlap > 0
            let crossGap = max(0, -crossOverlap)
            let primaryGap: CGFloat = axis.sign > 0
                ? max(0, axis.primaryMin(node.frame) - axis.primaryMax(source))
                : max(0, axis.primaryMin(source) - axis.primaryMax(node.frame))

            // Prefer the same row/column, then nearby staggered controls. Cross-axis distance
            // is a soft penalty: a sparse or rearranged layout must still offer a target in
            // the requested half-plane, even at 45 degrees or beyond a control-size threshold.
            // The strict forward check above keeps exhausted edges from wrapping backwards.
            let score = hypot(primaryGap, crossGap * 2) + forward * 0.2 + cross * 0.15
            guard score.isFinite else { return nil }
            return Candidate(node: node, inBeam: inBeam, score: score, forward: forward, cross: cross)
        }
        return candidates.min(by: candidateOrder)?.node.id ?? current.id
    }

    static func regions(nodes: [AppNavigationNode], window: CGRect,
                        layout: AppNavigationLayout,
                        containers: [AppNavigationContainer] = []) -> [AppNavigationRegion] {
        guard valid(window) else { return [] }
        let visible = cleaned(nodes, within: window)
        guard !visible.isEmpty else { return [] }
        return containerRegions(visible, containers: containers, window: window, layout: layout)
    }

    /// Region arrays follow the observed container hierarchy, with direct controls before children.
    /// At an edge the current region remains selected; an absent/stale selection starts at the first.
    static func movedRegion(currentID: String?, direction: Int,
                            regions: [AppNavigationRegion]) -> String? {
        var seen = Set<String>()
        let regions = regions.filter { valid($0.frame) && !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard let first = regions.first else { return nil }
        guard let index = regions.firstIndex(where: { $0.id == currentID }) else { return first.id }
        guard direction != 0 else { return regions[index].id }
        let next = direction < 0 ? max(0, index - 1) : min(regions.count - 1, index + 1)
        return regions[next].id
    }

    private struct Axis {
        let horizontal: Bool
        let sign: CGFloat

        init?(_ direction: RemoteKey) {
            switch direction {
            case .left: horizontal = true; sign = -1
            case .right: horizontal = true; sign = 1
            case .up: horizontal = false; sign = -1
            case .down: horizontal = false; sign = 1
            default: return nil
            }
        }

        func primaryCenter(_ r: CGRect) -> CGFloat { horizontal ? r.midX : r.midY }
        func primaryMin(_ r: CGRect) -> CGFloat { horizontal ? r.minX : r.minY }
        func primaryMax(_ r: CGRect) -> CGFloat { horizontal ? r.maxX : r.maxY }
        func crossCenter(_ r: CGRect) -> CGFloat { horizontal ? r.midY : r.midX }
        func crossMin(_ r: CGRect) -> CGFloat { horizontal ? r.minY : r.minX }
        func crossMax(_ r: CGRect) -> CGFloat { horizontal ? r.maxY : r.maxX }
    }

    private struct Candidate {
        let node: AppNavigationNode
        let inBeam: Bool
        let score: CGFloat
        let forward: CGFloat
        let cross: CGFloat
    }

    private static func candidateOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.inBeam != b.inBeam { return a.inBeam }
        if a.score != b.score { return a.score < b.score }
        if a.forward != b.forward { return a.forward < b.forward }
        if a.cross != b.cross { return a.cross < b.cross }
        return a.node.id < b.node.id
    }

    private static func valid(_ r: CGRect) -> Bool {
        !r.isNull && !r.isInfinite && r.origin.x.isFinite && r.origin.y.isFinite
            // CGRect.width/height standardize negative dimensions; reject malformed AX sizes
            // using the raw size before any intersection can normalize them into visible controls.
            && r.size.width.isFinite && r.size.height.isFinite && r.size.width > 0 && r.size.height > 0
            && r.maxX.isFinite && r.maxY.isFinite && r.midX.isFinite && r.midY.isFinite
            && r.maxX > r.minX && r.maxY > r.minY
            && (r.width * r.height).isFinite
    }

    /// Resolve duplicate snapshot IDs independently of enumeration order. Prefer an actionable,
    /// focused representation; remaining ties use geometry and strings, never dictionary order.
    private static func cleaned(_ nodes: [AppNavigationNode], within window: CGRect? = nil) -> [AppNavigationNode] {
        let visible = nodes.compactMap { node -> AppNavigationNode? in
            guard valid(node.frame) else { return nil }
            let frame = window.map { node.frame.intersection($0) } ?? node.frame
            guard valid(frame) else { return nil }
            return AppNavigationNode(id: node.id, label: node.label, role: node.role,
                                     frame: frame, kind: node.kind, focused: node.focused, containerIDs: node.containerIDs)
        }.sorted { a, b in
            if a.id != b.id { return a.id < b.id }
            if (a.kind == .scrollArea) != (b.kind == .scrollArea) { return a.kind != .scrollArea }
            if a.focused != b.focused { return a.focused }
            if a.frame != b.frame { return frameOrder(a.frame, b.frame) }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.label != b.label { return a.label < b.label }
            if a.role != b.role { return a.role < b.role }
            return Set(a.containerIDs).sorted().lexicographicallyPrecedes(Set(b.containerIDs).sorted())
        }
        var seen = Set<Int>()
        return visible.filter { seen.insert($0.id).inserted }
    }

    private static func frameOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        if a.minY != b.minY { return a.minY < b.minY }
        if a.minX != b.minX { return a.minX < b.minX }
        if a.height != b.height { return a.height < b.height }
        return a.width < b.width
    }

    private static func readingOrder(_ a: AppNavigationNode, _ b: AppNavigationNode) -> Bool {
        if a.frame.minY != b.frame.minY { return a.frame.minY < b.frame.minY }
        if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
        return a.id < b.id
    }

    private static func union(_ frames: [CGRect]) -> CGRect? {
        let frame = frames.reduce(CGRect.null) { $0.union($1) }
        return valid(frame) ? frame : nil
    }

    private enum ContainerKind {
        case group, list, menu, tabs, toolbar, scroll, media

        init(_ role: String) {
            switch role.lowercased() {
            case "axlist", "axoutline", "axtable", "axgrid", "axbrowser": self = .list
            case "axmenu", "axmenubar": self = .menu
            case "axtabgroup", "axradiogroup": self = .tabs
            case "axtoolbar": self = .toolbar
            case "axscrollarea": self = .scroll
            case "axvideo", "axplayer": self = .media
            default: self = .group
            }
        }
    }

    private struct Partition {
        var region: AppNavigationRegion
        let owner: Int?
        let input: Bool
        let path: [Int]
    }

    private static func mediaLabel(_ label: String) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["视频", "视频区域", "播放器", "视频播放器", "video", "player",
                "video player", "playback", "video playback"].contains(label)
    }

    /// The tree supplies boundaries; geometry only clips observed frames to the visible window.
    /// Container membership is reconstructed from parent IDs, independent of AX enumeration order.
    private static func containerRegions(_ nodes: [AppNavigationNode], containers: [AppNavigationContainer],
                                         window: CGRect, layout: AppNavigationLayout) -> [AppNavigationRegion] {
        var byID: [Int: AppNavigationContainer] = [:]
        for value in containers.filter({ valid($0.frame) }).sorted(by: {
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.frame != $1.frame { return frameOrder($0.frame, $1.frame) }
            if $0.label != $1.label { return $0.label < $1.label }
            if $0.role != $1.role { return $0.role < $1.role }
            return ($0.parentID ?? Int.min) < ($1.parentID ?? Int.min)
        }) {
            let frame = value.frame.intersection(window)
            guard valid(frame), byID[value.id] == nil else { continue }
            byID[value.id] = AppNavigationContainer(id: value.id, parentID: value.parentID,
                                                     label: value.label, role: value.role, frame: frame)
        }
        guard !byID.isEmpty else { return genericRegions(nodes, layout: layout) }
        let kinds = byID.mapValues { ContainerKind($0.role) }
        var ancestors: [Int: [Int]] = [:]
        for id in byID.keys {
            var path: [Int] = [], seen: Set<Int> = [id]
            var parent = byID[id]?.parentID
            while let next = parent, byID[next] != nil, seen.insert(next).inserted {
                path.append(next)
                parent = byID[next]?.parentID
            }
            ancestors[id] = path
        }
        func depth(_ id: Int) -> Int { ancestors[id]?.count ?? 0 }
        func path(_ id: Int) -> [Int] { Array((ancestors[id] ?? []).reversed()) + [id] }
        var memberships: [Int: Set<Int>] = [:]
        for node in nodes {
            var membership = Set(node.containerIDs.filter { byID[$0] != nil })
            for id in membership { membership.formUnion(ancestors[id] ?? []) }
            memberships[node.id] = membership
        }
        let controls = nodes.filter { $0.kind != .scrollArea }
        var members: [Int: Set<Int>] = [:]
        for node in controls {
            for id in memberships[node.id] ?? [] { members[id, default: []].insert(node.id) }
        }
        // A real scroll node must back every scroll operation. Exact frame matches also support
        // snapshots whose older reader omitted the scroll container itself from containerIDs.
        var anchors: [Int: AppNavigationNode] = [:]
        var matchedScrollIDs = Set<Int>()
        for node in nodes where node.kind == .scrollArea {
            var matching = (memberships[node.id] ?? []).filter { kinds[$0] == .scroll }
            if matching.isEmpty {
                matching = Set(byID.values.filter { kinds[$0.id] == .scroll && $0.frame == node.frame }.map(\.id))
            }
            if let owner = matching.sorted(by: { depth($0) == depth($1) ? $0 < $1 : depth($0) > depth($1) }).first {
                if anchors[owner] == nil { anchors[owner] = node }
                matchedScrollIDs.insert(node.id)
            }
        }
        let semantic = Set(byID.keys.filter {
            kinds[$0] != .group && (!(members[$0] ?? []).isEmpty || anchors[$0] != nil || kinds[$0] == .media)
        })
        var candidates = semantic
        var inputGroups = Set<Int>()
        for (id, container) in byID where kinds[id] == .group {
            let own = members[id] ?? []
            guard own.count >= 2 || (layout == .video && mediaLabel(container.label)) else { continue }
            let semanticChildren = semantic.filter { (ancestors[$0] ?? []).contains(id) }
            let childMembers = semanticChildren.reduce(into: Set<Int>()) { $0.formUnion(members[$1] ?? []) }
            let direct = own.subtracting(childMembers)
            let hasInput = controls.contains { own.contains($0.id) && $0.kind == .input }
            let collectionAncestor = (ancestors[id] ?? []).contains {
                kinds[$0] != .group && kinds[$0] != .media
            }
            // Anonymous message/row wrappers inside a scroll/list stay with that collection.
            // A real input group or a group with its own controls AND a nested semantic list
            // remains a boundary, including when the two menus occupy the same X coordinates.
            let dedicatedInput = hasInput && semanticChildren.isEmpty
            if dedicatedInput { inputGroups.insert(id) }
            if dedicatedInput || (!collectionAncestor && semanticChildren.isEmpty)
                || (!semanticChildren.isEmpty && !direct.isEmpty)
                || (layout == .video && mediaLabel(container.label)) {
                candidates.insert(id)
            }
        }
        // Collapse equal-membership wrapping chains. Semantic collections beat generic DOM
        // wrappers, and a more specific semantic child beats an enclosing scroll/root wrapper.
        let initial = candidates
        candidates = candidates.filter { id in
            let own = members[id] ?? []
            if kinds[id] == .group && !own.isEmpty && (ancestors[id] ?? []).contains(where: {
                initial.contains($0) && kinds[$0] != .group && kinds[$0] != .scroll && members[$0] == own
            }) { return false }
            return !initial.contains { child in
                child != id && !own.isEmpty && members[child] == own
                    && (ancestors[child] ?? []).contains(id)
                    && (kinds[child] != .group || kinds[id] == .group)
            }
        }
        func closestCandidate(_ ids: Set<Int>) -> Int? {
            ids.intersection(candidates).sorted {
                depth($0) == depth($1) ? $0 < $1 : depth($0) > depth($1)
            }.first
        }
        func parentCandidate(_ id: Int) -> Int? {
            (ancestors[id] ?? []).first { candidates.contains($0) }
        }
        func anchor(_ id: Int) -> AppNavigationNode? {
            ([id] + (ancestors[id] ?? [])).compactMap { anchors[$0] }.first
        }
        func baseID(_ id: Int) -> String { "container-\(id)" }
        func title(_ id: Int, direct: Bool) -> String {
            let chain = [id] + (ancestors[id] ?? []).prefix { members[$0] == members[id] }
            if let label = chain.compactMap({ byID[$0]?.label.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) { return label }
            let nested = parentCandidate(id) != nil
            switch kinds[id] ?? .group {
            case .list: return nested ? "内层列表" : "列表"
            case .menu: return nested ? "内层菜单" : "外层菜单"
            case .tabs: return "标签栏"
            case .toolbar: return "工具栏"
            case .scroll: return "滚动内容"
            case .media: return "播放器"
            case .group:
                if inputGroups.contains(id) { return "输入" }
                let insideMenu = (ancestors[id] ?? []).contains {
                    kinds[$0] == .list || kinds[$0] == .menu || kinds[$0] == .tabs
                }
                return direct ? (insideMenu ? "内层控件" : "外层菜单") : "控件"
            }
        }
        var ownerByNode: [Int: Int] = [:]
        for node in controls { ownerByNode[node.id] = closestCandidate(memberships[node.id] ?? []) }
        var buckets: [Int: [AppNavigationNode]] = [:]
        var inputNodes: [(AppNavigationNode, Int?)] = []
        var unowned: [AppNavigationNode] = []
        for node in controls {
            guard let owner = ownerByNode[node.id] else {
                if node.kind == .input { inputNodes.append((node, nil)) } else { unowned.append(node) }
                continue
            }
            if node.kind == .input && !inputGroups.contains(owner) && kinds[owner] != .toolbar {
                inputNodes.append((node, owner))
            } else { buckets[owner, default: []].append(node) }
        }
        var partitions: [Partition] = []
        for id in candidates.sorted() {
            guard let container = byID[id] else { continue }
            let own = buckets[id] ?? []
            let ownIDs = Set(own.map(\.id)), allIDs = members[id] ?? []
            let subdivided = ownIDs != allIDs
            let hasChildFace = candidates.contains { $0 != id && (ancestors[$0] ?? []).contains(id) }
            let backing = anchor(id)
            let isMedia = layout == .video && (kinds[id] == .media || mediaLabel(container.label))
            let emptyScroll = allIDs.isEmpty && !hasChildFace && anchors[id] != nil
            guard !own.isEmpty || emptyScroll || (isMedia && !hasChildFace) else { continue }
            let vertical: AppNavigationRegion.Vertical = isMedia ? .native
                : (kinds[id] == .scroll && anchors[id] != nil ? .scroll : .buttons)
            // A parent exposing only some direct controls uses those controls' union, rather
            // than its entire frame, so its inner list is a distinct selectable face.
            let frame: CGRect?
            if vertical == .scroll || isMedia { frame = container.frame }
            else if subdivided { frame = union(own.map(\.frame)) }
            else { frame = union([container.frame] + own.map(\.frame)) }
            guard let frame, valid(frame) else { continue }
            let ownRegionID = subdivided ? "\(baseID(id))-direct" : baseID(id)
            let parentID = subdivided ? baseID(id) : parentCandidate(id).map(baseID)
            partitions.append(Partition(region: AppNavigationRegion(
                id: ownRegionID, title: title(id, direct: subdivided), frame: frame,
                nodeIDs: own.sorted(by: readingOrder).map(\.id), vertical: vertical,
                scrollNodeID: backing?.id, parentID: parentID), owner: id, input: false, path: path(id)))
        }
        for (node, owner) in inputNodes {
            partitions.append(Partition(region: AppNavigationRegion(
                id: "input-\(node.id)", title: node.label.isEmpty ? "输入" : node.label,
                frame: node.frame, nodeIDs: [node.id], vertical: .buttons,
                parentID: owner.map(baseID)), owner: owner, input: true,
                path: owner.map(path) ?? [Int.max, node.id]))
        }
        // Only actual descendant faces are subtracted; spatial proximity never establishes
        // a parent/child relation. This keeps an enclosing scroll highlight off a real composer.
        for index in partitions.indices where partitions[index].region.vertical != .buttons {
            guard let owner = partitions[index].owner else { continue }
            let exclusions = partitions.enumerated().compactMap { otherIndex, other -> CGRect? in
                guard otherIndex != index, let otherOwner = other.owner,
                      (otherOwner == owner && other.input) || (ancestors[otherOwner] ?? []).contains(owner) else { return nil }
                return other.region.frame
            }
            let points = (buckets[owner] ?? []).map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            if let frame = remainingFrame(partitions[index].region.frame, excluding: exclusions, preferring: points) {
                partitions[index].region = replacingFrame(partitions[index].region, frame)
            }
        }
        partitions.sort {
            if $0.path != $1.path { return $0.path.lexicographicallyPrecedes($1.path) }
            if $0.input != $1.input { return !$0.input }
            return $0.region.id < $1.region.id
        }
        let represented = Set(partitions.flatMap { $0.region.nodeIDs })
        let unknownScrolls = nodes.filter { $0.kind == .scrollArea && !matchedScrollIDs.contains($0.id) }
        let rest = unowned.filter { !represented.contains($0.id) } + unknownScrolls
        let result = partitions.map(\.region) + genericRegions(rest, layout: layout)
        return result.isEmpty ? genericRegions(nodes, layout: layout) : result
    }

    private static func replacingFrame(_ region: AppNavigationRegion, _ frame: CGRect) -> AppNavigationRegion {
        AppNavigationRegion(id: region.id, title: region.title, frame: frame, nodeIDs: region.nodeIDs,
                            vertical: region.vertical, scrollNodeID: region.scrollNodeID, parentID: region.parentID)
    }

    /// Return an actual rectangular portion of a scroll frame after removing observed child
    /// regions. No point or area outside the original AX frame can be created here.
    private static func remainingFrame(_ frame: CGRect, excluding: [CGRect], preferring points: [CGPoint] = []) -> CGRect? {
        var fragments = [frame]
        for exclusion in excluding {
            fragments = fragments.flatMap { source -> [CGRect] in
                let cut = source.intersection(exclusion)
                guard valid(cut) else { return [source] }
                return [CGRect(x: source.minX, y: source.minY, width: source.width, height: cut.minY - source.minY),
                        CGRect(x: source.minX, y: cut.maxY, width: source.width, height: source.maxY - cut.maxY),
                        CGRect(x: source.minX, y: cut.minY, width: cut.minX - source.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: source.maxX - cut.maxX, height: cut.height)].filter(valid)
            }
            // A bounded fallback remains deterministic for unusually large AX trees.
            if fragments.count > 128 { fragments = Array(fragments.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(128)) }
        }
        return fragments.sorted { a, b in
            let first = points.filter { a.contains($0) }.count, second = points.filter { b.contains($0) }.count
            if first != second { return first > second }
            let firstArea = a.width * a.height, secondArea = b.width * b.height
            return firstArea == secondArea ? frameOrder(a, b) : firstArea > secondArea
        }.first
    }

    /// Missing hierarchy means a conservative generic fallback, shared by every app layout.
    /// Only actual scroll views and input nodes introduce boundaries; no sidebar is guessed.
    private static func genericRegions(_ nodes: [AppNavigationNode], layout: AppNavigationLayout) -> [AppNavigationRegion] {
        guard !nodes.isEmpty else { return [] }
        let scrolls = nodes.filter { $0.kind == .scrollArea }.sorted { $0.id < $1.id }
        let anchors = scrolls.filter { outer in
            !scrolls.contains { inner in
                inner.id != outer.id && outer.frame.contains(inner.frame)
                    && (inner.frame != outer.frame || inner.id < outer.id)
            }
        }
        let controls = nodes.filter { $0.kind != .scrollArea }
        let inputs = controls.filter { $0.kind == .input }
        var assigned = Set<Int>(), result: [AppNavigationRegion] = []
        for anchor in anchors.sorted(by: readingOrder) {
            let members = controls.filter {
                $0.kind != .input && !assigned.contains($0.id)
                    && anchor.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            assigned.formUnion(members.map(\.id))
            let frame = remainingFrame(anchor.frame, excluding: inputs.map(\.frame),
                                       preferring: members.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }) ?? anchor.frame
            result.append(AppNavigationRegion(id: "scroll-\(anchor.id)",
                                              title: anchor.label.isEmpty ? "滚动内容" : anchor.label,
                                              frame: frame, nodeIDs: members.sorted(by: readingOrder).map(\.id),
                                              vertical: layout == .video && mediaLabel(anchor.label) ? .native : .scroll,
                                              scrollNodeID: anchor.id))
        }
        let remaining = controls.filter { $0.kind != .input && !assigned.contains($0.id) }
        if let frame = union(remaining.map(\.frame)) {
            result.append(AppNavigationRegion(id: "controls", title: "控件", frame: frame,
                                              nodeIDs: remaining.sorted(by: readingOrder).map(\.id), vertical: .buttons))
        }
        for input in inputs.sorted(by: readingOrder) {
            result.append(AppNavigationRegion(id: "input-\(input.id)", title: input.label.isEmpty ? "输入" : input.label,
                                              frame: input.frame, nodeIDs: [input.id], vertical: .buttons))
        }
        return result
    }

    /// Synthetic snapshots only: no application lookup, event posting, AX access, or UI side effects.
    static func selfCheck() -> Bool {
        func failure(_ label: String) -> Bool {
            print("AppNavigationGeometry.selfCheck failed: \(label)")
            return false
        }
        func node(_ id: Int, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 40, _ h: CGFloat = 40,
                  _ kind: AppNavigationNode.Kind = .button, focused: Bool = false) -> AppNavigationNode {
            AppNavigationNode(id: id, label: "\(id)",
                              role: kind == .scrollArea ? "AXScrollArea" : (kind == .input ? "AXTextArea" : "AXButton"),
                              frame: CGRect(x: x, y: y, width: w, height: h), kind: kind, focused: focused)
        }
        let grid = [node(1, 100, 100), node(2, 100, 20), node(3, 100, 180),
                    node(4, 20, 100), node(5, 180, 100), node(6, 80, 80, 100, 100, .scrollArea)]
        guard target(currentID: 1, direction: .up, nodes: grid) == 2,
              target(currentID: 1, direction: .down, nodes: grid) == 3,
              target(currentID: 1, direction: .left, nodes: grid) == 4,
              target(currentID: 1, direction: .right, nodes: grid) == 5,
              target(currentID: 2, direction: .up, nodes: grid) == 2,
              target(currentID: 3, direction: .down, nodes: grid) == 3,
              target(currentID: 4, direction: .left, nodes: grid) == 4,
              target(currentID: 5, direction: .right, nodes: grid) == 5,
              target(currentID: 1, direction: .ok, nodes: grid) == 1 else { return failure("four directions and grid edge") }

        let beam = [node(1, 0, 0), node(2, 100, 10), node(3, 65, 45)]
        let list = [node(1, 0, 0, 180, 30), node(2, 0, 60, 180, 30), node(3, 0, 120, 180, 30)]
        guard target(currentID: 1, direction: .right, nodes: beam) == 2,
              target(currentID: 1, direction: .down, nodes: list) == 2,
              target(currentID: 2, direction: .down, nodes: list) == 3,
              target(currentID: 3, direction: .down, nodes: list) == 3,
              target(currentID: 1, direction: .right, nodes: [node(1, 0, 0), node(2, 60, 45)]) == 2 else {
            return failure("beam priority, list, and staggered neighbor")
        }

        // Sparse layouts deliberately permit diagonal fallback; angle and control-size limits
        // previously left both of these two-button snapshots without any movement at all.
        let diagonal = [node(1, 0, 0), node(2, 120, 120)]
        let sparse = [node(1, 0, 0), node(2, 300, 500)]
        for pair in [diagonal, sparse] {
            guard target(currentID: 1, direction: .right, nodes: pair) == 2,
                  target(currentID: 1, direction: .down, nodes: pair) == 2,
                  target(currentID: 2, direction: .left, nodes: pair) == 1,
                  target(currentID: 2, direction: .up, nodes: pair) == 1,
                  target(currentID: 1, direction: .left, nodes: pair) == 1,
                  target(currentID: 2, direction: .right, nodes: pair) == 2 else {
                return failure("45-degree and distant diagonal fallback without wrapping")
            }
        }

        let toolbar = [node(1, 0, 0, 50, 30), node(2, 180, 60, 80, 35),
                       node(3, 490, 135, 40, 25), node(4, 1_000, 240, 100, 50),
                       node(99, 0, 0, 1_100, 300, .scrollArea)]
        for snapshot in [toolbar, Array(toolbar.reversed())] {
            guard target(currentID: 1, direction: .right, nodes: snapshot) == 2,
                  target(currentID: 2, direction: .right, nodes: snapshot) == 3,
                  target(currentID: 3, direction: .right, nodes: snapshot) == 4,
                  target(currentID: 4, direction: .left, nodes: snapshot) == 3,
                  target(currentID: 3, direction: .left, nodes: snapshot) == 2,
                  target(currentID: 2, direction: .left, nodes: snapshot) == 1,
                  target(currentID: 4, direction: .right, nodes: snapshot) == 4 else {
                return failure("irregular toolbar nearest neighbors and snapshot-order stability")
            }
        }
        let rearranged = [node(1, 0, 0), node(2, 500, 140), node(3, 120, 60)]
        let nearDiagonal = [node(1, 0, 0), node(2, 80, 80), node(3, 500, 100)]
        let wideInput = [node(1, 0, 0, 400, 40, .input), node(2, 380, 5, 40, 30)]
        guard target(currentID: 1, direction: .right, nodes: rearranged) == 3,
              target(currentID: 1, direction: .right, nodes: nearDiagonal) == 2,
              target(currentID: 1, direction: .right, nodes: wideInput) == 2,
              target(currentID: 2, direction: .left, nodes: wideInput) == 1 else {
            return failure("live rearranged frames, nearby diagonals, and overlapping wide input")
        }

        let invalid = [node(9, .nan, 0), node(8, 0, 0, -10, 10), node(10, 0, 0, 10, -10), node(7, 0, 0, 0, 10),
                       node(6, .infinity, 0), node(5, 0, 0, 50, 50, .scrollArea)]
        let ties = [node(1, 0, 0), node(8, 100, -30), node(7, 100, 30), node(7, 500, 400)]
        let start = [node(2, 300, 300, 80, 40, .input, focused: true), node(1, 0, 0)]
        guard target(currentID: nil, direction: .right, nodes: invalid) == nil,
              target(currentID: nil, direction: .down, nodes: start) == 2,
              target(currentID: 99, direction: .down, nodes: list) == 1,
              target(currentID: 1, direction: .right, nodes: ties) == 7,
              target(currentID: 1, direction: .right, nodes: Array(ties.reversed())) == 7,
              target(currentID: 1, direction: .right, nodes: grid + invalid) == 5 else {
            return failure("invalid frames, focused input, duplicates, and ties")
        }

        func scoped(_ node: AppNavigationNode, _ ids: [Int]) -> AppNavigationNode {
            var node = node
            node.containerIDs = ids
            return node
        }
        func container(_ id: Int, _ parent: Int?, _ role: String, _ label: String,
                       _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> AppNavigationContainer {
            AppNavigationContainer(id: id, parentID: parent, label: label, role: role,
                                   frame: CGRect(x: x, y: y, width: width, height: height))
        }
        let window = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let tree = [container(100, nil, "AXGroup", "", 0, 0, 1_200, 800),
                    container(110, 100, "AXGroup", "导航", 0, 0, 300, 700),
                    container(111, 110, "AXGroup", "", 0, 0, 300, 700),
                    container(112, 111, "AXGroup", "", 0, 0, 300, 700),
                    container(120, 112, "AXList", "历史列表", 0, 200, 300, 500),
                    container(121, 120, "AXGroup", "", 10, 250, 280, 60),
                    container(122, 120, "AXGroup", "", 10, 350, 280, 60),
                    container(200, 100, "AXScrollArea", "对话", 300, 0, 900, 700),
                    container(210, 200, "AXGroup", "", 320, 100, 840, 100),
                    container(211, 210, "AXGroup", "", 320, 100, 840, 100),
                    container(220, 200, "AXGroup", "", 320, 300, 840, 100),
                    container(300, 100, "AXToolbar", "输入工具栏", 300, 700, 900, 100),
                    container(301, 300, "AXGroup", "", 300, 700, 900, 100)]
        let chat = [scoped(node(1, 20, 20, 60, 30), [112]), scoped(node(2, 20, 80, 60, 30), [112]),
                    scoped(node(3, 20, 250, 200, 30), [121]), scoped(node(4, 20, 350, 200, 30), [122]),
                    scoped(node(5, 240, 350, 30, 30), [122]),
                    scoped(node(50, 300, 0, 900, 700, .scrollArea), [200]),
                    scoped(node(6, 400, 120), [211]), scoped(node(7, 500, 120), [211]),
                    scoped(node(8, 400, 320), [220]), scoped(node(9, 500, 320), [220]),
                    scoped(node(10, 400, 720, 600, 50, .input), [301]), scoped(node(11, 1_040, 730), [301])]
        let chatRegions = regions(nodes: chat, window: window, layout: .chat, containers: tree)
        guard chatRegions.map(\.id) == ["container-112-direct", "container-120", "container-200", "container-300"],
              chatRegions.map(\.nodeIDs) == [[1, 2], [3, 4, 5], [6, 7, 8, 9], [10, 11]],
              chatRegions[0].title == "导航", chatRegions[1].title == "历史列表",
              chatRegions[0].parentID == "container-112", chatRegions[1].parentID == "container-112",
              chatRegions[0].frame.maxY < chatRegions[1].frame.minY,
              chatRegions[0].vertical == .buttons, chatRegions[1].vertical == .buttons,
              chatRegions[2].vertical == .scroll, chatRegions[2].scrollNodeID == 50,
              chatRegions[3].vertical == .buttons, chatRegions[3].title == "输入工具栏",
              chatRegions[2].frame.maxY <= chatRegions[3].frame.minY,
              Set(chatRegions.flatMap(\.nodeIDs)).count == 11,
              !chatRegions.flatMap(\.nodeIDs).contains(50),
              movedRegion(currentID: chatRegions[0].id, direction: -1, regions: chatRegions) == chatRegions[0].id,
              movedRegion(currentID: chatRegions[0].id, direction: 1, regions: chatRegions) == chatRegions[1].id,
              movedRegion(currentID: chatRegions[3].id, direction: 1, regions: chatRegions) == chatRegions[3].id else {
            return failure("nested same-X menus, DOM wrappers, message wrappers, and input toolbar")
        }

        let expandedTree = tree + [container(123, 120, "AXOutline", "展开列表", 20, 420, 260, 220),
                                   container(124, 123, "AXList", "更深列表", 20, 560, 260, 60)]
        let expandedNodes = chat + [scoped(node(12, 40, 450), [123]), scoped(node(13, 40, 510), [123]),
                                    scoped(node(14, 40, 570), [124])]
        let expanded = regions(nodes: expandedNodes, window: window, layout: .chat, containers: expandedTree)
        guard expanded.map(\.id) == ["container-112-direct", "container-120-direct", "container-123-direct",
                                      "container-124", "container-200", "container-300"],
              expanded[1].nodeIDs == [3, 4, 5], expanded[2].nodeIDs == [12, 13], expanded[3].nodeIDs == [14],
              expanded[2].parentID == "container-123", expanded[3].parentID == "container-123",
              Set(expanded.flatMap(\.nodeIDs)).count == 14 else {
            return failure("multiple expanded list levels preserve direct controls")
        }

        let enclosingScrollTree = tree.map { value in
            AppNavigationContainer(id: value.id, parentID: value.id == 300 ? 200 : value.parentID,
                                   label: value.label, role: value.role,
                                   frame: value.id == 200 ? CGRect(x: 300, y: 0, width: 900, height: 800) : value.frame)
        }
        let enclosingScrollNodes = chat.map { value in
            AppNavigationNode(id: value.id, label: value.label, role: value.role,
                              frame: value.id == 50 ? CGRect(x: 300, y: 0, width: 900, height: 800) : value.frame,
                              kind: value.kind, focused: value.focused, containerIDs: value.containerIDs)
        }
        let enclosingScroll = regions(nodes: enclosingScrollNodes, window: window, layout: .chat,
                                      containers: enclosingScrollTree)
        guard let scrolling = enclosingScroll.first(where: { $0.vertical == .scroll }),
              let toolbar = enclosingScroll.first(where: { $0.id == "container-300" }),
              scrolling.nodeIDs == [6, 7, 8, 9], scrolling.frame.maxY == 700,
              toolbar.nodeIDs == [10, 11], toolbar.parentID == "container-200",
              !scrolling.frame.intersects(toolbar.frame) else {
            return failure("enclosing scroll excludes its real descendant input toolbar")
        }

        // Anisotropic resize and translation move a narrow outer menu and its same-X inner
        // list together. Membership, rather than a fraction of the window width, defines them.
        func transform(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX * 0.37 - 1_800, y: frame.minY * 0.7 + 500,
                   width: frame.width * 0.37, height: frame.height * 0.7)
        }
        let resizedNodes = chat.map { value in
            AppNavigationNode(id: value.id, label: value.label, role: value.role,
                              frame: transform(value.frame), kind: value.kind, focused: value.focused,
                              containerIDs: value.containerIDs.reversed())
        }
        let resizedTree = tree.reversed().map { value in
            AppNavigationContainer(id: value.id, parentID: value.parentID, label: value.label,
                                   role: value.role, frame: transform(value.frame))
        }
        let resized = regions(nodes: resizedNodes, window: transform(window), layout: .chat, containers: resizedTree)
        guard resized.map(\.id) == chatRegions.map(\.id), resized.map(\.nodeIDs) == chatRegions.map(\.nodeIDs),
              resized.map(\.vertical) == chatRegions.map(\.vertical),
              target(currentID: 1, direction: .down, nodes: resizedNodes) == 2 else {
            return failure("narrow menu, resized/translated window, and unordered containers")
        }

        let playerTree = [container(450, nil, "AXGroup", "播放器", 300, 0, 700, 600)]
        let playerNodes = [scoped(node(70, 600, 500), [450])]
        let player = regions(nodes: playerNodes, window: window, layout: .video, containers: playerTree)
        let plainVideo = regions(nodes: [node(71, 600, 500)], window: window, layout: .video)
        let missingTreeNodes = [node(80, 0, 0, 1_200, 800, .scrollArea), node(81, 20, 20),
                                node(82, 900, 300), node(83, 300, 700, 600, 100, .input)]
        let missingTree = regions(nodes: missingTreeNodes, window: window, layout: .chat)
        let missingTreeVideo = regions(nodes: missingTreeNodes, window: window, layout: .video)
        let onlyControls = regions(nodes: [node(91, 20, 20), node(92, 1_100, 700)], window: window, layout: .chat)
        guard player.count == 1, player[0].vertical == .native,
              plainVideo.count == 1, plainVideo[0].vertical == .buttons,
              missingTree.map(\.id) == ["scroll-80", "input-83"], missingTree[0].nodeIDs == [81, 82],
              missingTree[0].frame.maxY == 700, missingTree[0].vertical == .scroll,
              missingTree.map(\.id) == missingTreeVideo.map(\.id),
              missingTree.map(\.vertical) == missingTreeVideo.map(\.vertical),
              onlyControls.count == 1, onlyControls[0].id == "controls", onlyControls[0].nodeIDs == [91, 92],
              regions(nodes: chat, window: .null, layout: .chat, containers: tree).isEmpty,
              regions(nodes: invalid, window: window, layout: .chat).count == 1,
              movedRegion(currentID: nil, direction: 1, regions: []) == nil else {
            return failure("real player label, no-tree generic fallback, input clipping, and invalid windows")
        }

        let anonymousTree = [container(600, nil, "AXGroup", "", 0, 0, 400, 400),
                             container(601, 600, "AXGroup", "", 0, 0, 400, 400),
                             container(602, 601, "AXGroup", "", 0, 0, 400, 400),
                             container(603, 602, "AXGroup", "", 0, 0, 200, 100),
                             container(604, 602, "AXGroup", "", 0, 200, 200, 100)]
        let anonymousNodes = [scoped(node(93, 20, 20), [603]), scoped(node(94, 20, 220), [604])]
        let anonymous = regions(nodes: anonymousNodes, window: window, layout: .chat, containers: anonymousTree)
        let unnamedNested = regions(nodes: chat, window: window, layout: .chat,
                                    containers: tree.map { AppNavigationContainer(id: $0.id, parentID: $0.parentID,
                                                                                 label: "", role: $0.role, frame: $0.frame) })
        let cycle = [container(700, 701, "AXGroup", "", 0, 0, 400, 400),
                     container(701, 700, "AXGroup", "", 0, 0, 400, 400)]
        let cyclic = regions(nodes: [scoped(node(95, 20, 20), [700]), scoped(node(96, 20, 220), [701])],
                             window: window, layout: .chat, containers: cycle)
        guard anonymous.count == 1, anonymous[0].nodeIDs == [93, 94],
              unnamedNested[0].title == "外层菜单", unnamedNested[1].title == "内层列表",
              Set(cyclic.flatMap(\.nodeIDs)) == [95, 96], cyclic.flatMap(\.nodeIDs).count == 2 else {
            return failure("anonymous same-set wrappers, hierarchy titles, and malformed parent cycle")
        }
        return true
    }
}
