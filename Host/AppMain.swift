import SwiftUI
import AppKit
import UserNotifications
import Savings

@main struct StandaloneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var route: URL?
    @State private var revision = 0
    @State private var dataError: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    init() { AppAppearance.current.apply() }

    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
            ?? NSApp.windows.first(where: { $0.styleMask.contains(.titled) && !($0 is NSPanel) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        Window("搞积蓄 V\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")", id: "main") {
            SavingsModuleView(route: route, routeRevision: revision)
                .frame(minWidth: 1040, minHeight: 720)
                .modifier(WindowToolbarOpaqueBackground())
                .task { SavingsModuleRuntime.start(); AutoLedger.start() }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.dataError"))) { dataError = $0.userInfo?["message"] as? String }
                .alert("数据操作未完成", isPresented: Binding(get: { dataError != nil }, set: { if !$0 { dataError = nil } })) {
                    Button("知道了") { dataError = nil }
                } message: { Text(dataError ?? "") }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.app.openSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appOpenSettings"))) { _ in openSettings() }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Standalone.showWindow"))) { _ in openWindow(id: "main"); Self.activate() }
                .onOpenURL { url in
                    route = url
                    revision &+= 1
                    openWindow(id: "main")
                    Self.activate()
                }
        }
        .defaultSize(width: 1380, height: 860)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .newItem) {
                Button("新增记账") { post("gaojixu.newLedgerEntry") }.keyboardShortcut("n")
                Button("新增积蓄记录") { post("gaojixu.newSavingsRecord") }
            }
        }
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

func post(_ name: String) { NotificationCenter.default.post(name: Notification.Name(name), object: nil) }

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { UNUserNotificationCenter.current().delegate = self }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        SavingsModuleRuntime.flush() ? .terminateNow : .terminateCancel
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let monthly = response.notification.request.content.userInfo["module"] as? String == "monthly"
        DispatchQueue.main.async {
            post("Standalone.showWindow")
            if monthly { NotificationCenter.default.post(name: Notification.Name("gaojixu.selectSection"), object: nil, userInfo: ["section": "fixedExpenses"]) }
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
