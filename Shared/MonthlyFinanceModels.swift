import Foundation

struct MonthlyFinanceError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum MonthlyFinanceCycle: String, Codable, CaseIterable, Identifiable {
  case weekly, monthly, quarterly, yearly, days
  var id: String { rawValue }
  func title(_ en: Bool) -> String {
    let a =
      en
      ? ["Weekly", "Monthly", "Quarterly", "Yearly", "Custom days"]
      : ["每周", "每月", "每季", "每年", "自定义天数"]
    return a[Self.allCases.firstIndex(of: self)!]
  }
}
enum MonthlyFinanceBenefit: String, Codable, CaseIterable {
  case none, daily, weekly
  func title(_ en: Bool) -> String {
    en
      ? ["none": "None", "daily": "Daily", "weekly": "Weekly"][rawValue]!
      : ["none": "无权益打卡", "daily": "每日权益", "weekly": "每周权益"][rawValue]!
  }
}
/// 独立权益（V0.5）：与订阅平级的打卡对象，可关联订阅也可独立存在（如游戏每日登录奖励）。
/// 迁移时复用所属订阅的 UUID，使历史打卡键 "id|kind|period" 与奖励键保持兼容。
struct MonthlyFinanceBenefitItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var kind: MonthlyFinanceBenefit = .daily
  var subscriptionID: UUID?
  var createdAt = Date()
  var archived = false
  var note = ""
}
struct MonthlyFinancePlan: Codable, Identifiable, Equatable {
  var id = UUID()
  var start = Date()
  var end: Date?
  var billingStop: Date?
  var anchor = Date()
  var price: Decimal = 0
  var currency = "CNY"
  var cycle: MonthlyFinanceCycle = .monthly
  var interval = 30
  var monthEnd = false
  var benefit: MonthlyFinanceBenefit = .none
}
struct MonthlyFinanceSubscription: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var category = "影音"
  var symbol = "play.rectangle"
  var color = "blue"
  var createdAt = Date()
  var updatedAt = Date()
  var plans: [MonthlyFinancePlan] = [MonthlyFinancePlan()]
  var autoRenew = true
  var cancelIntent = false
  var cancelledAt: Date?
  var serviceEnd: Date?
  var archived = false
  var trialEnd: Date?
  var trialResolved = false
  var cancelDeadline: Date?
  var reminderDays: Int?
  var link = ""
  var note = ""
  /// 月卡模式（V0.6）：剩余天数叠加。可选字段保证旧存档解码兼容；nil 视为关闭。
  var stacking: Bool?
  var isStacking: Bool { stacking == true }
  var current: MonthlyFinancePlan { plans.last! }
  var renewing: Bool { cancelledAt == nil }
}
struct MonthlyFinanceBill: Identifiable {
  var id: String
  var subscriptionID: UUID
  var planID: UUID
  var date: Date
  var price: Decimal
  var currency: String
  var sequence: Int
}
struct MonthlyFinancePayment: Codable, Equatable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var due: Date
  var paidAt: Date
  var recordedAt = Date()
  var amount: Decimal
  var currency: String
  var skipped = false
  var note = ""
  /// 一次支付覆盖的期数（V0.6 月卡模式提前续费）。可选字段保证旧存档解码兼容；nil 视为 1。
  var periods: Int?
  var coveredPeriods: Int { periods ?? 1 }
}
struct MonthlyFinanceClaim: Codable, Equatable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var date: Date
  var recordedAt = Date()
  var backfill = false
}
struct MonthlyFinanceReview: Codable, Equatable, Identifiable {
  var id: String
  var subscriptionID: UUID
  var month: String
  var rating: Int
}
struct MonthlyFinanceEvent: Codable, Identifiable, Equatable {
  var id = UUID()
  var name = ""
  var deadline = Date()
  var note = ""
  var subscriptionID: UUID?
  var createdAt = Date()
  var doneAt: Date?
}
struct MonthlyFinancePreferences: Codable, Equatable {
  var timezone = TimeZone.current.identifier
  var language = "zh"
  var appearance = "system"
  var backgroundHex = ""
  var notifications = false
  var reminderDays = 3
  var reminderHour = 9
  var privacy = false
  var onboarded = false
}
/// Receiver-owned domain only; never holds the full source snapshot or reward amounts.
struct MonthlyFinanceState: Codable, Equatable {
  var schemaVersion = 1
  var rulesVersion = 1
  var updatedAt = Date()
  var subscriptions: [MonthlyFinanceSubscription] = []
  var payments: [MonthlyFinancePayment] = []
  var claims: [MonthlyFinanceClaim] = []
  var reviews: [MonthlyFinanceReview] = []
  var events: [MonthlyFinanceEvent] = []
  var benefits: [MonthlyFinanceBenefitItem] = []
  var tombstones: Set<String> = []
  var legacyRewardIDs: Set<String> = []
  var preferences = MonthlyFinancePreferences()
}
