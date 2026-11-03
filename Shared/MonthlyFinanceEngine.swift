import Foundation

enum MonthlyFinanceEngine {
  static func calendar(_ s: MonthlyFinanceState) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: s.preferences.timezone) ?? .current
    c.firstWeekday = 2
    c.minimumDaysInFirstWeek = 4
    return c
  }
  static func day(_ date: Date, _ s: MonthlyFinanceState) -> String {
    let c = calendar(s)
    let v = c.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", v.year!, v.month!, v.day!)
  }
  static func month(_ date: Date, _ s: MonthlyFinanceState) -> String {
    String(day(date, s).prefix(7))
  }
  static func date(_ text: String, _ s: MonthlyFinanceState) -> Date {
    let f = DateFormatter()
    f.calendar = calendar(s)
    f.timeZone = calendar(s).timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: text)!
  }
  static func dateFor(_ p: MonthlyFinancePlan, index: Int, state s: MonthlyFinanceState) -> Date {
    let c = calendar(s)
    let anchor = c.startOfDay(for: p.anchor)
    switch p.cycle {
    case .weekly, .days:
      return c.date(
        byAdding: .day, value: index * (p.cycle == .weekly ? 7 : p.interval), to: anchor)!
    default:
      let months = index * (p.cycle == .yearly ? 12 : p.cycle == .quarterly ? 3 : 1)
      let first = c.date(from: c.dateComponents([.year, .month], from: anchor))!
      let target = c.date(byAdding: .month, value: months, to: first)!
      let count = c.range(of: .day, in: .month, for: target)!.count
      let d = p.monthEnd ? count : min(c.component(.day, from: anchor), count)
      return c.date(byAdding: .day, value: d - 1, to: target)!
    }
  }
  static func monthly(_ p: MonthlyFinancePlan) -> Decimal {
    switch p.cycle {
    case .weekly: return p.price * 52 / 12
    case .monthly: return p.price
    case .quarterly: return p.price / 3
    case .yearly: return p.price / 12
    case .days: return p.price * 365 / Decimal(p.interval) / 12
    }
  }
  /// 月卡模式每期天数：月=30、周=7、季=90、年=365，自定义天数按间隔。
  static func cycleDays(_ p: MonthlyFinancePlan) -> Int {
    switch p.cycle {
    case .weekly: return 7
    case .monthly: return 30
    case .quarterly: return 90
    case .yearly: return 365
    case .days: return p.interval
    }
  }
  static func bills(
    _ sub: MonthlyFinanceSubscription, state s: MonthlyFinanceState, from: Date, through: Date
  ) -> [MonthlyFinanceBill] {
    let c = calendar(s)
    var result: [MonthlyFinanceBill] = []
    // 月卡模式：账期序列跨计划连续编号（sequence 全局递增），覆盖判定依赖该序号。
    var seq = 0
    for p in sub.plans {
      let lower = max(c.startOfDay(for: from), c.startOfDay(for: p.start))
      let upper = c.startOfDay(for: through)
      guard lower <= upper else { continue }
      let days = max(
        0, c.dateComponents([.day], from: c.startOfDay(for: p.anchor), to: lower).day ?? 0)
      let months = max(0, c.dateComponents([.month], from: p.anchor, to: lower).month ?? 0)
      var i = max(
        0,
        p.cycle == .days
          ? days / p.interval - 1
          : p.cycle == .weekly
            ? days / 7 - 1 : months / (p.cycle == .yearly ? 12 : p.cycle == .quarterly ? 3 : 1) - 2)
      // 月卡模式从头逐期生成（跨计划 sequence 连续，性能由 10000 上限兜底）。
      if sub.isStacking { i = 0 }
      for _ in 0..<10000 {
        let d =
          sub.isStacking
          ? c.date(
            byAdding: .day, value: i * cycleDays(p), to: c.startOfDay(for: p.anchor))!
          : dateFor(p, index: i, state: s)
        if d > upper { break }
        if let end = p.end, d >= c.startOfDay(for: end) { break }
        if let stop = p.billingStop, d >= c.startOfDay(for: stop) { break }
        if let cancelled = sub.cancelledAt, d >= c.startOfDay(for: cancelled) { break }
        if d >= lower {
          result.append(
            MonthlyFinanceBill(
              id: "\(sub.id)|\(day(d,s))", subscriptionID: sub.id, planID: p.id, date: d,
              price: p.price, currency: p.currency, sequence: sub.isStacking ? seq : i))
        }
        i += 1
        if sub.isStacking { seq += 1 }
      }
    }
    return result.sorted { $0.date < $1.date }
  }
  /// 月卡模式已覆盖期数：所有非"本期未扣"支付按期数累加。
  static func coveredPeriods(_ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState) -> Int {
    s.payments.filter { $0.subscriptionID == sub.id && !$0.skipped }.reduce(0) {
      $0 + $1.coveredPeriods
    }
  }
  /// 账期是否已结清：月卡模式按覆盖期数判定（提前续费会覆盖未来账期），其余按支付记录匹配。
  static func covered(_ bill: MonthlyFinanceBill, _ s: MonthlyFinanceState) -> Bool {
    if let sub = s.subscriptions.first(where: { $0.id == bill.subscriptionID }), sub.isStacking {
      return bill.sequence < coveredPeriods(sub, s)
    }
    return s.payments.contains { $0.id == bill.id }
  }
  /// 月卡模式剩余天数：服务付费到的日期（下一个未覆盖账期日）距今天的天数；负数表示已到期。
  static func remainingDays(
    _ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState, now: Date = Date()
  ) -> Int? {
    guard sub.isStacking, !sub.plans.isEmpty else { return nil }
    let c = calendar(s)
    let first = sub.plans.map(\.start).min()!
    let far = c.date(byAdding: .year, value: 50, to: now)!
    guard
      let next = bills(sub, state: s, from: first, through: far).first(where: {
        !covered($0, s)
      })
    else { return nil }
    return c.dateComponents(
      [.day], from: c.startOfDay(for: now), to: c.startOfDay(for: next.date)
    ).day
  }
  static func upcoming(_ s: MonthlyFinanceState, now: Date = Date(), days: Int = 30)
    -> [MonthlyFinanceBill]
  {
    let c = calendar(s)
    let end = c.date(byAdding: .day, value: days, to: now)!
    return s.subscriptions.filter { !$0.archived }.flatMap {
      bills($0, state: s, from: now, through: end)
    }.filter { !covered($0, s) }.sorted { $0.date < $1.date }
  }
  static func pending(_ s: MonthlyFinanceState, now: Date = Date()) -> [MonthlyFinanceBill] {
    let c = calendar(s)
    let from = c.date(byAdding: .month, value: -12, to: now)!
    return s.subscriptions.filter { !$0.archived }.flatMap {
      bills($0, state: s, from: from, through: now)
    }.filter { !covered($0, s) }.sorted { $0.date < $1.date }
  }
  static func next(_ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState, now: Date = Date())
    -> MonthlyFinanceBill?
  {
    bills(sub, state: s, from: now, through: calendar(s).date(byAdding: .year, value: 5, to: now)!)
      .first { b in !covered(b, s) }
  }
  static func activePlan(_ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState, on date: Date)
    -> MonthlyFinancePlan?
  {
    let c = calendar(s)
    let d = c.startOfDay(for: date)
    if sub.cancelledAt != nil {
      guard let end = sub.serviceEnd, d <= c.startOfDay(for: end) else { return nil }
    }
    return sub.plans.last {
      c.startOfDay(for: $0.start) <= d && ($0.end == nil || d < c.startOfDay(for: $0.end!))
    }
  }
  /// 权益打卡键："<权益ID>|<daily/weekly>|<周期起始日>"。
  /// 关联订阅的权益在订阅归档或服务期结束后不再可打卡（与 V0.4 行为一致）；
  /// 独立权益（无关联订阅）只要未归档就可打卡。
  static func claimKey(
    _ benefit: MonthlyFinanceBenefitItem, _ s: MonthlyFinanceState, on date: Date
  ) -> String? {
    guard !benefit.archived, benefit.kind != .none else { return nil }
    if let subID = benefit.subscriptionID {
      guard let sub = s.subscriptions.first(where: { $0.id == subID }), !sub.archived,
        activePlan(sub, s, on: date) != nil
      else { return nil }
    }
    let c = calendar(s)
    let start =
      benefit.kind == .weekly
      ? c.dateInterval(of: .weekOfYear, for: date)!.start : c.startOfDay(for: date)
    return "\(benefit.id)|\(benefit.kind.rawValue)|\(day(start,s))"
  }
  static func dueBenefits(_ s: MonthlyFinanceState, now: Date = Date())
    -> [MonthlyFinanceBenefitItem]
  {
    s.benefits.filter { benefit in
      claimKey(benefit, s, on: now).map { key in !s.claims.contains { $0.id == key } } == true
    }
  }
}

extension MonthlyFinanceEngine {
  static let currencies = ["CNY", "USD", "EUR", "HKD", "JPY", "GBP"]
  static func validate(_ s: MonthlyFinanceState) throws {
    func expect(_ ok: Bool, _ message: String) throws {
      if !ok { throw MonthlyFinanceError(message) }
    }
    func distinct<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
    func named(_ name: String) -> Bool {
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func dateOK(_ d: Date) -> Bool {
      (-63_113_904_000...252_455_616_000).contains(d.timeIntervalSinceReferenceDate)
    }
    try expect(
      s.schemaVersion == 1 && s.rulesVersion == 1 && dateOK(s.updatedAt), "月供业务库版本或时间不受支持。")
    try expect(
      TimeZone(identifier: s.preferences.timezone) != nil
        && (0...23).contains(s.preferences.reminderHour) && s.preferences.reminderDays >= 0
        && s.preferences.reminderDays <= 3650, "原提醒时区或设置无效。")
    let ids = Set(s.subscriptions.map(\.id))
    let benefits = Set(s.benefits.map(\.id))
    try expect(
      ids.count == s.subscriptions.count && benefits.count == s.benefits.count
        && distinct(s.subscriptions.flatMap { $0.plans.map(\.id) })
        && distinct(s.payments.map(\.id)) && distinct(s.claims.map(\.id))
        && distinct(s.events.map(\.id)) && distinct(s.reviews.map(\.id)), "月供资料存在重复源标识。")
    for sub in s.subscriptions {
      try expect(
        named(sub.name) && !sub.plans.isEmpty
          && sub.plans.map(\.start) == sub.plans.map(\.start).sorted()
          && [
            sub.createdAt, sub.updatedAt, sub.cancelledAt, sub.serviceEnd, sub.trialEnd,
            sub.cancelDeadline,
          ].compactMap { $0 }.allSatisfy(dateOK), "订阅信息或计划顺序无效。")
      try expect(sub.reminderDays.map { (0...3650).contains($0) } ?? true, "订阅提醒天数无效。")
      for p in sub.plans {
        try expect(
          !p.price.isNaN && p.price > 0 && p.price <= 999_999_999 && currencies.contains(p.currency)
            && (1...3650).contains(p.interval)
            && [p.start, p.anchor, p.end, p.billingStop].compactMap { $0 }.allSatisfy(dateOK),
          "固定支出周期、币种或金额无效。")
      }
    }
    for p in s.payments {
      try expect(
        ids.contains(p.subscriptionID) && named(p.id) && !p.amount.isNaN && p.amount >= 0
          && currencies.contains(p.currency) && (1...120).contains(p.coveredPeriods)
          && [p.due, p.paidAt, p.recordedAt].allSatisfy(dateOK), "支付历史存在无效关联、金额或覆盖期数。")
    }
    for b in s.benefits {
      try expect(
        named(b.name) && b.kind != .none && (b.subscriptionID.map(ids.contains) ?? true)
          && dateOK(b.createdAt), "权益名称、类型或关联无效。")
    }
    for payment in s.payments {
      let parts = payment.id.split(separator: "|", omittingEmptySubsequences: false)
      try expect(
        parts.count == 2 && UUID(uuidString: String(parts[0])) == payment.subscriptionID
          && parts[1].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
        "支付标识与订阅或账期不符。")
    }
    let owners = ids.union(benefits)
    for c in s.claims {
      let k = c.id.split(separator: "|", omittingEmptySubsequences: false)
      try expect(
        k.count == 3 && UUID(uuidString: String(k[0])).map(owners.contains) == true
          && ["daily", "weekly"].contains(String(k[1]))
          && k[2].range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil
          && owners.contains(c.subscriptionID) && dateOK(c.date) && dateOK(c.recordedAt),
        "打卡记录的归属或日期无效。")
    }
    for r in s.reviews {
      try expect(
        named(r.id) && ids.contains(r.subscriptionID) && (0...2).contains(r.rating)
          && r.month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil,
        "月度评价记录无效。")
    }
    for e in s.events {
      try expect(
        named(e.name) && (e.subscriptionID.map(ids.contains) ?? true)
          && [e.deadline, e.createdAt, e.doneAt].compactMap { $0 }.allSatisfy(dateOK), "到期事项或关联无效。")
    }
  }

  /// Never replace historical plan rows when a new price or cycle takes effect.
  static func saveSubscription(
    _ s: inout MonthlyFinanceState, input: MonthlyFinanceSubscription,
    expected: MonthlyFinanceSubscription?, effectiveAt: Date, now: Date = Date()
  ) throws {
    var sub = input
    sub.name = sub.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sub.plans.isEmpty else { throw MonthlyFinanceError("至少需要一段计费计划。") }
    if let old = expected {
      guard let i = s.subscriptions.firstIndex(where: { $0.id == sub.id }),
        s.subscriptions[i] == old
      else { throw MonthlyFinanceError("订阅已变化，请重新打开编辑。") }
      let draft = sub.current
      sub.plans = old.plans
      if draft != old.current {
        let c = calendar(s)
        let day = c.startOfDay(for: effectiveAt)
        guard day >= c.startOfDay(for: old.current.start) else {
          throw MonthlyFinanceError("新计划生效日不能早于现有计划。")
        }
        sub.plans[sub.plans.count - 1].end = day
        var plan = draft
        plan.id = UUID()
        plan.start = day
        plan.end = nil
        sub.plans.append(plan)
      }
      sub.updatedAt = now
      s.subscriptions[i] = sub
    } else {
      guard !s.subscriptions.contains(where: { $0.id == sub.id }),
        !s.tombstones.contains("deleted|\(sub.id)")
      else { throw MonthlyFinanceError("订阅标识已被使用。") }
      sub.updatedAt = now
      s.subscriptions.append(sub)
    }
  }
  static func removeSubscription(
    _ s: inout MonthlyFinanceState, expected: MonthlyFinanceSubscription
  ) throws {
    guard s.subscriptions.contains(expected) else { throw MonthlyFinanceError("订阅已变化。") }
    let id = expected.id
    let detached = s.benefits.filter { $0.subscriptionID == id }
    s.subscriptions.removeAll { $0.id == id }
    s.payments.removeAll { $0.subscriptionID == id }
    s.reviews.removeAll { $0.subscriptionID == id }
    s.claims.removeAll { c in
      c.subscriptionID == id && !detached.contains { c.id.hasPrefix("\($0.id)|") }
    }
    for b in detached {
      for j in s.claims.indices where s.claims[j].id.hasPrefix("\(b.id)|") {
        s.claims[j].subscriptionID = b.id
      }
    }
    for i in s.benefits.indices where s.benefits[i].subscriptionID == id {
      s.benefits[i].subscriptionID = nil
    }
    for i in s.events.indices where s.events[i].subscriptionID == id {
      s.events[i].subscriptionID = nil
    }
    s.tombstones.insert("deleted|\(id)")
  }
  static func savePayment(
    _ s: inout MonthlyFinanceState, bill: MonthlyFinanceBill, expected: MonthlyFinancePayment?,
    amount: Decimal, paidAt: Date, skipped: Bool, note: String, periods: Int, now: Date = Date()
  ) throws {
    let c = calendar(s)
    guard let sub = s.subscriptions.first(where: { $0.id == bill.subscriptionID }), !amount.isNaN,
      amount >= 0, amount <= 999_999_999, (1...120).contains(periods),
      c.startOfDay(for: paidAt) <= c.startOfDay(for: now)
    else { throw MonthlyFinanceError("请输入有效实际支付日、金额和期数。") }
    var raw = amount
    var rounded = Decimal()
    NSDecimalRound(&rounded, &raw, bill.currency == "JPY" ? 0 : 2, .plain)
    guard rounded == amount else { throw MonthlyFinanceError("实际金额超出币种精度。") }
    let i = s.payments.firstIndex { $0.id == bill.id }
    guard i.map({ s.payments[$0] }) == expected else {
      throw MonthlyFinanceError("账期已确认或支付记录已变更，请重新核对。")
    }
    if let i {
      s.payments[i].amount = skipped ? 0 : amount
      s.payments[i].paidAt = paidAt
      s.payments[i].skipped = skipped
      s.payments[i].note = note
      s.payments[i].periods = skipped ? nil : periods
    } else {
      guard !sub.archived,
        let actual = bills(sub, state: s, from: bill.date, through: bill.date).first(where: {
          $0.id == bill.id && $0.planID == bill.planID && $0.currency == bill.currency
            && $0.price == bill.price
        }), !covered(actual, s)
      else { throw MonthlyFinanceError("原账期不再有效或已覆盖，请刷新。") }
      s.payments.append(
        .init(
          id: bill.id, subscriptionID: sub.id, due: bill.date, paidAt: paidAt, recordedAt: now,
          amount: skipped ? 0 : amount, currency: bill.currency, skipped: skipped, note: note,
          periods: skipped ? nil : periods))
    }
  }
  /// A Widget button belongs to the period it displayed. A stale button cannot claim a later one.
  static func claimPresented(_ s: inout MonthlyFinanceState, benefitID: UUID,
    expectedPeriodKey: String, expectedTimezone: String, now: Date = Date()) throws {
    guard s.preferences.timezone == expectedTimezone,
      let benefit = s.benefits.first(where: { $0.id == benefitID }),
      claimKey(benefit, s, on: now) == expectedPeriodKey
    else { throw MonthlyFinanceError("权益周期或设置已变化，请刷新小组件后重试。") }
    try claim(&s, benefitID: benefitID, date: now, now: now)
  }
  static func claim(_ s: inout MonthlyFinanceState, benefitID: UUID, date: Date, now: Date = Date())
    throws
  {
    let c = calendar(s)
    guard c.startOfDay(for: date) <= c.startOfDay(for: now),
      let b = s.benefits.first(where: { $0.id == benefitID }), let key = claimKey(b, s, on: date)
    else { throw MonthlyFinanceError("当日没有可领取权益。") }
    guard !s.claims.contains(where: { $0.id == key }) else { return }
    s.claims.append(
      .init(
        id: key, subscriptionID: b.subscriptionID ?? b.id, date: date, recordedAt: now,
        backfill: day(date, s) != day(now, s)))
  }
  static func removeBenefit(_ s: inout MonthlyFinanceState, expected: MonthlyFinanceBenefitItem)
    throws
  {
    guard s.benefits.contains(expected) else { throw MonthlyFinanceError("权益已变更。") }
    s.benefits.removeAll { $0.id == expected.id }
    s.claims.removeAll { $0.id.hasPrefix("\(expected.id)|") }
    s.tombstones.insert("deleted-benefit|\(expected.id)")
  }
}

extension MonthlyFinanceEngine {
  struct UsageRating {
    let label: String
    let score: Int?
    var claimed = 0
    var expected = 0
  }
  static func rating(
    _ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState, now: Date = Date(),
    interval: DateInterval? = nil
  ) -> UsageRating {
    let c = calendar(s)
    let en = s.preferences.language == "en"
    let end = interval?.end ?? c.startOfDay(for: now)
    let start = interval?.start ?? c.date(byAdding: .day, value: -30, to: end)!
    // 订阅的领取率由关联权益的打卡记录计算；没有关联权益则按月度自评。
    let linked = s.benefits.filter { $0.subscriptionID == sub.id && !$0.archived }
    if linked.isEmpty {
      let target = interval.map { month($0.start, s) } ?? month(now, s)
      let v = s.reviews.first { $0.subscriptionID == sub.id && $0.month == target }?.rating
      return UsageRating(
        label: v.map { (en ? ["Unused", "Sometimes", "Often"] : ["吃灰", "偶尔", "常用"])[$0] }
          ?? (en ? "Not reviewed" : "未评估"), score: v)
    }
    var opportunities = Set<String>()
    var d = start
    var daily = false
    while d < end {
      for benefit in linked {
        if let key = claimKey(benefit, s, on: d) {
          if benefit.kind == .weekly {
            let w = c.dateInterval(of: .weekOfYear, for: d)!
            if w.end <= end && w.end > start { opportunities.insert(key) }
          } else {
            daily = true
            opportunities.insert(key)
          }
        }
      }
      d = c.date(byAdding: .day, value: 1, to: d)!
    }
    let count = opportunities.count
    let done = s.claims.filter { opportunities.contains($0.id) }.count
    guard count >= (daily ? 7 : 4) else {
      return UsageRating(
        label: en ? "Not enough data" : "数据不足", score: nil, claimed: done, expected: count)
    }
    let r = Double(done) / Double(count)
    let value = r >= 0.7 ? 2 : r >= 0.3 ? 1 : 0
    return UsageRating(
      label: (en ? ["Unused", "Sometimes", "Often"] : ["吃灰", "偶尔", "常用"])[value], score: value,
      claimed: done, expected: count)
  }
  static func dusty(_ sub: MonthlyFinanceSubscription, _ s: MonthlyFinanceState, now: Date = Date())
    -> Bool
  {
    let c = calendar(s)
    let first = c.dateInterval(of: .month, for: now)!.start
    return (1...2).allSatisfy { i in
      let start = c.date(byAdding: .month, value: -i, to: first)!
      return rating(
        sub, s, now: now,
        interval: DateInterval(start: start, end: c.date(byAdding: .month, value: 1, to: start)!)
      ).score == 0
    }
  }

  struct MonthlyTotal: Identifiable {
    let month: String
    let paid: Decimal
    let count: Int
    var id: String { month }
  }
  struct Statistics {
    let trend: [MonthlyTotal]
    let monthlyEstimate: Decimal
    let categories: [String: Decimal]
    let activeCount: Int
  }
  static func statistics(_ s: MonthlyFinanceState, currency: String, now: Date = Date())
    -> Statistics
  {
    let cal = calendar(s)
    let start = cal.dateInterval(of: .month, for: now)!.start
    let matched = s.subscriptions.filter {
      $0.renewing && !$0.archived && ($0.trialEnd == nil || $0.trialResolved)
    }
    let plans = matched.compactMap { sub -> (String, MonthlyFinancePlan)? in
      guard let plan = activePlan(sub, s, on: now), plan.currency == currency else { return nil }
      return (sub.category, plan)
    }
    let cats = plans.reduce(into: [String: Decimal]()) { $0[$1.0, default: 0] += monthly($1.1) }
    let paid = Dictionary(
      grouping: s.payments.filter { !$0.skipped && $0.currency == currency },
      by: { month($0.paidAt, s) })
    let trend = (0..<12).reversed().map { n -> MonthlyTotal in
      let key = month(cal.date(byAdding: .month, value: -n, to: start)!, s)
      let rows = paid[key] ?? []
      return .init(month: key, paid: rows.reduce(0) { $0 + $1.amount }, count: rows.count)
    }
    return .init(
      trend: trend, monthlyEstimate: cats.values.reduce(0, +), categories: cats,
      activeCount: plans.count)
  }
  static func setReview(
    _ s: inout MonthlyFinanceState, subscriptionID: UUID, month date: Date, score: Int?,
    expected: MonthlyFinanceReview?, now: Date = Date()
  ) throws {
    let key = month(date, s)
    guard s.subscriptions.contains(where: { $0.id == subscriptionID }), key <= month(now, s),
      score.map({ (0...2).contains($0) }) ?? true
    else { throw MonthlyFinanceError("无效的月份、订阅或评分。") }
    let i = s.reviews.firstIndex { $0.subscriptionID == subscriptionID && $0.month == key }
    guard i.map({ s.reviews[$0] }) == expected else { throw MonthlyFinanceError("评价已被修改，请刷新后重试。") }
    if let score {
      if let i {
        s.reviews[i].rating = score
      } else {
        s.reviews.append(
          .init(
            id: "\(subscriptionID)|\(key)", subscriptionID: subscriptionID, month: key,
            rating: score))
      }
    } else if let i {
      s.reviews.remove(at: i)
    }
  }
}
