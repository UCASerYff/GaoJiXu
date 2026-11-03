import SwiftUI

private func monthlyMoney(_ amount: Decimal, _ currency: String) -> String {
  "\(currency) \(NSDecimalNumber(decimal:amount).stringValue)"
}
private enum MonthlyFinanceSheet: Identifiable {
  case sub(MonthlyFinanceSubscription?)
  case payment(MonthlyFinanceBill, MonthlyFinancePayment?)
  case event(MonthlyFinanceEvent?)
  case benefit(MonthlyFinanceBenefitItem?)
  case claims(MonthlyFinanceBenefitItem)
  case settings
  var id: String {
    switch self {
    case .sub(let s): return "sub-" + (s?.id.uuidString ?? "new")
    case .payment(let b, _): return "payment-" + b.id
    case .event(let e): return "event-" + (e?.id.uuidString ?? "new")
    case .benefit(let b): return "benefit-" + (b?.id.uuidString ?? "new")
    case .claims(let b): return "claims-" + b.id.uuidString
    case .settings: return "settings"
    }
  }
  @ViewBuilder func editor(_ state: MonthlyFinanceState) -> some View {
    switch self {
    case .sub(let s): MonthlyFinanceSubscriptionEditor(existing: s, state: state)
    case .payment(let b, let e): MonthlyFinancePaymentEditor(bill: b, existing: e)
    case .event(let e): MonthlyFinanceEventEditor(existing: e, state: state)
    case .benefit(let b): MonthlyFinanceBenefitEditor(existing: b, state: state)
    case .claims(let b): MonthlyFinanceClaimHistory(benefit: b)
    case .settings: MonthlyFinanceSettingsEditor(state: state)
    }
  }
}
private struct MonthlyFinanceUnavailable: View {
  @ObservedObject var store: MonthlyFinanceStore
  @State private var confirm = false
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "tray").font(.largeTitle)
      Text(store.unavailable).multilineTextAlignment(.center)
      Button("重新读取") { store.reload() }
      Button("从未使用月供，建立空白业务库…") { confirm = true }
    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).alert(
      "建立新的固定支出业务库？", isPresented: $confirm
    ) {
      Button("取消", role: .cancel) {}
      Button("建立空白库") { store.initializeEmpty() }
    } message: {
      Text("仅适用于全新用户。检测到已有来源资料、设置或目标时将拒绝创建。")
    }
  }
}
private struct MonthlyFinanceRow<Content: View>: View {
  let title: String, detail: String
  @ViewBuilder let content: () -> Content
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      content()
    }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
  }
}
private enum MonthlyFinanceDestructive: Identifiable {
  case sub(MonthlyFinanceSubscription)
  case pay(MonthlyFinancePayment)
  case event(MonthlyFinanceEvent)
  case benefit(MonthlyFinanceBenefitItem)
  case claim(MonthlyFinanceClaim)
  var id: String {
    switch self {
    case .sub(let a): return a.id.uuidString
    case .pay(let a): return a.id
    case .event(let a): return a.id.uuidString
    case .benefit(let a): return a.id.uuidString
    case .claim(let a): return a.id
    }
  }
  var title: String {
    switch self {
    case .sub: return "删除订阅及其支付历史？"
    case .pay: return "撤销这笔支付确认？"
    case .event: return "删除到期事项？"
    case .benefit: return "删除权益和它的打卡历史？"
    case .claim: return "撤销这次权益打卡？"
    }
  }
  @MainActor func run(_ store: MonthlyFinanceStore) {
    store.update { s in
      switch self {
      case .sub(let x): try MonthlyFinanceEngine.removeSubscription(&s, expected: x)
      case .benefit(let x): try MonthlyFinanceEngine.removeBenefit(&s, expected: x)
      case .pay(let x):
        guard s.payments.contains(x) else { throw MonthlyFinanceError("支付记录已变化。") }
        s.payments.removeAll { $0.id == x.id }
      case .event(let x):
        guard s.events.contains(x) else { throw MonthlyFinanceError("事项已变化。") }
        s.events.removeAll { $0.id == x.id }
      case .claim(let x):
        guard s.claims.contains(x) else { throw MonthlyFinanceError("打卡已变化。") }
        s.claims.removeAll { $0.id == x.id }
      }
    }
  }
}

struct FixedExpenseView: View {
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var tab = 0
  @State private var sheet: MonthlyFinanceSheet?
  @State private var remove: MonthlyFinanceDestructive?
  @State private var showArchived = false
  @State private var filter = ""
  @State private var pageSize = 30
  var body: some View {
    Group {
      if let s = store.state {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            HStack {
              Text("固定支出").font(.largeTitle.bold())
              Spacer()
              Button("提醒设置") { sheet = .settings }
              Button("新增订阅") { sheet = .sub(nil) }
            }
            Text("先安排账期，再核实实际支付。预计费用不会记入个人账本。").foregroundStyle(.secondary)
            Picker("内容", selection: $tab) {
              Text("订阅").tag(0)
              Text("待核实账期").tag(1)
              Text("支付历史").tag(2)
              Text("到期事项").tag(3)
              Text("统计与复盘").tag(4)
            }.pickerStyle(.segmented)
            switch tab {
            case 0: subscriptions(s)
            case 1: billList(s)
            case 2: payments(s)
            case 3: events(s)
            default: MonthlyFinanceStatisticsView(state: s)
            }
          }.padding(24)
        }
      } else {
        MonthlyFinanceUnavailable(store: store)
      }
    }.onAppear { store.reload() }.onChange(of: tab) { _, _ in pageSize = 30 }
      .sheet(item: $sheet) { route in
        if let s = store.state {
          route.editor(s).environment(\.timeZone, MonthlyFinanceEngine.calendar(s).timeZone)
        }
      }
      .alert(item: $remove) { a in
        Alert(
          title: Text(a.title), message: Text("仅在记录仍与当前显示一致时执行，已关联的自动流水将按核实结果对账。"),
          primaryButton: .destructive(Text("确认")) { a.run(store) }, secondaryButton: .cancel())
      }
      .safeAreaInset(edge: .bottom) {
        if let p = store.problem { Text(p).foregroundStyle(.red).padding(6) }
      }
  }
  @ViewBuilder private func subscriptions(_ s: MonthlyFinanceState) -> some View {
    HStack {
      TextField("搜索订阅名称", text: $filter)
      Toggle("含归档", isOn: $showArchived)
    }
    let rows = s.subscriptions.filter {
      (showArchived || !$0.archived)
        && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    if rows.isEmpty { Text("没有符合条件的订阅。").foregroundStyle(.secondary) }
    ForEach(rows) { sub in
      MonthlyFinanceRow(
        title: sub.name,
        detail:
          "\(sub.archived ? "已归档" : (sub.cancelledAt != nil ? "已取消" : "进行中")) · \(sub.current.cycle.title(false)) · \(monthlyMoney(sub.current.price,sub.current.currency)) · \(sub.plans.count) 段计划"
      ) {
        if sub.isStacking && !sub.archived && sub.renewing, let start = sub.plans.first?.start,
          let end = MonthlyFinanceEngine.calendar(s).date(byAdding: .year, value: 50, to: Date()),
          let b = MonthlyFinanceEngine.bills(sub, state: s, from: start, through: end).first(
            where: { !MonthlyFinanceEngine.covered($0, s) })
        {
          Button("续费") { sheet = .payment(b, nil) }
        }
        Button("编辑") { sheet = .sub(sub) }
        Menu("更多") {
          Button(sub.archived ? "取消归档" : "归档") {
            store.update { s in
              guard let i = s.subscriptions.firstIndex(of: sub) else {
                throw MonthlyFinanceError("订阅已变化。")
              }
              s.subscriptions[i].archived.toggle()
              s.subscriptions[i].updatedAt = Date()
            }
          }
          Button("删除订阅和支付历史", role: .destructive) { remove = .sub(sub) }
        }
      }
    }
  }
  @ViewBuilder private func billList(_ s: MonthlyFinanceState) -> some View {
    let overdue = MonthlyFinanceEngine.pending(s)
    let future = MonthlyFinanceEngine.upcoming(s, days: 90)
    let all = (overdue + future).reduce(into: [String: MonthlyFinanceBill]()) { $0[$1.id] = $1 }
      .values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    Text("近一年待核实及未来 90 天账期。月卡可提前续费并填写实际覆盖期数。").font(.caption).foregroundStyle(.secondary)
    if all.isEmpty {
      Text("没有待核实账期。")
    } else {
      ForEach(Array(all.prefix(pageSize))) { b in
        MonthlyFinanceRow(
          title: s.subscriptions.first { $0.id == b.subscriptionID }?.name ?? "未识别订阅",
          detail: MonthlyFinanceEngine.day(b.date, s) + " · 预计 " + monthlyMoney(b.price, b.currency)
        ) { Button("核实本期") { sheet = .payment(b, nil) } }
      }
      if all.count > pageSize { Button("显示更多账期") { pageSize += 50 } }
    }
  }
  @ViewBuilder private func payments(_ s: MonthlyFinanceState) -> some View {
    let rows = s.payments.sorted {
      ($0.paidAt, $0.recordedAt, $0.id) > ($1.paidAt, $1.recordedAt, $1.id)
    }
    if rows.isEmpty {
      Text("还没有已核实的支付。")
    } else {
      ForEach(Array(rows.prefix(pageSize))) { p in
        let sub = s.subscriptions.first { $0.id == p.subscriptionID }
        MonthlyFinanceRow(
          title: sub?.name ?? "未识别订阅",
          detail:
            "\(MonthlyFinanceEngine.day(p.paidAt,s)) · \(p.skipped ? "本期未扣" : monthlyMoney(p.amount,p.currency)) · 覆盖 \(p.coveredPeriods) 期"
            + (p.note.isEmpty ? "" : " · " + p.note)
        ) {
          Button("更正") {
            if let sub {
              let b = MonthlyFinanceBill(
                id: p.id, subscriptionID: p.subscriptionID, planID: sub.current.id, date: p.due,
                price: p.amount, currency: p.currency, sequence: 0)
              sheet = .payment(b, p)
            }
          }
          Button("撤销") { remove = .pay(p) }
        }
      }
      if rows.count > pageSize { Button("显示更多支付") { pageSize += 50 } }
    }
  }
  @ViewBuilder private func events(_ s: MonthlyFinanceState) -> some View {
    Button("新增到期事项") { sheet = .event(nil) }
    if s.events.isEmpty { Text("没有到期事项。") }
    ForEach(s.events.sorted { $0.deadline < $1.deadline }) { e in
      MonthlyFinanceRow(
        title: e.name,
        detail: MonthlyFinanceEngine.day(e.deadline, s) + (e.doneAt == nil ? " · 待办" : " · 已完成")
      ) {
        Button(e.doneAt == nil ? "标记完成" : "撤销完成") {
          store.update { s in
            guard let i = s.events.firstIndex(of: e) else { throw MonthlyFinanceError("事项已变化。") }
            s.events[i].doneAt = e.doneAt == nil ? Date() : nil
          }
        }
        Button("编辑") { sheet = .event(e) }
        Button("删除") { remove = .event(e) }
      }
    }
  }
}

struct MonthlyBenefitsView: View {
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @State private var sheet: MonthlyFinanceSheet?
  @State private var remove: MonthlyFinanceDestructive?
  @State private var archived = false
  var body: some View {
    Group {
      if let s = store.state {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            HStack {
              Text("权益打卡").font(.largeTitle.bold())
              Spacer()
              Toggle("含归档", isOn: $archived)
              Button("新增权益") { sheet = .benefit(nil) }
            }
            Text("记录日领或周领权益；实际领取请到服务平台完成。").foregroundStyle(.secondary)
            let rows = s.benefits.filter { archived || !$0.archived }
            if rows.isEmpty { Text("暂无权益，可新建独立权益或关联订阅。") }
            ForEach(rows) { b in
              let key = MonthlyFinanceEngine.claimKey(b, s, on: Date())
              let recorded = key.map { k in s.claims.contains { $0.id == k } } ?? false
              MonthlyFinanceRow(
                title: b.name,
                detail:
                  "\(b.kind.title(false)) · \(b.subscriptionID.flatMap{id in s.subscriptions.first{$0.id==id}?.name} ?? "独立权益")"
                  + (b.archived ? " · 归档" : "")
              ) {
                Button(recorded ? "本期已记" : "标记已领取") {
                  store.update {
                    try MonthlyFinanceEngine.claim(&$0, benefitID: b.id, date: Date())
                  }
                }.disabled(recorded || key == nil)
                Button("历史 / 补记") { sheet = .claims(b) }
                Menu("更多") {
                  Button("编辑") { sheet = .benefit(b) }
                  Button("删除权益及历史", role: .destructive) { remove = .benefit(b) }
                }
              }
            }
          }.padding(24)
        }
      } else {
        MonthlyFinanceUnavailable(store: store)
      }
    }.onAppear { store.reload() }.sheet(item: $sheet) { route in
      if let s = store.state {
        route.editor(s).environment(\.timeZone, MonthlyFinanceEngine.calendar(s).timeZone)
      }
    }.alert(item: $remove) { a in
      Alert(
        title: Text(a.title), primaryButton: .destructive(Text("删除")) { a.run(store) },
        secondaryButton: .cancel())
    }.safeAreaInset(edge: .bottom) {
      if let p = store.problem { Text(p).foregroundStyle(.red).padding(6) }
    }
  }
}

private struct MonthlyFinanceClaimHistory: View {
  let benefit: MonthlyFinanceBenefitItem
  @ObservedObject var store = MonthlyFinanceStore.shared
  @Environment(\.dismiss) var dismiss
  @State private var day = Date()
  @State private var remove: MonthlyFinanceDestructive?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(benefit.name).font(.title2)
        Spacer()
        Button("完成") { dismiss() }
      }
      DatePicker("补记日期", selection: $day, in: ...Date(), displayedComponents: .date)
      Button("记录该周期已领取") {
        store.update { try MonthlyFinanceEngine.claim(&$0, benefitID: benefit.id, date: day) }
      }
      if let s = store.state {
        let rows = s.claims.filter { $0.id.hasPrefix("\(benefit.id)|") }.sorted {
          $0.date > $1.date
        }
        if rows.isEmpty { Text("没有打卡记录。") }
        List(rows) { c in
          HStack {
            Text(MonthlyFinanceEngine.day(c.date, s) + (c.backfill ? " · 补记" : ""))
            Spacer()
            Button("撤销") { remove = .claim(c) }
          }
        }
      }
      if let p = store.problem { Text(p).foregroundStyle(.red) }
    }.padding(20).frame(minWidth: 430, minHeight: 350).alert(item: $remove) { a in
      Alert(
        title: Text(a.title), primaryButton: .destructive(Text("撤销打卡")) { a.run(store) },
        secondaryButton: .cancel())
    }
  }
}
