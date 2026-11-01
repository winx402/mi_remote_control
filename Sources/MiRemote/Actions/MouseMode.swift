import AppKit
import CoreGraphics
import os

/// 鼠标输入由串行队列隔离；纯状态机只产生意图，系统事件只在执行层发出。
/// Home/Menu 的单击与 TV 的长按由 MappingEngine 决断，本模块不另开双击窗口。
final class MouseMode: @unchecked Sendable {
    static let shared = MouseMode()

    enum Speed {
        case slow, fast

        var base: Double { self == .slow ? 1 : 3 }
        var maximum: Double { self == .slow ? 3 : 12 }
        var title: String { self == .slow ? "慢速" : "快速" }
    }

    static let baseSpeed = Speed.slow.base
    static let maxSpeed = Speed.slow.maximum
    static let rampSeconds = 0.8
    static let dragHoldSeconds = 0.6
    static let idleSeconds = 20

    static func speed(afterSeconds t: Double, mode: Speed = .slow) -> Double {
        if t <= 0 { return mode.base }
        if t >= rampSeconds { return mode.maximum }
        return mode.base + (mode.maximum - mode.base) * (t / rampSeconds)
    }

    /// 归一化避免两键同按时比单方向快；相反方向仍相互抵消。
    static func delta(dirs: Set<RemoteKey>, speed: Double) -> (dx: Double, dy: Double) {
        var dx = 0.0, dy = 0.0
        if dirs.contains(.left) { dx -= 1 }
        if dirs.contains(.right) { dx += 1 }
        if dirs.contains(.up) { dy -= 1 }
        if dirs.contains(.down) { dy += 1 }
        let length = hypot(dx, dy)
        guard length > 0 else { return (0, 0) }
        return (dx / length * speed, dy / length * speed)
    }

    /// Quartz 的正滚轮值向上/向左，与屏幕坐标的正方向相反。
    static func scrollDelta(dirs: Set<RemoteKey>, speed: Double) -> (vertical: Int32, horizontal: Int32) {
        let d = delta(dirs: dirs, speed: speed)
        return (Int32((-d.dy).rounded()), Int32((-d.dx).rounded()))
    }

    private enum Mode { case pointer, scroll }
    private enum OKPress {
        case awaiting(UInt64)
        case dragLocked
        case releaseOnly
    }
    private enum Effect: Equatable {
        case move(dx: Double, dy: Double, dragging: Bool)
        case scroll(vertical: Int32, horizontal: Int32)
        case leftClick, rightClick, leftDown, leftUp
    }

    /// 时间完全由调用方提供，selfCheck 不需要触碰单例、计时器或 CGEvent。
    private struct State {
        var active = false
        var mode: Mode = .pointer
        var speedMode: Speed = .slow
        var held: Set<RemoteKey> = []
        var directionStartNs: UInt64?
        var lastInputNs: UInt64 = 0
        var okPress: OKPress?
        var dragging = false

        var statusText: String? {
            guard active else { return nil }
            let name = mode == .scroll ? "滚动" : "指针"
            return dragging ? "\(name)·拖拽·\(speedMode.title)" : "\(name)·\(speedMode.title)"
        }

        mutating func activate(nowNs: UInt64) {
            self = State()
            active = true
            lastInputNs = nowNs
        }

        mutating func deactivate() -> [Effect] {
            let effects: [Effect] = dragging ? [.leftUp] : []
            self = State()
            return effects
        }

        mutating func toggleScrollMode(nowNs: UInt64) -> [Effect] {
            guard active else { return [] }
            mode = mode == .pointer ? .scroll : .pointer
            let effects = mode == .scroll ? releaseDrag() : []
            // 切模式后不让此前尚未决断的 OK 在新模式意外点击或锁拖。
            if okPress != nil { okPress = .releaseOnly }
            if !held.isEmpty { directionStartNs = nowNs }
            lastInputNs = nowNs
            return effects
        }

        mutating func handle(key: RemoteKey, isDown: Bool, nowNs: UInt64) -> (consumed: Bool, effects: [Effect]) {
            guard active else { return (false, []) }
            var effects: [Effect] = []
            switch key {
            case .up, .down, .left, .right:
                if isDown {
                    if held.isEmpty { directionStartNs = nowNs }
                    if held.insert(key).inserted { effects += movement(nowNs: nowNs) }
                } else {
                    held.remove(key)
                    if held.isEmpty { directionStartNs = nil }
                }
            case .ok:
                if isDown {
                    if okPress == nil {
                        if dragging {
                            effects += releaseDrag()
                            okPress = .releaseOnly
                        } else {
                            okPress = .awaiting(nowNs)
                        }
                    }
                } else if let press = okPress {
                    if case .awaiting(let start) = press {
                        if Self.seconds(from: start, to: nowNs) >= MouseMode.dragHoldSeconds {
                            effects += lockDrag()
                        } else {
                            effects.append(.leftClick)
                        }
                    }
                    okPress = nil
                }
            case .home:
                if isDown {
                    speedMode = speedMode == .slow ? .fast : .slow
                    if !held.isEmpty { directionStartNs = nowNs }
                }
            case .menu:
                if isDown {
                    effects += releaseDrag()
                    effects.append(.rightClick)
                }
            case .back:
                if isDown { effects += deactivate() }
            default:
                return (false, [])
            }
            if active { lastInputNs = nowNs }
            return (true, effects)
        }

        mutating func advance(nowNs: UInt64) -> [Effect] {
            guard active else { return [] }
            var effects: [Effect] = []
            if case .awaiting(let start)? = okPress,
               Self.seconds(from: start, to: nowNs) >= MouseMode.dragHoldSeconds {
                okPress = .dragLocked
                effects += lockDrag()
            }
            // 方向或 OK 仍物理按住时属于操作中；已锁拖但未按键时仍会空闲退出。
            if held.isEmpty, okPress == nil,
               Self.seconds(from: lastInputNs, to: nowNs) >= Double(MouseMode.idleSeconds) {
                effects += deactivate()
                return effects
            }
            effects += movement(nowNs: nowNs)
            return effects
        }

        private func movement(nowNs: UInt64) -> [Effect] {
            guard let start = directionStartNs, !held.isEmpty else { return [] }
            let amount = MouseMode.speed(afterSeconds: Self.seconds(from: start, to: nowNs), mode: speedMode)
            if mode == .scroll {
                let d = MouseMode.scrollDelta(dirs: held, speed: amount)
                return d.vertical == 0 && d.horizontal == 0 ? [] : [.scroll(vertical: d.vertical, horizontal: d.horizontal)]
            }
            let d = MouseMode.delta(dirs: held, speed: amount)
            return d.dx == 0 && d.dy == 0 ? [] : [.move(dx: d.dx, dy: d.dy, dragging: dragging)]
        }

        private mutating func lockDrag() -> [Effect] {
            // 拖拽需要指针移动；从滚动态长按 OK 时回到指针，避免按住左键滚页。
            mode = .pointer
            dragging = true
            return [.leftDown]
        }

        private mutating func releaseDrag() -> [Effect] {
            guard dragging else { return [] }
            dragging = false
            return [.leftUp]
        }

        private static func seconds(from start: UInt64, to end: UInt64) -> Double {
            end >= start ? Double(end - start) / 1_000_000_000 : 0
        }
    }

    private struct Snapshot {
        var active = false
        var statusText: String?
    }

    private let q = DispatchQueue(label: "com.miremote.mousemode")
    private var state = State()
    private var timer: DispatchSourceTimer?
    private let source = CGEventSource(stateID: .combinedSessionState)
    /// TapEngine 热路径与 UI 轮询只读取镜像，不同步等待鼠标事件队列。
    private let snapshot = OSAllocatedUnfairLock(initialState: Snapshot())

    var isActive: Bool { snapshot.withLock { $0.active } }
    var statusText: String? { snapshot.withLock { $0.statusText } }

    func toggle() {
        q.sync {
            if state.active {
                updateRuntimeLocked(effects: state.deactivate())
            } else {
                state.activate(nowNs: DispatchTime.now().uptimeNanoseconds)
                updateRuntimeLocked(effects: [])
            }
        }
    }

    /// 暂停、断线和全局退出统一走这里，返回前为锁拖发出 mouseUp。
    func deactivate() {
        q.sync { updateRuntimeLocked(effects: state.deactivate()) }
    }

    func toggleScrollMode() {
        q.sync {
            updateRuntimeLocked(effects: state.toggleScrollMode(nowNs: DispatchTime.now().uptimeNanoseconds))
        }
    }

    func handle(key: RemoteKey, isDown: Bool) -> Bool {
        q.sync {
            let result = state.handle(key: key, isDown: isDown, nowNs: DispatchTime.now().uptimeNanoseconds)
            updateRuntimeLocked(effects: result.effects)
            return result.consumed
        }
    }

    private func updateRuntimeLocked(effects: [Effect]) {
        let wasActive = snapshot.withLock { $0.active }
        effects.forEach(emit)
        if state.active, timer == nil {
            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !state.active {
            timer?.cancel()
            timer = nil
        }
        snapshot.withLock { $0 = Snapshot(active: state.active, statusText: state.statusText) }
        if wasActive != state.active { NSLog("[MouseMode] \(state.active ? "进入" : "退出")鼠标模式") }
    }

    private func tick() {
        updateRuntimeLocked(effects: state.advance(nowNs: DispatchTime.now().uptimeNanoseconds))
    }

    private func emit(_ effect: Effect) {
        switch effect {
        case .move(let dx, let dy, let dragging):
            let current = CGEvent(source: nil)?.location ?? .zero
            // 仍只允许主屏，避免把本次交互调整扩展为多显示器坐标改造。
            let bounds = CGDisplayBounds(CGMainDisplayID())
            let position = CGPoint(x: min(max(current.x + dx, bounds.minX), bounds.maxX - 1),
                                   y: min(max(current.y + dy, bounds.minY), bounds.maxY - 1))
            CGWarpMouseCursorPosition(position)
            postMouse(dragging ? .leftMouseDragged : .mouseMoved, at: position)
        case .scroll(let vertical, let horizontal):
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event?.post(tap: .cghidEventTap)
        case .leftClick:
            click(.left)
        case .rightClick:
            click(.right)
        case .leftDown:
            postMouse(.leftMouseDown)
        case .leftUp:
            postMouse(.leftMouseUp)
        }
    }

    private func postMouse(_ type: CGEventType, at position: CGPoint? = nil, button: CGMouseButton = .left) {
        let point = position ?? CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func click(_ button: CGMouseButton) {
        let position = CGEvent(source: nil)?.location ?? .zero
        postMouse(button == .right ? .rightMouseDown : .leftMouseDown, at: position, button: button)
        postMouse(button == .right ? .rightMouseUp : .leftMouseUp, at: position, button: button)
    }

    static func selfCheck() -> Bool {
        func ns(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }
        var s = State()
        s.activate(nowNs: 0)
        guard s.statusText == "指针·慢速",
              s.handle(key: .ok, isDown: true, nowNs: 0).effects.isEmpty,
              s.advance(nowNs: ns(0.59)).isEmpty,
              s.handle(key: .ok, isDown: false, nowNs: ns(0.59)).effects == [.leftClick],
              !s.dragging else { return false }

        _ = s.handle(key: .ok, isDown: true, nowNs: ns(1))
        guard s.advance(nowNs: ns(1.6)) == [.leftDown], s.dragging,
              s.statusText == "指针·拖拽·慢速",
              s.handle(key: .ok, isDown: true, nowNs: ns(1.65)).effects.isEmpty,
              s.handle(key: .ok, isDown: false, nowNs: ns(1.7)).effects.isEmpty,
              s.handle(key: .right, isDown: true, nowNs: ns(1.8)).effects == [.move(dx: 1, dy: 0, dragging: true)],
              s.handle(key: .ok, isDown: true, nowNs: ns(1.9)).effects == [.leftUp],
              s.handle(key: .ok, isDown: false, nowNs: ns(2)).effects.isEmpty,
              !s.dragging else { return false }
        _ = s.handle(key: .right, isDown: false, nowNs: ns(2))

        // 松开时也检查阈值，覆盖定时器尚未执行、松开已先到达的边界。
        _ = s.handle(key: .ok, isDown: true, nowNs: ns(3))
        guard s.handle(key: .ok, isDown: false, nowNs: ns(3.6)).effects == [.leftDown],
              s.deactivate() == [.leftUp], !s.active, s.statusText == nil,
              s.deactivate().isEmpty else { return false }

        s.activate(nowNs: 0)
        _ = s.handle(key: .ok, isDown: true, nowNs: 0)
        _ = s.advance(nowNs: ns(0.6))
        _ = s.handle(key: .ok, isDown: false, nowNs: ns(0.7))
        guard s.advance(nowNs: ns(20.69)).isEmpty, s.active,
              s.advance(nowNs: ns(20.7)) == [.leftUp], !s.active else { return false }

        s.activate(nowNs: 0)
        guard s.handle(key: .right, isDown: true, nowNs: 0).effects == [.move(dx: 1, dy: 0, dragging: false)],
              s.advance(nowNs: ns(21)) == [.move(dx: 3, dy: 0, dragging: false)], s.active else { return false }
        _ = s.handle(key: .right, isDown: false, nowNs: ns(21))
        guard s.handle(key: .home, isDown: true, nowNs: ns(22)).consumed,
              s.statusText == "指针·快速",
              speed(afterSeconds: 0) == 1, speed(afterSeconds: 0.4) == 2,
              speed(afterSeconds: 0.8) == 3, speed(afterSeconds: -1) == 1,
              speed(afterSeconds: 0, mode: .fast) == 3,
              speed(afterSeconds: 0.4, mode: .fast) == 7.5,
              speed(afterSeconds: 10, mode: .fast) == 12 else { return false }
        _ = s.toggleScrollMode(nowNs: ns(22))
        guard s.statusText == "滚动·快速",
              s.handle(key: .down, isDown: true, nowNs: ns(22)).effects == [.scroll(vertical: -3, horizontal: 0)],
              scrollDelta(dirs: [.up], speed: 3).vertical == 3,
              scrollDelta(dirs: [.left], speed: 3).horizontal == 3,
              scrollDelta(dirs: [.right], speed: 3).horizontal == -3 else { return false }
        _ = s.handle(key: .down, isDown: false, nowNs: ns(22))
        _ = s.handle(key: .ok, isDown: true, nowNs: ns(23))
        guard s.advance(nowNs: ns(23.6)) == [.leftDown], s.mode == .pointer,
              s.toggleScrollMode(nowNs: ns(23.7)) == [.leftUp], !s.dragging,
              s.handle(key: .ok, isDown: false, nowNs: ns(23.8)).effects.isEmpty,
              s.handle(key: .menu, isDown: true, nowNs: ns(24)).effects == [.rightClick],
              s.handle(key: .back, isDown: true, nowNs: ns(25)).consumed, !s.active,
              !s.handle(key: .right, isDown: true, nowNs: ns(26)).consumed else { return false }

        s.activate(nowNs: 0)
        _ = s.handle(key: .ok, isDown: true, nowNs: 0)
        _ = s.advance(nowNs: ns(0.6))
        guard s.handle(key: .back, isDown: true, nowNs: ns(0.7)).effects == [.leftUp], !s.active else { return false }
        s.activate(nowNs: 0)
        _ = s.handle(key: .home, isDown: true, nowNs: 0)
        _ = s.handle(key: .home, isDown: false, nowNs: 0)
        _ = s.handle(key: .home, isDown: true, nowNs: 0)
        guard s.statusText == "指针·慢速" else { return false }

        let diagonal = delta(dirs: [.up, .right], speed: 10)
        let opposed = delta(dirs: [.left, .right], speed: 10)
        return abs(hypot(diagonal.dx, diagonal.dy) - 10) < 0.001 && diagonal.dy < 0 && diagonal.dx > 0
            && opposed.dx == 0 && opposed.dy == 0
    }
}
