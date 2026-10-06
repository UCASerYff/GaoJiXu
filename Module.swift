import SwiftUI
import CoreText
import Foundation

public final class SavingsBundleMarker: NSObject {}
enum SavingsBundle {
    static let bundle = Bundle(for: SavingsBundleMarker.self)
    static let defaults = UserDefaults(suiteName: ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" ? "com.gaojixu.savings.test.Savings" : "com.gaojixu.savings.Savings") ?? .standard
}

@MainActor private enum SavingsRuntime {
    static let store = SavingsStore()
    static let settings = SavingsSettings()
    static var battleClock: Timer?
    static func start() {
        guard battleClock == nil, ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] != "1" else { return }
        battleClock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { store.performAutoBattleTick() }
        }
    }

    /// 注册打包的缝合像素字体（OFL 许可，随 Resources/ 拷入 framework Bundle）。
    /// 只注册一次（lazy 静态属性），避免视图重建时反复注册。
    /// 失败静默：Font.pixel 运行时会探测 PostScript 名并回退系统等宽字体。
    static let registerFontsOnce: Void = {
        if let fontURL = SavingsBundle.bundle.url(forResource: "FusionPixel12px", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
    }()
}

public struct SavingsModuleView: View {
    @ObservedObject private var store = SavingsRuntime.store
    @ObservedObject private var settings = SavingsRuntime.settings
    @Environment(\.scenePhase) private var scenePhase
    private let route: URL?
    private let routeRevision: Int
    public init(route: URL? = nil, routeRevision: Int = 0) {
        self.route = route
        self.routeRevision = routeRevision
        _ = SavingsRuntime.registerFontsOnce
    }
    public var body: some View {
        ContentView(route: route, routeRevision: routeRevision)
            .environmentObject(store)
            .environmentObject(settings)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { store.flushSave() }
                if phase == .active { store.materializeRecurringTransactions() }
            }
    }
}

/// 搞积蓄设置页（app 级设置中心嵌入用）：内容与模块原设置 sheet 完全一致，
/// settings 由 framework 内 singleton 注入，外部嵌入无需提供环境对象。
public struct SavingsSettingsView: View {
    @ObservedObject private var settings = SavingsRuntime.settings
    public init() {}
    public var body: some View {
        SavingsSettingsPanelView()
            .environmentObject(settings)
            .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
    }
}

@MainActor public enum SavingsModuleRuntime {
    public static func start() { SavingsRuntime.start() }
    public static func flush() -> Bool { SavingsRuntime.store.flushSave() }
    public static func reconcileMonthly(_ data: Data, ignored: Set<String> = []) throws -> [String:String] {
        try SavingsRuntime.store.reconcileMonthly(JSONDecoder().decode([ConfirmedMonthlyPayment].self,from:data), ignored:ignored)
    }
}
