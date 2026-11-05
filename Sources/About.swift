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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
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
    static let official = load("WeChatOfficialAccount", extension: "jpg")
    static let appreciation = load("AppreciationCode", extension: "png")
    private static func load(_ name: String, extension ext: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct AboutView: View {
    @State private var expandedCode: AboutCode?

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                if let icon = AboutImages.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Mac合盖和显示器联动助手").font(.system(size: 20, weight: .semibold))
                    Text("版本 \(AppInformation.versionLabel) · MIT 免费开源")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 24) {
                Link("小破猫官网", destination: URL(string: "https://xiaopomao.com")!)
                Link("GitHub 项目", destination: URL(string: "https://github.com/xinlaoshi/mac-lid-display-helper")!)
                Link("MIT 协议", destination: URL(string: "https://github.com/xinlaoshi/mac-lid-display-helper/blob/main/LICENSE")!)
            }.font(.system(size: 13))
            Divider()
            HStack(alignment: .top, spacing: 20) {
                GroupBox {
                    VStack(spacing: 10) {
                        codeButton(.official)
                        Text("Apple TV & Vision Pro 第一答主，全网20万+粉丝")
                            .font(.system(size: 12)).multilineTextAlignment(.center)
                        Text("教程帮助了超 1000 万人").font(.system(size: 13, weight: .medium))
                        Text("扫码关注获取 Vision Pro 和 Apple TV 教程合集")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(10).frame(maxWidth: .infinity, minHeight: 352, alignment: .top)
                } label: { Text("关注殇小辛").font(.system(size: 14, weight: .semibold)) }
                GroupBox {
                    VStack(spacing: 10) {
                        codeButton(.appreciation)
                        Text("殇小辛 的赞赏码").font(.system(size: 13, weight: .medium))
                        Text("如果它让你的桌面切换更省心，欢迎请我喝杯咖啡。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(10).frame(maxWidth: .infinity, minHeight: 352, alignment: .top)
                } label: { Text("支持开发").font(.system(size: 14, weight: .semibold)) }
            }.fixedSize(horizontal: false, vertical: true)
            Text("点击二维码可放大。赞赏完全自愿，不影响功能使用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 660, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $expandedCode) { code in ExpandedCodeView(code: code) }
    }

    private func codeButton(_ code: AboutCode) -> some View {
        Button { expandedCode = code } label: {
            Group {
                if let image = code.image {
                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                } else {
                    Label("二维码未载入", systemImage: "exclamationmark.triangle")
                }
            }
            .frame(width: 210, height: 210).padding(10)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(code.image == nil)
        .accessibilityLabel("放大\(code.title)")
        .help("点击放大二维码")
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
    }
}
