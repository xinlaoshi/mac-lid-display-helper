import Foundation

let internalKey = "builtin-display"
struct DisplayFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct DisabledDisplayLease: Codable {
    var session: String
    var records: [DisplayRecord]
    func permits(_ target: DisplayRecord, session: String, online: [DisplayRecord]) -> Bool {
        self.session == session && records.contains(where: { $0.id == target.id && $0.uuid == target.uuid && $0.builtIn == target.builtIn }) && !online.contains(where: { $0.id == target.id && $0.uuid != target.uuid })
    }
}
struct DisplayRecord: Codable, Equatable {
    var id: UInt32
    var uuid: String
    var name: String
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    var builtIn: Bool
    var active: Bool
    var main: Bool
    var mirrored: Bool
    var width: Int
    var height: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var hz: Double
    var hdr: Bool?
    var hdrSupported: Bool? = nil
    var mirrorSource: UInt32? = nil
    var key: String { builtIn ? internalKey : uuid }
    static let internalPlaceholder = DisplayRecord(id: 0, uuid: internalKey, name: "Mac 内置显示器", vendor: 0, model: 0, serial: 0, builtIn: true, active: false, main: false, mirrored: false, width: 0, height: 0, pixelWidth: 0, pixelHeight: 0, hz: 0, hdr: nil)
    var hasReliableSerial: Bool { vendor != 0 && model != 0 && ![UInt32(0), 0x01010101, 0xffffffff].contains(serial) }
    func sameFingerprint(as other: DisplayRecord) -> Bool {
        hasReliableSerial && other.hasReliableSerial && vendor == other.vendor && model == other.model && serial == other.serial && builtIn == other.builtIn
    }
    var outputDescription: String {
        guard pixelWidth > 0 else { return builtIn ? "由 macOS 管理" : "等待连接" }
        let rate = hz > 0 ? " · \(hz.formatted(.number.precision(.fractionLength(0...2)))) Hz" : ""
        return "\(pixelWidth) × \(pixelHeight)\(rate)" + (hdr == true ? " · HDR" : "")
    }
}
enum LidEvent: String, Codable, CaseIterable, Identifiable {
    case open, closed
    var id: String { rawValue }
    var title: String { self == .open ? "开盖时" : "合盖时" }
}
enum ScreenAction: String, Codable, CaseIterable, Identifiable {
    case on, off, keep
    var id: String { rawValue }
    var title: String { switch self { case .on: return "启用"; case .off: return "停用"; case .keep: return "保持" } }
}
enum HDRChoice: String, Codable, CaseIterable, Identifiable {
    case keep, automatic, on, off
    var id: String { rawValue }
    var title: String { switch self { case .keep: return "保持当前"; case .automatic: return "自动"; case .on: return "开启 HDR"; case .off: return "关闭 HDR" } }
}
enum ScenePreset: String, CaseIterable, Identifiable {
    case internalOnly, externalOnly, extended, keep, custom
    var id: String { rawValue }
    var title: String { switch self { case .internalOnly: return "只用内屏"; case .externalOnly: return "只用外屏"; case .extended: return "扩展使用"; case .keep: return "保持原状"; case .custom: return "自定义" } }
}
struct ModeRequest: Codable, Equatable, Hashable, Identifiable {
    var width: Int?
    var pixelWidth: Int
    var pixelHeight: Int
    var hz: Double
    var id: String { "\(width ?? 0):\(pixelWidth):\(pixelHeight):\(hz)" }
    var title: String {
        let rate = hz > 0 ? " · \(hz.formatted(.number.precision(.fractionLength(0...2)))) Hz" : " · 默认刷新率"
        let scale = width.map { $0 != pixelWidth ? "（缩放 \($0)）" : "" } ?? ""
        return "\(pixelWidth) × \(pixelHeight)\(rate)\(scale)"
    }
    func matches(_ record: DisplayRecord) -> Bool {
        pixelWidth == record.pixelWidth && pixelHeight == record.pixelHeight && (width == nil || width == record.width) && (hz == 0 || abs(hz - record.hz) < 0.1)
    }
}
struct ModeChoice: Equatable {
    let index: Int
    let width: Int
    let height: Int
    let pixelsWide: Int
    let pixelsHigh: Int
    let hz: Double
    var request: ModeRequest { ModeRequest(width: width, pixelWidth: pixelsWide, pixelHeight: pixelsHigh, hz: hz) }
    static func best(_ modes: [ModeChoice], request: ModeRequest?, automatic: Bool, preferredWidth: Int) -> ModeChoice? {
        modes.filter { m in
            guard let r = request else { return automatic }
            return m.pixelsWide == r.pixelWidth && m.pixelsHigh == r.pixelHeight && (r.hz == 0 || abs(m.hz - r.hz) < 0.1) && (r.width == nil || r.width == m.width)
        }.sorted { a, b in
            if automatic && request == nil {
                let aa = Int64(a.pixelsWide) * Int64(a.pixelsHigh), bb = Int64(b.pixelsWide) * Int64(b.pixelsHigh)
                if aa != bb { return aa > bb }
                if abs(a.hz - b.hz) > 0.1 { return a.hz > b.hz }
            }
            let da = abs(a.width - preferredWidth), db = abs(b.width - preferredWidth)
            return da == db ? a.index < b.index : da < db
        }.first
    }
}
struct OutputPreference: Codable, Equatable {
    var mode: ModeRequest? = nil
    var automaticMode = false
    var hdr: HDRChoice = .keep
    static let legacyLG = OutputPreference(mode: ModeRequest(width: nil, pixelWidth: 3840, pixelHeight: 2160, hz: 120), hdr: .on)
}
struct KnownDisplay: Codable, Equatable, Identifiable {
    var record: DisplayRecord
    var alias = ""
    var confirmed = false
    var output = OutputPreference()
    var id: String { record.key }
    var name: String {
        if !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return alias }
        if record.builtIn { return "Mac 内置显示器" }
        let systemName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return systemName.isEmpty ? "显示器 \(record.id)" : systemName
    }
}
enum DualDisplayMode: String, Codable, CaseIterable, Identifiable {
    case extended, mirror
    var id: String { rawValue }
    var title: String { self == .mirror ? "镜像使用" : "扩展使用" }
}
struct SceneRule: Codable, Equatable {
    var actions: [String: ScreenAction] = [:]
    var main: String? = nil
    var target: String? = nil
    var noChange = false
    var dualMode: DualDisplayMode? = nil
    func action(_ key: String) -> ScreenAction { actions[key] ?? .keep }
}
struct Configuration: Codable, Equatable {
    var schemaVersion = 2
    var automatic = true
    var openDelay: Double = 0
    var devices: [KnownDisplay] = [KnownDisplay(record: .internalPlaceholder, confirmed: true)]
    var openRule = SceneRule(actions: [internalKey: .on], main: internalKey)
    var closedRule = SceneRule(actions: [internalKey: .off], noChange: true)
    init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, automatic, openDelay, devices, openRule, closedRule, target, onOpen, onClose }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        let delay = try c.decodeIfPresent(Double.self, forKey: .openDelay) ?? 0
        openDelay = delay.isFinite ? min(3, max(0, delay)) : 0
        if let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            guard version == 2 else { throw DisplayFailure("配置版本不受支持，原文件已保留") }
            devices = try c.decode([KnownDisplay].self, forKey: .devices)
            openRule = try c.decode(SceneRule.self, forKey: .openRule)
            closedRule = try c.decode(SceneRule.self, forKey: .closedRule)
            guard Set(devices.map(\.id)).count == devices.count, devices.contains(where: { $0.id == internalKey }) else { throw DisplayFailure("显示器配置身份重复或缺少内屏") }
            try validate()
        } else if let target = try c.decodeIfPresent(DisplayRecord.self, forKey: .target), !target.builtIn {
            devices.append(KnownDisplay(record: target, confirmed: true, output: .legacyLG))
            let onOpen = try c.decodeIfPresent(String.self, forKey: .onOpen) ?? "macOnly"
            let onClose = try c.decodeIfPresent(String.self, forKey: .onClose) ?? "lgMain"
            openRule.target = target.key; closedRule.target = target.key
            switch onOpen {
            case "macOnly": openRule.actions[target.key] = .off
            case "extended": openRule.actions[target.key] = .on
            case "lgMain": openRule.actions = [internalKey: .keep, target.key: .on]; openRule.main = target.key
            case "noChange": openRule.noChange = true; openRule.main = nil
            default: throw DisplayFailure("旧版开盖动作无法识别，原配置已保留")
            }
            closedRule = SceneRule(actions: [internalKey: .off, target.key: .on], main: target.key, target: target.key, noChange: onClose == "noChange")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .schemaVersion); try c.encode(automatic, forKey: .automatic); try c.encode(openDelay, forKey: .openDelay)
        try c.encode(devices, forKey: .devices); try c.encode(openRule, forKey: .openRule); try c.encode(closedRule, forKey: .closedRule)
    }
    var externals: [KnownDisplay] { devices.filter { !$0.record.builtIn && $0.confirmed } }
    func rule(_ event: LidEvent) -> SceneRule { event == .open ? openRule : closedRule }
    mutating func updateRule(_ event: LidEvent, _ rule: SceneRule) { if event == .open { openRule = rule } else { closedRule = rule } }
    func validate() throws {
        guard devices.filter({ $0.record.builtIn }).count == 1, Set(devices.map(\.id)).count == devices.count,
              devices.allSatisfy({ !$0.record.uuid.isEmpty && ($0.record.builtIn || $0.record.uuid != internalKey) }) else { throw DisplayFailure("显示器身份配置无效") }
        for d in devices {
            if let m = d.output.mode {
                guard m.pixelWidth > 0, m.pixelHeight > 0, m.pixelWidth <= 32768, m.pixelHeight <= 32768,
                      m.hz.isFinite, m.hz >= 0, m.hz <= 2000, m.width.map({ $0 > 0 && $0 <= 32768 }) ?? true else { throw DisplayFailure("保存的显示模式无效") }
            }
        }
        for event in LidEvent.allCases {
            let r = rule(event)
            if r.noChange { continue }
            if r.dualMode == .mirror {
                guard event == .open, r.action(internalKey) == .on, r.main == nil,
                      let target = r.target, externals.contains(where: { $0.id == target && r.action($0.id) == .on }),
                      externals.filter({ r.action($0.id) == .on }).count == 1 else {
                    throw DisplayFailure("镜像使用需要 Mac 屏幕和一台外接屏，不需要指定主显示器")
                }
            }
            if event == .closed && r.action(internalKey) == .on { throw DisplayFailure("合盖时不能启用 Mac 内屏") }
            let eligible = devices.filter { ($0.confirmed || $0.record.builtIn) && (event == .open || !$0.record.builtIn) }
            guard !eligible.isEmpty, eligible.contains(where: { r.action($0.id) != .off }) else { throw DisplayFailure("请至少保留一块启用或保持原状的屏幕") }
            if let main = r.main { guard eligible.contains(where: { $0.id == main }), r.action(main) == .on else { throw DisplayFailure("主屏必须是已确认且启用的屏幕") } }
            for (key, action) in r.actions where action != .keep && key != internalKey {
                guard devices.contains(where: { $0.id == key && $0.confirmed }) else { throw DisplayFailure("请先确认要操作的外接显示器") }
            }
        }
    }
    func preset(_ event: LidEvent) -> ScenePreset {
        let r = rule(event); if r.noChange { return .keep }
        let on = externals.filter { r.action($0.id) == .on }, allExplicit = externals.allSatisfy { r.action($0.id) != .keep }
        if event == .open && r.action(internalKey) == .on && externals.allSatisfy({ r.action($0.id) == .off }) { return .internalOnly }
        if (event == .closed || r.action(internalKey) == .off) && on.count == 1 && allExplicit { return .externalOnly }
        if allExplicit && ((event == .open && r.action(internalKey) == .on && !on.isEmpty) || (event == .closed && on.count >= 2)) { return .extended }
        return .custom
    }
    mutating func select(_ preset: ScenePreset, event: LidEvent, target: String? = nil) throws {
        if preset == .custom { return }
        if preset == .internalOnly && event == .closed { throw DisplayFailure("合盖时内屏由系统熄灭") }
        var r = rule(event)
        if preset == .keep { r.noChange = true; updateRule(event, r); return }
        let chosen = target ?? r.target ?? externals.first?.id
        if preset != .internalOnly { guard let chosen, externals.contains(where: { $0.id == chosen }) else { throw DisplayFailure("请先确认一台外接显示器") } }
        if preset == .extended && event == .closed && externals.count < 2 { throw DisplayFailure("合盖扩展使用需要两台外接显示器") }
        r.noChange = false; r.target = chosen; r.main = nil; r.dualMode = nil
        r.actions = Dictionary(uniqueKeysWithValues: externals.map { ($0.id, ScreenAction.off) }); r.actions[internalKey] = .off
        switch preset {
        case .internalOnly: r.actions[internalKey] = .on; r.main = internalKey
        case .externalOnly: r.actions[chosen!] = .on; r.main = chosen
        case .extended:
            if event == .open { r.actions[internalKey] = .on; r.actions[chosen!] = .on; r.main = internalKey }
            else { for d in externals { r.actions[d.id] = .on }; r.main = chosen }
        default: break
        }
        updateRule(event, r)
    }
    mutating func setAction(_ action: ScreenAction, key: String, event: LidEvent) throws {
        if key == internalKey && event == .closed { throw DisplayFailure("合盖内屏由系统管理") }
        let before = self; var r = rule(event); r.noChange = false; r.actions[key] = action
        if r.main == key && action != .on { r.main = devices.first { ($0.confirmed || $0.record.builtIn) && r.action($0.id) == .on && (event == .open || !$0.record.builtIn) }?.id }
        updateRule(event, r)
        do { try validate() } catch { self = before; throw error }
    }
    mutating func selectTarget(_ key: String, event: LidEvent) throws {
        let previous = rule(event)
        if event == .open && previous.dualMode == .mirror { try selectDualMode(.mirror, target: key); return }
        let scene = event == .closed ? ScenePreset.externalOnly : preset(event) == .extended ? .extended : .externalOnly
        try select(scene, event: event, target: key)
        if scene == .extended, let main = previous.main, main != internalKey {
            var updated = rule(event); updated.main = key; updateRule(event, updated)
        }
    }
    mutating func setMain(_ key: String, event: LidEvent) throws {
        let before = self
        guard rule(event).dualMode != .mirror else { throw DisplayFailure("镜像使用不需要设置主显示器") }
        guard devices.contains(where: { $0.id == key && ($0.confirmed || $0.record.builtIn) }),
              rule(event).action(key) == .on, event == .open || key != internalKey else {
            throw DisplayFailure("请先选择要使用的屏幕，再将它设为主显示器")
        }
        var updated = rule(event); updated.main = key; updated.noChange = false; updateRule(event, updated)
        do { try validate() } catch { self = before; throw error }
    }
    mutating func selectDualMode(_ mode: DualDisplayMode, target: String? = nil) throws {
        let previous = openRule
        try select(.extended, event: .open, target: target)
        openRule.dualMode = mode
        if mode == .mirror { openRule.main = nil }
        else if let main = previous.main, openRule.action(main) == .on { openRule.main = main }
    }
    mutating func setSecondary(_ key: String) throws {
        let enabled = devices.filter { ($0.confirmed || $0.record.builtIn) && openRule.action($0.id) == .on }
        guard openRule.dualMode != .mirror, enabled.count == 2, enabled.contains(where: { $0.id == key }),
              let main = enabled.first(where: { $0.id != key }) else { throw DisplayFailure("请先选择扩展使用的两块屏幕") }
        try setMain(main.id, event: .open)
    }
    mutating func confirm(_ key: String) {
        guard let i = devices.firstIndex(where: { $0.id == key && !$0.record.builtIn }) else { return }
        let first = externals.isEmpty; devices[i].confirmed = true
        if first { try? select(.internalOnly, event: .open, target: key); try? select(.externalOnly, event: .closed, target: key) }
    }
    mutating func reconcile(_ records: [DisplayRecord]) {
        let online = Set(records.map(\.key))
        for record in records {
            if let i = devices.firstIndex(where: { $0.id == record.key }) { devices[i].record = record; continue }
            let old = devices.indices.filter { !online.contains(devices[$0].id) && devices[$0].record.sameFingerprint(as: record) }
            let peers = records.filter { $0.sameFingerprint(as: record) }
            if old.count == 1 && peers.count == 1 {
                let i = old[0], oldKey = devices[i].id; devices[i].record = record
                for event in LidEvent.allCases {
                    var r = rule(event)
                    if let a = r.actions.removeValue(forKey: oldKey) { r.actions[record.key] = a }
                    if r.main == oldKey { r.main = record.key }; if r.target == oldKey { r.target = record.key }; updateRule(event, r)
                }
            } else { devices.append(KnownDisplay(record: record, confirmed: record.builtIn)) }
        }
    }
}
