import AppKit
import ApplicationServices
import CoreGraphics
import os

// BEGIN PURE APP NAVIGATION ACCESSIBILITY LOGIC
/// Pure policies used by the worker. Can be extracted with Foundation/CoreGraphics only.
enum AppNavigationAccessibilityLogic {
    static let containerRoles: Set<String> = [
        "AXGroup", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXTabGroup", "AXSplitGroup",
        "AXToolbar", "AXScrollArea", "AXRadioGroup", "AXGrid", "AXLayoutArea", "AXWebArea", "AXRow",
        "AXVideo", "AXPlayer"
    ]
    static let semanticButtonRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXDisclosureTriangle"
    ]
    private static let genericRoles: Set<String> = ["AXGroup", "AXGenericElement", "AXUnknown"]
    private static let buttonDescriptions: Set<String> = [
        "button", "push button", "toggle button", "menu button", "pop up button", "checkbox", "radio button",
        "按钮", "切换按钮", "菜单按钮", "弹出式按钮", "复选框", "单选按钮"
    ]

    static func isButtonCandidate(role: String, roleDescription: String, actions: [String],
                                  selectableRow: Bool) -> Bool {
        if semanticButtonRoles.contains(role) { return true }
        if role == "AXRow" {
            return selectableRow || actions.contains("AXPress") || actions.contains("AXConfirm")
        }
        guard genericRoles.contains(role) else { return false }
        return actions.contains("AXPress") || buttonDescriptions.contains(roleDescription.lowercased())
    }

    static func permitsPointerActivation(role: String, selectableRow: Bool) -> Bool {
        semanticButtonRoles.contains(role) || (role == "AXRow" && selectableRow)
    }

    struct HitStep {
        let isTarget: Bool
        let ownerPID: Int32
        let role: String
        var subrole: String = ""
        var enabled = true
        var hidden = false
    }

    /// Facts are gathered from the actual hit element upward via AXParent. The target flag
    /// comes from CFEqual, never from labels or matching rectangles.
    static func hitBelongsToTarget(_ path: [HitStep], expectedPID: Int32) -> Bool {
        let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
        let transientRoles: Set<String> = ["AXSheet", "AXDialog", "AXWindow", "AXMenu", "AXMenuItem"]
        guard !path.isEmpty, path.count <= 22 else { return false }
        for step in path {
            guard step.ownerPID == expectedPID, step.enabled, !step.hidden,
                  !inputRoles.contains(step.role), step.subrole != "AXSecureTextField" else { return false }
            if step.isTarget { return true }
            // A nested, distinct control is not a decorative descendant of the target button.
            if semanticButtonRoles.contains(step.role) || step.role == "AXRow" || transientRoles.contains(step.role) {
                return false
            }
        }
        return false
    }

    static func containerPath(ancestors: [Int], ownID: Int?) -> [Int] {
        guard let ownID, !ancestors.contains(ownID) else { return ancestors }
        return ancestors + [ownID]
    }

    /// Reject aggregated prose rather than truncating it into a misleading container name.
    static func shortLabel(_ value: String?, limit: Int = 48) -> String? {
        guard let value else { return nil }
        let prefix = String(value.prefix(limit + 1))
        guard prefix.count <= limit else { return nil }
        let label = prefix.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    /// Anonymous Electron wrappers may not expose geometry. Only missing frames are filled,
    /// using visible descendant nodes/containers, never estimated window percentages.
    static func resolvedContainerFrames(
        containers: [(id: Int, parentID: Int?, frame: CGRect)],
        nodes: [(frame: CGRect, containerIDs: [Int])]
    ) -> [Int: CGRect] {
        func valid(_ frame: CGRect) -> Bool {
            !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite
                && frame.width.isFinite && frame.height.isFinite && frame.width >= 3 && frame.height >= 3
        }
        var derived: [Int: CGRect] = [:]
        var ownFrames: [Int: CGRect] = [:]
        var parents: [Int: Int] = [:]
        for container in containers {
            if let parentID = container.parentID { parents[container.id] = parentID }
            if valid(container.frame) { ownFrames[container.id] = container.frame }
        }
        func add(_ frame: CGRect, to id: Int) {
            derived[id] = derived[id].map { $0.union(frame) } ?? frame
        }
        for node in nodes where valid(node.frame) {
            for id in node.containerIDs { add(node.frame, to: id) }
        }
        for container in containers where valid(container.frame) {
            var parent = container.parentID
            var visited: Set<Int> = [container.id]
            for _ in 0..<24 {
                guard let id = parent, visited.insert(id).inserted else { break }
                add(container.frame, to: id)
                parent = parents[id]
            }
        }
        return derived.merging(ownFrames) { _, actual in actual }
    }

    static func selfCheck() -> Bool {
        guard containerRoles.contains("AXVideo"), containerRoles.contains("AXPlayer") else { return false }
        guard isButtonCandidate(role: "AXButton", roleDescription: "", actions: [], selectableRow: false),
              isButtonCandidate(role: "AXLink", roleDescription: "", actions: [], selectableRow: false),
              isButtonCandidate(role: "AXRow", roleDescription: "", actions: [], selectableRow: true),
              !isButtonCandidate(role: "AXRow", roleDescription: "", actions: [], selectableRow: false),
              isButtonCandidate(role: "AXGroup", roleDescription: "", actions: ["AXPress"], selectableRow: false),
              isButtonCandidate(role: "AXGroup", roleDescription: "按钮", actions: [], selectableRow: false),
              !isButtonCandidate(role: "AXGroup", roleDescription: "button group", actions: [], selectableRow: false),
              !isButtonCandidate(role: "AXImage", roleDescription: "button", actions: [], selectableRow: false),
              !isButtonCandidate(role: "AXStaticText", roleDescription: "", actions: [], selectableRow: false),
              permitsPointerActivation(role: "AXButton", selectableRow: false),
              permitsPointerActivation(role: "AXRow", selectableRow: true),
              !permitsPointerActivation(role: "AXRow", selectableRow: false),
              !permitsPointerActivation(role: "AXGroup", selectableRow: false),
              !permitsPointerActivation(role: "AXImage", selectableRow: false) else { return false }
        let outer = containerPath(ancestors: [], ownID: 3)
        let inner = containerPath(ancestors: outer, ownID: 8)
        let scroll = containerPath(ancestors: inner, ownID: 12)
        let child = CGRect(x: 20, y: 30, width: 180, height: 70)
        let sibling = CGRect(x: 250, y: 30, width: 100, height: 70)
        let frames = resolvedContainerFrames(containers: [
            (3, nil, .null), (8, 3, .null), (12, 8, child), (15, 3, sibling)
        ], nodes: [(child.insetBy(dx: 5, dy: 5), scroll)])
        return outer == [3] && inner == [3, 8] && inner.last == 8
            && scroll == [3, 8, 12] && containerPath(ancestors: scroll, ownID: 12) == scroll
            && shortLabel("  Navigation\n items ") == "Navigation items"
            && shortLabel(String(repeating: "正文", count: 40)) == nil
            && frames[3] == child.union(sibling) && frames[8] == child && frames[12] == child
            && hitBelongsToTarget([.init(isTarget: true, ownerPID: 42, role: "AXButton")], expectedPID: 42)
            && hitBelongsToTarget([.init(isTarget: false, ownerPID: 42, role: "AXStaticText"),
                                  .init(isTarget: true, ownerPID: 42, role: "AXButton")], expectedPID: 42)
            && !hitBelongsToTarget([.init(isTarget: true, ownerPID: 43, role: "AXButton")], expectedPID: 42)
            && !hitBelongsToTarget([.init(isTarget: false, ownerPID: 42, role: "AXTextField"),
                                   .init(isTarget: true, ownerPID: 42, role: "AXButton")], expectedPID: 42)
            && !hitBelongsToTarget([.init(isTarget: false, ownerPID: 42, role: "AXButton"),
                                   .init(isTarget: true, ownerPID: 42, role: "AXButton")], expectedPID: 42)
            && !hitBelongsToTarget([.init(isTarget: false, ownerPID: 42, role: "AXGroup")], expectedPID: 42)
    }
}
// END PURE APP NAVIGATION ACCESSIBILITY LOGIC

/// Only this serial worker owns AX references. Public requests and replies contain values only.
/// Electron initialization is restricted to configured, known apps, on a user's first scan.
/// Input values and body text are not read; no screenshots or guessed coordinates are used.
/// Pointer activation happens only on user OK, after PID/window/sheet/geometry/identity and hit
/// verification. Runtime compatibility still depends on the target application's AX exposure.
final class AppNavigationAccessibility: @unchecked Sendable {
    struct Session: Equatable, Sendable {
        let generation: UInt64
        let pid: pid_t
        let bundleID: String
        let screens: [CGRect]
    }

    struct Snapshot: Sendable {
        let windowID: UInt64
        let frame: CGRect
        let nodes: [AppNavigationNode]
        let limited: Bool
        var containers: [AppNavigationContainer] = []
    }

    enum NativeReason: Sendable {
        case editing
        case navigation
        case videoRegion(String, AppNavigationLayout)
        case escape
        case menu
    }

    enum Request: Sendable {
        case scan
        case activate(nodeID: Int, windowID: UInt64)
        case scroll(nodeID: Int, windowID: UInt64, up: Bool)
        case native(RemoteKey, NativeReason, windowID: UInt64?)
    }

    enum Reply: Sendable {
        case snapshot(Snapshot)
        case performed
        case editing
        case cancelled
        case menu
        case menuPerformed
        case staleSelection
        case unavailable(String)
    }

    /// Cancel retains the occupied slot until its worker finishes, so rapid context changes
    /// cannot enqueue an unbounded series of already-cancelled AX traversals.
    struct Gate: Sendable {
        private(set) var generation: UInt64 = 0
        private(set) var active: UInt64?

        mutating func cancel() -> UInt64 {
            generation &+= 1
            return generation
        }

        mutating func begin(_ ticket: UInt64) -> Bool {
            guard generation == ticket, active == nil else { return false }
            active = ticket
            return true
        }

        func accepts(_ ticket: UInt64) -> Bool { generation == ticket }

        mutating func finish(_ ticket: UInt64) {
            if active == ticket { active = nil }
        }

        static func selfCheck() -> Bool {
            var gate = Gate()
            let first = gate.cancel()
            guard gate.begin(first), !gate.begin(first) else { return false }
            let second = gate.cancel()
            guard !gate.accepts(first), !gate.begin(second) else { return false }
            gate.finish(first)
            guard gate.begin(second), gate.accepts(second), !gate.accepts(first) else { return false }
            gate.finish(first)
            guard !gate.begin(second) else { return false }
            gate.finish(second)
            return gate.begin(second)
        }
    }

    private struct CachedNode {
        let value: AppNavigationNode
        let element: AXUIElement
        let rawFrame: CGRect
    }

    private struct CachedContainer {
        let value: AppNavigationContainer
        let element: AXUIElement
    }

    private struct WindowCache {
        let session: UInt64
        let app: AXUIElement
        let window: AXUIElement
        let root: AXUIElement
        let windowID: UInt64
        let frame: CGRect
        let windowFrame: CGRect
        var nodes: [CachedNode]
        let containers: [CachedContainer]
        let limited: Bool
        var scannedAt: TimeInterval
    }

    private struct Structure {
        let role: String
        let subrole: String
        let roleDescription: String
        let frame: CGRect?
        let enabled: Bool
        let hidden: Bool
        let focused: Bool
    }

    private struct Budget {
        let deadline: TimeInterval
        let generation: UInt64
    }

    private let queue = DispatchQueue(label: "com.miremote.app-navigation.ax", qos: .userInitiated)
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    private var cache: WindowCache?
    private var nextNodeID = 0
    private var nextContainerID = 0
    private var nextWindowID: UInt64 = 0
    private var initializedElectronGeneration: UInt64?
    private let messageTimeout: Float = 0.018
    private static let inputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
    private static let excludedSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXSecureTextField"
    ]
    private static let menuRoles: Set<String> = ["AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem"]
    /// Match the application's event-filter convention without carrying physical modifier flags.
    static let syntheticEventTag: Int64 = 0x4D69524E6176

    func start(pid: pid_t, bundleID: String, screens: [CGRect]) -> Session {
        let generation = gate.withLock { $0.cancel() }
        return Session(generation: generation, pid: pid, bundleID: bundleID, screens: screens)
    }

    func cancel() { _ = gate.withLock { $0.cancel() } }

    /// Returns false while busy. Callers may drop repeated directions and retry on a later tick.
    @discardableResult
    func request(_ request: Request, session: Session,
                 completion: @escaping @MainActor @Sendable (Reply) -> Void) -> Bool {
        guard gate.withLock({ $0.begin(session.generation) }) else { return false }
        queue.async { [self] in
            let reply = run(request, session: session)
            gate.withLock { $0.finish(session.generation) }
            Task { @MainActor in completion(reply) }
        }
        return true
    }

    private func current(_ session: Session) -> Bool {
        gate.withLock { $0.accepts(session.generation) }
    }

    private func allowed(_ budget: Budget) -> Bool {
        ProcessInfo.processInfo.systemUptime < budget.deadline
            && gate.withLock { $0.accepts(budget.generation) }
    }

    private func run(_ request: Request, session: Session) -> Reply {
        guard current(session) else { return .cancelled }
        guard AXIsProcessTrusted() else { return .unavailable("应用导航需要辅助功能权限，方向键保留原生行为。") }
        let budget = Budget(deadline: ProcessInfo.processInfo.systemUptime + 0.42,
                            generation: session.generation)
        if case .native = request {
            // Native requests independently distinguish menu, input and ordinary navigation.
        } else {
            guard focusedPID(budget: budget) == session.pid else { return .cancelled }
            let app = AXUIElementCreateApplication(session.pid)
            if focusedMenu(app, pid: session.pid, budget: budget) != nil { return .menu }
        }
        switch request {
        case .scan:
            initializeElectronIfNeeded(session: session, budget: budget)
            return scan(session: session, budget: budget)
        case .activate(let nodeID, let windowID):
            guard let context = validCache(session: session, windowID: windowID, budget: budget),
                  let node = context.nodes.first(where: { $0.value.id == nodeID }),
                  validNode(node, in: context, session: session, budget: budget) else { return stale(session) }
            if node.value.kind == .input {
                guard focusableInput(node.element, budget: budget),
                      preflight(context, session: session, budget: budget),
                      cachedFrameUnchanged(node.element, in: context, budget: budget) else { return stale(session) }
                guard
                      effect(session, { AXUIElementSetAttributeValue(node.element,
                          kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success }),
                      bool(node.element, kAXFocusedAttribute, budget: budget) == true else {
                    return .unavailable("这个输入框没有提供可用的聚焦操作。")
                }
                return .editing
            }
            guard node.value.kind == .button else { return .unavailable("这个区域不是可激活控件。") }
            return activateButton(node, in: context, session: session, budget: budget)
        case .scroll(let nodeID, let windowID, let up):
            guard let context = validCache(session: session, windowID: windowID, budget: budget),
                  let node = context.nodes.first(where: { $0.value.id == nodeID && $0.value.kind == .scrollArea }),
                  validNode(node, in: context, session: session, budget: budget) else { return stale(session) }
            return scroll(node.element, up: up, context: context, session: session, budget: budget)
        case .native(let key, let reason, let windowID):
            return native(key, reason: reason, windowID: windowID, session: session, budget: budget)
        }
    }

    private static func initializesElectron(_ bundleID: String) -> Bool {
        ["com.openai.codex", "com.bytedance.douyin.desktop"].contains(bundleID)
    }

    private func initializeElectronIfNeeded(session: Session, budget: Budget) {
        guard Self.initializesElectron(session.bundleID), initializedElectronGeneration != session.generation,
              focusedPID(budget: budget) == session.pid, allowed(budget) else { return }
        initializedElectronGeneration = session.generation
        let app = AXUIElementCreateApplication(session.pid)
        AXUIElementSetMessagingTimeout(app, messageTimeout)
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            guard allowed(budget), focusedPID(budget: budget) == session.pid else { return }
            _ = effect(session) { AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue) == .success }
        }
    }

    private func stale(_ session: Session) -> Reply {
        cache = nil
        return current(session) ? .staleSelection : .cancelled
    }

    private func scan(session: Session, budget: Budget) -> Reply {
        guard let (app, window, root, windowFrame, outerFrame) = frontWindow(session: session, budget: budget) else {
            return current(session) ? .unavailable("当前窗口未提供可用的辅助功能控件，方向键保留原生行为。") : .cancelled
        }
        let old = cache
        let sameWindow = old.map {
            $0.session == session.generation && CFEqual($0.window, window) && CFEqual($0.root, root)
                && $0.frame == windowFrame
                && $0.windowFrame == outerFrame
        } == true
        if sameWindow, let old, ProcessInfo.processInfo.systemUptime - old.scannedAt < 1.0 {
            return .snapshot(Snapshot(windowID: old.windowID, frame: old.frame,
                                      nodes: old.nodes.map(\.value), limited: old.limited,
                                      containers: old.containers.map(\.value)))
        }
        if !sameWindow { nextWindowID &+= 1 }
        var entries: [(AXUIElement, Int, CGRect, [Int])] = [(root, 0, windowFrame, [])]
        var head = 0
        var visited = Set<CFHashCode>()
        var found: [CachedNode] = []
        var foundContainers: [CachedContainer] = []
        var limited = false
        while head < entries.count, head < 720, allowed(budget) {
            let (element, depth, clip, ancestors) = entries[head]
            head += 1
            // AX trees occasionally contain cycles. Hash collisions only omit a node; they cannot activate another.
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard let info = structure(element, budget: budget), !info.hidden, info.enabled else { continue }
            let visible = info.frame.flatMap { visibleFrame($0, clip: clip, screens: session.screens) }
            var containerID: Int?
            if AppNavigationAccessibilityLogic.containerRoles.contains(info.role) {
                let id: Int
                if sameWindow, let previous = old?.containers.first(where: { CFEqual($0.element, element) }) {
                    id = previous.value.id
                } else {
                    nextContainerID &+= 1
                    id = nextContainerID
                }
                containerID = id
                let value = AppNavigationContainer(id: id, parentID: ancestors.last,
                    label: containerLabel(element, budget: budget), role: info.role, frame: visible ?? .null)
                foundContainers.append(CachedContainer(value: value, element: element))
            }
            let path = AppNavigationAccessibilityLogic.containerPath(ancestors: ancestors, ownID: containerID)
            if let visible, info.enabled, !Self.excludedSubroles.contains(info.subrole) {
                let kind: AppNavigationNode.Kind?
                if Self.inputRoles.contains(info.role), focusableInput(element, budget: budget) {
                    kind = .input
                } else if info.role == kAXScrollAreaRole as String {
                    kind = .scrollArea
                } else if isButtonCandidate(element, info: info, budget: budget) {
                    kind = .button
                } else {
                    kind = nil
                }
                if let kind {
                    let id: Int
                    if sameWindow, let previous = old?.nodes.first(where: { CFEqual($0.element, element) }) {
                        id = previous.value.id
                    } else {
                        nextNodeID &+= 1
                        id = nextNodeID
                    }
                    let value = AppNavigationNode(id: id,
                        label: label(element, kind: kind, role: info.role, budget: budget),
                        role: info.role, frame: visible, kind: kind, focused: info.focused, containerIDs: path)
                    if let rawFrame = info.frame { found.append(CachedNode(value: value, element: element, rawFrame: rawFrame)) }
                }
            }
            guard depth < 18 else { limited = true; continue }
            // Descendants of scroll areas are clipped, including offscreen virtual list buttons.
            let childClip = info.role == kAXScrollAreaRole as String && info.frame != nil ? (visible ?? .null) : clip
            guard !childClip.isNull else { continue }
            let children = children(element, budget: budget)
            if children.count == 160 { limited = true }
            for child in children.prefix(max(0, 960 - entries.count)) {
                entries.append((child, depth + 1, childClip, path))
            }
            if entries.count >= 960 { limited = true }
        }
        limited = limited || head < entries.count
        let resolved = AppNavigationAccessibilityLogic.resolvedContainerFrames(
            containers: foundContainers.map { ($0.value.id, $0.value.parentID, $0.value.frame) },
            nodes: found.map { ($0.value.frame, $0.value.containerIDs) })
        let containers = foundContainers.compactMap { cached -> CachedContainer? in
            guard let frame = resolved[cached.value.id] else { return nil }
            let value = AppNavigationContainer(id: cached.value.id, parentID: cached.value.parentID,
                label: cached.value.label, role: cached.value.role, frame: frame)
            return CachedContainer(value: value, element: cached.element)
        }
        guard current(session), allowed(budget),
              sameFrontWindow(app: app, window: window, root: root, session: session, budget: budget),
              sameGeometry(window: window, root: root, windowFrame: outerFrame,
                           rootFrame: windowFrame, budget: budget) else {
            // A fully spent budget may still return a partial snapshot after one short revalidation.
            guard current(session) else { return .cancelled }
            let validation = Budget(deadline: ProcessInfo.processInfo.systemUptime + 0.09,
                                    generation: session.generation)
            guard sameFrontWindow(app: app, window: window, root: root, session: session, budget: validation),
                  sameGeometry(window: window, root: root, windowFrame: outerFrame,
                               rootFrame: windowFrame, budget: validation) else {
                return current(session) ? .unavailable("当前窗口控件正在变化，方向键使用原生行为。") : .cancelled
            }
            cache = WindowCache(session: session.generation, app: app, window: window, root: root,
                                windowID: nextWindowID, frame: windowFrame, windowFrame: outerFrame,
                                nodes: found, containers: containers, limited: true,
                                scannedAt: ProcessInfo.processInfo.systemUptime)
            return .snapshot(Snapshot(windowID: nextWindowID, frame: windowFrame,
                                      nodes: found.map(\.value), limited: true, containers: containers.map(\.value)))
        }
        cache = WindowCache(session: session.generation, app: app, window: window, root: root,
                            windowID: nextWindowID, frame: windowFrame, windowFrame: outerFrame,
                            nodes: found, containers: containers, limited: limited,
                            scannedAt: ProcessInfo.processInfo.systemUptime)
        return .snapshot(Snapshot(windowID: nextWindowID, frame: windowFrame,
                                  nodes: found.map(\.value), limited: limited, containers: containers.map(\.value)))
    }

    private func validCache(session: Session, windowID: UInt64, budget: Budget) -> WindowCache? {
        guard let cache, cache.session == session.generation, cache.windowID == windowID,
              preflight(cache, session: session, budget: budget) else { return nil }
        return cache
    }

    private func frontWindow(session: Session, budget: Budget) -> (AXUIElement, AXUIElement, AXUIElement, CGRect, CGRect)? {
        guard focusedPID(budget: budget) == session.pid else { return nil }
        let app = AXUIElementCreateApplication(session.pid)
        guard let window = element(app, kAXFocusedWindowAttribute, budget: budget),
              let root = activeRoot(window, budget: budget),
              let frame = structure(root, budget: budget)?.frame,
              let outerFrame = CFEqual(window, root) ? frame : structure(window, budget: budget)?.frame,
              visibleFrame(frame, clip: frame, screens: session.screens) != nil,
              !menuHasFocus(app, budget: budget) else { return nil }
        return (app, window, root, frame, outerFrame)
    }

    private func activeRoot(_ window: AXUIElement, budget: Budget) -> AXUIElement? {
        let advertisedSheets = attribute(window, "AXSheets", budget: budget) as? [AXUIElement] ?? []
        // AXSheets is not advertised by every toolkit. Public AXSheet children are also
        // inspected directly; ordinary background-window controls are never a sheet fallback.
        for sheet in advertisedSheets.reversed() {
            if let info = structure(sheet, budget: budget), info.role == "AXSheet", !info.hidden { return sheet }
        }
        for child in children(window, budget: budget).reversed() {
            if string(child, kAXRoleAttribute, budget: budget) == "AXSheet",
               let info = structure(child, budget: budget), !info.hidden { return child }
        }
        return allowed(budget) ? window : nil
    }

    private func sameFrontWindow(app: AXUIElement, window: AXUIElement, root: AXUIElement,
                                 session: Session, budget: Budget) -> Bool {
        guard current(session), focusedPID(budget: budget) == session.pid,
              let focused = element(app, kAXFocusedWindowAttribute, budget: budget), CFEqual(focused, window),
              let actualRoot = activeRoot(focused, budget: budget), CFEqual(actualRoot, root),
              !menuHasFocus(app, budget: budget) else { return false }
        return allowed(budget)
    }

    private func preflight(_ cache: WindowCache, session: Session, budget: Budget) -> Bool {
        sameFrontWindow(app: cache.app, window: cache.window, root: cache.root, session: session, budget: budget)
            && sameGeometry(window: cache.window, root: cache.root, windowFrame: cache.windowFrame,
                            rootFrame: cache.frame, budget: budget)
    }

    /// Exact comparison deliberately rejects moved/resized highlights rather than guessing.
    static func geometryUnchanged(displayed: CGRect, current: CGRect) -> Bool {
        !displayed.isNull && !displayed.isInfinite && !current.isNull && !current.isInfinite
            && displayed.width >= 3 && displayed.height >= 3 && displayed == current
    }

    private func sameGeometry(window: AXUIElement, root: AXUIElement, windowFrame: CGRect,
                              rootFrame: CGRect, budget: Budget) -> Bool {
        guard let actualRoot = structure(root, budget: budget)?.frame,
              Self.geometryUnchanged(displayed: rootFrame, current: actualRoot) else { return false }
        let actualWindow = CFEqual(window, root) ? actualRoot : structure(window, budget: budget)?.frame
        return actualWindow.map { Self.geometryUnchanged(displayed: windowFrame, current: $0) } == true
    }

    private func cachedFrameUnchanged(_ element: AXUIElement, in cache: WindowCache, budget: Budget) -> Bool {
        guard let node = cache.nodes.first(where: { CFEqual($0.element, element) }),
              let frame = structure(element, budget: budget)?.frame else { return false }
        return Self.geometryUnchanged(displayed: node.rawFrame, current: frame)
    }

    private func isButtonCandidate(_ element: AXUIElement, info: Structure, budget: Budget) -> Bool {
        if AppNavigationAccessibilityLogic.semanticButtonRoles.contains(info.role) { return true }
        let names = actions(element, budget: budget)
        let selectable = info.role == "AXRow" && settable(element, kAXSelectedAttribute, budget: budget)
        return AppNavigationAccessibilityLogic.isButtonCandidate(role: info.role,
            roleDescription: info.roleDescription, actions: names, selectableRow: selectable)
    }

    /// Invoked only by a user's OK on an existing selection. AX actions stay first; pointer
    /// fallback is restricted to semantic buttons/selectable rows and a verified real hit.
    private func activateButton(_ node: CachedNode, in context: WindowCache,
                                session: Session, budget: Budget) -> Reply {
        let names = actions(node.element, budget: budget)
        for action in ["AXPress", "AXConfirm"] where names.contains(action) {
            guard preflight(context, session: session, budget: budget),
                  cachedFrameUnchanged(node.element, in: context, budget: budget) else { return stale(session) }
            var outcome = AXError.failure
            if effect(session, {
                outcome = AXUIElementPerformAction(node.element, action as CFString)
                return outcome == .success
            }) { return .performed }
            guard current(session) else { return .cancelled }
            // cannotComplete/timeout may already have reached the app: a second click could
            // toggle a checkbox back. Only definite unsupported actions permit a fallback.
            guard outcome == .actionUnsupported || outcome == .notImplemented else {
                return .unavailable("控件响应尚未确认，请重新选择后重试。")
            }
        }
        let selectableRow = node.value.role == "AXRow" && settable(node.element, kAXSelectedAttribute, budget: budget)
        guard AppNavigationAccessibilityLogic.permitsPointerActivation(role: node.value.role, selectableRow: selectableRow) else {
            return .unavailable("此控件没有提供可验证的辅助功能激活方式。")
        }
        guard preflight(context, session: session, budget: budget),
              validNode(node, in: context, session: session, budget: budget) else { return stale(session) }
        // AX and CGEvent locations share the primary display's top-left coordinate system.
        let point = CGPoint(x: node.value.frame.midX, y: node.value.frame.midY)
        guard node.rawFrame.contains(point), context.frame.contains(point),
              point.x.isFinite, point.y.isFinite,
              label(node.element, kind: .button, role: node.value.role, budget: budget) == node.value.label,
              hitBelongsToTarget(at: point, node: node, session: session, budget: budget),
              preflight(context, session: session, budget: budget),
              cachedFrameUnchanged(node.element, in: context, budget: budget),
              focusedPID(budget: budget) == session.pid, allowed(budget) else { return stale(session) }
        return effect(session, { Self.postClick(at: point, pid: session.pid) }) ? .performed : .cancelled
    }

    private func hitBelongsToTarget(at point: CGPoint, node: CachedNode,
                                    session: Session, budget: Budget) -> Bool {
        guard allowed(budget) else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messageTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var ancestor = hit else { return false }
        var path: [AppNavigationAccessibilityLogic.HitStep] = []
        var seen = Set<CFHashCode>()
        for _ in 0..<22 {
            guard allowed(budget), seen.insert(CFHash(ancestor)).inserted else { return false }
            var pid: pid_t = 0
            guard AXUIElementGetPid(ancestor, &pid) == .success, pid == session.pid,
                  let info = structure(ancestor, budget: budget), !info.hidden, info.enabled else { return false }
            let isTarget = CFEqual(ancestor, node.element)
            path.append(.init(isTarget: isTarget, ownerPID: pid, role: info.role,
                              subrole: info.subrole, enabled: info.enabled, hidden: info.hidden))
            if isTarget {
                guard info.role == node.value.role, let frame = info.frame,
                      Self.geometryUnchanged(displayed: node.rawFrame, current: frame) else { return false }
                return AppNavigationAccessibilityLogic.hitBelongsToTarget(path, expectedPID: session.pid)
            }
            guard let parent = element(ancestor, kAXParentAttribute, budget: budget) else { return false }
            ancestor = parent
        }
        return false
    }

    private static func postClick(at point: CGPoint, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            // PID targeting prevents a late foreground transition from clicking a new app at
            // this old location. It does not activate or reposition any application window.
            event.postToPid(pid)
        }
        return true
    }

    private func validNode(_ node: CachedNode, in cache: WindowCache, session: Session, budget: Budget) -> Bool {
        var pid: pid_t = 0
        guard allowed(budget), AXUIElementGetPid(node.element, &pid) == .success, pid == session.pid,
              let info = structure(node.element, budget: budget), info.enabled, !info.hidden,
              info.role == node.value.role,
              !Self.excludedSubroles.contains(info.subrole), let frame = info.frame,
              Self.geometryUnchanged(displayed: node.rawFrame, current: frame),
              visibleFrame(frame, clip: cache.frame, screens: session.screens) != nil,
              label(node.element, kind: node.value.kind, role: info.role, budget: budget) == node.value.label else {
            return false
        }
        var ancestor = node.element
        var visible = frame.intersection(cache.frame)
        for _ in 0..<22 {
            if CFEqual(ancestor, cache.root) {
                return Self.geometryUnchanged(displayed: node.value.frame, current: visible)
            }
            guard let parent = element(ancestor, kAXParentAttribute, budget: budget) else { return false }
            guard let parentInfo = structure(parent, budget: budget), !parentInfo.hidden, parentInfo.enabled else { return false }
            if parentInfo.role == kAXScrollAreaRole as String, let parentFrame = parentInfo.frame {
                visible = visible.intersection(parentFrame)
                guard !visible.isNull else { return false }
            }
            ancestor = parent
        }
        return false
    }

    private func scroll(_ area: AXUIElement, up: Bool, context: WindowCache,
                        session: Session, budget: Budget) -> Reply {
        let names = actions(area, budget: budget)
        for action in up ? ["AXScrollUpByLine", "AXScrollUpByPage"] : ["AXScrollDownByLine", "AXScrollDownByPage"] {
            if names.contains(action), preflight(context, session: session, budget: budget),
               cachedFrameUnchanged(area, in: context, budget: budget),
               effect(session, { AXUIElementPerformAction(area, action as CFString) == .success }) {
                return .performed
            }
        }
        if let bar = element(area, kAXVerticalScrollBarAttribute, budget: budget),
           structure(bar, budget: budget)?.enabled == true {
            let action = up ? kAXDecrementAction as String : kAXIncrementAction as String
            if actions(bar, budget: budget).contains(action),
               preflight(context, session: session, budget: budget),
               cachedFrameUnchanged(area, in: context, budget: budget),
               effect(session, { AXUIElementPerformAction(bar, action as CFString) == .success }) {
                return .performed
            }
            // Reading AXValue is limited to a confirmed scroll bar; text values are never read.
            if string(bar, kAXRoleAttribute, budget: budget) == kAXScrollBarRole as String,
               settable(bar, kAXValueAttribute, budget: budget),
               let value = attribute(bar, kAXValueAttribute, budget: budget) as? NSNumber,
               let minimum = attribute(bar, kAXMinValueAttribute, budget: budget) as? NSNumber,
               let maximum = attribute(bar, kAXMaxValueAttribute, budget: budget) as? NSNumber,
               maximum.doubleValue > minimum.doubleValue {
                let step = (maximum.doubleValue - minimum.doubleValue) * (up ? -0.10 : 0.10)
                let target = min(maximum.doubleValue, max(minimum.doubleValue, value.doubleValue + step))
                if preflight(context, session: session, budget: budget),
                   cachedFrameUnchanged(area, in: context, budget: budget),
                   effect(session, { AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                                                  NSNumber(value: target)) == .success }) {
                    return .performed
                }
            }
        }
        guard current(session) else { return .cancelled }
        guard preflight(context, session: session, budget: budget),
              cachedFrameUnchanged(area, in: context, budget: budget) else { return stale(session) }
        return .unavailable("此区域未提供辅助功能滚动操作。")
    }

    private func native(_ key: RemoteKey, reason: NativeReason, windowID: UInt64?,
                        session: Session, budget: Budget) -> Reply {
        guard focusedPID(budget: budget) == session.pid else { return .cancelled }
        let app = AXUIElementCreateApplication(session.pid)
        if let menu = focusedMenu(app, pid: session.pid, budget: budget) {
            guard case .menu = reason else { return .menu }
            guard [.up, .down, .left, .right, .ok, .back].contains(key),
                  let code = Self.keyCode(key), focusedPID(budget: budget) == session.pid,
                  let latestMenu = focusedMenu(app, pid: session.pid, budget: budget),
                  CFEqual(menu, latestMenu), allowed(budget) else { return .cancelled }
            return effect(session, { Self.postKey(code, pid: session.pid) }) ? .menuPerformed : .cancelled
        }
        switch reason {
        case .menu:
            // Menu dismissal cannot turn its pending OK into an Enter in ordinary app content.
            return .cancelled
        case .navigation, .escape:
            let permitted: Bool
            switch reason {
            case .navigation: permitted = [.up, .down, .left, .right].contains(key)
            case .escape: permitted = key == .back
            default: permitted = false
            }
            // This is a native fallback, so text input retains its ordinary arrow behavior.
            // No AX window, control, or text value is needed to target a verified foreground PID.
            guard permitted, let code = Self.keyCode(key),
                  focusedPID(budget: budget) == session.pid,
                  focusedMenu(app, pid: session.pid, budget: budget) == nil,
                  allowed(budget) else { return .cancelled }
            return effect(session, { Self.postKey(code, pid: session.pid) }) ? .performed : .cancelled
        case .editing, .videoRegion: break
        }
        guard let (_, window, root, _, _) = frontWindow(session: session, budget: budget),
              let focused = element(app, kAXFocusedUIElementAttribute, budget: budget),
              let focusInfo = structure(focused, budget: budget), !focusInfo.hidden,
              focusInfo.subrole != "AXSecureTextField" else { return .cancelled }
        if let windowID {
            guard let cache, cache.session == session.generation, cache.windowID == windowID,
                  CFEqual(cache.window, window), CFEqual(cache.root, root) else { return stale(session) }
            if case .videoRegion = reason,
               !preflight(cache, session: session, budget: budget) { return stale(session) }
        }
        let inputFocused = Self.inputRoles.contains(focusInfo.role)
        switch reason {
        case .editing:
            guard inputFocused, focusableInput(focused, budget: budget),
                  [.up, .down, .left, .right, .ok].contains(key) else { return .cancelled }
        case .videoRegion(let regionID, let layout):
            guard !inputFocused, layout == .video, key == .up || key == .down,
                  let cache, cache.session == session.generation,
                  preflight(cache, session: session, budget: budget),
                  AppNavigationGeometry.regions(nodes: cache.nodes.map(\.value), window: cache.frame, layout: layout,
                                                containers: cache.containers.map(\.value))
                    .contains(where: { $0.id == regionID && $0.vertical == .native }) else { return .cancelled }
        case .navigation, .escape, .menu: return .cancelled
        }
        guard sameFrontWindow(app: app, window: window, root: root, session: session, budget: budget),
              let finalFocus = element(app, kAXFocusedUIElementAttribute, budget: budget),
              CFEqual(finalFocus, focused), let code = Self.keyCode(key) else { return .cancelled }
        return effect(session, { Self.postKey(code, pid: session.pid) }) ? .performed : .cancelled
    }

    /// The lock covers only the bounded mutation, never a traversal or preflight query.
    /// This linearizes cancellation with AXPress/AXFocused and complete key down/up pairs.
    private func effect(_ session: Session, _ body: () -> Bool) -> Bool {
        let performed = gate.withLock { state in state.accepts(session.generation) && body() }
        // Keep AX identities for revalidation, but never reuse geometry after a mutation.
        if performed { cache?.scannedAt = 0 }
        return performed
    }

    private static func keyCode(_ key: RemoteKey) -> CGKeyCode? {
        switch key {
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        case .ok: 36
        case .back: 53
        default: nil
        }
    }

    private static func postKey(_ code: CGKeyCode, pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = event.flags.intersection([.maskSecondaryFn, .maskNumericPad])
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
            event.postToPid(pid)
        }
        return true
    }

    private func focusedPID(budget: Budget) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        guard let app = element(system, kAXFocusedApplicationAttribute, budget: budget) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }

    private func menuHasFocus(_ app: AXUIElement, budget: Budget) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return false }
        return focusedMenu(app, pid: pid, budget: budget) != nil
    }

    private func focusedMenu(_ app: AXUIElement, pid: pid_t, budget: Budget) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        for owner in [system, app] {
            if let focused = element(owner, kAXFocusedUIElementAttribute, budget: budget),
               let role = string(focused, kAXRoleAttribute, budget: budget), Self.menuRoles.contains(role) {
                var ownerPID: pid_t = 0
                if AXUIElementGetPid(focused, &ownerPID) == .success, ownerPID == pid { return focused }
            }
        }
        return nil
    }

    private func focusableInput(_ element: AXUIElement, budget: Budget) -> Bool {
        guard let info = structure(element, budget: budget), Self.inputRoles.contains(info.role),
              info.subrole != "AXSecureTextField", info.enabled, !info.hidden else { return false }
        return settable(element, kAXFocusedAttribute, budget: budget)
    }

    private func structure(_ element: AXUIElement, budget: Budget) -> Structure? {
        guard allowed(budget) else { return nil }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     kAXEnabledAttribute, kAXFocusedAttribute, "AXHidden", "AXVisible", "AXRoleDescription"] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let result = values as? [Any], result.count == 9,
              let role = result[0] as? String else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        var frame: CGRect?
        if CFGetTypeID(result[2] as CFTypeRef) == AXValueGetTypeID(),
           CFGetTypeID(result[3] as CFTypeRef) == AXValueGetTypeID(),
           AXValueGetValue(unsafeBitCast(result[2] as CFTypeRef, to: AXValue.self), .cgPoint, &point),
           AXValueGetValue(unsafeBitCast(result[3] as CFTypeRef, to: AXValue.self), .cgSize, &size),
           point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
           size.width >= 3, size.height >= 3 {
            frame = CGRect(origin: point, size: size)
        }
        return Structure(role: role, subrole: result[1] as? String ?? "",
                         roleDescription: result[8] as? String ?? "", frame: frame,
                         enabled: (result[4] as? Bool) != false,
                         hidden: (result[6] as? Bool) == true || (result[7] as? Bool) == false,
                         focused: (result[5] as? Bool) == true)
    }

    private func visibleFrame(_ frame: CGRect, clip: CGRect, screens: [CGRect]) -> CGRect? {
        let clipped = frame.intersection(clip)
        guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3,
              screens.contains(where: { $0.intersects(clipped) }) else { return nil }
        return clipped
    }

    private func label(_ element: AXUIElement, kind: AppNavigationNode.Kind,
                       role: String, budget: Budget) -> String {
        // Container descriptions may aggregate an entire conversation. Do not request them.
        let names = AppNavigationAccessibilityLogic.containerRoles.contains(role)
            ? [kAXTitleAttribute, "AXIdentifier"]
            : [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
        for name in names {
            if let label = AppNavigationAccessibilityLogic.shortLabel(string(element, name, budget: budget), limit: 90) {
                return label
            }
        }
        switch kind {
        case .input: return "输入框"
        case .scrollArea: return "滚动区域"
        case .button: return role == "AXLink" ? "链接" : (role == "AXRow" ? "列表项" : "按钮")
        }
    }

    private func containerLabel(_ element: AXUIElement, budget: Budget) -> String {
        guard allowed(budget) else { return "" }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var values: CFArray?
        let names = [kAXTitleAttribute, "AXIdentifier"] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let values = values as? [Any] else { return "" }
        for value in values {
            if let label = AppNavigationAccessibilityLogic.shortLabel(value as? String) { return label }
        }
        return ""
    }

    private func attribute(_ element: AXUIElement, _ name: String, budget: Budget) -> CFTypeRef? {
        guard allowed(budget) else { return nil }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ owner: AXUIElement, _ name: String, budget: Budget) -> AXUIElement? {
        guard let value = attribute(owner, name, budget: budget), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func string(_ element: AXUIElement, _ name: String, budget: Budget) -> String? {
        attribute(element, name, budget: budget) as? String
    }

    private func bool(_ element: AXUIElement, _ name: String, budget: Budget) -> Bool? {
        attribute(element, name, budget: budget) as? Bool
    }

    private func settable(_ element: AXUIElement, _ name: String, budget: Budget) -> Bool {
        guard allowed(budget) else { return false }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var result = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
    }

    private func actions(_ element: AXUIElement, budget: Budget) -> [String] {
        guard allowed(budget) else { return [] }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFArray?
        return AXUIElementCopyActionNames(element, &value) == .success ? (value as? [String] ?? []) : []
    }

    private func children(_ element: AXUIElement, budget: Budget) -> [AXUIElement] {
        guard allowed(budget) else { return [] }
        AXUIElementSetMessagingTimeout(element, messageTimeout)
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, 160, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// Pure checks: no AX objects, workspace reads, event sources, or OS events are created.
    static func selfCheck() -> Bool {
        let frame = CGRect(x: -40, y: 60, width: 200, height: 100)
        return AppNavigationAccessibilityLogic.selfCheck() && Gate.selfCheck()
            && keyCode(.ok) == 36 && keyCode(.back) == 53 && keyCode(.voice) == nil
            && geometryUnchanged(displayed: frame, current: frame)
            && !geometryUnchanged(displayed: frame, current: frame.offsetBy(dx: 1, dy: 0))
            && !geometryUnchanged(displayed: frame, current: frame.insetBy(dx: 1, dy: 0))
            && !geometryUnchanged(displayed: frame, current: .null)
            && initializesElectron("com.openai.codex") && initializesElectron("com.bytedance.douyin.desktop")
            && !initializesElectron("com.example.native")
    }
}
