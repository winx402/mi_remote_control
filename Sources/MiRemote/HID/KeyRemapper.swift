import Foundation
import CoreGraphics
import os
import OSLog

/// M2 按键接管的最终架构（实机验证 2026-07-19）：
/// macOS 不允许用户态 seize 蓝牙 HID 键盘（0xE00002C1），IOHID 独占不可行。
/// 正路：hidutil 把有副作用的键在内核层重映射到 F13-F19（系统零默认行为），
/// 再用 CGEventTap 捕获并吞掉这些中转键，反查回原始键触发动作。
/// 音量键保持系统原生（默认行为即所需）。
/// M3：方向键也进中转表，TapEngine 按 MappingEngine 快照三态分流：
/// 纯原生场景就地改写回方向键 keycode 放行（保住系统 autorepeat 与零延迟），
/// 层/手势场景吞掉喂引擎。
///
/// 已知限制（v1 接受）：Secure Input（密码框等安全输入）期间 CGEventTap 被系统
/// 旁路，而 hidutil 映射仍然生效——遥控器方向键会以中转键（F13/F19/F20/小键盘
/// Clear）泄漏进前台应用，破坏原生光标导航。只有遥控器受影响，真键盘不经过
/// hidutil 重映射、不受影响。未来可轮询 IsSecureEventInputEnabled()，进入
/// Secure Input 时临时卸载方向键映射、退出后重装。

enum KeyRemapper {

    /// 日志通道（main 接线；nil 时静默）。
    nonisolated(unsafe) static var log: ((String) -> Void)?

    /// (遥控器原始 usage, 中转键 usage, 中转键 macOS keycode, 逻辑键)
    static let table: [(src: UInt32, dst: UInt32, keycode: Int64, key: RemoteKey)] = [
        // back(0xF1) 不在此表：超出标准键盘 usage 范围，hidutil 不认、系统也忽略它，
        // 它由 IOHID 监听通道直接读取（无双触发风险，系统本来就不处理 0xF1）。
        (0x4A, 0x69, 107, .home),   // F14
        (0x65, 0x6A, 113, .menu),   // F15
        (0x35, 0x6B, 106, .tv),     // F16
        (0x66, 0x6C, 64,  .power),  // F17
        (0x28, 0x6D, 79,  .ok),     // F18
        // 方向键中转。F21-F24 在 macOS 没有虚拟键码（<HIToolbox/Events.h> 只到 kVK_F20，
        // 2026-07 对照本机 SDK 核实），映过去系统不产事件——不可用。
        // 故第 4 个中转用小键盘 Clear（usage 0x53 → kVK_ANSI_KeypadClear=71）：
        // macOS 无 NumLock 状态、系统零默认行为，即使 tap 失效泄漏也不输出字符。
        (0x52, 0x6E, 80,  .up),     // F19 (kVK_F19)
        (0x51, 0x6F, 90,  .down),   // F20 (kVK_F20)
        (0x50, 0x68, 105, .left),   // F13 (kVK_F13)
        (0x4F, 0x53, 71,  .right),  // Keypad Clear (kVK_ANSI_KeypadClear)
        // 音量键也需进入引擎：基础模式仍执行系统音量，App 控制模式复用为切 Agent。
        // 选用少见的小键盘除/乘作为中转，避免与普通字母数字键冲突。
        (0x80, 0x54, 75,  .volUp),   // Keypad Divide
        (0x81, 0x55, 67,  .volDown), // Keypad Multiply
    ]

    /// 只静默、不送入 MappingEngine 的设备级映射。
    /// 遥控器语音键同时报告键盘 F5；终端会把 F5 的 ESC[15~ 序列显示成 `~`。
    /// 映射到 F21 usage 后 macOS 不产生键盘事件，真正的语音生命周期仍由 ATVV BLE 通道处理。
    private static let silentTable: [(src: UInt32, dst: UInt32)] = [
        (0x3E, 0x70), // voice/F5 → F21（macOS 无虚拟键码，静默）
    ]

    private static var mappingTable: [(src: UInt32, dst: UInt32)] {
        table.map { ($0.src, $0.dst) } + silentTable
    }

    /// 方向键 → 原生方向键 keycode（就地改写放行用）。
    static let nativeArrowKeycode: [RemoteKey: Int64] = [
        .up: 126, .down: 125, .left: 123, .right: 124,   // kVK_UpArrow 等
    ]

    /// 方向键中转的三态分流判定（纯函数，供 self-test）。非方向键返回 nil。
    enum DirectionVerdict: Equatable {
        case rewrite(Int64)   // 就地改写为原生方向键 keycode 放行（含 autorepeat）
        case drop             // 吞弃（引擎路径上的 autorepeat）
        case engine           // 吞掉并转 ButtonEvent 喂 MappingEngine
    }
    static func directionVerdict(key: RemoteKey, isRepeat: Bool, route: TapRoute) -> DirectionVerdict? {
        guard let arrow = nativeArrowKeycode[key] else { return nil }
        // 浮层捕获态：方向键必须吞给引擎（引擎再转交浮层），绝不原生放行。
        if route.uiCapture { return isRepeat ? .drop : .engine }
        // 鼠标模式：方向键喂引擎（MouseMode.handle 消费为光标移动），autorepeat 吞弃
        //（移动靠按住状态 + 60Hz 定时器，不靠系统重复事件）。
        if route.mouseCapture { return isRepeat ? .drop : .engine }
        // 调度中心模式：左右由引擎转换为跨 Space 操作。
        if route.systemUICapture { return isRepeat ? .drop : .engine }
        if route.effectiveLayer == 0, !route.okDown, route.nativeDirections.contains(key) {
            return .rewrite(arrow)
        }
        return isRepeat ? .drop : .engine
    }

    static var keycodeMap: [Int64: RemoteKey] {
        Dictionary(uniqueKeysWithValues: table.map { ($0.keycode, $0.key) })
    }

    // MARK: - hidutil 调用（install/uninstall/reinstall 可能来自不同线程，串行化）

    private static var matching: String { RemoteIdentity.hidutilMatching }
    private static let hidutilLock = NSLock()
    private static let recoveryLog = Logger(subsystem: "com.miremote.controller", category: "KeyMappingRecovery")
    /// 最近一次成功读取的第三方映射（已剔除本程序来源条目）。每次 install/uninstall
    /// 都优先读取 live；快照仅供 uninstall 在查询失败时沿用既有安全清理策略。
    /// 该回退无法保全最近一次读取之后尚未观测的外部修改，调用时必须明确日志。
    nonisolated(unsafe) private static var savedForeign: [(src: UInt64, dst: UInt64)]?

    /// 运行 hidutil，返回 (退出码==0, stdout)。启动失败/非零退出记日志。
    private static func runHidutil(_ args: [String], capture: Bool = false) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = capture ? pipe : FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log?("hidutil 启动失败: \(error)")
            return (false, "")
        }
        let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            log?("hidutil 非零退出码 \(p.terminationStatus)（\(args.first(where: { $0 == "--set" }) != nil ? "set" : "get")）")
        }
        return (p.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }

    /// 解析 `hidutil property --get UserKeyMapping` 的 plist 风格输出为 (src, dst) 对。
    /// 空输出 / (null) / 空数组 → []；有条目 → 逐块提取；输出非空但无法识别 → nil（解析失败）。
    static func parseUserKeyMapping(_ text: String) -> [(src: UInt64, dst: UInt64)]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if !trimmed.contains("{") {
            if trimmed.contains("(null)") { return [] }
            // 空数组：首个 "(" 与末尾 ")" 之间只有空白。
            if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"),
               open < close,
               trimmed[trimmed.index(after: open)..<close]
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            return nil
        }
        var pairs: [(src: UInt64, dst: UInt64)] = []
        var rest = Substring(trimmed)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return nil }
            let block = rest[open...close]
            guard let src = number(after: "HIDKeyboardModifierMappingSrc", in: block),
                  let dst = number(after: "HIDKeyboardModifierMappingDst", in: block) else { return nil }
            pairs.append((src, dst))
            rest = rest[rest.index(after: close)...]
        }
        return pairs
    }

    private static func number(after key: String, in block: Substring) -> UInt64? {
        guard let r = block.range(of: key) else { return nil }
        let digits = block[r.upperBound...].drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return UInt64(digits)
    }

    /// 每次 install 都重新读取 live，避免重连修复覆盖运行中新加/删除的第三方映射。
    /// 即使持有快照，查询/解析失败也不允许安装。
    private static func refreshForeignMappingSnapshot() -> Bool {
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else {
            log?("读取设备现有 UserKeyMapping 失败或无法解析，禁止安装（避免覆盖第三方映射）")
            return false
        }
        savedForeign = mappingPreservingLiveForeign(pairs, installing: false)
        return true
    }

    private static func entryJSON(src: UInt64, dst: UInt64) -> String {
        #"{"HIDKeyboardModifierMappingSrc":\#(src),"HIDKeyboardModifierMappingDst":\#(dst)}"#
    }

    /// 安装重映射（幂等），与当前 live 第三方条目共存。
    /// 现有映射读不到时拒绝安装——绝不使用旧快照覆盖未知现状。
    @discardableResult
    static func install() -> Bool {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        guard refreshForeignMappingSnapshot(), let foreign = savedForeign else {
            log?("hidutil 映射安装跳过：无法确认设备现有映射（健康检查会重试）")
            return false
        }
        let entries = mappingPreservingLiveForeign(foreign, installing: true)
            .map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        if !ok { log?("hidutil 映射安装失败") }
        return ok
    }

    // MARK: - 稳定性专项消费接口（HealthMonitor 用：只读查询 + 异常退出残留清理）

    enum ResidueCleanResult: Equatable {
        case none            // 无本程序残留条目
        case cleaned(Int)    // 清理了 n 条残留（第三方条目原样保留）
        case queryFailed     // --get 失败或输出无法解析（遥控器不在场也走这里）
        case cleanFailed     // 有残留但 --set 回写失败
    }

    /// 启动时（安装映射前）/ --doctor 用：清除上次异常退出遗留的本程序中转条目，
    /// 保留第三方条目。映射在用时（tap 运行中）不要调用——在用映射不是残留。
    static func cleanResidualMapping() -> ResidueCleanResult {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else { return .queryFailed }
        let ours = Set(mappingTable.map { 0x700000000 + UInt64($0.src) })
        let residual = pairs.filter { ours.contains($0.src) }
        if residual.isEmpty { return .none }
        let entries = pairs.filter { !ours.contains($0.src) }
            .map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        return ok ? .cleaned(residual.count) : .cleanFailed
    }

    /// 本程序全部中转条目的完整 (src,dst) 对（含静默表；self-test 构造样本用）。
    static var expectedMappingPairs: [(src: UInt64, dst: UInt64)] {
        mappingTable.map { (0x700000000 + UInt64($0.src), 0x700000000 + UInt64($0.dst)) }
    }

    /// 只认本次读取到的 live：安装时替换本程序来源，卸载时仅剔除这些来源。
    /// 不与旧快照做并集，避免已被外部删除的映射重新出现。
    static func mappingPreservingLiveForeign(_ live: [(src: UInt64, dst: UInt64)],
                                             installing: Bool) -> [(src: UInt64, dst: UInt64)] {
        let ours = Set(expectedMappingPairs.map { $0.src })
        let foreign = live.filter { !ours.contains($0.src) }
        return installing ? expectedMappingPairs + foreign : foreign
    }

    static func liveMappingPreservationSelfCheck() -> Bool {
        let a: (src: UInt64, dst: UInt64) = (0x700000004, 0x700000005)
        let b: (src: UInt64, dst: UInt64) = (0x700000006, 0x700000007)
        let same: ([(src: UInt64, dst: UInt64)], [(src: UInt64, dst: UInt64)]) -> Bool = { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.src == pair.1.src && pair.0.dst == pair.1.dst
            }
        }
        // 先只有 A；运行中 B 新增，同时本程序映射已被服务重建清掉。
        let first = mappingPreservingLiveForeign([a], installing: true)
        let repaired = mappingPreservingLiveForeign([a, b], installing: true)
        guard mappingSatisfied(first), mappingSatisfied(repaired),
              same(mappingPreservingLiveForeign(first, installing: false), [a]),
              same(mappingPreservingLiveForeign(repaired, installing: false), [a, b]) else { return false }
        // A 后来被外部删除；无论重装还是卸载，都不能用旧 A 快照把它复活。
        let afterDeletion = mappingPreservingLiveForeign(expectedMappingPairs + [b], installing: true)
        return mappingSatisfied(afterDeletion)
            && same(mappingPreservingLiveForeign(afterDeletion, installing: false), [b])
            && same(mappingPreservingLiveForeign([b], installing: false), [b])
    }

    /// 在位判据（纯函数，供 self-test）：本程序每条 (src,dst) 必须唯一在位且目标正确。
    /// 同源重复条目或被第三方改到错误目标 → 不算在位（健康检查触发重装修复）。
    static func mappingSatisfied(_ pairs: [(src: UInt64, dst: UInt64)]) -> Bool {
        for entry in mappingTable {
            let src = 0x700000000 + UInt64(entry.src)
            let dst = 0x700000000 + UInt64(entry.dst)
            let matches = pairs.filter { $0.src == src }
            guard matches.count == 1, matches[0].dst == dst else { return false }
        }
        return true
    }

    /// 只读查询：本程序全部中转条目是否在位（nil = 查询/解析失败）。
    /// HealthMonitor 周期校验用，判据见 mappingSatisfied（缺失/错目标/重复即不在位）。
    static func mappingPresent() -> Bool? {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        guard r.ok, let pairs = parseUserKeyMapping(r.output) else { return nil }
        return mappingSatisfied(pairs)
    }

    /// 优先读取 live，只剔除本程序条目，并刷新第三方快照。
    /// 查询失败时保留既有安全策略：有最近快照则尝试卸载，无快照则不写未知现状。
    @discardableResult
    static func uninstall() -> Bool {
        hidutilLock.lock(); defer { hidutilLock.unlock() }
        let r = runHidutil(["property", "--matching", matching, "--get", "UserKeyMapping"], capture: true)
        let foreign: [(src: UInt64, dst: UInt64)]
        if r.ok, let live = parseUserKeyMapping(r.output) {
            foreign = mappingPreservingLiveForeign(live, installing: false)
            savedForeign = foreign
            if foreign.count == live.count {
                savedForeign = nil
                return true // live 已无本程序条目，无需回写健康的第三方映射。
            }
        } else if let savedForeign {
            foreign = savedForeign
            log?("hidutil 映射卸载：live 查询失败，回退最近第三方快照安全清理；无法保证保全上次读取后的未观测修改")
            recoveryLog.warning("Mapping uninstall live query unconfirmed; using last foreign snapshot; unobserved foreign changes may not be preserved")
        } else {
            log?("hidutil 映射卸载跳过：无快照且无法读取 live（不写未知现状）")
            recoveryLog.warning("Mapping uninstall live query unconfirmed; no foreign snapshot, no mapping write")
            return false
        }
        let entries = foreign.map { entryJSON(src: $0.src, dst: $0.dst) }
        let ok = runHidutil(["property", "--matching", matching,
                             "--set", #"{"UserKeyMapping":[\#(entries.joined(separator: ","))]}"#]).ok
        if ok { savedForeign = nil } else { log?("hidutil 映射卸载失败，未确认中转条目已清理") }
        return ok
    }
}

/// 有界恢复的纯计划：生命周期与单次恢复各有代次，旧回调即使已入队也不能越代生效。
/// 仅在 TapEngine.healthQueue 上变更；selfCheck 不创建 tap、不调用 hidutil。
struct MappingRecoveryPlan {
    struct Token: Equatable {
        let lifecycle: UInt64
        let burst: UInt64
    }

    enum MappingAction: Equatable {
        case keep, reinstall, queryUnconfirmed, safetyUninstall
    }

    static let delays: [TimeInterval] = [0.25, 1, 3, 6]
    private(set) var running = false
    private(set) var suspended = false
    private(set) var lifecycle: UInt64 = 0
    private var burst: UInt64 = 0

    var active: Bool { running && !suspended }

    @discardableResult
    mutating func start() -> Bool {
        guard !running else { return false }
        lifecycle &+= 1
        burst &+= 1
        running = true
        suspended = false
        return true
    }

    mutating func stop() {
        running = false
        suspended = false
        lifecycle &+= 1
        burst &+= 1
    }

    @discardableResult
    mutating func setSuspended(_ value: Bool) -> Bool {
        guard running, suspended != value else { return false }
        suspended = value
        burst &+= 1
        return true
    }

    mutating func beginBurst() -> Token? {
        guard active else { return nil }
        burst &+= 1
        return Token(lifecycle: lifecycle, burst: burst)
    }

    func accepts(_ token: Token) -> Bool {
        active && token.lifecycle == lifecycle && token.burst == burst
    }

    static func action(mappingPresent: Bool?, tapReady: Bool = true) -> MappingAction {
        guard tapReady else { return .safetyUninstall }
        return switch mappingPresent {
        case true: .keep
        case false: .reinstall
        case nil: .queryUnconfirmed
        }
    }

    static func selfCheck() -> Bool {
        var plan = MappingRecoveryPlan()
        guard plan.beginBurst() == nil, plan.start(), !plan.start(),
              let first = plan.beginBurst(), plan.accepts(first),
              let newer = plan.beginBurst(), !plan.accepts(first), plan.accepts(newer),
              plan.setSuspended(true), !plan.accepts(newer), plan.beginBurst() == nil,
              plan.setSuspended(false), !plan.accepts(newer),
              let resumed = plan.beginBurst(), plan.accepts(resumed) else { return false }
        plan.stop()
        guard !plan.accepts(resumed), plan.beginBurst() == nil,
              !plan.setSuspended(false), plan.start(),
              let restarted = plan.beginBurst(), restarted.lifecycle != resumed.lifecycle,
              !plan.accepts(resumed), plan.accepts(restarted),
              action(mappingPresent: true) == .keep,
              action(mappingPresent: false) == .reinstall,
              action(mappingPresent: nil) == .queryUnconfirmed,
              action(mappingPresent: true, tapReady: false) == .safetyUninstall,
              action(mappingPresent: false, tapReady: false) == .safetyUninstall,
              action(mappingPresent: nil, tapReady: false) == .safetyUninstall else { return false }
        // 计划固定为四次，最后一次排在六秒处；无递归或无限重试。
        return delays == [0.25, 1, 3, 6]
    }
}

/// CGEventTap：捕获中转键（F13-F20/小键盘Clear），吞掉并转成 ButtonEvent。
/// 需要「辅助功能」权限。复用 HIDEngineDelegate 契约。
///
/// 失效安全（Codex 加固）：tap 被禁用（超时/用户输入）或健康检查发现失效时，
/// 先尝试重启；重启失败立即卸载 hidutil 映射——绝不允许「映射在、过滤器不在」
/// 的中转键泄漏态；tap 恢复后由健康检查自动重装映射。
final class TapEngine: @unchecked Sendable {

    weak var delegate: HIDEngineDelegate?
    /// 方向键分流的快照来源（MappingEngine）。nil 时方向键全走引擎路径（安全默认）。
    weak var router: MappingEngine?
    /// hidutil 映射在位状态回调（HealthMonitor.setMappingInstalled 接线）。
    /// tap 存活与映射在位是两个独立健康源，不再经 hidSeizeState 合并上报。
    var onMappingState: ((Bool) -> Void)?
    /// tap 与 run-loop source：生命周期操作（start/stop/暂停/重装/健康检查）全部
    /// 串行在 healthQueue 上执行（start/stop 用 sync 投递），杜绝 stop 后残留重装。
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// 按压锁存（tap 回调线程写，健康检查/复位线程可能清空，锁保护）。
    private struct PressState {
        /// 当前按压走「原生改写放行」路径的方向键。
        var nativeHeld: Set<RemoteKey> = []
        /// OK 键物理按住（tap 回调同步维护——OK 是中转键，回调能同步看到；
        /// 方向键分流用它替代快照里的异步 okDown，消掉手势漏判窗口）。
        var okDown = false
        /// hidutil 映射当前是否已安装（失效安全的恢复判据）。
        var mappingInstalled = false
        /// 暂停遥控位：true 期间映射保持卸载，健康检查/重装一律豁免。
        var suspended = false
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: PressState())

    /// 低频健康检查：tap 可能被系统静默禁用（辅助功能撤权等），每 30s 校验一次。
    private var healthTimer: DispatchSourceTimer?
    private let healthQueue = DispatchQueue(label: "com.miremote.taphealth")
    private var recoveryPlan = MappingRecoveryPlan()
    private static let recoveryLog = Logger(subsystem: "com.miremote.controller", category: "KeyMappingRecovery")

    init(delegate: HIDEngineDelegate?) {
        self.delegate = delegate
    }

    /// 创建 CGEventTap + run-loop source（不做任何生命周期赋值，供 start/健康检查/
    /// 重装复用）。失败（通常是辅助功能权限缺失）返回 nil。
    private func makeTap() -> (CFMachPort, CFRunLoopSource?)? {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                              | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, ev, userInfo in
                let me = Unmanaged<TapEngine>.fromOpaque(userInfo!).takeUnretainedValue()
                return me.handle(type: type, event: ev)
            },
            userInfo: selfPtr) else { return nil }
        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return (tap, rls)
    }

    func start() {
        let outcome: (tapCreated: Bool, installed: Bool)? = healthQueue.sync {
            guard recoveryPlan.start() else { return nil }
            guard let (tap, rls) = makeTap() else {
                // 上次异常退出可能残留映射；tap 起不来绝不留映射。
                // uninstall 此时无快照——按现状只剔除本程序条目，不动第三方映射。
                _ = KeyRemapper.uninstall()
                // tap 创建失败不代表引擎不该运行——起健康定时器，30s 后自动重试
                // 重建 tap（否则「所有按键失灵」只能靠用户手动重启 App 才能恢复）。
                startHealthTimerOnce()
                return (false, false)
            }
            self.tap = tap
            self.runLoopSource = rls
            let ok = KeyRemapper.install()
            stateLock.withLock { $0.mappingInstalled = ok }
            startHealthTimerOnce()
            return (true, ok)
        }
        guard let outcome else { return }
        onMappingState?(outcome.installed)
        delegate?.hidSeizeState(outcome.tapCreated)
        if !outcome.tapCreated {
            delegate?.hidLog("TAP 创建失败（需辅助功能权限），已尝试清理可能残留的 hidutil 映射")
        } else {
            delegate?.hidLog(outcome.installed ? "TAP 就绪，hidutil 中转映射已安装"
                                              : "TAP 就绪，但 hidutil 映射安装失败（中转键位不生效）")
        }
    }

    func stop() {
        healthQueue.sync {
            recoveryPlan.stop()
            healthTimer?.cancel()
            healthTimer = nil
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            tap = nil
            runLoopSource = nil
            KeyRemapper.uninstall()
            releaseNativeHeld()
            stateLock.withLock { $0 = PressState() }
        }
        onMappingState?(false)
    }

    /// 「tap 恢复后是否允许自动重装映射」的纯判据（healthCheck 用，self-test 直接测）：
    /// 暂停期间一律不装；tap 不在或映射已在位也不装。
    static func shouldAutoReinstall(suspended: Bool, tapEnabled: Bool, mappingInstalled: Bool) -> Bool {
        !suspended && tapEnabled && !mappingInstalled
    }

    /// 暂停/恢复遥控（MappingEngine.onSuspendChanged 接线）：
    /// 暂停=卸载 hidutil 映射（遥控键回系统原生，方向/音量天然可用）；
    /// 恢复=tap 在运行则幂等重装。串行在 healthQueue 上执行，与健康检查天然互斥。
    func setSuspended(_ suspended: Bool) {
        healthQueue.async { [weak self] in
            guard let self, self.recoveryPlan.setSuspended(suspended) else { return }
            let changed = self.stateLock.withLock { st -> Bool in
                guard st.suspended != suspended else { return false }
                st.suspended = suspended
                return true
            }
            guard changed else { return }
            if suspended {
                KeyRemapper.uninstall()
                self.stateLock.withLock { $0.mappingInstalled = false }
                self.releaseNativeHeld()
                self.stateLock.withLock { $0.okDown = false }
                self.onMappingState?(false)
                self.delegate?.hidLog("遥控已暂停：hidutil 映射已卸载（按键回系统原生）")
            } else if self.tap != nil {
                let ok = KeyRemapper.install()
                self.stateLock.withLock { $0.mappingInstalled = ok }
                self.onMappingState?(ok)
                self.delegate?.hidLog(ok ? "遥控已恢复：hidutil 映射已重装"
                                         : "遥控恢复：hidutil 映射重装失败（健康检查会重试）")
            }
        }
    }

    /// 幂等重装 hidutil 映射（蓝牙重连 / 系统唤醒后调用：设备服务重建后映射可能失效）。
    /// 暂停期间豁免。tap 已经死掉（创建失败/被系统摧毁且未恢复）时，先尝试重建 tap
    /// 本身——否则「事件注入通道」整条链路死透，光重装 hidutil 映射毫无意义，
    /// 体检页的「重建通道」按钮会变成按了没反应。
    func reinstallMapping(reason: String) {
        healthQueue.async { [weak self] in
            guard let self, self.recoveryPlan.running else { return }
            if self.recoveryPlan.suspended {
                self.delegate?.hidLog("遥控已暂停，跳过映射重装（\(reason)）")
                return
            }
            guard self.ensureTapReady(reason: reason) else {
                self.uninstallMappingAfterTapFailure(reason: reason)
                return
            }
            _ = self.installMapping(reason: reason)
        }
    }

    /// 设备/显示服务重建后的短恢复窗口。只查四次实际映射；确认缺失才写，未知则保留。
    /// 新事件覆盖旧窗口，暂停/stop 作废代次；回调不另开轮询，也不合成测试按键。
    func scheduleMappingRecovery(reason: String) {
        healthQueue.async { [weak self] in
            guard let self, let token = self.recoveryPlan.beginBurst() else { return }
            Self.recoveryLog.info("Mapping recovery started: \(reason, privacy: .public)")
            for delay in MappingRecoveryPlan.delays {
                self.healthQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.recoveryPlan.accepts(token) else { return }
                    let tapReady = self.ensureTapReady(reason: reason)
                    let present = tapReady ? KeyRemapper.mappingPresent() : nil
                    switch MappingRecoveryPlan.action(mappingPresent: present, tapReady: tapReady) {
                    case .safetyUninstall:
                        self.uninstallMappingAfterTapFailure(reason: reason)
                    case .keep:
                        self.stateLock.withLock { $0.mappingInstalled = true }
                        self.onMappingState?(true)
                        Self.recoveryLog.debug("Mapping recovery verified present: \(reason, privacy: .public)")
                    case .queryUnconfirmed:
                        Self.recoveryLog.warning("Mapping recovery query unconfirmed; no mapping write: \(reason, privacy: .public)")
                    case .reinstall:
                        self.stateLock.withLock { $0.mappingInstalled = false }
                        self.onMappingState?(false)
                        let ok = self.installMapping(reason: reason)
                        Self.recoveryLog.info("Mapping recovery missing; reinstall success=\(ok, privacy: .public): \(reason, privacy: .public)")
                    }
                }
            }
        }
    }

    /// 必须在 healthQueue 上执行。短恢复不依赖缓存的 mappingInstalled，不发模拟 keyDown；
    /// TAP 恢复时沿用已记录 nativeHeld 的配对 keyUp 清理，避免留下系统按住态。
    private func ensureTapReady(reason: String) -> Bool {
        guard recoveryPlan.active else { return false }
        let recovered: Bool
        if let tap {
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            CGEvent.tapEnable(tap: tap, enable: true)
            recovered = CGEvent.tapIsEnabled(tap: tap)
        } else if let (tap, rls) = makeTap() {
            self.tap = tap
            self.runLoopSource = rls
            recovered = true
        } else {
            recovered = false
        }
        guard recovered else {
            delegate?.hidSeizeState(false)
            Self.recoveryLog.warning("TAP recovery unavailable: \(reason, privacy: .public)")
            return false
        }
        resetPressState()
        router?.resetInputState(reason: "恢复 TAP")
        delegate?.hidSeizeState(true)
        Self.recoveryLog.info("TAP recovered: \(reason, privacy: .public)")
        return true
    }

    /// healthQueue 调用方已确认生命周期和 TAP 可用。
    @discardableResult
    private func installMapping(reason: String) -> Bool {
        let ok = KeyRemapper.install()
        stateLock.withLock { $0.mappingInstalled = ok }
        onMappingState?(ok)
        delegate?.hidLog(ok ? "hidutil 映射已重装（\(reason)）" : "hidutil 映射重装失败（\(reason)）")
        return ok
    }

    /// TAP 仍不可用时，优先消除中转键泄漏。这是失效安全清理，不是对健康映射重装。
    /// uninstall 内部优先读取 live；无法确认清理成功时，不把缓存/健康状态谎报为已清理。
    private func uninstallMappingAfterTapFailure(reason: String) {
        let cleaned = KeyRemapper.uninstall()
        if cleaned {
            stateLock.withLock { $0.mappingInstalled = false }
            onMappingState?(false)
            Self.recoveryLog.warning("TAP unavailable; intermediary mapping cleanup succeeded: \(reason, privacy: .public)")
        } else {
            Self.recoveryLog.error("TAP unavailable; mapping cleanup failed or unconfirmed: \(reason, privacy: .public)")
        }
        resetPressState()
        router?.resetInputState(reason: "TAP 恢复失败")
    }

    /// 清空按压锁存（OK 物理态 / 原生按住方向）。设备移除、系统睡眠、tap 失效恢复时调用。
    /// 已透传给系统的「原生改写放行」方向键此刻可能仍处于按下态——为每个补发原生 keyUp，
    /// 否则系统会永久卡住方向键（tap 失效/暂停发生在按住期间的场景）。
    func resetPressState() {
        releaseNativeHeld()
        stateLock.withLock { $0.okDown = false }
    }

    /// 锁内取出 nativeHeld 快照并清空，锁外为每个键合成原生 keyUp。
    private func releaseNativeHeld() {
        let held = stateLock.withLock { st -> Set<RemoteKey> in
            let h = st.nativeHeld
            st.nativeHeld.removeAll()
            return h
        }
        guard !held.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for key in held {
            guard let code = KeyRemapper.nativeArrowKeycode[key],
                  let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code),
                                   keyDown: false) else { continue }
            ev.post(tap: .cghidEventTap)
        }
        delegate?.hidLog("已为按住中的原生方向键补发 keyUp：\(held.map(\.rawValue).joined(separator: ","))")
    }

    // MARK: - 失效安全

    /// 幂等：已有定时器时不重复创建（tap 创建失败分支与成功分支都会调用它，
    /// 必须在 healthQueue 上执行才安全）。
    private func startHealthTimerOnce() {
        guard recoveryPlan.running, healthTimer == nil else { return }
        let lifecycle = recoveryPlan.lifecycle
        let t = DispatchSource.makeTimerSource(queue: healthQueue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self, self.recoveryPlan.running,
                  self.recoveryPlan.lifecycle == lifecycle else { return }
            self.healthCheck()
        }
        t.resume()
        healthTimer = t
    }

    private func healthCheck() {
        guard recoveryPlan.active else { return }
        let suspended = stateLock.withLock { $0.suspended }
        if suspended { return }
        guard let tap else {
            // tap 从未建成或已彻底死亡（不是「被禁用」，是 CFMachPort 都不在）：
            // 每 30s 重试重建，否则「事件注入通道」死透后只能靠用户手动重启 App。
            guard let (newTap, rls) = makeTap() else {
                delegate?.hidLog("健康检查：TAP 重建失败，30s 后重试")
                return
            }
            self.tap = newTap
            self.runLoopSource = rls
            resetPressState()
            router?.resetInputState(reason: "健康检查重建 TAP")
            let ok = KeyRemapper.install()
            stateLock.withLock { $0.mappingInstalled = ok }
            onMappingState?(ok)
            delegate?.hidSeizeState(true)
            delegate?.hidLog(ok ? "健康检查：TAP 已重建，hidutil 映射已重装"
                                 : "健康检查：TAP 已重建，但 hidutil 映射安装失败")
            return
        }
        let installed = stateLock.withLock { $0.mappingInstalled }
        if CGEvent.tapIsEnabled(tap: tap) {
            // tap 健康。若此前因失效卸载过映射，恢复后自动重装。
            if Self.shouldAutoReinstall(suspended: suspended, tapEnabled: true,
                                        mappingInstalled: installed),
               KeyRemapper.install() {
                stateLock.withLock { $0.mappingInstalled = true }
                onMappingState?(true)
                delegate?.hidLog("健康检查：TAP 已恢复，hidutil 映射已重装")
            }
            return
        }
        delegate?.hidLog("健康检查：TAP 已失效，尝试恢复")
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            delegate?.hidLog("健康检查：TAP 已重新启用")
            resetPressState()
            router?.resetInputState(reason: "健康检查恢复 tap")
            delegate?.hidSeizeState(true)   // 失效期间上报过 false，恢复必须对称上报
        } else if installed {
            KeyRemapper.uninstall()
            stateLock.withLock { $0.mappingInstalled = false }
            onMappingState?(false)
            resetPressState()
            router?.resetInputState(reason: "tap 失效")
            delegate?.hidLog("健康检查：TAP 无法恢复，已卸载 hidutil 映射防止中转键泄漏（恢复后自动重装）")
            delegate?.hidSeizeState(false)
        }
    }

    /// tap 被系统禁用（超时/用户输入）后的恢复：重启成功则复位输入状态
    /// （禁用期间可能丢 keyUp）；失败立即卸载映射。在 healthQueue 上执行
    ///（与 stop/暂停/重装串行互斥；tap 回调线程只投递不直接操作生命周期）。
    private func recoverDisabledTap(_ reason: String) {
        guard recoveryPlan.active, let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            delegate?.hidLog("TAP 被禁用（\(reason)），已重新启用")
            resetPressState()
            router?.resetInputState(reason: "tap 重启")
            delegate?.hidSeizeState(true)
        } else {
            delegate?.hidLog("TAP 被禁用（\(reason)）且重启失败，卸载 hidutil 映射防止中转键泄漏")
            KeyRemapper.uninstall()
            stateLock.withLock { $0.mappingInstalled = false }
            onMappingState?(false)
            resetPressState()
            router?.resetInputState(reason: "tap 失效")
            delegate?.hidSeizeState(false)
        }
    }

    // MARK: - 事件回调

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "超时" : "用户输入"
            healthQueue.async { [weak self] in self?.recoverDisabledTap(reason) }
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let key = KeyRemapper.keycodeMap[keycode] else {
            return Unmanaged.passUnretained(event) // 非中转键，放行
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // OK 物理态同步锁存：OK 是中转键，回调在这里能同步看到它的 down/up；
        // 方向键分流判定用锁存值覆盖快照里的异步 okDown，消掉「OK↓与方向↓几乎同时」
        // 时快照来不及更新导致的手势漏判窗口。
        if key == .ok, !isRepeat {
            stateLock.withLock { $0.okDown = (type == .keyDown) }
        }

        // 方向键三态分流：纯原生场景就地改写 keycode 放行（保住系统 autorepeat 与零延迟）。
        // 分流只在首次 keyDown 时决定（层/纯原生判定读 MappingEngine 快照，okDown 用本地
        // 同步锁存值）；autorepeat 与 keyUp 跟随该次按压记录的路径，避免按压中途层变化导致
        // 原生 down 配不上 up（系统卡住方向键）或引擎收到孤儿 up。
        if let arrow = KeyRemapper.nativeArrowKeycode[key] {
            let verdict: KeyRemapper.DirectionVerdict = stateLock.withLock { st in
                if type == .keyDown, !isRepeat {
                    var route = router?.tapRoute ?? TapRoute()
                    route.okDown = st.okDown
                    route.mouseCapture = MouseMode.shared.isActive
                    route.systemUICapture = TransientSystemUI.isMissionControlActive()
                    let v = KeyRemapper.directionVerdict(key: key, isRepeat: false, route: route)!
                    if case .rewrite = v { st.nativeHeld.insert(key) } else { st.nativeHeld.remove(key) }
                    return v
                }
                let wasNative = st.nativeHeld.contains(key)
                if type == .keyUp { st.nativeHeld.remove(key) }
                return wasNative ? .rewrite(arrow) : (isRepeat ? .drop : .engine)
            }
            switch verdict {
            case .rewrite(let a):
                event.setIntegerValueField(.keyboardEventKeycode, value: a)
                return Unmanaged.passUnretained(event)
            case .drop:
                return nil
            case .engine:
                // 落到下方吞掉上报
                break
            }
        } else if isRepeat {
            // 非方向中转键的 autorepeat 也吞弃：重复 keyDown 会不断重置
            // MappingEngine 的 hold 定时器，长按（如 ok→瞬时层）永远触发不了。
            return nil
        }
        // 吞掉中转键并上报（注意：外接键盘的真 F13-F20/小键盘Clear 也会被吞——Mac 键盘几乎没有这些键，可接受）
        delegate?.hidButton(ButtonEvent(key: key, isDown: type == .keyDown,
                                        timeNs: DispatchTime.now().uptimeNanoseconds))
        return nil
    }
}
