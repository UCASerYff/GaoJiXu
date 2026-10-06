import Foundation

/// App 级统一语言偏好：UserDefaults.standard 的 `gqns.language`（system / zh-Hans / en）。
/// 各模块 framework 独立编译，本文件是该键在搞积蓄模块内的最小读取实现。
enum GQNSLanguage {
    static let key = "gqns.language"

    static var raw: String { UserDefaults.standard.string(forKey: key) ?? "system" }

    /// 解析后的界面语言是否为英文。system 时跟随系统首选语言：中文 → 简体，其余 → 英文；
    /// 读不到系统偏好时维持中文（与模块既有默认值一致）。
    static var isEnglish: Bool {
        switch raw {
        case "en": return true
        case "zh-Hans": return false
        default:
            guard let first = Locale.preferredLanguages.first else { return false }
            return !first.hasPrefix("zh")
        }
    }

    static var localeIdentifier: String { isEnglish ? "en" : "zh-Hans" }
}

/// 搞积蓄最小双语机制（V1.9 新增）：zh-Hans 保持现有文案，en 走第二个参数。
/// 覆盖范围：导航/侧栏、工具栏、栏目名、设置页、主要按钮与提示；
/// 游戏内容（冒险/宠物/抽奖等）与 CSV 格式说明等仍为硬编码中文，列为遗留。
enum SavingsL10n {
    static func text(_ zh: String, _ en: String) -> String {
        GQNSLanguage.isEnglish ? en : zh
    }
}

/// 便捷全局函数（模块内专用，避免与视图代码重复写 SavingsL10n.text）。
func tS(_ zh: String, _ en: String) -> String {
    SavingsL10n.text(zh, en)
}
