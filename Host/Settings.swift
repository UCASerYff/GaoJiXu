import AppKit
import SwiftUI
import Savings

struct GeneralSettings: View {
    @AppStorage("gqns.language") private var language = "system"
    @AppStorage("gqns.appearance") private var appearance = "system"
    var body: some View {
        Form {
            Picker("语言", selection: $language) {
                Text("跟随系统").tag("system")
                Text("中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            LabeledContent("版本", value: "V" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, _ in AppAppearance.current.apply() }
    }
}

enum AppAppearance: String {
    case system, light, dark
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: "gqns.appearance") ?? "system") ?? .system }
    func apply() {
        guard let app = NSApp else { DispatchQueue.main.async { self.apply() }; return }
        app.appearance = self == .system ? nil : NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

enum AppDataLocations {
    static var appSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GaoSeries/Savings", isDirectory: true)
    }
    static var groupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "5G96498KGJ.com.gaojixu.savings")
    }
}

struct DataSettings: View {
    @State private var status = ""

    var body: some View {
        Form {
            Section("现用资料") {
                Text("账本、固定收支、游戏进度与附件继续保存在原位置。此处仅提供目录入口，不复制或改写资料。")
                Button("打开数据目录") { reveal(AppDataLocations.appSupport) }
                Button("打开小组件共享目录") { reveal(AppDataLocations.groupContainer) }
                if !status.isEmpty { Text(status).textSelection(.enabled) }
            }
            Section("隐私") {
                Label("凭据继续由 macOS 钥匙串保管", systemImage: "key.fill")
                Label("源码与安装包不包含本机业务记录", systemImage: "lock.shield.fill")
            }
        }
        .formStyle(.grouped)
    }

    private func reveal(_ url: URL?) {
        guard let url else { status = "无法定位现用资料目录。"; return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            status = error.localizedDescription
        }
    }
}
