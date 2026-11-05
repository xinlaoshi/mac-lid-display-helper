import AppKit
import IOKit

@MainActor final class AppStore {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LGLidSwitch")
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LGLidSwitch/events.log")
    var configuration = Configuration()
    var loadError: String?
    var recoveryURL: URL { directory.appendingPathComponent("internal-recovery.json") }
    init() {
        let url = directory.appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)) }
            catch { loadError = "配置读取失败，自动切换已暂停：\(error.localizedDescription)"; configuration.automatic = false }
        }
    }
    func save() throws {
        try configuration.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
        loadError = nil
    }
    func markRecovery(_ record: DisplayRecord?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let record { try JSONEncoder().encode(record).write(to: recoveryURL, options: .atomic) }
        else if FileManager.default.fileExists(atPath: recoveryURL.path) { try FileManager.default.removeItem(at: recoveryURL) }
    }
    var recovery: DisplayRecord? { (try? Data(contentsOf: recoveryURL)).flatMap { try? JSONDecoder().decode(DisplayRecord.self, from: $0) } }
    func log(_ text: String) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("previous.log")
            try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: logURL, to: old)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8))
    }
}

final class LidObserver {
    var port: IONotificationPortRef?
    var notification: io_object_t = 0
    var root: io_service_t = 0
    let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard root != 0, let port else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<LidObserver>.fromOpaque(context).takeUnretainedValue().changed()
        }, Unmanaged.passUnretained(self).toOpaque(), &notification)
    }
    deinit {
        if notification != 0 { IOObjectRelease(notification) }
        if root != 0 { IOObjectRelease(root) }
        if let port { IONotificationPortDestroy(port) }
    }
}

@MainActor final class MenuApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let hardware = DisplaySystem()
    let store = AppStore()
    lazy var engine = SwitchEngine(backend: hardware)
    var item: NSStatusItem!
    var observer: LidObserver?
    var timer: Timer?
    var transition: Task<Void, Never>?
    var wakeTask: Task<Void, Never>?
    var lastLid: Bool?
    var lastDisplayUUIDs = Set<String>()
    var pendingScreenChange = false
    var sleeping = false
    var busy = false
    var terminating = false
    var status = "正在识别显示器…"
    var settingsWindow: NSWindow?
    var settingsModel: SettingsModel?
    var diagnosticWindow: NSWindow?
    var aboutWindow: NSWindow?
    let loginURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.xiaopomao.LGLidSwitch.plist")
    var loginEnabled: Bool { FileManager.default.fileExists(atPath: loginURL.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image: NSImage? = makeLinkSymbol()
        image?.isTemplate = true; item.button?.image = image
        item.menu = NSMenu(); item.menu?.delegate = self
        engine.onStatus = { [weak self] text in self?.setStatus(text) }
        engine.internalRecovery = { [weak self] record in try self?.store.markRecovery(record) }
        discover()
        lastLid = hardware.lidClosed()
        lastDisplayUUIDs = Set(hardware.records().map(\.uuid))
        observer = LidObserver { [weak self] in self?.pollLid() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollLid() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        store.log("启动 \(AppInformation.versionLabel)；自动切换=\(store.configuration.automatic)")
        if let error = store.loadError { setStatus(error) }
        else {
            // Let AppKit finish registering the process with WindowServer before reading active displays.
            wakeTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, !self.sleeping else { return }
                self.discover(); self.automaticSwitch()
            }
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        rebuildMenu()
    }
    func discover() {
        let previous = store.configuration
        let records = hardware.records()
        store.configuration.reconcile(records)
        if previous != store.configuration && store.loadError == nil {
            do { try store.save() } catch { setStatus("无法保存屏幕身份：\(error.localizedDescription)") }
        }
        settingsModel?.refresh(configuration: store.configuration, login: loginEnabled, records: records)
    }
    func pollLid() {
        guard !sleeping, !terminating else { return }
        let lid = hardware.lidClosed()
        if lid == false { recoverInternalIfNeeded() }
        guard lid != lastLid else { return }
        lastLid = lid
        store.log(lid == true ? "合盖事件" : "开盖事件")
        discover(); automaticSwitch()
    }
    func recoverInternalIfNeeded() {
        guard !busy, hardware.lidClosed() == false,
              !hardware.records().contains(where: { $0.active }),
              let record = store.recovery ?? store.configuration.devices.first(where: { $0.record.builtIn })?.record,
              record.id != 0 else { return }
        do { try hardware.enable(record); setStatus("正在恢复 Mac 内屏…") }
        catch { store.log("内屏恢复等待：\(error.localizedDescription)") }
    }
    func automaticSwitch() {
        guard store.configuration.automatic, store.loadError == nil, !sleeping, !terminating, let lid = hardware.lidClosed() else { return }
        request(store.configuration.rule(lid ? .closed : .open), delay: lid ? 0 : store.configuration.openDelay)
    }
    func request(_ rule: SceneRule?, restore: Bool = false, quitting: Bool = false, delay: Double = 0, retry: Int = 0) {
        engine.cancel(); let previous = transition; previous?.cancel()
        let configuration = store.configuration, expectedLid = hardware.lidClosed()
        busy = true; settingsModel?.busy = true
        transition = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            var failed = false
            do {
                if delay > 0 {
                    self.setStatus("等待 \(delay.formatted()) 秒后切换…")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled, self.hardware.lidClosed() == expectedLid else { throw CancellationError() }
                if restore { try await self.engine.restore(configuration.devices) }
                else if let rule { try await self.engine.apply(rule, configuration: configuration) }
            } catch is CancellationError { self.store.log("已取消过期的显示切换") }
            catch { failed = true; self.setStatus(error.localizedDescription) }
            guard !Task.isCancelled else { return }
            self.busy = false; self.settingsModel?.busy = false
            let pending = self.pendingScreenChange; self.pendingScreenChange = false
            self.discover(); self.lastDisplayUUIDs = Set(self.hardware.records().map(\.uuid)); self.rebuildMenu()
            if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
            else if pending && failed && retry == 0 && expectedLid == self.hardware.lidClosed() { self.request(rule, restore: restore, retry: 1) }
        }
    }
    func setStatus(_ text: String) {
        status = text; store.log(text); item?.button?.toolTip = "Mac合盖和显示器联动助手 · \(text)"
        settingsModel?.status = text; rebuildMenu()
    }
    @objc func screensChanged() {
        guard !sleeping, !terminating else { return }
        if busy { pendingScreenChange = true; return }
        let current = Set(hardware.records().map(\.uuid)), changed = current != lastDisplayUUIDs
        lastDisplayUUIDs = current; recoverInternalIfNeeded(); discover()
        if changed { automaticSwitch() }
    }
    @objc func willSleep() {
        sleeping = true; wakeTask?.cancel(); engine.cancel(); transition?.cancel(); busy = false; settingsModel?.busy = false
        store.log("系统将睡眠")
    }
    @objc func didWake() {
        sleeping = false; wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            guard let self, !self.sleeping else { return }
            self.recoverInternalIfNeeded(); self.discover(); self.lastLid = self.hardware.lidClosed(); self.automaticSwitch()
        }
    }
    func saveConfiguration(_ draft: Configuration, login: Bool) throws {
        var updated = draft; updated.reconcile(hardware.records()); try updated.validate()
        let original = store.configuration
        let loginData = try? Data(contentsOf: loginURL)
        // Prepare both writes, then restore the previous data if either write fails.
        do {
            if login {
                guard let executable = Bundle.main.executableURL?.path else { throw DisplayFailure("无法读取应用位置") }
                try writeLoginAgent(to: loginURL, executable: executable)
            } else if loginEnabled { try FileManager.default.removeItem(at: loginURL) }
            store.configuration = updated; try store.save()
        } catch {
            store.configuration = original
            if let loginData { try? loginData.write(to: loginURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: loginURL) }
            throw error
        }
        engine.cancel(); transition?.cancel(); busy = false; settingsModel?.busy = false
        settingsModel?.accept(configuration: store.configuration, login: loginEnabled, records: hardware.records())
        setStatus("设置已保存 · 下次开合盖时生效")
    }
    func applySaved(_ event: LidEvent) {
        guard hardware.lidClosed() == (event == .closed) else { setStatus(event == .open ? "请先打开 Mac 上盖" : "请先合上 Mac 上盖"); return }
        request(store.configuration.rule(event))
    }
    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }
    func rebuildMenu() {
        guard let menu = item?.menu else { return }
        menu.removeAllItems(); menu.autoenablesItems = false
        func add(_ title: String, _ selector: Selector? = nil, enabled: Bool = true, checked: Bool = false) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; entry.state = checked ? .on : .off; menu.addItem(entry)
        }
        add("Mac合盖和显示器联动助手", enabled: false); add(status, enabled: false); menu.addItem(.separator())
        add("设置…", #selector(showSettings)); add("自动切换", #selector(toggleAutomatic), checked: store.configuration.automatic)
        add("应用当前开合盖规则", #selector(applyCurrent), enabled: !busy)
        add("只用 Mac 内屏", #selector(toMac), enabled: !busy && hardware.lidClosed() == false)
        menu.addItem(.separator()); add("恢复所有显示器并暂停", #selector(restoreDisplays))
        add("重新检测显示器", #selector(rediscover), enabled: !busy)
        add("登录后启动", #selector(toggleLogin), checked: loginEnabled); add("连接状态…", #selector(showDiagnostics))
        menu.addItem(.separator()); add("关于…", #selector(showAbout))
        add("退出并恢复显示器", #selector(quit))
    }
    @objc func toggleAutomatic() {
        store.configuration.automatic.toggle()
        do { try store.save() } catch { setStatus(error.localizedDescription) }
        engine.cancel(); transition?.cancel(); busy = false
        settingsModel?.busy = false
        settingsModel?.refresh(configuration: store.configuration, login: loginEnabled, records: hardware.records())
        if store.configuration.automatic { automaticSwitch() } else { setStatus("自动切换已暂停") }
    }
    @objc func applyCurrent() { if let lid = hardware.lidClosed() { applySaved(lid ? .closed : .open) } }
    @objc func toMac() {
        var c = store.configuration
        do { try c.select(.internalOnly, event: .open); request(c.openRule) } catch { setStatus(error.localizedDescription) }
    }
    @objc func restoreDisplays() {
        store.configuration.automatic = false; try? store.save()
        request(nil, restore: true)
    }
    @objc func rediscover() { discover(); setStatus("已检测显示器；新设备需在设置中确认") }
    @objc func toggleLogin() {
        do { try saveConfiguration(store.configuration, login: !loginEnabled) } catch { setStatus(error.localizedDescription) }
    }
    @objc func showDiagnostics() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(hardware.records())) ?? Data()
        let text = "Mac合盖和显示器联动助手 \(AppInformation.versionLabel)\n\(status)\n\n开盖：\(hardware.lidClosed() == false)\n自动切换：\(store.configuration.automatic)\n登录启动：\(loginEnabled)\n\n\(String(data: data, encoding: .utf8) ?? "")\n\n日志：\(store.logURL.path)"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "显示器连接状态"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.isSelectable = true; view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 18, height: 18); view.autoresizingMask = [.width]; view.string = text
        scroll.documentView = view; window.contentView?.addSubview(scroll)
        diagnosticWindow?.close(); diagnosticWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true; request(nil, restore: true, quitting: true); return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
}

func writeLoginAgent(to url: URL, executable: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist: [String: Any] = ["Label": "com.xiaopomao.LGLidSwitch", "ProgramArguments": [executable], "RunAtLoad": true, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
}

@main struct EntryPoint {
    @MainActor static func main() {
        let app = NSApplication.shared, args = CommandLine.arguments
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if args.contains("--status") { let d = try! encoder.encode(DisplaySystem().records()); print(String(decoding: d, as: UTF8.self)); return }
        if args.contains("--configuration") { let d = try! encoder.encode(AppStore().configuration); print(String(decoding: d, as: UTF8.self)); return }
        if args.contains("--capabilities") {
            let hardware = DisplaySystem()
            struct Capabilities: Encodable { var screen: DisplayRecord; var modes: [ModeRequest] }
            let d = try! encoder.encode(hardware.records().map { Capabilities(screen: $0, modes: hardware.modes($0)) })
            print(String(decoding: d, as: UTF8.self)); return
        }
        if let command = args.first(where: { ["--external", "--internal", "--restore", "--mirror", "--extended"].contains($0) }) {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.xiaopomao.LGLidSwitch").contains(where: { $0.processIdentifier != getpid() }) else { fputs("请先退出菜单栏工具再使用硬件测试命令。\n", stderr); exit(1) }
            let store = AppStore(), hardware = DisplaySystem(); var configuration = store.configuration
            guard store.loadError == nil else { fputs("配置不可用\n", stderr); exit(1) }
            configuration.reconcile(hardware.records())
            let engine = SwitchEngine(backend: hardware); engine.onStatus = { print($0) }; engine.internalRecovery = { try store.markRecovery($0) }
            Task {
                do {
                    if command == "--restore" { try await engine.restore(configuration.devices) }
                    else {
                        guard !["--internal", "--mirror", "--extended"].contains(command) || hardware.lidClosed() == false else { throw DisplayFailure("请先开盖") }
                        let event: LidEvent = hardware.lidClosed() == true ? .closed : .open
                        if command == "--mirror" { try configuration.selectDualMode(.mirror) }
                        else if command == "--extended" { try configuration.selectDualMode(.extended) }
                        else { try configuration.select(command == "--internal" ? .internalOnly : .externalOnly, event: event) }
                        try await engine.apply(configuration.rule(event), configuration: configuration)
                    }
                    exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            app.run(); return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.xiaopomao.LGLidSwitch").contains(where: { $0.processIdentifier != getpid() }) { return }
        let delegate = MenuApp(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
