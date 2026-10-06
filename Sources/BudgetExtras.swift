import Foundation

#if !SMOKE_TEST
import UserNotifications
#endif

/// SavingsSettings 定义在 AppTheme.swift（本迭代禁区），这里用扩展补充
/// 「预算滚存」开关：UserDefaults 持久化 + objectWillChange 通知视图刷新。
extension SavingsSettings {
    private static let budgetRolloverKey = "savings.budgetRollover"

    /// 预算滚存：开启后分类可用额度 = 本月预算 + 上月结余（上月预算 − 上月实际，可为负）。
    var budgetRolloverEnabled: Bool {
        get { SavingsBundle.defaults.bool(forKey: Self.budgetRolloverKey) }
        set {
            SavingsBundle.defaults.set(newValue, forKey: Self.budgetRolloverKey)
            objectWillChange.send()
        }
    }
}

/// 月度预算工具：monthKey（"yyyy-MM"）相邻月份推算与当月剩余天数，纯函数便于测试。
enum BudgetMonth {
    /// monthKey 的上一个月；解析失败时原样返回。
    static func previous(_ monthKey: String) -> String {
        offset(monthKey, by: -1)
    }

    /// monthKey 的下一个月；解析失败时原样返回。
    static func next(_ monthKey: String) -> String {
        offset(monthKey, by: 1)
    }

    static func offset(_ monthKey: String, by delta: Int) -> String {
        let parts = monthKey.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return monthKey }
        let index = year * 12 + (month - 1) + delta
        return String(format: "%04d-%02d", index / 12, index % 12 + 1)
    }

    /// 本月剩余天数（含今天）；无法计算时返回 1，避免除零。
    static func remainingDaysInCurrentMonth(from now: Date = Date()) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        guard let range = calendar.range(of: .day, in: .month, for: now) else { return 1 }
        let today = calendar.component(.day, from: now)
        return max(1, range.count - today + 1)
    }
}

/// 预算超支本地通知：每类每月在达到 80% 与 100% 时各发一次，
/// 已发记录存 UserDefaults（key 含年月 + 分类 + 阈值），不会重复打扰。
/// SMOKE_TEST 下全部为空操作，避免测试触发系统授权弹窗。
enum BudgetNotifier {
    private static let authorizationKey = "savings.budgetNotify.authRequested"

    static func requestAuthorizationIfNeeded() {
        #if !SMOKE_TEST
        let defaults = SavingsBundle.defaults
        guard !defaults.bool(forKey: authorizationKey) else { return }
        defaults.set(true, forKey: authorizationKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// ratio = 实际 / 预算（含滚存口径由调用方决定）；跨过 80%/100% 阈值时各发一次。
    static func notifyIfNeeded(monthKey: String, currency: SavingsCurrency,
                               categoryID: String, categoryName: String,
                               ratio: Double, planned: Double, actual: Double) {
        #if !SMOKE_TEST
        guard planned > 0 else { return }
        let defaults = SavingsBundle.defaults
        for threshold in [100, 80] where ratio >= Double(threshold) / 100 {
            let key = "savings.budgetNotify.\(monthKey).\(currency.rawValue).\(categoryID).\(threshold)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            let content = UNMutableNotificationContent()
            content.title = threshold >= 100 ? "预算已超支" : "预算即将用完"
            content.body = "「\(categoryName)」\(monthKey) 已用 \(SavingsFormatters.money(actual, currency: currency)) / 预算 \(SavingsFormatters.money(planned, currency: currency))（\(Int(ratio * 100))%）。"
            content.sound = .default
            let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
        #endif
    }
}
