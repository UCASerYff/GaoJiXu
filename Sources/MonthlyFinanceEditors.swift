import SwiftUI

private func monthlyParseAmount(_ text: String) throws -> Decimal {
  let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard cleaned.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
    let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
  else { throw MonthlyFinanceError("请输入有效金额。") }
  return value
}
private struct MonthlyFinanceActions: View {
  let title: String
  let save: () -> Bool
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    HStack {
      Text(title).font(.title2.bold())
      Spacer()
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("保存") { if save() { dismiss() } }.keyboardShortcut(.defaultAction).buttonStyle(
        .borderedProminent)
    }
  }
}
private struct MonthlyFinanceEditorFrame<Content: View>: View {
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @Environment(\.dismiss) private var dismiss
  let title: String
  let save: () -> Bool
  @ViewBuilder let fields: () -> Content
  var body: some View {
    WorkbenchEditorScaffold(title: title, subtitle: "核对后保存，原业务记录与提醒规则保持不变。") {
      Group { fields() }
        .textFieldStyle(.roundedBorder)
      if let p = store.problem {
        Text(p).font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
    } actions: {
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("保存") { if save() { dismiss() } }
        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(SavingsTheme.accent)
    }
    .frame(minWidth: 560, idealWidth: 610, minHeight: 480, idealHeight: 650)
  }
}

struct MonthlyFinanceSubscriptionEditor: View {
  let existing: MonthlyFinanceSubscription?, originalState: MonthlyFinanceState
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var sub: MonthlyFinanceSubscription
  @State private var plan: MonthlyFinancePlan
  @State private var price: String
  @State private var effective: Date
  @State private var trial: Bool
  @State private var trialEnd: Date
  @State private var deadlineEnabled: Bool
  @State private var deadline: Date
  @State private var cancelled: Bool
  @State private var cancelDate: Date
  @State private var serviceEnabled: Bool
  @State private var serviceEnd: Date
  @State private var customReminder: Bool
  @State private var advance: Int
  @State private var monthReview: Int
  @State private var reviewMonth: Date
  init(existing: MonthlyFinanceSubscription?, state: MonthlyFinanceState) {
    self.existing = existing
    originalState = state
    let s = existing ?? MonthlyFinanceSubscription()
    _sub = State(initialValue: s)
    _plan = State(initialValue: s.current)
    _price = State(
      initialValue: existing.map { NSDecimalNumber(decimal: $0.current.price).stringValue } ?? "")
    _effective = State(initialValue: max(Date(), s.current.start))
    _trial = State(initialValue: s.trialEnd != nil)
    _trialEnd = State(initialValue: s.trialEnd ?? Date())
    _deadlineEnabled = State(initialValue: s.cancelDeadline != nil)
    _deadline = State(initialValue: s.cancelDeadline ?? Date())
    _cancelled = State(initialValue: s.cancelledAt != nil)
    _cancelDate = State(initialValue: s.cancelledAt ?? Date())
    _serviceEnabled = State(initialValue: s.serviceEnd != nil)
    _serviceEnd = State(initialValue: s.serviceEnd ?? Date())
    _customReminder = State(initialValue: s.reminderDays != nil)
    _advance = State(initialValue: s.reminderDays ?? state.preferences.reminderDays)
    _reviewMonth = State(initialValue: Date())
    _monthReview = State(
      initialValue: state.reviews.first {
        $0.subscriptionID == s.id && $0.month == MonthlyFinanceEngine.month(Date(), state)
      }?.rating ?? -1)
  }
  var body: some View {
    MonthlyFinanceEditorFrame(title: existing == nil ? "新增固定支出" : "编辑订阅", save: save) {
      Section("订阅") {
        TextField("名称", text: $sub.name)
        TextField("分类", text: $sub.category)
        TextField("管理网址（可选）", text: $sub.link)
        TextField("备注（可选）", text: $sub.note)
        Toggle("自动续费", isOn: $sub.autoRenew)
        Toggle("计划取消", isOn: $sub.cancelIntent)
        Toggle("月卡模式（按覆盖期数叠加）", isOn: Binding(get: { sub.isStacking }, set: { sub.stacking = $0 }))
      }
      Section("计费计划") {
        TextField("每期价格", text: $price)
        Picker("币种", selection: $plan.currency) {
          ForEach(MonthlyFinanceEngine.currencies, id: \.self) { Text($0) }
        }
        Picker("周期", selection: $plan.cycle) {
          ForEach(MonthlyFinanceCycle.allCases) { Text($0.title(false)).tag($0) }
        }
        if plan.cycle == .days {
          Stepper("每 \(plan.interval) 天", value: $plan.interval, in: 1...3650)
        }
        DatePicker("账期锚点", selection: $plan.anchor, displayedComponents: .date)
        Toggle("按月末", isOn: $plan.monthEnd)
        if existing != nil {
          DatePicker("计划变更生效日", selection: $effective, displayedComponents: .date)
        } else {
          DatePicker("计划开始日", selection: $plan.start, displayedComponents: .date)
        }
      }
      Section("试用、服务与提醒") {
        Toggle("订阅有试用期", isOn: $trial)
        if trial {
          DatePicker("试用截止", selection: $trialEnd, displayedComponents: .date)
          Toggle("试用已处理", isOn: $sub.trialResolved)
        }
        Toggle("指定取消截止日期", isOn: $deadlineEnabled)
        if deadlineEnabled { DatePicker("取消截止", selection: $deadline, displayedComponents: .date) }
        Toggle("已取消续费", isOn: $cancelled)
        if cancelled {
          DatePicker("取消日期", selection: $cancelDate, in: ...Date(), displayedComponents: .date)
        }
        Toggle("指定权益服务截止日期", isOn: $serviceEnabled)
        if serviceEnabled { DatePicker("服务截止", selection: $serviceEnd, displayedComponents: .date) }
        Toggle("使用专属提前提醒", isOn: $customReminder)
        if customReminder { Stepper("提前 \(advance) 天", value: $advance, in: 0...3650) }
      }
      if let existing {
        Section("历史计划") {
          ForEach(existing.plans) { p in
            Text(
              "\(MonthlyFinanceEngine.day(p.start,originalState)) → \(p.end.map{MonthlyFinanceEngine.day($0,originalState)} ?? "持续中")　\(p.currency) \(NSDecimalNumber(decimal:p.price).stringValue) · \(p.cycle.title(false))"
            ).font(.callout)
          }
        }
        Section("月度使用评价") {
          DatePicker("评价月份", selection: $reviewMonth, in: ...Date(), displayedComponents: .date)
            .onChange(of: reviewMonth) { _, d in
              monthReview =
                originalState.reviews.first {
                  $0.subscriptionID == existing.id
                    && $0.month == MonthlyFinanceEngine.month(d, originalState)
                }?.rating ?? -1
            }
          Picker("使用频率", selection: $monthReview) {
            Text("未评价").tag(-1)
            Text("较少使用").tag(0)
            Text("偶尔使用").tag(1)
            Text("经常使用").tag(2)
          }
        }
      }
    }
  }
  private func save() -> Bool {
    store.update { s in
      var d = sub
      var p = plan
      p.price = try monthlyParseAmount(price)
      var v = p.price
      var rounded = Decimal()
      NSDecimalRound(&rounded, &v, p.currency == "JPY" ? 0 : 2, .plain)
      guard rounded == v else { throw MonthlyFinanceError("每期价格超出币种精度。") }
      if !d.link.isEmpty {
        guard let u = URL(string: d.link),
          ["https", "http"].contains(u.scheme?.lowercased() ?? ""), u.host != nil
        else { throw MonthlyFinanceError("管理网址需为有效 http(s) 链接。") }
      }
      d.plans[d.plans.count - 1] = p
      d.reminderDays = customReminder ? advance : nil
      d.trialEnd = trial ? trialEnd : nil
      d.cancelDeadline = deadlineEnabled ? deadline : nil
      d.serviceEnd = serviceEnabled ? serviceEnd : nil
      d.cancelledAt = cancelled ? cancelDate : nil
      if cancelled && existing?.cancelledAt == nil {
        d.cancelIntent = false
        d.trialResolved = true
      }
      try MonthlyFinanceEngine.saveSubscription(
        &s, input: d, expected: existing, effectiveAt: effective)
      if let existing {
        let key = MonthlyFinanceEngine.month(reviewMonth, s)
        let prior = originalState.reviews.first {
          $0.subscriptionID == existing.id && $0.month == key
        }
        if monthReview != (prior?.rating ?? -1) {
          try MonthlyFinanceEngine.setReview(
            &s, subscriptionID: existing.id, month: reviewMonth,
            score: monthReview < 0 ? nil : monthReview, expected: prior)
        }
      }
    }
  }
}
struct MonthlyFinancePaymentEditor: View {
  let bill: MonthlyFinanceBill, existing: MonthlyFinancePayment?
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var amount: String
  @State private var date: Date
  @State private var skip: Bool
  @State private var note: String
  @State private var periods: Int
  init(bill: MonthlyFinanceBill, existing: MonthlyFinancePayment?) {
    self.bill = bill
    self.existing = existing
    _amount = State(
      initialValue: NSDecimalNumber(decimal: existing?.amount ?? bill.price).stringValue)
    _date = State(initialValue: existing?.paidAt ?? min(Date(), bill.date))
    _skip = State(initialValue: existing?.skipped ?? false)
    _note = State(initialValue: existing?.note ?? "")
    _periods = State(initialValue: existing?.coveredPeriods ?? 1)
  }
  var body: some View {
    MonthlyFinanceEditorFrame(
      title: existing == nil ? "核实实际支付" : "更正支付",
      save: {
        store.update {
          try MonthlyFinanceEngine.savePayment(
            &$0, bill: bill, expected: existing, amount: skip ? 0 : try monthlyParseAmount(amount),
            paidAt: date, skipped: skip, note: note, periods: periods)
        }
      }
    ) {
      if let state = store.state { Text("账期：" + MonthlyFinanceEngine.day(bill.date, state)) }
      Toggle("本期未扣款", isOn: $skip)
      if !skip {
        TextField("实际金额（\(bill.currency)）", text: $amount)
        if store.state?.subscriptions.first(where: { $0.id == bill.subscriptionID })?.isStacking
          == true
        {
          Stepper("覆盖 \(periods) 期", value: $periods, in: 1...120)
        }
      }
      DatePicker("实际日期", selection: $date, in: ...Date(), displayedComponents: .date)
      TextField("备注", text: $note)
      Text("确认的是已发生的支付，不会向服务平台发起扣款。").font(.caption).foregroundStyle(.secondary)
    }
  }
}
struct MonthlyFinanceBenefitEditor: View {
  let existing: MonthlyFinanceBenefitItem?, state: MonthlyFinanceState
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var draft: MonthlyFinanceBenefitItem
  init(existing: MonthlyFinanceBenefitItem?, state: MonthlyFinanceState) {
    self.existing = existing
    self.state = state
    _draft = State(initialValue: existing ?? MonthlyFinanceBenefitItem())
  }
  var body: some View {
    MonthlyFinanceEditorFrame(title: existing == nil ? "新增权益" : "编辑权益", save: save) {
      TextField("权益名称", text: $draft.name)
      Picker("领取周期", selection: $draft.kind) {
        Text("每日").tag(MonthlyFinanceBenefit.daily)
        Text("每周").tag(MonthlyFinanceBenefit.weekly)
      }
      Picker("关联订阅", selection: $draft.subscriptionID) {
        Text("独立权益").tag(Optional<UUID>.none)
        ForEach(state.subscriptions) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("备注", text: $draft.note)
      Toggle("已归档", isOn: $draft.archived)
    }
  }
  private func save() -> Bool {
    store.update { s in
      guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MonthlyFinanceError("请输入权益名称。")
      }
      let i = s.benefits.firstIndex { $0.id == draft.id }
      guard i.map({ s.benefits[$0] }) == existing else { throw MonthlyFinanceError("权益已变化，请重新编辑。") }
      if let i { s.benefits[i] = draft } else { s.benefits.append(draft) }
    }
  }
}
struct MonthlyFinanceEventEditor: View {
  let existing: MonthlyFinanceEvent?, state: MonthlyFinanceState
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var draft: MonthlyFinanceEvent
  init(existing: MonthlyFinanceEvent?, state: MonthlyFinanceState) {
    self.existing = existing
    self.state = state
    _draft = State(initialValue: existing ?? MonthlyFinanceEvent())
  }
  var body: some View {
    MonthlyFinanceEditorFrame(title: existing == nil ? "新增到期事项" : "编辑到期事项", save: save) {
      TextField("事项名称", text: $draft.name)
      DatePicker("到期时间", selection: $draft.deadline)
      Picker("关联订阅", selection: $draft.subscriptionID) {
        Text("不关联").tag(Optional<UUID>.none)
        ForEach(state.subscriptions) { Text($0.name).tag(Optional($0.id)) }
      }
      TextField("备注", text: $draft.note)
    }
  }
  private func save() -> Bool {
    store.update { s in
      let i = s.events.firstIndex { $0.id == draft.id }
      guard i.map({ s.events[$0] }) == existing else { throw MonthlyFinanceError("事项已变化，请重新编辑。") }
      if let i { s.events[i] = draft } else { s.events.append(draft) }
    }
  }
}
struct MonthlyFinanceSettingsEditor: View {
  let original: MonthlyFinancePreferences
  @State private var prefs: MonthlyFinancePreferences
  @ObservedObject private var store = MonthlyFinanceStore.shared
  init(state: MonthlyFinanceState) {
    original = state.preferences
    _prefs = State(initialValue: state.preferences)
  }
  var body: some View {
    MonthlyFinanceEditorFrame(
      title: "固定支出与权益设置",
      save: {
        store.update { s in
          guard s.preferences == original else { throw MonthlyFinanceError("设置已变化。") }
          s.preferences = prefs
        }
      }
    ) {
      TextField("业务时区（如 Asia/Shanghai）", text: $prefs.timezone)
      Toggle("隐私模式：隐藏提醒中的业务详情", isOn: $prefs.privacy)
      Toggle("排程续费、试用与到期事项提醒", isOn: $prefs.notifications)
      Button("请求系统通知权限") {
        Task { if await store.enableReminders() { prefs.notifications = true } }
      }
      Stepper("默认提前 \(prefs.reminderDays) 天", value: $prefs.reminderDays, in: 0...3650)
      Stepper("提醒时刻：\(prefs.reminderHour) 时", value: $prefs.reminderHour, in: 0...23)
      Text("日/周权益按保存的业务时区判断是否已领。系统通知需本应用单独获准。").font(.caption).foregroundStyle(.secondary)
    }
  }
}
