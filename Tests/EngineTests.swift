import Foundation

@MainActor final class FakeDisplaySystem: DisplayBackend {
    var screens: [DisplayRecord] = [screen(1, builtIn: true), screen(5), screen(6)]
    var lid: Bool? = false
    var operations: [String] = []
    var absent = Set<String>()
    var noEnable = Set<String>()
    var failConfiguration: String?
    var failMain = false
    var loseHDR = false
    var mirrorSlaves: [String: Set<String>] = [:]
    var mirrorMasters: [String: String] = [:]
    var onlineInactive = Set<String>()
    var activateOnConfigure = Set<String>()
    var noMirror = false
    static func screen(_ id: UInt32, builtIn: Bool = false) -> DisplayRecord {
        DisplayRecord(id: id, uuid: "UUID-\(id)", name: builtIn ? "Mac" : "Other Brand \(id)", vendor: 1, model: id, serial: id, builtIn: builtIn, active: true, main: builtIn, mirrored: false, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 120, hdr: !builtIn, hdrSupported: !builtIn)
    }
    func records() -> [DisplayRecord] { screens.filter { !absent.contains($0.key) && ($0.active || $0.mirrored || onlineInactive.contains($0.key)) && (!($0.builtIn && lid == true)) } }
    func lidClosed() -> Bool? { lid }
    func enable(_ target: DisplayRecord) throws {
        operations.append("enable-\(target.key)")
        if absent.contains(target.key) || noEnable.contains(target.key) { return }
        guard let i = screens.firstIndex(where: { $0.key == target.key && $0.id == target.id }) else { throw DisplayFailure("stale identity") }
        if !screens[i].mirrored { screens[i].active = true }
    }
    func disable(_ target: DisplayRecord) throws {
        guard records().contains(where: { $0.key != target.key && $0.active && $0.main }) else { throw DisplayFailure("unsafe disable") }
        operations.append("disable-\(target.key)")
        if let i = screens.firstIndex(where: { $0.key == target.key && $0.id == target.id }) { screens[i].active = false; screens[i].main = false }
    }
    func unmirror(_ target: DisplayRecord, allowed: Set<String>) throws {
        let master = mirrorMasters[target.key] ?? target.key
        let group = (mirrorSlaves[master] ?? []).union([master, target.key])
        guard group.isSubset(of: allowed) else { throw DisplayFailure("protected mirror member") }
        if let i = screens.firstIndex(where: { $0.key == target.key }), screens[i].mirrored {
            operations.append("unmirror-\(target.key)")
            for j in screens.indices where group.contains(screens[j].key) { screens[j].mirrored = false; screens[j].mirrorSource = nil; screens[j].active = true }
            for key in group { mirrorMasters.removeValue(forKey: key); mirrorSlaves.removeValue(forKey: key) }
        }
    }
    func mirror(_ target: DisplayRecord, source: DisplayRecord, allowed: Set<String>) throws {
        guard allowed.contains(target.key), allowed.contains(source.key) else { throw DisplayFailure("protected mirror") }
        operations.append("mirror-\(target.key)-to-\(source.key)")
        if noMirror { return }
        mirrorMasters[target.key] = source.key; mirrorSlaves[source.key] = [target.key]
        for i in screens.indices where screens[i].key == source.key || screens[i].key == target.key {
            screens[i].mirrored = true
            if screens[i].key == target.key { screens[i].active = false; screens[i].main = false; screens[i].mirrorSource = source.id }
        }
    }
    func configure(_ target: DisplayRecord, output: OutputPreference) throws -> ModeRequest? {
        operations.append("configure-\(target.key)")
        if failConfiguration == target.key { throw DisplayFailure("unsupported output") }
        guard let i = screens.firstIndex(where: { $0.key == target.key }) else { throw DisplayFailure("missing") }
        if activateOnConfigure.contains(target.key) { screens[i].active = true }
        if let mode = output.mode { screens[i].width = mode.width ?? screens[i].width; screens[i].pixelWidth = mode.pixelWidth; screens[i].pixelHeight = mode.pixelHeight; screens[i].hz = mode.hz }
        if output.hdr == .on || output.hdr == .automatic { screens[i].hdr = !loseHDR }; if output.hdr == .off { screens[i].hdr = false }
        return output.mode
    }
    func makeMain(_ id: UInt32) throws {
        operations.append("main-\(id)")
        if failMain { return }
        for i in screens.indices { screens[i].main = screens[i].id == id }
    }
}

@main struct EngineTests {
    @MainActor static func main() async throws {
        var count = 0
        func expect(_ value: Bool, _ name: String) throws {
            guard value else { throw DisplayFailure("FAIL: \(name)") }; count += 1; print("PASS: \(name)")
        }
        func setup() -> (FakeDisplaySystem, SwitchEngine, Configuration) {
            let f = FakeDisplaySystem()
            let e = SwitchEngine(backend: f); e.wait = { _ in }
            var c = Configuration(); c.reconcile(f.screens)
            c.confirm("UUID-5"); c.confirm("UUID-6")
            try! c.select(.internalOnly, event: .open); try! c.select(.externalOnly, event: .closed, target: "UUID-5")
            return (f,e,c)
        }
        func rejects(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        func fails(_ operation: () async throws -> Void) async -> Bool { do { try await operation(); return false } catch { return true } }
        do {
            let legacyRecord = FakeDisplaySystem.screen(5)
            let data = try JSONSerialization.data(withJSONObject: ["automatic":false,"target":JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyRecord)),"onOpen":"macOnly","onClose":"lgMain","openDelay":0])
            let c = try JSONDecoder().decode(Configuration.self, from: data)
            try expect(c.schemaVersion == 2 && !c.automatic && c.externals.first?.record == legacyRecord, "migrate accepted identity and automatic flag")
            try expect(c.preset(.open) == .internalOnly && c.preset(.closed) == .externalOnly && c.openDelay == 0, "migrate accepted lid defaults without changing actions")
            try expect(c.externals.first?.output == .legacyLG, "4K120HDR belongs to migrated LG preference only")
            let roundtrip = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(c))
            try expect(roundtrip == c, "version2 configuration roundtrip")
        }
        do {
            let target = FakeDisplaySystem.screen(5), record = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
            let c = try JSONDecoder().decode(Configuration.self, from: Data("{\"target\":\(record),\"onOpen\":\"lgMain\"}".utf8))
            try expect(c.openRule.action(internalKey) == .keep && c.openRule.main == target.key, "legacy external main does not silently become internal off")
        }
        do {
            var c = Configuration(); var screen = FakeDisplaySystem.screen(8); screen.name = "Same Name"
            c.reconcile([screen]); try expect(c.externals.isEmpty && c.devices.last?.confirmed == false, "arbitrary brand enumerated without opting it into switching")
            c.confirm(screen.key); try expect(c.externals.count == 1 && c.externals[0].output == OutputPreference(), "newly confirmed screen keeps its current output settings")
            var other = FakeDisplaySystem.screen(9); other.name = screen.name; c.reconcile([screen,other])
            try expect(c.devices.count == 3 && c.devices.last?.confirmed == false, "same display names remain different identities")
            try expect(c.openRule.action(other.key) == .keep && c.closedRule.action(other.key) == .keep, "new display absent from both old rules defaults keep")
        }
        do {
            var c = Configuration(); let old = FakeDisplaySystem.screen(5); c.reconcile([old]); c.confirm(old.key)
            var changed = old; changed.uuid = "new-UUID"; changed.id = 12; c.reconcile([changed])
            try expect(c.externals.count == 1 && c.closedRule.target == changed.key && c.closedRule.main == changed.key, "unique reliable fingerprint remaps rules and main on ID change")
            var unsafe = old; unsafe.serial = 0; var d = Configuration(); d.reconcile([unsafe]); d.confirm(unsafe.key)
            unsafe.uuid = "no-serial-new"; d.reconcile([unsafe])
            try expect(d.devices.last?.confirmed == false && d.externals.count == 1, "no serial means no guessing across changed UUIDs")
            var placeholder = old; placeholder.serial = 0x01010101
            try expect(!placeholder.hasReliableSerial, "reject common placeholder EDID serial for fingerprint matching")
        }
        do {
            let (_,_,original) = setup(); var c = original
            try expect(rejects { try c.select(.internalOnly, event: .closed) }, "closed internal-only scene refused")
            try c.select(.extended, event: .closed)
            try expect(c.closedRule.action("UUID-5") == .on && c.closedRule.action("UUID-6") == .on && c.closedRule.main != internalKey, "closed extended scene uses multiple external displays")
            try expect(c.openRule == original.openRule, "closed edits never modify open rule")
            try c.select(.externalOnly, event: .open)
            try expect(c.openRule.action(internalKey) == .off && c.openRule.main == "UUID-5", "open external-only is explicit internal off")
            try c.setAction(.on, key: internalKey, event: .open); try c.setAction(.off, key: "UUID-5", event: .open)
            try expect(c.openRule.main == internalKey, "disabling main reassigns an enabled main")
            try expect(rejects { try c.setAction(.off, key: internalKey, event: .open) }, "all-off edit rejected and rolled back")
            try expect(c.openRule.action(internalKey) == .on, "rejected edit leaves prior rule intact")
            try c.select(.keep, event: .closed); try expect(c.closedRule.noChange, "unchanged event distinct from display-off")
        }
        let modes = [ModeChoice(index:0,width:1920,height:1080,pixelsWide:3840,pixelsHigh:2160,hz:60),ModeChoice(index:1,width:3840,height:2160,pixelsWide:3840,pixelsHigh:2160,hz:120),ModeChoice(index:2,width:1920,height:1080,pixelsWide:3840,pixelsHigh:2160,hz:120),ModeChoice(index:3,width:2560,height:1440,pixelsWide:2560,pixelsHigh:1440,hz:60)]
        try expect(ModeChoice.best(modes, request: .init(width:nil,pixelWidth:3840,pixelHeight:2160,hz:120), automatic:false, preferredWidth:1920)?.index == 2, "legacy mode preserves HiDPI scale at actual4K120")
        try expect(ModeChoice.best(modes, request:modes[3].request,automatic:false,preferredWidth:1920)?.index == 3, "general screen supports1440p60 without imposing4K")
        try expect(ModeChoice.best(Array(modes.prefix(1)),request:.init(width:nil,pixelWidth:3840,pixelHeight:2160,hz:120),automatic:false,preferredWidth:1920) == nil, "unsupported refresh never silently substituted")
        do {
            let (f,e,c) = setup(); try await e.apply(c.openRule, configuration:c)
            try expect(f.screens[0].active && f.screens[0].main && !f.screens[1].active && !f.screens[2].active, "Mac-only disables both confirmed arbitrary-brand external screens")
            let mainIndex = f.operations.firstIndex(of:"main-1")!, offIndex = f.operations.firstIndex(of:"disable-UUID-5")!
            try expect(mainIndex < offIndex, "confirm new main before stopping old external outputs")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open)
            var marker: DisplayRecord?; e.internalRecovery = { marker = $0 }
            try await e.apply(c.openRule,configuration:c)
            try expect(!f.screens[0].active && f.screens[1].active && f.screens[1].main, "open external-only disables internal only after external main")
            try expect(marker?.builtIn == true, "internal recovery record recorded before disabling internal")
            try await e.restore(c.devices)
            try expect(f.screens[0].active && f.screens[0].main && marker == nil, "restore re-enables internal and clears recovery marker")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open)
            e.internalRecovery = { record in if record != nil { throw DisplayFailure("disk failure") } }
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "recovery marker write failure prevents internal disable")
            try expect(f.screens[0].active, "retain internal when recovery cannot be persisted")
        }
        do {
            let (f,e,c) = setup(); f.lid = true; try await e.apply(c.closedRule,configuration:c)
            try expect(f.screens[1].active && f.screens[1].main && !f.operations.contains("disable-\(internalKey)"), "closed-lid external switching works without touching internal")
        }
        do {
            let (f,e,c) = setup(); f.screens[0].active = false; f.noEnable.insert(internalKey)
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "missing internal readiness cannot report success")
            try expect(f.screens[1].active && !f.operations.contains(where: { $0.hasPrefix("disable-") }), "keep external while internal wake fails")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open); f.absent.insert("UUID-5")
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "offline selected target fails")
            try expect(f.screens[0].active && !f.operations.contains("disable-\(internalKey)"), "offline target never blanks internal")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[1].output = .legacyLG; try c.select(.externalOnly,event:.open); f.failConfiguration = "UUID-5"
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "unsupported output fails before any disable")
            try expect(!f.operations.contains(where: { $0.hasPrefix("disable-") }), "unsupported mode preserves other outputs")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[1].output = .legacyLG; try c.select(.externalOnly,event:.open); f.loseHDR = true
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "HDR actual readback required")
            try expect(f.screens[0].active, "HDR verification failure preserves internal")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open); f.failMain = true
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "main-display readback required")
            try expect(!f.operations.contains(where: { $0.hasPrefix("disable-") }), "never disable without confirmed new main")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[2].confirmed = false; c.openRule.actions.removeValue(forKey:"UUID-6")
            try await e.apply(c.openRule,configuration:c)
            try expect(f.screens[2].active && !f.operations.contains("disable-UUID-6") && !f.operations.contains("configure-UUID-6"), "unconfirmed new external remains untouched")
            c.openRule.actions["UUID-6"] = .off
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "unknown explicit device action refused")
        }
        do {
            let (f,e,c) = setup(); e.wait = { _ in f.lid = true }
            var cancelled = false; do { try await e.apply(c.openRule,configuration:c) } catch is CancellationError { cancelled = true }
            try expect(cancelled && !f.operations.contains(where: { $0.hasPrefix("disable-") }), "rapid lid change cancels before destructive phase")
        }
        do {
            let (f,e,c) = setup(); e.wait = { _ in e.cancel() }
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "revision cancels obsolete request")
            try expect(!f.operations.contains(where: { $0.hasPrefix("disable-") }), "revision cancellation preserves outputs")
        }
        do {
            let (f,e,c) = setup(); f.lid = nil
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "unknown lid state rejected")
            try expect(f.operations.isEmpty, "unknown lid has zero hardware changes")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.extended,event:.open); f.screens[1].active = false; f.screens[1].mirrored = true
            try await e.apply(c.openRule,configuration:c)
            try expect(!f.screens[1].mirrored && f.screens[1].active && f.screens[0].main, "inactive mirror slave becomes extended display")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open); f.screens[1].id = 18
            try await e.apply(c.openRule,configuration:c)
            try expect(f.operations.contains("main-18") && f.screens[1].main, "current runtime ID wins over persisted ID for same identity")
        }
        do {
            let (f,e,c) = setup(); var rule = c.openRule; rule.noChange = true
            try await e.apply(rule,configuration:c); try expect(f.operations.isEmpty, "no-change event has zero display writes")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[1].output.hdr = .automatic; try c.select(.externalOnly,event:.open); f.loseHDR = true
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "automatic HDR also requires actual readback")
            var invalid = base; invalid.closedRule.actions[internalKey] = .on
            try expect(rejects { try invalid.validate() }, "closed internal-on configuration rejected")
            invalid = base; invalid.devices[1].output.mode = ModeRequest(width:0,pixelWidth:3840,pixelHeight:2160,hz:120)
            try expect(rejects { try invalid.validate() }, "invalid persisted mode rejected before hardware")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[2].confirmed = false; c.openRule.actions.removeValue(forKey:"UUID-6")
            f.mirrorSlaves[internalKey] = ["UUID-6"]
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "unconfirmed mirror group member blocks unmirroring")
            try expect(!f.operations.contains("configure-\(internalKey)") && !f.operations.contains(where: { $0.hasPrefix("disable-") }), "protected mirror rejected before mode or power changes")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.openRule = SceneRule(actions:[internalKey:.keep,"UUID-5":.on,"UUID-6":.off],main:"UUID-5",target:"UUID-5")
            f.mirrorMasters["UUID-5"] = internalKey; f.mirrorSlaves[internalKey] = ["UUID-5"]
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "slave target cannot bypass protected mirror master")
            try expect(!f.operations.contains("configure-UUID-5"), "protected master stops slave before configuration")
        }
        do {
            let target = FakeDisplaySystem.screen(5), lease = DisabledDisplayLease(session:"boot:login1",records:[FakeDisplaySystem.screen(5)])
            try expect(lease.permits(target,session:"boot:login1",online:[]), "our disabled display can be enabled while public UUID is unavailable")
            try expect(!lease.permits(target,session:"boot:login2",online:[]), "do not reuse disabled IDs across login sessions")
            var occupant = target; occupant.uuid = "OTHER"
            try expect(!lease.permits(target,session:"boot:login1",online:[occupant]), "reused runtime ID cannot enable another display")
            try expect(!lease.permits(FakeDisplaySystem.screen(6),session:"boot:login1",online:[]), "never enable an unobserved offline display by guessing")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.select(.externalOnly,event:.open)
            f.screens[1].active = false; f.onlineInactive.insert("UUID-5"); f.noEnable.insert("UUID-5"); f.activateOnConfigure.insert("UUID-5")
            try await e.apply(c.openRule,configuration:c)
            try expect(f.screens[1].active && f.screens[1].main && !f.screens[0].active, "online inactive TV is configured before waiting for activation")
        }
        do {
            let (_,_,base) = setup(); var c = base
            try c.select(.extended,event:.open,target:"UUID-5")
            let actions = c.openRule.actions, closed = c.closedRule, outputs = c.devices.map(\.output)
            try c.setMain("UUID-5",event:.open)
            try expect(c.openRule.main == "UUID-5" && c.openRule.actions == actions && c.closedRule == closed && c.devices.map(\.output) == outputs, "main picker changes main without changing screen usage or output settings")
            try c.selectTarget("UUID-6",event:.open)
            try expect(c.openRule.main == "UUID-6" && c.openRule.action(internalKey) == .on && c.openRule.action("UUID-5") == .off && c.openRule.action("UUID-6") == .on, "changing extended external preserves external main preference")
            try c.setMain(internalKey,event:.open); try c.selectTarget("UUID-5",event:.open)
            try expect(c.openRule.main == internalKey && c.openRule.action("UUID-5") == .on, "changing extended target preserves Mac main preference")
            let before = c
            try expect(rejects { try c.setMain("UUID-6",event:.open) } && c == before, "main picker refuses a screen excluded from the scene")
            try c.selectTarget("UUID-6",event:.closed)
            try expect(c.closedRule.main == "UUID-6" && c.closedRule.action("UUID-5") == .off && c.closedRule.action(internalKey) == .off && c.openRule == before.openRule, "closed screen choice automatically sets external main without altering open rule")
        }
        do {
            let (_,_,base) = setup(); var c = base
            try c.selectDualMode(.mirror,target:"UUID-5"); try c.validate()
            try expect(c.preset(.open) == .extended && c.openRule.dualMode == .mirror && c.openRule.main == nil && c.openRule.action(internalKey) == .on, "mirror scene uses both screens without a user main selection")
            let roundtrip = try JSONDecoder().decode(Configuration.self,from:JSONEncoder().encode(c))
            try expect(roundtrip == c, "mirror preference persists without changing configuration schema")
            try c.selectTarget("UUID-6",event:.open)
            try expect(c.openRule.dualMode == .mirror && c.openRule.main == nil && c.openRule.action("UUID-6") == .on && c.openRule.action("UUID-5") == .off, "external list choice preserves mirror mode")
            try expect(rejects { try c.setMain(internalKey,event:.open) }, "mirror mode refuses unnecessary primary selection")
            try c.selectDualMode(.extended); try c.setSecondary(internalKey)
            try expect(c.openRule.main == "UUID-6" && c.openRule.action(internalKey) == .on, "secondary picker swaps extended roles without disabling either screen")
            try c.selectTarget("UUID-5",event:.closed)
            try expect(c.closedRule.dualMode == nil && c.closedRule.main == "UUID-5", "closed external selection never enables mirroring")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[1].output = .legacyLG
            try c.selectDualMode(.mirror,target:"UUID-5"); try await e.apply(c.openRule,configuration:c)
            try expect(f.screens[0].active && f.screens[1].mirrored && f.screens[1].mirrorSource == f.screens[0].id && !f.screens[1].active, "mirror readback accepts an inactive mirror slave with confirmed source")
            try expect(!f.operations.contains(where: { $0.hasPrefix("configure-") }), "mirror does not force incompatible independent display preferences")
            try expect(f.operations.firstIndex(of:"mirror-UUID-5-to-builtin-display")! < f.operations.firstIndex(of:"disable-UUID-6")!, "mirror relationship is verified before disabling unused screens")
            f.screens[1].pixelWidth = 1920; f.screens[1].pixelHeight = 1080; f.screens[1].hz = 60; f.screens[1].hdr = false
            try c.selectDualMode(.extended); try await e.apply(c.openRule,configuration:c)
            try expect(!f.screens[0].mirrored && !f.screens[1].mirrored && f.screens[1].active && f.screens[1].pixelWidth == 3840 && f.screens[1].hz == 120 && f.screens[1].hdr == true, "returning to extended restores independent4K120HDR preference")
        }
        do {
            let (f,e,base) = setup(); var c = base; try c.selectDualMode(.mirror,target:"UUID-5"); f.noMirror = true
            try expect(await fails { try await e.apply(c.openRule,configuration:c) }, "mirror success requires actual source relationship readback")
            try expect(!f.operations.contains(where: { $0.hasPrefix("disable-") }), "mirror readback failure preserves existing outputs")
            f.operations=[]; f.lid=true
            try expect(await fails { try await e.apply(c.openRule,configuration:c) } && f.operations.isEmpty, "closed lid rejects mirroring before hardware writes")
        }
        do {
            let (f,e,base) = setup(); var c = base; c.devices[2].confirmed=false; c.openRule.actions.removeValue(forKey:"UUID-6")
            try c.selectDualMode(.mirror,target:"UUID-5"); f.mirrorSlaves[internalKey] = ["UUID-6"]
            try expect(await fails { try await e.apply(c.openRule,configuration:c) } && !f.operations.contains(where: { $0.hasPrefix("mirror-") }), "mirror cannot absorb an unconfirmed member of an existing group")
        }
        do {
            let (f,e,base) = setup(); var c = base
            try c.selectDualMode(.mirror,target:"UUID-5")
            f.screens[1].active = false; f.onlineInactive.insert("UUID-5"); f.noEnable.insert("UUID-5")
            try await e.apply(c.openRule,configuration:c)
            try expect(f.screens[0].active && f.screens[1].mirrored && f.screens[1].mirrorSource == f.screens[0].id, "online inactive TV reaches mirror transaction before active wait")
        }
        print("\(count) checks passed")
    }
}
