import AppKit
import SwiftUI

struct ResearchFundingView: View {
  @StateObject private var store = ResearchFundingStore()
  let recordID: String?
  @State private var trash = false
  @State private var query = ""
  @State private var editor: EditorRequest?
  @State private var trashDetails: ResearchFundingTrashItem?
  @State private var destructive: Deletion?
  @State private var alert: String?
  init(recordID: String? = nil) { self.recordID = recordID }
  private struct EditorRequest: Identifiable {
    let id = UUID()
    let record: ResearchFundingRecord?
  }
  private struct Deletion: Identifiable {
    let id: String
    let permanent: Bool
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("科研资金").font(.title2.bold())
          Text("按发放年份和月份查看资金计划；只有实际到账才应记入个人账本。").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.reload()
        } label: {
          Label("重新读取", systemImage: "arrow.clockwise")
        }
        if store.access == .ready {
          Button {
            editor = .init(record: nil)
          } label: {
            Label("新建计划", systemImage: "plus")
          }.buttonStyle(.borderedProminent)
        }
      }
      if store.access == .ready, let lib = store.library {
        HStack(alignment: .top, spacing: 12) {
          ForEach(-1...1, id: \.self) { offset in monthOverview(lib, offset: offset) }
        }
        HStack {
          Picker("查看", selection: $trash) {
            Text("发放计划 (\(lib.fundingRecords.count))").tag(false)
            Text("回收站 (\(lib.trashItems.count))").tag(true)
          }.pickerStyle(.segmented).frame(maxWidth: 290)
          Spacer()
          TextField("搜索名称、年份、月份或收款账户", text: $query).textFieldStyle(.roundedBorder).frame(
            maxWidth: 310)
        }
        if trash { trashList(lib) } else { activeList(lib) }
      } else if store.access == .mayCreate {
        ContentUnavailableView {
          Label("尚未创建科研资金库", systemImage: "tray")
        } description: {
          Text("已确认是新资料环境，可从空白资金库开始。")
        } actions: {
          Button("创建空白资金库") { act { try store.initializeNew() } }
        }
      } else if store.access == .awaitingAuthority {
        ContentUnavailableView {
          Label("科研资金尚未启用", systemImage: "tray.and.arrow.down")
        } description: {
          Text("已有搞研究资料需先迁移。如果是首次使用，可以检查并创建新的空白资金库。")
        } actions: {
          Button("检查并创建新资金库") { act { try store.requestNewLibrary() } }
        }
      } else {
        ContentUnavailableView {
          Label(
            store.access == .protected ? "科研资金暂不可写" : "科研资金尚未启用",
            systemImage: store.access == .protected ? "lock.shield" : "tray.and.arrow.down")
        } description: {
          Text(store.message ?? "等待科研资金迁移或新资料库启用。现有个人账本不受影响。")
        }
      }
    }
    .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      store.reload()
      followRoute()
    }.onChange(of: recordID) { _, _ in followRoute() }
    .sheet(item: $editor) { ResearchFundingEditor(store: store, record: $0.record) }
    .sheet(item: $trashDetails) { item in
      VStack(alignment: .leading, spacing: 12) {
        Text(item.funding.name).font(.title2.bold())
        Text("已移入回收站，不计入发放计划。").foregroundStyle(.secondary)
        LabeledContent(
          "金额", value: "\(item.funding.currency ?? "CNY（旧资料显示口径）") \(item.funding.amount)")
        LabeledContent(
          "发放时间",
          value:
            "\(String(item.funding.year)) · \(item.funding.months.map(String.init).joined(separator:"、")) 月"
        )
        LabeledContent("收款账户说明", value: item.funding.receivingAccount)
        if let project = item.funding.projectReference { LabeledContent("关联项目", value: project) }
        if let when = ResearchFundingFormat.date(item.deletedAt) {
          LabeledContent("删除时间", value: when.formatted())
        }
        HStack {
          Spacer()
          Button("关闭") { trashDetails = nil }.keyboardShortcut(.cancelAction)
        }
      }.padding(22).frame(minWidth: 440)
    }
    .alert("科研资金", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
      Button("知道了") {}
    } message: {
      Text(alert ?? "")
    }
    .confirmationDialog(
      destructive?.permanent == true ? "永久删除这条科研资金及其附件？" : "将这条资金计划移入回收站？",
      isPresented: Binding(get: { destructive != nil }, set: { if !$0 { destructive = nil } }),
      presenting: destructive
    ) { op in
      Button(op.permanent ? "永久删除" : "移入回收站", role: .destructive) {
        act {
          if op.permanent {
            try store.permanentlyDelete(op.id)
          } else {
            try store.moveToTrash(op.id)
          }
        }
        destructive = nil
      }
      Button("取消", role: .cancel) { destructive = nil }
    } message: { op in
      Text(op.permanent ? "永久删除无法在本应用中撤销。" : "该项将不再计入计划汇总，可在回收站恢复。")
    }
  }
  private func act(_ block: () throws -> Void) {
    do {
      try block()
      if let msg = store.message { alert = msg }
    } catch {
      alert = error.localizedDescription
      store.reload()
    }
  }
  private func followRoute() {
    guard let recordID, store.access == .ready, let l = store.library else { return }
    if let r = l.fundingRecords.first(where: { $0.id == recordID }) {
      trash = false
      editor = .init(record: r)
    } else if let removed = l.trashItems.first(where: { $0.funding.id == recordID }) {
      trash = true
      query = ""
      trashDetails = removed
    } else {
      alert = "当前科研资金库没有找到这条原记录。"
    }
  }
  private func matches(_ r: ResearchFundingRecord) -> Bool {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return q.isEmpty
      || [
        r.name, r.receivingAccount, String(r.year),
        r.months.map(String.init).joined(separator: " "), r.projectReference ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(q) }
  }
  private func monthOverview(_ lib: ResearchFundingLibrary, offset: Int) -> some View {
    let date = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
    let c = Calendar.current.dateComponents([.year, .month], from: date)
    let plans = lib.fundingRecords.filter { r in c.year == r.year && r.months.contains(c.month ?? 0)
    }
    let totals = Dictionary(grouping: plans, by: { $0.currency ?? "CNY" }).mapValues {
      $0.reduce(0) { $0 + $1.amount }
    }
    return VStack(alignment: .leading, spacing: 5) {
      Text(date.formatted(.dateTime.year().month())).font(.caption).foregroundStyle(.secondary)
      if totals.isEmpty {
        Text("无发放安排").font(.callout)
      } else {
        ForEach(totals.keys.sorted(), id: \.self) { c in
          Text("\(c) \(totals[c] ?? 0, format:.number.precision(.fractionLength(0...8)))").font(
            .headline
          ).monospacedDigit()
        }
      }
      Text("\(plans.count) 项计划").font(.caption2).foregroundStyle(.secondary)
      if plans.contains(where: { $0.currency == nil }) {
        Text("旧资料沿用人民币显示口径").font(.caption2).foregroundStyle(.secondary)
      }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
      .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
  }
  private func activeList(_ lib: ResearchFundingLibrary) -> some View {
    let visible = lib.fundingRecords.filter(matches).sorted {
      $0.year != $1.year
        ? $0.year > $1.year
        : ($0.name != $1.name
          ? $0.name.localizedCompare($1.name) == .orderedAscending : $0.id < $1.id)
    }
    return Group {
      if visible.isEmpty {
        ContentUnavailableView("没有匹配的资金计划", systemImage: "calendar")
      } else {
        List(visible) { row in
          HStack {
            VStack(alignment: .leading) {
              Text(row.name).font(.headline)
              Text(
                "\(String(row.year)) · \(row.months.map(String.init).joined(separator:"、")) 月 · \(row.receivingAccount)"
              ).foregroundStyle(.secondary)
            }
            Spacer()
            Text(
              "\(row.currency ?? "CNY（旧口径）") \(row.amount, format:.number.precision(.fractionLength(0...8)))"
            ).monospacedDigit()
            Button("编辑") { editor = .init(record: row) }
            Button("删除", role: .destructive) {
              destructive = Deletion(id: row.id, permanent: false)
            }
          }.padding(.vertical, 4)
        }
      }
    }
  }
  private func trashList(_ lib: ResearchFundingLibrary) -> some View {
    let visible = lib.trashItems.filter { matches($0.funding) }.sorted {
      (ResearchFundingFormat.date($0.deletedAt) ?? .distantPast)
        > (ResearchFundingFormat.date($1.deletedAt) ?? .distantPast)
    }
    return Group {
      if visible.isEmpty {
        ContentUnavailableView("回收站没有匹配的记录", systemImage: "trash")
      } else {
        List(visible) { t in
          HStack {
            VStack(alignment: .leading) {
              Text(t.title)
              if let d = ResearchFundingFormat.date(t.deletedAt) {
                Text(d.formatted()).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button("查看") { trashDetails = t }
            Button("恢复") { act { try store.restore(t.id) } }
            Button("永久删除", role: .destructive) { destructive = Deletion(id: t.id, permanent: true) }
          }.padding(.vertical, 4)
        }
      }
    }
  }
}

private struct ResearchFundingEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: ResearchFundingStore
  let record: ResearchFundingRecord?
  @State private var name: String
  @State private var amount: String
  @State private var account: String
  @State private var currency: String
  @State private var project: String
  @State private var year: Int
  @State private var months: Set<Int>
  @State private var error: String?
  init(store: ResearchFundingStore, record: ResearchFundingRecord?) {
    self.store = store
    self.record = record
    _name = State(initialValue: record?.name ?? "")
    _amount = State(initialValue: record.map { String($0.amount) } ?? "")
    _account = State(initialValue: record?.receivingAccount ?? "")
    _currency = State(initialValue: record.map { $0.currency ?? "" } ?? "CNY")
    _year = State(initialValue: record?.year ?? Calendar.current.component(.year, from: Date()))
    _months = State(initialValue: Set(record?.months ?? Array(1...12)))
    _project = State(initialValue: record?.projectReference ?? "")
  }
  var body: some View {
    WorkbenchEditorScaffold(
      title: record == nil ? "新建科研资金计划" : "编辑科研资金计划",
      subtitle: "科研资金独立管理，不并入个人净资产。"
    ) {
      WorkbenchFormSection("资金信息") {
        TextField("资金名称", text: $name).textFieldStyle(.roundedBorder)
        TextField("每个发放月份的金额", text: $amount).textFieldStyle(.roundedBorder)
          .font(.title3.monospacedDigit())
        TextField("币种", text: $currency, prompt: Text("原界面按 CNY 显示")).textFieldStyle(.roundedBorder)
        TextField("收款账户说明", text: $account).textFieldStyle(.roundedBorder)
        TextField("明确关联的项目标识（选填）", text: $project).textFieldStyle(.roundedBorder)
        Stepper(
          "适用年份：\(String(year))", value: $year,
          in: min(2000, record?.year ?? 2000)...max(2100, record?.year ?? 2100))
      }
      WorkbenchFormSection("发放月份") {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
          ForEach(1...12, id: \.self) { m in
            Toggle(
              "\(m) 月",
              isOn: Binding(
                get: { months.contains(m) },
                set: { if $0 { months.insert(m) } else { months.remove(m) } })
            ).toggleStyle(.checkbox)
          }
        }
      }
      if let record {
        let attachments = store.library?.attachments.filter { $0.fundingID == record.id } ?? []
        if !attachments.isEmpty {
          WorkbenchFormSection("关联附件") {
            ForEach(attachments) { a in
              Button(a.relativePath) {
                do {
                  let url = try store.attachmentURL(a.id)
                  guard NSWorkspace.shared.open(url) else { throw ResearchFundingError.unavailable }
                } catch { self.error = error.localizedDescription }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    } actions: {
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("保存") { save() }.buttonStyle(.borderedProminent).tint(SavingsTheme.accent).keyboardShortcut(.defaultAction)
    }
    .frame(minWidth: 590, idealWidth: 630, minHeight: 650)
  }
  private func save() {
    guard let a = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)), a.isFinite, a > 0
    else {
      error = "请填写有效的正金额。"
      return
    }
    do {
      let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try store.save(
        id: record?.id, name: name, amount: a, year: year, months: Array(months),
        receivingAccount: account, currency: code.isEmpty ? nil : code,
        projectReference: project.isEmpty ? nil : project)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
