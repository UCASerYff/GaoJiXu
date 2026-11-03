import Charts
import SwiftUI

struct MonthlyFinanceStatisticsView: View {
  let state: MonthlyFinanceState
  @State private var currency = "CNY"
  @State private var review: MonthlyFinanceSubscription?
  private func money(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.numberStyle = .decimal
    f.minimumFractionDigits = currency == "JPY" ? 0 : 2
    f.maximumFractionDigits = f.minimumFractionDigits
    return "\(currency) " + (f.string(from: NSDecimalNumber(decimal: d)) ?? String(describing: d))
  }
  var body: some View {
    let totals = MonthlyFinanceEngine.statistics(state, currency: currency)
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("支出统计与价值复盘").font(.title2.bold())
        Spacer()
        Picker("币种", selection: $currency) {
          ForEach(MonthlyFinanceEngine.currencies, id: \.self) { Text($0) }
        }.frame(width: 150)
      }
      HStack(spacing: 26) {
        metric("本月确认支付", money(totals.trend.last?.paid ?? 0))
        metric("当前订阅月化预计", money(totals.monthlyEstimate))
        metric("按现价预计全年", money(totals.monthlyEstimate * 12))
      }
      Text("实际支出按业务时区和支付日汇总，不计未确认账期和本期未扣。估算仅含当前有效的非试用付费订阅，未作汇率换算。").font(.caption).foregroundStyle(
        .secondary)
      Text("近十二个月 · 实际支付").font(.headline)
      Chart(totals.trend) { point in
        BarMark(
          x: .value("月份", point.month),
          y: .value("已支付", NSDecimalNumber(decimal: point.paid).doubleValue))
      }.frame(height: 150).accessibilityLabel("过去十二个月的确认支付")
      DisclosureGroup("查看逐月笔数与金额") {
        ForEach(totals.trend.reversed()) { point in
          HStack {
            Text(point.month)
            Spacer()
            Text("\(point.count) 笔　" + money(point.paid))
          }
        }
      }
      if !totals.categories.isEmpty {
        Text("按分类月折算").font(.headline)
        ForEach(totals.categories.keys.sorted(), id: \.self) { category in
          HStack {
            Text(category)
            Spacer()
            Text(money(totals.categories[category] ?? 0))
          }
        }
      }
      Divider()
      Text("订阅使用回顾").font(.headline)
      Text("有关联权益时，使用状态从已完成周期的领取率估计；没有权益时，参考月度自评。数据不足不会自动建议取消。").font(.caption).foregroundStyle(
        .secondary)
      let subs = state.subscriptions.filter { $0.current.currency == currency }.sorted {
        $0.name < $1.name
      }
      if subs.isEmpty { Text("此币种尚无订阅。").foregroundStyle(.secondary) }
      ForEach(subs) { sub in
        let use = MonthlyFinanceEngine.rating(sub, state)
        let flag = MonthlyFinanceEngine.dusty(sub, state)
        HStack {
          VStack(alignment: .leading) {
            Text(sub.name).font(.headline)
            Text(
              sub.cancelledAt.map { "已取消 · " + MonthlyFinanceEngine.day($0, state) }
                ?? (sub.archived ? "已归档" : (flag ? "连续两个完整月使用较少，可复盘是否续费" : use.label))
            ).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("评价与历史") { review = sub }
        }
      }
    }.sheet(item: $review) { sub in
      MonthlyFinanceReviewEditor(subscription: sub, state: state).environment(
        \.timeZone, MonthlyFinanceEngine.calendar(state).timeZone)
    }
  }
  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.bold()).monospacedDigit()
    }
  }
}
private struct MonthlyFinanceReviewEditor: View {
  let subscription: MonthlyFinanceSubscription
  let prior: MonthlyFinanceState
  @ObservedObject private var store = MonthlyFinanceStore.shared
  @Environment(\.dismiss) private var dismiss
  @State private var date = Date()
  @State private var score: Int
  init(subscription: MonthlyFinanceSubscription, state: MonthlyFinanceState) {
    self.subscription = subscription
    self.prior = state
    _score = State(
      initialValue: state.reviews.first {
        $0.subscriptionID == subscription.id
          && $0.month == MonthlyFinanceEngine.month(Date(), state)
      }?.rating ?? -1)
  }
  private func title(_ n: Int) -> String { ["较少使用", "偶尔使用", "经常使用"][n] }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(subscription.name + " · 月度评价").font(.title2)
        Spacer()
        Button("关闭") { dismiss() }
      }
      DatePicker("评价月份", selection: $date, in: ...Date(), displayedComponents: .date).onChange(
        of: date
      ) { _, new in
        score =
          prior.reviews.first {
            $0.subscriptionID == subscription.id
              && $0.month == MonthlyFinanceEngine.month(new, prior)
          }?.rating ?? -1
      }
      Picker("使用频率", selection: $score) {
        Text("无评价").tag(-1)
        ForEach(0...2, id: \.self) { Text(title($0)).tag($0) }
      }
      Button("保存该月评价") {
        let key = MonthlyFinanceEngine.month(date, prior)
        let expected = prior.reviews.first {
          $0.subscriptionID == subscription.id && $0.month == key
        }
        if store.update({
          try MonthlyFinanceEngine.setReview(
            &$0, subscriptionID: subscription.id, month: date, score: score < 0 ? nil : score,
            expected: expected)
        }) {
          dismiss()
        }
      }.buttonStyle(.borderedProminent)
      Divider()
      Text("已保存的历史评价").font(.headline)
      let rows = prior.reviews.filter { $0.subscriptionID == subscription.id }.sorted {
        $0.month > $1.month
      }
      if rows.isEmpty {
        Text("尚无记录。").foregroundStyle(.secondary)
      } else {
        List(rows) { r in
          HStack {
            Text(r.month)
            Spacer()
            Text(title(r.rating))
          }
        }
      }
      if let p = store.problem { Text(p).foregroundStyle(.red) }
    }.padding(20).frame(minWidth: 440, minHeight: 350)
  }
}
