import Foundation

@MainActor protocol DisplayBackend: AnyObject {
    func records() -> [DisplayRecord]
    func lidClosed() -> Bool?
    func enable(_ target: DisplayRecord) throws
    func disable(_ target: DisplayRecord) throws
    func unmirror(_ target: DisplayRecord, allowed: Set<String>) throws
    func mirror(_ target: DisplayRecord, source: DisplayRecord, allowed: Set<String>) throws
    func configure(_ target: DisplayRecord, output: OutputPreference) throws -> ModeRequest?
    func makeMain(_ id: UInt32) throws
}

@MainActor final class SwitchEngine {
    let backend: DisplayBackend
    var revision = 0
    var onStatus: ((String) -> Void)?
    var internalRecovery: ((DisplayRecord?) throws -> Void)?
    var wait: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    init(backend: DisplayBackend) { self.backend = backend }
    func cancel() { revision += 1 }
    private func check(_ token: Int, lid: Bool) throws {
        guard token == revision, !Task.isCancelled, backend.lidClosed() == lid else { throw CancellationError() }
    }
    private func current(_ key: String) -> DisplayRecord? { backend.records().first { $0.key == key } }
    private func hdrVerified(_ record: DisplayRecord, output: OutputPreference) -> Bool {
        switch output.hdr {
        case .keep: return true
        case .on: return record.hdr == true
        case .off: return record.hdr == false
        case .automatic: return record.hdrSupported.map { record.hdr == $0 } ?? true
        }
    }
    private func ready(_ key: String, token: Int, lid: Bool, active: Bool = true) async throws -> DisplayRecord {
        for _ in 0..<24 {
            try check(token, lid: lid)
            if let r = current(key), !active || r.active { return r }
            try await wait(250_000_000)
        }
        throw DisplayFailure(key == internalKey ? "Mac 内屏尚未恢复，已保留可用外屏" : "目标显示器未响应，已保留现有画面；请检查电源、输入源或连接线")
    }
    private func recover(_ before: [DisplayRecord], devices: [KnownDisplay]) {
        // Recovery only enables; a cancelled older request never disables a newer target.
        let candidates = devices.filter { d in
            (d.confirmed && before.contains { $0.key == d.id && $0.active }) || (d.record.builtIn && backend.lidClosed() == false)
        }
        for d in candidates where d.record.id != 0 { try? backend.enable(d.record) }
        if let screen = backend.records().first(where: { $0.builtIn && $0.active }), backend.lidClosed() == false {
            if !backend.records().contains(where: { $0.active && $0.main }) { try? backend.makeMain(screen.id) }
            try? internalRecovery?(nil)
        }
    }
    func apply(_ rule: SceneRule, configuration: Configuration) async throws {
        guard let lid = backend.lidClosed() else { throw DisplayFailure("无法读取开合盖状态，请稍后重试") }
        let token = revision
        try check(token, lid: lid)
        if rule.noChange { onStatus?("保持当前显示状态"); return }
        let before = backend.records()
        let known = configuration.devices.filter { $0.confirmed || $0.record.builtIn }
        let eligible = known.filter { !lid || !$0.record.builtIn }
        let mirroring = rule.dualMode == .mirror
        if mirroring {
            guard !lid, rule.action(internalKey) == .on, rule.main == nil,
                  let target = rule.target, eligible.contains(where: { $0.id == target && !$0.record.builtIn && rule.action($0.id) == .on }),
                  eligible.filter({ !$0.record.builtIn && rule.action($0.id) == .on }).count == 1 else {
                throw DisplayFailure("镜像使用需要开盖并选择一台外接屏")
            }
        }
        guard eligible.contains(where: { rule.action($0.id) != .off }) else { throw DisplayFailure("不能停用所有可用屏幕") }
        if let main = rule.main {
            guard eligible.contains(where: { $0.id == main }), rule.action(main) == .on else { throw DisplayFailure("主屏规则无效，未修改显示配置") }
        }
        for (key, action) in rule.actions where action != .keep && key != internalKey {
            guard eligible.contains(where: { $0.id == key }) else { throw DisplayFailure("规则包含尚未确认的显示器，未执行切换") }
        }
        do {
            var expectedModes: [String: ModeRequest] = [:]
            for d in eligible where rule.action(d.id) == .on {
                try check(token, lid: lid)
                onStatus?("正在启用 \(d.name)…")
                if d.record.id != 0 { try backend.enable(current(d.id) ?? d.record) }
                let online = try await ready(d.id, token: token, lid: lid, active: false)
                try check(token, lid: lid)
                try backend.unmirror(online, allowed: Set(eligible.filter { rule.action($0.id) != .keep }.map(\.id)))
                try check(token, lid: lid)
                var configurable = current(d.id) ?? online
                if configurable.width == 0 { configurable.width = d.record.width }
                // Online does not imply active. Some TVs need their mode restored before
                // they become active again; only wait for active after configuration.
                if !mirroring, let mode = try backend.configure(configurable, output: d.output) { expectedModes[d.id] = mode }
                // An online mirror target may stay inactive until the mirror transaction.
                _ = try await ready(d.id, token: token, lid: lid, active: !mirroring || d.record.builtIn)
                if d.record.builtIn { try internalRecovery?(nil) }
            }
            if mirroring {
                guard let source = current(internalKey), let targetKey = rule.target, let target = current(targetKey) else { throw DisplayFailure("镜像屏幕尚未就绪") }
                try check(token, lid: lid)
                try backend.makeMain(source.id)
                try await wait(200_000_000)
                try check(token, lid: lid)
                guard current(internalKey)?.main == true, current(internalKey)?.active == true else { throw DisplayFailure("Mac 屏幕尚未就绪，未切换镜像") }
                onStatus?("正在镜像到 \(target.name)…")
                try backend.mirror(target, source: source, allowed: Set(eligible.filter { rule.action($0.id) != .keep }.map(\.id)))
                var verified = false
                for _ in 0..<24 {
                    try check(token, lid: lid)
                    if current(internalKey)?.active == true, let external = current(targetKey), external.mirrored, external.mirrorSource == source.id { verified = true; break }
                    try await wait(250_000_000)
                }
                guard verified else { throw DisplayFailure("屏幕镜像未确认，已保留可用画面") }
            }
            // Mirroring uses a coordinated system mode; independent output preferences
            // apply again when switching back to extended or single-display use.
            for d in eligible where !mirroring && rule.action(d.id) == .on {
                var verified = false
                for _ in 0..<24 {
                    try check(token, lid: lid)
                    if let r = current(d.id), r.active, !r.mirrored,
                       expectedModes[d.id].map({ $0.matches(r) }) ?? true,
                       hdrVerified(r, output: d.output) { verified = true; break }
                    try await wait(250_000_000)
                }
                guard verified else { throw DisplayFailure("\(d.name) 的输出设置未全部生效，已保留原有屏幕") }
            }
            try check(token, lid: lid)
            let active = backend.records().filter { $0.active && (!lid || !$0.builtIn) }
            let remaining = active.filter { record in
                guard eligible.contains(where: { $0.id == record.key }) else { return true }
                return rule.action(record.key) != .off
            }
            guard !remaining.isEmpty else { throw DisplayFailure("这组规则没有留下可用画面，已保留当前输出") }
            let main: DisplayRecord
            if let requested = rule.main {
                guard let selected = remaining.first(where: { $0.key == requested }) else { throw DisplayFailure("主屏未就绪，已保留原有输出") }
                main = selected
            } else if let existing = remaining.first(where: { $0.main }) { main = existing }
            else { main = remaining.first(where: { $0.builtIn }) ?? remaining[0] }
            try backend.makeMain(main.id)
            try await wait(200_000_000)
            try check(token, lid: lid)
            guard current(main.key)?.main == true, current(main.key)?.active == true else { throw DisplayFailure("新主屏未确认，已停止停用其他屏幕") }
            for d in eligible where rule.action(d.id) == .off {
                try check(token, lid: lid)
                guard let r = current(d.id), r.active else { continue }
                if r.builtIn { try internalRecovery?(r) }
                onStatus?("正在停用 \(d.name)…")
                try backend.disable(r)
                for _ in 0..<24 {
                    try check(token, lid: lid)
                    if current(d.id)?.active != true { break }
                    try await wait(250_000_000)
                }
                guard current(d.id)?.active != true else { throw DisplayFailure("\(d.name) 未能停用，仍保留输出") }
            }
            try check(token, lid: lid)
            guard backend.records().contains(where: { $0.active && $0.main }) else { throw DisplayFailure("未确认有效主屏，正在恢复画面") }
            let names = backend.records().filter { $0.active || (mirroring && $0.mirrored && $0.mirrorSource != nil) }.map { record in known.first(where: { $0.id == record.key })?.name ?? record.name }
            onStatus?("\(mirroring ? "已镜像" : "已切换") · \(names.joined(separator: "、"))")
        } catch {
            recover(before, devices: known)
            throw error
        }
    }
    func restore(_ devices: [KnownDisplay]) async throws {
        guard let lid = backend.lidClosed() else { throw DisplayFailure("无法读取开合盖状态") }
        let token = revision
        var failures: [String] = []
        for d in devices where (d.confirmed || d.record.builtIn) && (!lid || !d.record.builtIn) && d.record.id != 0 {
            try check(token, lid: lid)
            do { try backend.enable(current(d.id) ?? d.record) } catch { failures.append(d.name) }
        }
        if !lid {
            let screen = try await ready(internalKey, token: token, lid: lid)
            try backend.makeMain(screen.id); try internalRecovery?(nil)
        }
        guard backend.records().contains(where: { $0.active }) else { throw DisplayFailure("显示器尚未恢复，请重新插拔连接线") }
        onStatus?(failures.isEmpty ? "可用显示器已恢复 · 自动切换暂停" : "已保留画面；部分显示器未响应：\(failures.joined(separator: "、"))")
    }
}
