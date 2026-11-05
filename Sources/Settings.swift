import AppKit
import SwiftUI

extension MenuApp {
    @objc func showSettings() {
        if let window = settingsWindow, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        discover()
        let model = SettingsModel(owner: self); settingsModel = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mac合盖和显示器联动助手"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 950, height: 650)
        window.contentView = NSHostingView(rootView: SettingsRoot(model: model))
        settingsWindow = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.57, green: 0.67, blue: 1, alpha: 1)
        : NSColor(red: 0.25, green: 0.36, blue: 0.72, alpha: 1)
})
private let secondaryInk = Color(nsColor: .secondaryLabelColor)

struct SettingsRoot: View {
    @Bindable var model: SettingsModel
    private var pending: [KnownDisplay] { model.draft.devices.filter { !$0.confirmed && !$0.record.builtIn } }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text(model.page == .rules ? "开合盖设置" : model.page.title).font(.system(size: 25, weight: .semibold))
                            Spacer()
                            if model.page == .outputs {
                                Button("重新检测") { model.owner?.rediscover(); model.refreshModes() }.controlSize(.large)
                            }
                        }
                        switch model.page {
                        case .rules:
                            OpenLidCard(model: model)
                            ClosedLidCard(model: model)
                        case .outputs:
                            ForEach(model.draft.devices.filter { $0.confirmed || $0.record.builtIn }) { d in OutputCard(model: model, device: d) }
                            if !pending.isEmpty { pendingDevices }
                        case .help: help
                        }
                    }.padding(26)
                }
                Divider()
                footer
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 950, minHeight: 650).tint(accent)
        .alert("无法完成操作", isPresented: $model.showingError) { Button("好", role: .cancel) {} } message: { Text(model.errorMessage) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        Label(page.title, systemImage: page.symbol).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).frame(height: 44)
                            .foregroundStyle(model.page == page ? accent : .primary)
                            .background(model.page == page ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                Text("已加入联动").font(.system(size: 12)).foregroundStyle(secondaryInk)
                ForEach(model.draft.devices.filter { $0.confirmed || $0.record.builtIn }) { d in
                    Button { model.page = .outputs } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: d.record.builtIn ? "laptopcomputer" : "display").foregroundStyle(secondaryInk).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(d.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(model.connection(d)).font(.system(size: 11)).foregroundStyle(secondaryInk)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if !pending.isEmpty {
                    Button { model.page = .outputs } label: {
                        Label("添加显示器（\(pending.count)）", systemImage: "plus.circle").font(.system(size: 12))
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(accent)
                }
            }.padding(.top, 3)
            Spacer(minLength: 12)
            Divider()
            sidebarSwitch("自动切换", value: $model.draft.automatic)
            sidebarSwitch("登录后启动", value: $model.login)
        }.padding(16).background(Color(nsColor: .underPageBackgroundColor))
    }
    private func sidebarSwitch(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel(title)
        }
    }
    private var footer: some View {
        HStack(spacing: 14) {
            if model.busy { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.dirty ? "未保存的更改" : model.status).font(.system(size: 12)).lineLimit(2)
                if model.dirty { Text("保存后，下次开合盖生效").font(.system(size: 11)).foregroundStyle(secondaryInk) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("撤销") { model.revert() }.disabled(!model.dirty || model.busy)
            Button("保存") { model.save() }.buttonStyle(.borderedProminent).disabled(!model.dirty || model.busy).keyboardShortcut("s", modifiers: .command)
        }.controlSize(.large).padding(.horizontal, 24).padding(.vertical, 13)
    }
    private var pendingDevices: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 16) {
                Text("未加入联动").font(.system(size: 16, weight: .semibold))
                ForEach(pending) { d in
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.system(size: 23)).foregroundStyle(secondaryInk).frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.name).font(.system(size: 13, weight: .medium))
                            Text(d.record.outputDescription).font(.system(size: 12)).foregroundStyle(secondaryInk)
                        }
                        Spacer()
                        Button("加入联动") { model.draft.confirm(d.id) }.controlSize(.large)
                    }
                }
            }
        }
    }
    private var help: some View {
        VStack(alignment: .leading, spacing: 18) {
            helpBlock("开盖与合盖", "开盖时可只用 Mac、只用外接屏，或同时使用。合盖时只用所选外接屏。保存后下次开合盖生效。")
            helpBlock("主显示器", "镜像使用让两块屏幕显示相同内容，无需选择主副屏。扩展使用可直接选择主显示器和副显示器。只用一块屏幕时，它自动成为主显示器。")
            helpBlock("添加与输出", "在“设备与输出”中加入新显示器，并设置输出模式与 HDR。可用模式取决于屏幕和连接设备。停用输出不等于关闭显示器电源。")
            helpBlock("恢复画面", "目标屏幕未响应时会保留可用画面。也可恢复所有显示器并暂停自动切换。")
            Button("恢复所有显示器并暂停自动切换") { model.owner?.restoreDisplays() }.controlSize(.large)
            HStack(spacing: 14) {
                Text("版本 \(AppInformation.versionLabel)").font(.system(size: 12)).foregroundStyle(secondaryInk)
                Button("关于…") { model.owner?.showAbout() }
            }
        }
    }
    private func helpBlock(_ title: String, _ text: String) -> some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(secondaryInk).lineSpacing(5)
            }
        }
    }
}

private struct SectionSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.4)))
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).font(.system(size: 13)).frame(width: 128, alignment: .leading)
            content.frame(width: 350, alignment: .leading)
            Spacer(minLength: 0)
        }.frame(minHeight: 32).controlSize(.large)
    }
}

private struct NativeChoicePicker: NSViewRepresentable {
    let title: String
    let options: [(id: String, title: String)]
    let selected: String
    let choose: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemArray.map({ $0.representedObject as? String ?? "" }) != options.map(\.id) || button.itemTitles != options.map(\.title) {
            button.removeAllItems()
            if button.menu == nil { button.menu = NSMenu() }
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.representedObject = option.id
                button.menu?.addItem(item)
            }
        }
        if let index = options.firstIndex(where: { $0.id == selected }) { button.selectItem(at: index) }
        button.setAccessibilityLabel(title)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 350, height: 28)
    }
    final class Coordinator: NSObject {
        var parent: NativeChoicePicker
        init(_ parent: NativeChoicePicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { parent.choose(id) }
        }
    }
}

private struct EventHeader: View {
    @Bindable var model: SettingsModel
    let event: LidEvent
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if event == .open { Image(systemName: "laptopcomputer").font(.system(size: 23)) }
                else { ClosedLaptop().frame(width: 29, height: 22) }
            }.foregroundStyle(secondaryInk).frame(width: 32)
            Text(event.title).font(.system(size: 18, weight: .semibold))
            Spacer()
            if model.lidClosed == (event == .closed) {
                Button("立即应用") { model.apply(event) }
                    .disabled(model.busy || model.dirty).help("执行已保存的这组设置")
            }
        }
    }
}

private struct OpenLidCard: View {
    @Bindable var model: SettingsModel
    private var preset: ScenePreset { model.draft.preset(.open) }
    private var enabled: [KnownDisplay] { model.draft.devices.filter { ($0.confirmed || $0.record.builtIn) && model.draft.openRule.action($0.id) == .on } }
    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 18) {
                EventHeader(model: model, event: .open)
                HStack(spacing: 10) {
                    ForEach([ScenePreset.internalOnly, .externalOnly, .extended]) { p in
                        let disabled = p != .internalOnly && model.draft.externals.isEmpty
                        Button { model.select(p, event: .open) } label: {
                            VStack(spacing: 10) {
                                SceneArt(preset: p).frame(height: 32)
                                Text(title(p)).font(.system(size: 13, weight: .medium))
                            }.frame(maxWidth: .infinity).frame(height: 93)
                                .background(preset == p ? accent.opacity(0.08) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(preset == p ? accent : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: preset == p ? 1.7 : 1))
                                .overlay(alignment: .topTrailing) { if preset == p { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent).padding(8) } }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.43 : 1)
                            .accessibilityLabel("开盖时：\(title(p))").accessibilityAddTraits(preset == p ? .isSelected : [])
                    }
                }
                if preset == .externalOnly || preset == .extended {
                    ExternalAssignment(model: model, event: .open)
                }
                if preset == .extended {
                    SettingRow(title: "同时使用方式") {
                        Picker("同时使用方式", selection: Binding(get: { model.draft.openRule.dualMode ?? .extended }, set: { model.dualMode($0) })) {
                            ForEach(DualDisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.labelsHidden().pickerStyle(.segmented).controlSize(.regular)
                    }
                    if model.draft.openRule.dualMode == .mirror {
                        Text("两块屏幕显示相同内容，输出模式由 macOS 协调。").font(.system(size: 12)).foregroundStyle(secondaryInk)
                    } else {
                        SettingRow(title: "主显示器") {
                            NativeChoicePicker(title: "主显示器", options: enabled.map { ($0.id, $0.name) },
                                selected: model.draft.openRule.main ?? enabled.first?.id ?? "") { model.main($0, event: .open) }
                        }
                        SettingRow(title: "副显示器") {
                            NativeChoicePicker(title: "副显示器", options: enabled.map { ($0.id, $0.name) },
                                selected: enabled.first(where: { $0.id != model.draft.openRule.main })?.id ?? "") { model.secondary($0) }
                        }
                    }
                }
                if preset == .keep || preset == .custom {
                    Text("已载入之前的规则，请选择上方一种屏幕用法。").font(.system(size: 12)).foregroundStyle(secondaryInk)
                }
                Divider()
                SettingRow(title: "开盖后切换") {
                    Picker("开盖后切换", selection: $model.draft.openDelay) {
                        ForEach([0.0, 0.5, 1, 2, 3], id: \.self) { delay in
                            Text(delay == 0 ? "立即" : "\(delay.formatted()) 秒").tag(delay)
                        }
                    }.labelsHidden().pickerStyle(.segmented).controlSize(.regular)
                }
            }
        }
    }
    private func title(_ p: ScenePreset) -> String {
        switch p { case .internalOnly: return "只用 Mac 屏幕"; case .externalOnly: return "只用外接屏"; default: return "同时使用" }
    }
}

private struct ClosedLidCard: View {
    @Bindable var model: SettingsModel
    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 18) {
                EventHeader(model: model, event: .closed)
                if model.draft.externals.isEmpty {
                    Button("添加外接显示器") { model.page = .outputs }.controlSize(.large)
                } else {
                    ExternalAssignment(model: model, event: .closed)
                    if model.draft.preset(.closed) != .externalOnly {
                        Text("已载入之前的规则，选择外接屏后可更新为只用该屏幕。").font(.system(size: 12)).foregroundStyle(secondaryInk)
                    }
                }
            }
        }
    }
}

private struct ExternalAssignment: View {
    @Bindable var model: SettingsModel
    let event: LidEvent
    private var rule: SceneRule { model.draft.rule(event) }
    private var selected: String {
        if let target = rule.target, model.draft.externals.contains(where: { $0.id == target }) { return target }
        return model.draft.externals.first(where: { rule.action($0.id) == .on })?.id ?? model.draft.externals.first?.id ?? ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event == .closed ? "只用外接屏" : "外接显示器").font(.system(size: 13, weight: .medium))
            ForEach(model.draft.externals) { device in
                let chosen = selected == device.id && !rule.noChange && rule.action(device.id) == .on
                Button { model.target(device.id, event: event) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "display").font(.system(size: 21)).foregroundStyle(chosen ? accent : secondaryInk).frame(width: 26)
                        Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                    }.padding(.horizontal, 13).frame(height: 50)
                        .background(chosen ? accent.opacity(0.07) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? accent : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: chosen ? 1.3 : 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).frame(maxWidth: 350).accessibilityLabel("\(event.title)：使用 \(device.name)")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SceneArt: View {
    let preset: ScenePreset
    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            Image(systemName: "laptopcomputer").foregroundStyle(preset != .externalOnly ? accent : Color.gray.opacity(0.45))
            Image(systemName: "display").foregroundStyle(preset != .internalOnly ? accent : Color.gray.opacity(0.45))
        }.font(.system(size: 27, weight: .light)).symbolRenderingMode(.hierarchical)
    }
}

private struct ClosedLaptop: View {
    var body: some View {
        GeometryReader { proxy in
            Path { p in
                let w = proxy.size.width, h = proxy.size.height
                p.move(to: CGPoint(x: w * 0.12, y: h * 0.4)); p.addLine(to: CGPoint(x: w * 0.88, y: h * 0.4))
                p.move(to: CGPoint(x: w * 0.05, y: h * 0.6)); p.addLine(to: CGPoint(x: w * 0.95, y: h * 0.6))
                p.addLine(to: CGPoint(x: w * 0.84, y: h * 0.8)); p.addLine(to: CGPoint(x: w * 0.16, y: h * 0.8)); p.closeSubpath()
            }.stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("合盖的笔记本电脑")
    }
}


private struct OutputCard: View {
    @Bindable var model: SettingsModel
    let device: KnownDisplay
    private var modeID: String { device.output.automaticMode ? "auto" : device.output.mode?.id ?? "keep" }
    private var choices: [ModeRequest] { model.modes[device.id] ?? [] }
    private var modeOptions: [(id: String, title: String)] {
        var result = [("keep", "使用当前设置"), ("auto", "自动选择")]
        if let saved = device.output.mode, !choices.contains(where: { $0.id == saved.id }) { result.append((saved.id, saved.title)) }
        return result + choices.map { ($0.id, $0.title) }
    }
    private var hdrOptions: [(id: String, title: String)] {
        var result = [("keep", "使用当前设置"), ("automatic", "自动")]
        if live?.hdrSupported == true || device.output.hdr == .on { result.append(("on", "开启")) }
        result.append(("off", "关闭"))
        return result
    }
    private var live: DisplayRecord? { model.records.first(where: { $0.key == device.id }) }
    var body: some View {
        SectionSurface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    Image(systemName: device.record.builtIn ? "laptopcomputer" : "display")
                        .font(.system(size: 27, weight: .regular)).foregroundStyle(secondaryInk).frame(width: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.name).font(.system(size: 17, weight: .semibold))
                        Text(model.connection(device)).font(.system(size: 12)).foregroundStyle(secondaryInk)
                    }
                    Spacer()
                    if let live { Text(live.outputDescription).font(.system(size: 12)).foregroundStyle(secondaryInk) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "显示器名称") {
                        TextField(device.record.builtIn ? "Mac 内置显示器" : (device.record.name.isEmpty ? device.name : device.record.name), text: Binding(get: { device.alias }, set: { value in model.editDevice(device.id) { $0.alias = String(value.prefix(80)) } }))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("显示器名称")
                    }
                    SettingRow(title: "分辨率与刷新率") {
                        NativeChoicePicker(title: "分辨率与刷新率", options: modeOptions, selected: modeID) { model.selectMode($0, key: device.id) }
                    }
                    SettingRow(title: "HDR") {
                        NativeChoicePicker(title: "HDR", options: hdrOptions, selected: device.output.hdr.rawValue) { value in
                            if let value = HDRChoice(rawValue: value) { model.editDevice(device.id) { $0.output.hdr = value } }
                        }
                    }
                }
                if choices.isEmpty {
                    Text("连接并启用此屏幕后，可读取可用的输出模式。").font(.system(size: 12)).foregroundStyle(secondaryInk)
                }
                if !device.alias.isEmpty && !device.record.name.isEmpty {
                    Text("系统名称：\(device.record.name)").font(.system(size: 11)).foregroundStyle(secondaryInk).textSelection(.enabled)
                }
            }
        }
    }
}
