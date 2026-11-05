import AppKit
import Observation

enum SettingsPage: String, CaseIterable, Identifiable {
    case rules, outputs, help
    var id: String { rawValue }
    var title: String { switch self { case .rules: return "显示联动"; case .outputs: return "设备与输出"; case .help: return "使用帮助" } }
    var symbol: String { switch self { case .rules: return "rectangle.on.rectangle"; case .outputs: return "display"; case .help: return "questionmark.circle" } }
}

@MainActor @Observable final class SettingsModel {
    @ObservationIgnored weak var owner: MenuApp?
    var draft: Configuration
    var saved: Configuration
    var login: Bool
    var savedLogin: Bool
    var records: [DisplayRecord]
    var modes: [String: [ModeRequest]] = [:]
    var page: SettingsPage = .rules
    var status: String
    var busy = false
    var errorMessage = ""
    var showingError = false
    var lidClosed: Bool?
    init(owner: MenuApp) {
        self.owner = owner; draft = owner.store.configuration; saved = owner.store.configuration
        login = owner.loginEnabled; savedLogin = owner.loginEnabled; records = owner.hardware.records()
        status = owner.status; busy = owner.busy; lidClosed = owner.hardware.lidClosed()
        refreshModes()
    }
    var dirty: Bool { draft != saved || login != savedLogin }
    func report(_ error: Error) { errorMessage = error.localizedDescription; showingError = true }
    func refreshModes() {
        guard let owner else { return }
        for d in draft.devices {
            let choices = owner.hardware.modes(records.first(where: { $0.key == d.id }) ?? d.record)
            if !choices.isEmpty { modes[d.id] = choices }
        }
    }
    func refresh(configuration: Configuration, login: Bool, records: [DisplayRecord]) {
        let edited = dirty
        self.records = records; lidClosed = owner?.hardware.lidClosed(); busy = owner?.busy ?? false
        if !edited { draft = configuration; self.login = login }
        else { draft.reconcile(records) }
        saved = configuration; savedLogin = login
        refreshModes()
    }
    func accept(configuration: Configuration, login: Bool, records: [DisplayRecord]) {
        saved = configuration; draft = configuration; self.login = login; savedLogin = login; self.records = records
        refreshModes()
    }
    func select(_ preset: ScenePreset, event: LidEvent) {
        do { try draft.select(preset, event: event) } catch { report(error) }
    }
    func target(_ key: String, event: LidEvent) {
        do { try draft.selectTarget(key, event: event) } catch { report(error) }
    }
    func main(_ key: String, event: LidEvent) {
        do { try draft.setMain(key, event: event) } catch { report(error) }
    }
    func dualMode(_ mode: DualDisplayMode) {
        do { try draft.selectDualMode(mode) } catch { report(error) }
    }
    func secondary(_ key: String) {
        do { try draft.setSecondary(key) } catch { report(error) }
    }
    func editDevice(_ key: String, _ edit: (inout KnownDisplay) -> Void) {
        guard let i = draft.devices.firstIndex(where: { $0.id == key }) else { return }
        edit(&draft.devices[i])
    }
    func selectMode(_ id: String, key: String) {
        editDevice(key) { d in
            if id == "keep" { d.output.mode = nil; d.output.automaticMode = false }
            else if id == "auto" { d.output.mode = nil; d.output.automaticMode = true }
            else if let m = modes[key]?.first(where: { $0.id == id }) { d.output.mode = m; d.output.automaticMode = false }
        }
    }
    func save() {
        do { try owner?.saveConfiguration(draft, login: login) } catch { report(error) }
    }
    func revert() { draft = saved; login = savedLogin }
    func apply(_ event: LidEvent) {
        guard !dirty else { report(DisplayFailure("请先保存，再应用这组规则")); return }
        owner?.applySaved(event)
    }
    func connection(_ device: KnownDisplay) -> String {
        if let actual = records.first(where: { $0.key == device.id }) { return actual.main ? "已连接 · 当前主屏" : actual.mirrored ? "已连接 · 镜像" : "已连接" }
        if device.record.builtIn && lidClosed == true { return "合盖熄屏" }
        return "未输出或未连接"
    }
}
