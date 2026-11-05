import AppKit
import SwiftUI

enum AppInformation {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    static var versionLabel: String { build.isEmpty ? version : "\(version) (\(build))" }
}

extension MenuApp {
    @objc func showAbout() {
        if let window = aboutWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 696, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "关于 Mac合盖和显示器联动助手"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        aboutWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum AboutCode: String, Identifiable {
    case official, appreciation
    var id: String { rawValue }
    var title: String { self == .official ? "殇小辛的公众号" : "殇小辛 的赞赏码" }
    var image: NSImage? { self == .official ? AboutImages.official : AboutImages.appreciation }
}

private enum AboutImages {
    static let icon = load("AppIcon", extension: "icns")
    static let avatar = load("AuthorAvatar", extension: "png")
    static let official = load("WeChatOfficialAccount", extension: "jpg")
    static let appreciation = load("AppreciationCode", extension: "png")
    private static func load(_ name: String, extension ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private enum AboutSection: String, CaseIterable, Identifiable {
    case software = "关于软件", official = "公众号", appreciation = "赞赏支持"
    var id: String { rawValue }
}

private struct AboutView: View {
    @State private var section: AboutSection = .software
    @State private var expandedCode: AboutCode?

    var body: some View {
        HStack(spacing: 0) {
            AuthorProfileView()
            Divider()
            VStack(spacing: 24) {
                Picker("关于内容", selection: $section) {
                    ForEach(AboutSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented).controlSize(.large)
                .labelsHidden().accessibilityLabel("关于内容")
                Group {
                    switch section {
                    case .software: SoftwareInformationView()
                    case .official: codePanel(.official)
                    case .appreciation: codePanel(.appreciation)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.padding(26)
        }
        .frame(width: 696, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $expandedCode) { code in ExpandedCodeView(code: code) }
    }

    private func codePanel(_ code: AboutCode) -> some View {
        VStack(spacing: 12) {
            Text(code == .official ? "关注殇小辛" : code.title)
                .font(.system(size: 20, weight: .semibold))
            Text(code == .official ? "扫码关注获取 Vision Pro 和 Apple TV 教程合集" : "赞赏完全自愿，不影响功能使用。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { expandedCode = code } label: {
                Group {
                    if let image = code.image {
                        Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    } else {
                        Label("二维码未载入", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 184, height: 184).padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.gray.opacity(0.25)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(code.image == nil)
            .accessibilityLabel("放大\(code.title)").help("点击放大二维码")
            Text("点击二维码放大").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 2)
    }
}

private struct AuthorProfileView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let avatar = AboutImages.avatar {
                Image(nsImage: avatar).resizable().scaledToFit()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 23))
                    .accessibilityLabel("殇小辛头像")
            }
            Text("作者").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary).padding(.top, 24)
            Text("殇小辛").font(.system(size: 26, weight: .semibold)).padding(.top, 4)
            Text("Apple TV & Vision Pro 第一答主，全网20万+粉丝")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true).padding(.top, 20)
            Divider().padding(.vertical, 17)
            Text("教程帮助了超 1000 万人")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 30).padding(.bottom, 24)
        .frame(width: 226, height: 470, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct SoftwareInformationView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                if let icon = AboutImages.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                Text("Mac合盖和显示器联动助手")
                    .font(.system(size: 21, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("开盖与合盖，屏幕自动切换。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                informationRow("版本", value: AppInformation.versionLabel)
                Divider()
                informationRow("许可", value: "MIT 免费开源")
            }
            .padding(.horizontal, 14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                websiteLink("小破猫官网", url: "https://xiaopomao.com")
                websiteLink("GitHub", url: "https://github.com/xinlaoshi/mac-lid-display-helper")
            }
            Link("查看 MIT 协议", destination: URL(string: "https://github.com/xinlaoshi/mac-lid-display-helper/blob/main/LICENSE")!)
                .font(.system(size: 12)).frame(maxWidth: .infinity)
        }
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 14)).monospacedDigit()
        }.padding(.vertical, 11)
    }

    private func websiteLink(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 7) {
                Text(title)
                Image(systemName: "arrow.up.right.square").font(.system(size: 12))
            }.font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 28)
        }.buttonStyle(.bordered).controlSize(.large)
    }
}

private struct ExpandedCodeView: View {
    let code: AboutCode
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            Text(code.title).font(.system(size: 18, weight: .semibold))
            if let image = code.image {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                    .frame(width: 420, height: 420).padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(code.title)
            }
            Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24)
        .onExitCommand { dismiss() }
    }
}
