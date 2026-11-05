import AppKit
import IOKit
import Darwin

@MainActor final class DisplaySystem: DisplayBackend {
    typealias EnableFunction = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    typealias HDRRead = @convention(c) (CGDirectDisplayID) -> Bool
    typealias HDRWrite = @convention(c) (CGDirectDisplayID, Bool) -> Void
    private let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
    private let sessionToken = DisplaySystem.currentSessionToken()
    private let disabledURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LGLidSwitch/disabled-displays.json")
    private var observed: [UInt32: String] = [:]
    private var disabled: [DisplayRecord] = []
    init() {
        if let token = sessionToken, let data = try? Data(contentsOf: disabledURL), let lease = try? JSONDecoder().decode(DisabledDisplayLease.self, from: data), lease.session == token { disabled = lease.records }
    }
    private static func currentSessionToken() -> String? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let audit = session?["kCGSSessionAuditIDKey"] as? NSNumber else { return nil }
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer) + ":" + audit.stringValue
    }
    private func saveDisabled() throws {
        guard let token = sessionToken else { throw DisplayFailure("无法确认当前登录会话，已保留输出") }
        try FileManager.default.createDirectory(at: disabledURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(DisabledDisplayLease(session: token, records: disabled)).write(to: disabledURL, options: .atomic)
    }
    private func readHDR(_ id: UInt32, symbol: String = "CoreDisplay_Display_IsHDRModeEnabled") -> Bool? {
        guard let h = coreDisplay, let fn = dlsym(h, symbol) else { return nil }
        return unsafeBitCast(fn, to: HDRRead.self)(id)
    }
    private func uuid(_ id: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func requireIdentity(_ target: DisplayRecord) throws {
        guard target.id != 0, uuid(target.id) == target.uuid,
              (CGDisplayIsBuiltin(target.id) != 0) == target.builtIn else {
            throw DisplayFailure("\(target.name) 的设备标识已变化，请在设备与输出中重新确认")
        }
    }
    private func enabledFunction() throws -> EnableFunction {
        guard let h = graphics, let fn = dlsym(h, "CGSConfigureDisplayEnabled") else { throw DisplayFailure("这版 macOS 未提供显示器停用接口") }
        return unsafeBitCast(fn, to: EnableFunction.self)
    }
    func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    func records() -> [DisplayRecord] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { s -> (UInt32, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return (id, s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        let result = ids.prefix(Int(count)).compactMap { id -> DisplayRecord? in
            guard let identity = uuid(id) else { return nil }
            let mode = CGDisplayCopyDisplayMode(id)
            let parent = CGDisplayMirrorsDisplay(id)
            return DisplayRecord(id: id, uuid: identity, name: names[id] ?? "Display \(id)", vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), builtIn: CGDisplayIsBuiltin(id) != 0, active: CGDisplayIsActive(id) != 0, main: CGMainDisplayID() == id, mirrored: CGDisplayIsInMirrorSet(id) != 0, width: mode?.width ?? 0, height: mode?.height ?? 0, pixelWidth: mode?.pixelWidth ?? 0, pixelHeight: mode?.pixelHeight ?? 0, hz: mode?.refreshRate ?? 0, hdr: readHDR(id), hdrSupported: readHDR(id, symbol: "CoreDisplay_Display_SupportsHDRMode"), mirrorSource: parent == kCGNullDirectDisplay ? nil : parent)
        }
        for screen in result { observed[screen.id] = screen.uuid }
        return result
    }
    private func require(_ code: CGError, _ action: String) throws {
        guard code == .success else { throw DisplayFailure("\(action)失败（macOS \(code.rawValue)）") }
    }
    private func transaction(_ changes: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try require(CGBeginDisplayConfiguration(&config), "开始显示配置")
        guard let config else { throw DisplayFailure("无法开始显示配置") }
        do { try changes(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        try require(CGCompleteDisplayConfiguration(config, .forSession), "应用显示配置")
    }
    func enable(_ target: DisplayRecord) throws {
        let online = records()
        // Mirror slaves can be online but inactive; they are already enabled.
        if online.contains(where: { $0.uuid == target.uuid && $0.builtIn == target.builtIn && ($0.active || $0.mirrored) }) {
            if disabled.contains(where: { $0.uuid == target.uuid }) { disabled.removeAll { $0.uuid == target.uuid }; try? saveDisabled() }
            return
        }
        guard target.id != 0, !online.contains(where: { $0.id == target.id && $0.uuid != target.uuid }) else { throw DisplayFailure("屏幕编号已被其他设备使用，请重新检测") }
        let actual = uuid(target.id)
        let leased = sessionToken.map { DisabledDisplayLease(session: $0, records: disabled).permits(target, session: $0, online: online) } ?? false
        // Disabled displays may have no public UUID until enabled. Only reuse a runtime ID
        // observed by this process, or one we explicitly disabled in this login session.
        guard (actual == nil || actual == target.uuid), actual == target.uuid || observed[target.id] == target.uuid || leased else {
            throw DisplayFailure("\(target.name) 的设备标识需要重新确认，请检测显示器或重新连接")
        }
        let fn = try enabledFunction()
        try transaction { config in
            guard fn(config, target.id, true) == 0 else { throw DisplayFailure("无法启用 \(target.name)，请检查连接") }
        }
        let after = records()
        if after.contains(where: { $0.id == target.id && $0.uuid != target.uuid }) { throw DisplayFailure("重新启用后设备身份不匹配，未继续切换") }
        if after.contains(where: { $0.uuid == target.uuid }) { disabled.removeAll { $0.uuid == target.uuid }; try? saveDisabled() }
    }
    func disable(_ target: DisplayRecord) throws {
        try requireIdentity(target)
        let screens = records()
        guard screens.contains(where: { $0.uuid == target.uuid && $0.id == target.id && $0.active }),
              screens.contains(where: { $0.uuid != target.uuid && $0.active && $0.main && (!$0.builtIn || lidClosed() == false) }) else {
            throw DisplayFailure("其他主屏尚未就绪，已保留 \(target.name) 输出")
        }
        if target.builtIn && lidClosed() != false { throw DisplayFailure("内屏当前由系统管理") }
        disabled.removeAll { $0.id == target.id || $0.uuid == target.uuid }; disabled.append(target)
        try saveDisabled()
        let fn = try enabledFunction()
        try transaction { config in
            guard fn(config, target.id, false) == 0 else { throw DisplayFailure("这台 Mac 未能停用 \(target.name)，已保留输出") }
        }
    }
    func makeMain(_ id: UInt32) throws {
        if CGMainDisplayID() == id { return }
        let current = records()
        guard current.contains(where: { $0.id == id && $0.active }) else { throw DisplayFailure("目标主屏尚未就绪") }
        let origin = CGDisplayBounds(id).origin
        try transaction { config in
            for display in current where display.active {
                let point = CGDisplayBounds(display.id).origin
                try require(CGConfigureDisplayOrigin(config, display.id, Int32(point.x - origin.x), Int32(point.y - origin.y)), "设置主显示器")
            }
        }
    }
    func unmirror(_ target: DisplayRecord, allowed: Set<String>) throws {
        try requireIdentity(target)
        guard CGDisplayIsInMirrorSet(target.id) != 0 else { return }
        let current = records(), parent = CGDisplayMirrorsDisplay(target.id)
        let master = parent == kCGNullDirectDisplay ? target.id : parent
        let group = current.filter { $0.id == master || $0.id == target.id || CGDisplayMirrorsDisplay($0.id) == master }
        guard group.contains(where: { $0.id == master }), group.allSatisfy({ allowed.contains($0.key) }) else {
            throw DisplayFailure("镜像组包含保持原状或未确认的屏幕。请先在系统显示器设置中取消镜像，或将相关屏幕加入规则")
        }
        let slaves = parent == kCGNullDirectDisplay ? group.filter { $0.id != target.id } : []
        try transaction { config in
            try require(CGConfigureDisplayMirrorOfDisplay(config, target.id, kCGNullDirectDisplay), "取消屏幕镜像")
            for slave in slaves {
                try require(CGConfigureDisplayMirrorOfDisplay(config, slave.id, kCGNullDirectDisplay), "扩展显示桌面")
            }
        }
    }
    func mirror(_ target: DisplayRecord, source: DisplayRecord, allowed: Set<String>) throws {
        try requireIdentity(target); try requireIdentity(source)
        guard lidClosed() == false, source.builtIn, !target.builtIn, target.id != source.id,
              allowed.contains(target.key), allowed.contains(source.key) else { throw DisplayFailure("请开盖并选择 Mac 和一台外接屏进行镜像") }
        let current = records()
        for id in [source.id, target.id] {
            let parent = CGDisplayMirrorsDisplay(id), master = parent == kCGNullDirectDisplay ? id : parent
            let group = current.filter { $0.id == master || $0.id == id || CGDisplayMirrorsDisplay($0.id) == master }
            guard group.allSatisfy({ allowed.contains($0.key) }) else { throw DisplayFailure("镜像涉及未加入规则的屏幕，已保留当前画面") }
        }
        try transaction { config in
            try require(CGConfigureDisplayMirrorOfDisplay(config, target.id, source.id), "设置屏幕镜像")
        }
    }
    private func rawModes(_ target: DisplayRecord) -> [CGDisplayMode] {
        guard target.id != 0, uuid(target.id) == target.uuid else { return [] }
        return CGDisplayCopyAllDisplayModes(target.id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
    }
    func modes(_ target: DisplayRecord) -> [ModeRequest] {
        let set = Set(rawModes(target).map { ModeRequest(width: $0.width, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, hz: $0.refreshRate) })
        return set.filter { $0.pixelWidth > 0 && $0.pixelHeight > 0 && $0.hz.isFinite }.sorted {
            if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
            if $0.pixelHeight != $1.pixelHeight { return $0.pixelHeight > $1.pixelHeight }
            if abs($0.hz - $1.hz) > 0.1 { return $0.hz > $1.hz }
            return ($0.width ?? 0) < ($1.width ?? 0)
        }
    }
    func configure(_ target: DisplayRecord, output: OutputPreference) throws -> ModeRequest? {
        try requireIdentity(target)
        let all = rawModes(target)
        var selected: ModeChoice?
        if output.mode != nil || output.automaticMode {
            let choices = all.enumerated().map { i, m in ModeChoice(index: i, width: m.width, height: m.height, pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight, hz: m.refreshRate) }
            selected = ModeChoice.best(choices, request: output.mode, automatic: output.automaticMode, preferredWidth: target.width)
            guard selected != nil else { throw DisplayFailure("\(target.name) 当前连接不支持保存的分辨率或刷新率，已保留现有画面") }
        }
        let support = readHDR(target.id, symbol: "CoreDisplay_Display_SupportsHDRMode")
        if output.hdr == .on && support != true { throw DisplayFailure("\(target.name) 当前连接没有确认 HDR 支持") }
        let hdrValue: Bool? = output.hdr == .on ? true : output.hdr == .off ? false : output.hdr == .automatic ? support : nil
        let setter = coreDisplay.flatMap { dlsym($0, "CoreDisplay_Display_SetHDRModeEnabled") }
        if let hdrValue, readHDR(target.id) != hdrValue || selected != nil {
            guard setter != nil else { throw DisplayFailure("当前系统无法设置 HDR") }
        }
        if let selected, !target.active || CGDisplayCopyDisplayMode(target.id)?.ioDisplayModeID != all[selected.index].ioDisplayModeID {
            try require(CGDisplaySetDisplayMode(target.id, all[selected.index], nil), "设置分辨率和刷新率")
        } else if selected == nil, !target.active, let currentMode = CGDisplayCopyDisplayMode(target.id) {
            try require(CGDisplaySetDisplayMode(target.id, currentMode, nil), "恢复当前显示模式")
        }
        // A mode switch may reset HDR; compare again after applying the mode.
        if let hdrValue, readHDR(target.id) != hdrValue, let setter { unsafeBitCast(setter, to: HDRWrite.self)(target.id, hdrValue) }
        return selected?.request
    }
    func setHDRForVerification(_ target: DisplayRecord, enabled: Bool) throws {
        _ = try configure(target, output: OutputPreference(hdr: enabled ? .on : .off))
    }
}
