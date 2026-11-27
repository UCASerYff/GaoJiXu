import SwiftUI
import AppKit
import Combine
import UserNotifications
import Savings

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    init() { AppAppearance.current.apply() }

    var body: some Scene {
        Window("搞积蓄 V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")", id: "main") {
            MainWindowContent(delegate: delegate)
        }
        .defaultSize(width: 1380, height: 860)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .newItem) {
                Button("新增记账") { post("gaojixu.newLedgerEntry") }.keyboardShortcut("n")
                Button("新增积蓄记录") { post("gaojixu.newSavingsRecord") }
                Button(SavingsModuleRuntime.localized("导入审核箱", "Import Review Inbox")) {
                    delegate.installWindowAction(openWindow)
                    delegate.showMainWindow(route: URL(string: "gaojixu://csv-review"))
                }
            }
        }
        MenuBarExtra {
            MenuBarCommands(delegate: delegate)
        } label: {
            if let url = Bundle.main.url(forResource: "GaoJiXuIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18).accessibilityLabel("搞积蓄")
            } else {
                Image(systemName: "wallet.bifold").accessibilityLabel("搞积蓄")
            }
        }
        .menuBarExtraStyle(.menu)
        Settings {
            TabView {
                SavingsSettingsView().tabItem { Label("模块设置", systemImage: "slider.horizontal.3") }
                GeneralSettings().tabItem { Label("外观", systemImage: "paintpalette") }
                DataSettings().tabItem { Label("数据", systemImage: "externaldrive") }
            }
            .frame(width: 720, height: 480)
        }
    }
}

private struct MainWindowContent: View {
    @ObservedObject var delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        SavingsModuleView(route: delegate.route, routeRevision: delegate.routeRevision)
            .frame(minWidth: 1040, minHeight: 720)
            .modifier(WindowToolbarOpaqueBackground())
            .onAppear { delegate.installWindowAction(openWindow) }
            .onOpenURL { url in
                delegate.installWindowAction(openWindow)
                delegate.showMainWindow(route: url)
            }
            .alert("数据操作未完成", isPresented: Binding(
                get: { delegate.dataError != nil }, set: { if !$0 { delegate.dataError = nil } }
            )) {
                Button("知道了") { delegate.dataError = nil }
            } message: { Text(delegate.dataError ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appOpenSettings"))) { _ in openSettings() }
    }
}

private struct MenuBarCommands: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("gqns.language") private var language = "system"

    var body: some View {
        Group {
            Button(SavingsModuleRuntime.localized("打开 搞积蓄", "Open Gao Savings")) {
                delegate.installWindowAction(openWindow)
                delegate.showMainWindow()
            }
            Divider()
            Button(SavingsModuleRuntime.localized("退出搞积蓄", "Quit Gao Savings")) { NSApp.terminate(nil) }
        }
        .id(language)
    }
}

func post(_ name: String) { NotificationCenter.default.post(name: Notification.Name(name), object: nil) }

@MainActor
final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var route: URL?
    @Published private(set) var routeRevision = 0
    @Published var dataError: String?
    private var windowAction: OpenWindowAction?
    private var hasPendingWindowRequest = false
    private var observers: [NSObjectProtocol] = []

    func installWindowAction(_ action: OpenWindowAction) {
        windowAction = action
        if hasPendingWindowRequest { showMainWindow() }
    }

    func showMainWindow(route destination: URL? = nil) {
        if let destination {
            route = destination
            routeRevision &+= 1
        }
        guard let windowAction else {
            hasPendingWindowRequest = true
            return
        }
        hasPendingWindowRequest = false
        NSApp.activate(ignoringOtherApps: true)
        windowAction(id: "main")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Notification.Name("Standalone.showWindow"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showMainWindow() }
            },
            center.addObserver(forName: Notification.Name("GaoSeries.dataError"), object: nil, queue: .main) { [weak self] note in
                let message = note.userInfo?["message"] as? String
                MainActor.assumeIsolated { self?.dataError = message }
            }
        ]
        SavingsModuleRuntime.start()
        AutoLedger.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard windowAction != nil else { return true }
        showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SavingsModuleRuntime.hasUnsubmittedCSVReview {
            sender.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = SavingsModuleRuntime.localized("导入审核还有未提交的修改", "Unsubmitted import review changes")
            alert.informativeText = SavingsModuleRuntime.localized(
                "可返回审核并保存。选择退出将放弃本次修改，已暂存的批次和已入账的流水会保留。",
                "Return to the inbox to save. Quitting discards these changes and keeps staged batches and recorded entries."
            )
            alert.addButton(withTitle: SavingsModuleRuntime.localized("返回审核", "Return to Review"))
            alert.addButton(withTitle: SavingsModuleRuntime.localized("放弃修改并退出", "Discard and Quit"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        return SavingsModuleRuntime.isLibraryProtected || SavingsModuleRuntime.flush() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let monthly = response.notification.request.content.userInfo["module"] as? String == "monthly"
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow(route: monthly ? URL(string: "gaojixu://fixed-expenses") : nil)
            completionHandler()
        }
    }
}

private struct WindowToolbarOpaqueBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else {
            content.toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        }
    }
}
