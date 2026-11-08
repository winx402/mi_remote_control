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

            if !inBeam {
                // A narrow direction cone admits nearby staggered controls. Additional bounds,
                // relative to actual control sizes, prevent an exhausted list from jumping to
                // an unrelated distant diagonal column. Directly aligned controls remain reachable.
                guard cross <= forward * 0.75,
                      crossGap <= max(axis.crossSize(source), axis.crossSize(node.frame)) * 1.5,
                      primaryGap <= max(axis.primarySize(source), axis.primarySize(node.frame)) * 6 else {
                    return nil
                }
            }
            let score = hypot(primaryGap, crossGap * 2) + forward * 0.2 + cross * 0.15
            guard score.isFinite else { return nil }
            return Candidate(node: node, inBeam: inBeam, score: score, forward: forward, cross: cross)
        }
        return candidates.min(by: candidateOrder)?.node.id ?? current.id
    }

    static func regions(nodes: [AppNavigationNode], window: CGRect,
                        layout: AppNavigationLayout) -> [AppNavigationRegion] {
        guard valid(window) else { return [] }
        let visible = cleaned(nodes, within: window)
        guard !visible.isEmpty else { return [] }
        switch layout {
        case .automatic: return automaticRegions(visible)
        case .chat: return arrangedRegions(visible, window: window, video: false)
        case .video: return arrangedRegions(visible, window: window, video: true)
        }
    }

    /// Region arrays define the semantic order: navigation, content, comments, then composer.
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
        func primarySize(_ r: CGRect) -> CGFloat { horizontal ? r.width : r.height }
        func crossCenter(_ r: CGRect) -> CGFloat { horizontal ? r.midY : r.midX }
        func crossMin(_ r: CGRect) -> CGFloat { horizontal ? r.minY : r.minX }
        func crossMax(_ r: CGRect) -> CGFloat { horizontal ? r.maxY : r.maxX }
        func crossSize(_ r: CGRect) -> CGFloat { horizontal ? r.height : r.width }
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
                                     frame: frame, kind: node.kind, focused: node.focused)
        }.sorted { a, b in
            if a.id != b.id { return a.id < b.id }
            if (a.kind == .scrollArea) != (b.kind == .scrollArea) { return a.kind != .scrollArea }
            if a.focused != b.focused { return a.focused }
            if a.frame != b.frame { return frameOrder(a.frame, b.frame) }
            if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
            if a.label != b.label { return a.label < b.label }
            return a.role < b.role
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

    private static func makeRegion(id: String, title: String, nodes: [AppNavigationNode],
                                   anchor: AppNavigationNode? = nil,
                                   vertical: AppNavigationRegion.Vertical,
                                   clip: CGRect? = nil) -> AppNavigationRegion? {
        let controls = nodes.filter { $0.kind != .scrollArea }.filter {
            guard let clip else { return true }
            return valid($0.frame.intersection(clip))
        }.sorted(by: readingOrder)
        let anchorFrame = anchor.flatMap { node -> CGRect? in
            let frame = clip.map { node.frame.intersection($0) } ?? node.frame
            return valid(frame) ? frame : nil
        }
        let frames = controls.map { node in clip.map { node.frame.intersection($0) } ?? node.frame }
            + (anchorFrame.map { [$0] } ?? [])
        guard let frame = union(frames) else { return nil }
        // No synthetic scroll target or point can be introduced by a preset.
        guard vertical != .scroll || anchorFrame != nil else { return nil }
        return AppNavigationRegion(id: id, title: title, frame: frame,
                                   nodeIDs: controls.map(\.id), vertical: vertical,
                                   scrollNodeID: anchorFrame == nil ? nil : anchor?.id)
    }

    private static func largestAnchor(_ nodes: [AppNavigationNode], in clip: CGRect) -> AppNavigationNode? {
        nodes.filter { $0.kind == .scrollArea && valid($0.frame.intersection(clip)) }.sorted { a, b in
            let first = a.frame.intersection(clip), second = b.frame.intersection(clip)
            let firstArea = first.width * first.height, secondArea = second.width * second.height
            if firstArea != secondArea { return firstArea > secondArea }
            // For equivalent visible coverage prefer the more specific actual container.
            let firstFull = a.frame.width * a.frame.height, secondFull = b.frame.width * b.frame.height
            if firstFull != secondFull { return firstFull < secondFull }
            return a.id < b.id
        }.first
    }

    private static func hasColumnEvidence(_ nodes: [AppNavigationNode], window: CGRect,
                                          acceptsLowerInput: Bool = false) -> Bool {
        if nodes.contains(where: { $0.kind == .scrollArea && $0.frame.height >= window.height * 0.25 }) {
            return true
        }
        let controls = nodes.filter { $0.kind != .scrollArea }
        if acceptsLowerInput && controls.contains(where: {
            $0.kind == .input && $0.frame.midY >= window.minY + window.height * 0.4
        }) { return true }
        guard controls.count >= 2,
              let low = controls.map({ $0.frame.midY }).min(),
              let high = controls.map({ $0.frame.midY }).max() else { return false }
        return high - low >= window.height * 0.16
    }

    private static func arrangedRegions(_ nodes: [AppNavigationNode], window: CGRect,
                                        video: Bool) -> [AppNavigationRegion] {
        let leftCandidates = nodes.filter {
            $0.frame.midX <= window.minX + window.width * 0.29
                && $0.frame.maxX <= window.minX + window.width * 0.4
        }
        let sidebar = hasColumnEvidence(leftCandidates, window: window) ? leftCandidates : []
        let sidebarIDs = Set(sidebar.map(\.id))
        let leftEdge = union(sidebar.map(\.frame))?.maxX ?? window.minX

        let rightCandidates = video ? nodes.filter {
            !sidebarIDs.contains($0.id)
                && $0.frame.midX >= window.minX + window.width * 0.72
                && $0.frame.minX >= window.minX + window.width * 0.58
        } : []
        let comments = hasColumnEvidence(rightCandidates, window: window, acceptsLowerInput: true)
            ? rightCandidates : []
        let commentIDs = Set(comments.map(\.id))
        let rightEdge = union(comments.map(\.frame))?.minX ?? window.maxX

        let bottomInputs = video ? [] : nodes.filter {
            $0.kind == .input && !sidebarIDs.contains($0.id)
                && $0.frame.midY >= window.minY + window.height * 0.6
                && $0.frame.midX >= leftEdge
        }
        let inputTop = bottomInputs.map({ $0.frame.minY }).min()
        let inputIDs = Set(bottomInputs.map(\.id))
        let composer = inputTop.map { top in nodes.filter {
            $0.kind != .scrollArea && !sidebarIDs.contains($0.id)
                && (inputIDs.contains($0.id) || ($0.frame.midY >= top && $0.frame.midX >= leftEdge))
        } } ?? []
        let composerIDs = Set(composer.map(\.id))

        // Boundaries come from the observed side columns and input edge. Intersecting a large
        // real scroll container with these bounds keeps it from covering a separate input region.
        let contentBounds = CGRect(x: leftEdge, y: window.minY,
                                   width: rightEdge - leftEdge,
                                   height: (inputTop ?? window.maxY) - window.minY)
        let content = nodes.filter {
            !sidebarIDs.contains($0.id) && !commentIDs.contains($0.id) && !composerIDs.contains($0.id)
                && valid($0.frame.intersection(contentBounds))
        }

        var result: [AppNavigationRegion] = []
        if let frame = union(sidebar.map(\.frame)),
           let region = makeRegion(id: "navigation", title: "导航", nodes: sidebar,
                                   anchor: largestAnchor(sidebar, in: frame),
                                   vertical: sidebar.contains(where: { $0.kind != .scrollArea }) ? .buttons : .scroll) {
            result.append(region)
        }
        if valid(contentBounds) {
            let anchor = largestAnchor(content, in: contentBounds)
            let vertical: AppNavigationRegion.Vertical = video ? .native : (anchor == nil ? .buttons : .scroll)
            if let region = makeRegion(id: "content", title: video ? "视频" : "内容", nodes: content,
                                       anchor: anchor, vertical: vertical, clip: contentBounds) {
                result.append(region)
            }
        }
        if let frame = union(comments.map(\.frame)) {
            let anchor = largestAnchor(comments, in: frame)
            if let region = makeRegion(id: "comments", title: "评论", nodes: comments, anchor: anchor,
                                       vertical: anchor == nil ? .buttons : .scroll) {
                result.append(region)
            }
        }
        if let region = makeRegion(id: "input", title: "输入", nodes: composer, vertical: .buttons) {
            result.append(region)
        }
        if result.isEmpty || (result.count == 1 && result[0].id == "content" && result[0].vertical == .buttons) {
            return fallbackRegion(nodes)
        }
        return result
    }

    private static func automaticRegions(_ nodes: [AppNavigationNode]) -> [AppNavigationRegion] {
        let scrolls = nodes.filter { $0.kind == .scrollArea }
        // Prefer inner scroll views over a broad enclosing root. No AX hierarchy is inferred;
        // this is only a geometric fallback for apps without a chosen layout.
        let leaves = scrolls.filter { outer in
            !scrolls.contains { inner in
                guard inner.id != outer.id else { return false }
                let outerArea = outer.frame.width * outer.frame.height
                let innerArea = inner.frame.width * inner.frame.height
                return innerArea < outerArea * 0.95 && outer.frame.contains(inner.frame)
            }
        }.sorted {
            let a = $0.frame.width * $0.frame.height, b = $1.frame.width * $1.frame.height
            return a == b ? $0.id < $1.id : a < b
        }
        var anchors: [AppNavigationNode] = []
        for leaf in leaves {
            // Equivalent/overlapping AX scroll representations must not create duplicate regions.
            let overlaps = anchors.contains { anchor in
                let overlap = leaf.frame.intersection(anchor.frame)
                return valid(overlap) && overlap.width * overlap.height
                    > min(leaf.frame.width * leaf.frame.height, anchor.frame.width * anchor.frame.height) * 0.25
            }
            if !overlaps { anchors.append(leaf) }
        }
        guard !anchors.isEmpty else { return fallbackRegion(nodes) }
        let controls = nodes.filter { $0.kind != .scrollArea }
        var assigned = Set<Int>()
        var result: [AppNavigationRegion] = []
        for anchor in anchors.sorted(by: readingOrder) {
            let members = controls.filter {
                !assigned.contains($0.id) && anchor.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            assigned.formUnion(members.map(\.id))
            if let region = makeRegion(id: "scroll-\(anchor.id)", title: "滚动区域 \(result.count + 1)",
                                       nodes: members, anchor: anchor,
                                       vertical: members.isEmpty ? .scroll : .buttons) {
                result.append(region)
            }
        }
        let remaining = controls.filter { !assigned.contains($0.id) }
        result.append(contentsOf: fallbackRegion(remaining))
        return result
    }

    private static func fallbackRegion(_ nodes: [AppNavigationNode]) -> [AppNavigationRegion] {
        guard let region = makeRegion(id: "controls", title: "控件", nodes: nodes, vertical: .buttons) else {
            return []
        }
        return [region]
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
              target(currentID: 5, direction: .right, nodes: grid) == 5,
              target(currentID: 1, direction: .ok, nodes: grid) == 1 else { return failure("four directions and grid edge") }

        let beam = [node(1, 0, 0), node(2, 100, 10), node(3, 65, 45)]
        let list = [node(1, 0, 0, 180, 30), node(2, 0, 60, 180, 30), node(3, 0, 120, 180, 30)]
        guard target(currentID: 1, direction: .right, nodes: beam) == 2,
              target(currentID: 1, direction: .down, nodes: list) == 2,
              target(currentID: 2, direction: .down, nodes: list) == 3,
              target(currentID: 3, direction: .down, nodes: list) == 3,
              target(currentID: 1, direction: .right, nodes: [node(1, 0, 0), node(2, 300, 500)]) == 1,
              target(currentID: 1, direction: .down, nodes: [node(1, 0, 0), node(2, 300, 500)]) == 1,
              target(currentID: 1, direction: .right, nodes: [node(1, 0, 0), node(2, 60, 45)]) == 2 else {
            return failure("beam priority, list, and diagonal bounds")
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

        let window = CGRect(x: 100, y: 200, width: 1_000, height: 800)
        let chat = [node(1, 120, 240, 180, 36), node(2, 120, 440, 180, 36),
                    node(20, 100, 220, 220, 740, .scrollArea),
                    node(21, 100, 200, 1_000, 800, .scrollArea), node(41, 500, 400),
                    node(31, 400, 880, 480, 70, .input), node(32, 900, 900)]
        let chatRegions = regions(nodes: chat, window: window, layout: .chat)
        guard chatRegions.map(\.id) == ["navigation", "content", "input"],
              chatRegions[0].vertical == .buttons, chatRegions[0].nodeIDs == [1, 2],
              chatRegions[1].vertical == .scroll, chatRegions[1].scrollNodeID == 21,
              chatRegions[1].nodeIDs == [41], chatRegions[1].frame.minX == 320,
              chatRegions[1].frame.maxY == 880, chatRegions[2].nodeIDs == [31, 32],
              !chatRegions.flatMap(\.nodeIDs).contains(20), !chatRegions.flatMap(\.nodeIDs).contains(21),
              movedRegion(currentID: "navigation", direction: -1, regions: chatRegions) == "navigation",
              movedRegion(currentID: "content", direction: 1, regions: chatRegions) == "input",
              movedRegion(currentID: "input", direction: 1, regions: chatRegions) == "input",
              movedRegion(currentID: nil, direction: -1, regions: chatRegions) == "navigation" else {
            return failure("chat partitions and region edges")
        }

        let videoWindow = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let video = [node(1, 20, 100, 160, 40), node(2, 20, 300, 160, 40),
                     node(20, 0, 0, 1_200, 800, .scrollArea), node(3, 500, 650),
                     node(21, 850, 100, 330, 650, .scrollArea),
                     node(4, 950, 400), node(5, 860, 700, 270, 40, .input)]
        let videoRegions = regions(nodes: video, window: videoWindow, layout: .video)
        let fallback = regions(nodes: [node(1, 30, 30)], window: videoWindow, layout: .chat)
        let automatic = regions(nodes: [node(20, 0, 0, 200, 200, .scrollArea), node(1, 10, 10),
                                        node(2, 300, 300)], window: videoWindow, layout: .automatic)
        guard videoRegions.map(\.id) == ["navigation", "content", "comments"],
              videoRegions[1].vertical == .native, videoRegions[1].frame.maxX == 850,
              videoRegions[2].vertical == .scroll, videoRegions[2].scrollNodeID == 21,
              videoRegions[2].nodeIDs == [4, 5],
              fallback.count == 1, fallback[0].id == "controls", fallback[0].nodeIDs == [1],
              automatic.map(\.id) == ["scroll-20", "controls"],
              automatic[0].nodeIDs == [1], automatic[1].nodeIDs == [2],
              regions(nodes: chat, window: .null, layout: .chat).isEmpty,
              regions(nodes: invalid, window: videoWindow, layout: .chat).count == 1,
              movedRegion(currentID: nil, direction: 1, regions: []) == nil else {
            return failure("video partitions, automatic fallback, and invalid windows")
        }

        // Both classification and selection must work away from the primary screen origin.
        let shifted = chat.map { value in
            AppNavigationNode(id: value.id, label: value.label, role: value.role,
                              frame: value.frame.offsetBy(dx: -2_000, dy: 500), kind: value.kind,
                              focused: value.focused)
        }
        let shiftedRegions = regions(nodes: shifted, window: window.offsetBy(dx: -2_000, dy: 500), layout: .chat)
        guard shiftedRegions.map(\.id) == chatRegions.map(\.id),
              shiftedRegions.map(\.nodeIDs) == chatRegions.map(\.nodeIDs),
              target(currentID: 1, direction: .down, nodes: shifted) == 2 else {
            return failure("translated window and controls")
        }
        return true
    }
}
