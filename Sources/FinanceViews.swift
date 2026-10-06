import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @Binding var selection: SavingsSection
    @State private var currency: SavingsCurrency = .CNY
    @State private var showingRecordEditor = false

    private var featuredGoal: SavingsGoal? {
        store.activeGoals.first { $0.currency == currency } ?? store.activeGoals.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Text("按币种查看").font(.callout).foregroundStyle(.secondary)
                    Picker("币种", selection: $currency) {
                        ForEach(SavingsCurrency.allCases) { value in
                            Text(value.rawValue).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Spacer()
                    Button {
                        showingRecordEditor = true
                    } label: {
                        Label("存下一笔，自动出击", systemImage: "bolt.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.activeGoals.isEmpty)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                    SavingsStatTile(
                        value: SavingsFormatters.money(store.total(currency: currency), currency: currency),
                        label: "当前总积蓄", symbol: "banknote.fill", color: SavingsTheme.teal
                    )
                    SavingsStatTile(
                        value: SavingsFormatters.money(store.depositedThisMonth(currency: currency), currency: currency),
                        label: "本月已存", symbol: "calendar", color: SavingsTheme.blue
                    )
                    SavingsStatTile(
                        value: SavingsFormatters.money(store.depositedToday(currency: currency), currency: currency),
                        label: "今日已存", symbol: "sun.max.fill", color: SavingsTheme.orange
                    )
                    SavingsStatTile(
                        value: "\(store.currentSavingStreak) 天",
                        label: "当前连续积蓄", symbol: "flame.fill", color: SavingsTheme.purple
                    )
                }

                HStack(alignment: .top, spacing: 16) {
                    featuredGoalCard
                    AdventureMiniCard { selection = .adventure }
                        .frame(maxWidth: .infinity)
                }

                HStack(alignment: .top, spacing: 16) {
                    recentRecordsCard
                    recentRewardsCard
                }
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .onAppear { currency = settings.defaultCurrency }
        .sheet(isPresented: $showingRecordEditor) {
            RecordEditorView(existingRecord: nil)
                .environmentObject(store)
                .environmentObject(settings)
        }
    }

    private var featuredGoalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当前目标").font(.headline)
                Spacer()
                Button("全部") { selection = .goals }.buttonStyle(.plain).foregroundStyle(SavingsTheme.blue)
            }
            if let goal = featuredGoal {
                let color = SavingsTheme.goalColor(goal.colorKey)
                HStack(spacing: 12) {
                    Image(systemName: goal.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color)
                        .frame(width: 42, height: 42)
                        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.title).font(.headline).lineLimit(1)
                        Text("截止 \(SavingsFormatters.shortDay.string(from: goal.deadline))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(store.progress(for: goal) * 100))%")
                        .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(color)
                }
                ProgressView(value: store.progress(for: goal)).tint(color)
                HStack {
                    Text(SavingsFormatters.money(store.balance(for: goal), currency: goal.currency))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text("目标 \(SavingsFormatters.money(goal.targetAmount, currency: goal.currency))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(goal.notes.isEmpty ? "每一笔积蓄，都会让勇者向前一步。" : goal.notes)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("当前币种还没有进行中的目标。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 135, alignment: .center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 225, alignment: .top)
        .savingsPanel()
    }

    private var recentRecordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近记录").font(.headline)
                Spacer()
                Button("全部") { selection = .records }.buttonStyle(.plain).foregroundStyle(SavingsTheme.blue)
            }
            if store.records.isEmpty {
                Text("还没有记录。存下第一笔，冒险就会开始。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ForEach(store.records.prefix(5)) { record in
                    CompactRecordRow(record: record)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
        .savingsPanel()
    }

    private var recentRewardsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近成长").font(.headline)
                Spacer()
                Text("Lv.\(store.adventure.level)").font(.callout.weight(.semibold)).foregroundStyle(SavingsTheme.green)
            }
            ForEach(store.rewardEvents.prefix(5)) { event in
                HStack(spacing: 10) {
                    Image(systemName: event.symbol)
                        .foregroundStyle(SavingsTheme.green)
                        .frame(width: 30, height: 30)
                        .background(SavingsTheme.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
        .savingsPanel()
    }
}

private struct GoalEditorContext: Identifiable {
    let id = UUID()
    let goal: SavingsGoal?
}

struct GoalsView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @State private var editorContext: GoalEditorContext?
    @State private var deleteCandidate: SavingsGoal?

    private var visibleGoals: [SavingsGoal] {
        store.goals.filter { $0.status != .archived }.sorted {
            if $0.status != $1.status { return $0.status == .active }
            return $0.deadline < $1.deadline
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    SavingsStatTile(value: "\(store.activeGoals.count)", label: "进行中目标", symbol: "target", color: SavingsTheme.blue)
                    SavingsStatTile(value: "\(store.goals.filter { $0.status == .completed }.count)", label: "已完成目标", symbol: "checkmark.seal.fill", color: SavingsTheme.green)
                    SavingsStatTile(value: "\(store.goals.filter { $0.status == .archived }.count)", label: "已归档目标", symbol: "archivebox.fill", color: SavingsTheme.purple)
                }

                HStack {
                    Text("全部目标").font(.headline)
                    Spacer()
                    Button {
                        editorContext = GoalEditorContext(goal: nil)
                    } label: {
                        Label("新建攒钱目标", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if visibleGoals.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "target").font(.system(size: 34)).foregroundStyle(SavingsTheme.blue)
                        Text("还没有攒钱目标").font(.title3.weight(.semibold))
                        Text("为真正想要的东西定一个金额和日期。").foregroundStyle(.secondary)
                        Button("创建第一个目标") { editorContext = GoalEditorContext(goal: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .savingsPanel(cornerRadius: 14)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)], spacing: 14) {
                        ForEach(visibleGoals) { goal in
                            GoalCard(goal: goal) {
                                editorContext = GoalEditorContext(goal: goal)
                            } togglePause: {
                                store.setGoalStatus(goal, status: goal.status == .paused ? .active : .paused)
                            } delete: {
                                deleteCandidate = goal
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(item: $editorContext) { context in
            GoalEditorView(goal: context.goal)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .confirmationDialog("处理这个目标？", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            if let goal = deleteCandidate {
                Button(store.records.contains(where: { $0.goalID == goal.id }) ? "归档目标" : "删除目标", role: .destructive) {
                    store.deleteGoal(goal); deleteCandidate = nil
                }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("已有积蓄记录的目标会被归档，不会破坏历史统计。")
        }
    }
}

private struct GoalCard: View {
    @EnvironmentObject private var store: SavingsStore
    let goal: SavingsGoal
    let edit: () -> Void
    let togglePause: () -> Void
    let delete: () -> Void

    var body: some View {
        let color = SavingsTheme.goalColor(goal.colorKey)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: goal.symbol)
                    .font(.title3.weight(.semibold)).foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title).font(.headline).lineLimit(1)
                    Text(goal.status.title).font(.caption.weight(.medium)).foregroundStyle(color)
                }
                Spacer()
                Menu {
                    Button("编辑", action: edit)
                    if goal.status == .active || goal.status == .paused {
                        Button(goal.status == .paused ? "继续目标" : "暂停目标", action: togglePause)
                    }
                    Button("删除或归档", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
            }

            ProgressView(value: store.progress(for: goal)).tint(color)

            HStack(alignment: .firstTextBaseline) {
                Text(SavingsFormatters.money(store.balance(for: goal), currency: goal.currency))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                Spacer()
                Text("/ \(SavingsFormatters.money(goal.targetAmount, currency: goal.currency))")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Label("\(Int(store.progress(for: goal) * 100))%", systemImage: "chart.bar.fill")
                Spacer()
                Label(SavingsFormatters.day.string(from: goal.deadline), systemImage: "calendar")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let account = store.account(goal.savingsAccountID) {
                Label("存钱罐·\(account.name)", systemImage: "arrow.left.arrow.right.circle.fill")
                    .font(.caption).foregroundStyle(SavingsTheme.teal)
            } else {
                Label("存钱罐账户将在首笔积蓄时选择", systemImage: "wallet.pass")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !goal.notes.isEmpty {
                Text(goal.notes).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 205, alignment: .top)
        .savingsPanel()
    }
}

struct RecordsView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @State private var showingNew = false
    @State private var editingRecord: SavingsRecord?
    @State private var deleteCandidate: SavingsRecord?
    @State private var kindFilter: SavingsRecordKind?

    private var filteredRecords: [SavingsRecord] {
        guard let kindFilter else { return store.records }
        return store.records.filter { $0.kind == kindFilter }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("类型", selection: $kindFilter) {
                    Text("全部记录").tag(Optional<SavingsRecordKind>.none)
                    ForEach(SavingsRecordKind.allCases) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
                .frame(width: 180)
                Spacer()
                Text("经验只由击杀怪物获得；取出不会扣除成长资源。")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    showingNew = true
                } label: {
                    Label("记一笔", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.activeGoals.isEmpty)
            }

            if filteredRecords.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 34)).foregroundStyle(SavingsTheme.blue)
                    Text("还没有积蓄记录").font(.title3.weight(.semibold))
                    Text("每积蓄 1 个货币单位奖励 1 张星券；完成目标额外奖励 100 张。")
                        .foregroundStyle(.secondary)
                    Button("记录第一笔") { showingNew = true }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .savingsPanel(cornerRadius: 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        SavingsTableHeader()
                        ForEach(filteredRecords) { record in
                            SavingsTableRow(record: record) {
                                editingRecord = record
                            } delete: {
                                deleteCandidate = record
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: 1080)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .sheet(isPresented: $showingNew) {
            RecordEditorView(existingRecord: nil)
                .environmentObject(store).environmentObject(settings)
        }
        .sheet(item: $editingRecord) { record in
            RecordEditorView(existingRecord: record)
                .environmentObject(store).environmentObject(settings)
        }
        .confirmationDialog("删除这条记录？", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }
        ), titleVisibility: .visible) {
            if let record = deleteCandidate {
                Button("删除记录", role: .destructive) { store.deleteRecord(record); deleteCandidate = nil }
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("记录会从目标和统计中移除；已经获得的游戏成长不会被扣除。")
        }
    }
}

private struct SavingsTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("日期").frame(width: 72, alignment: .leading)
            Text("类型").frame(width: 82, alignment: .leading)
            Text("目标 / 账户").frame(width: 235, alignment: .leading)
            Text("分类 / 备注")
            Spacer(minLength: 12)
            Text("金额").frame(width: 122, alignment: .trailing)
            Text("").frame(width: 26)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SavingsTableRow: View {
    @EnvironmentObject private var store: SavingsStore
    let record: SavingsRecord
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        let goal = store.goal(for: record.goalID)
        let color = record.kind == .deposit ? SavingsTheme.teal : SavingsTheme.orange
        HStack(spacing: 12) {
            Text(SavingsFormatters.shortDay.string(from: record.date))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Label(record.kind.shortTitle, systemImage: record.kind.symbol)
                .font(.callout.weight(.medium)).foregroundStyle(color)
                .frame(width: 82, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(goal?.title ?? "已删除的目标").font(.callout.weight(.medium)).lineLimit(1)
                if let route = accountRoute { Text(route).font(.caption2).foregroundStyle(SavingsTheme.blue).lineLimit(1) }
            }
            .frame(width: 235, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.category.title).font(.callout).lineLimit(1)
                if !record.note.isEmpty { Text(record.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(SavingsFormatters.money(record.kind == .deposit ? record.amount : -record.amount,
                                             currency: recordCurrency, signed: true))
                    .font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(color)
                Text(recordCurrency.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 122, alignment: .trailing)
            Menu {
                Button("编辑", action: edit)
                Button("删除", role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            Button("编辑", action: edit)
            Button("删除", role: .destructive, action: delete)
        }
        .overlay(alignment: .bottom) { Divider().opacity(0.55) }
    }

    /// 记录币种：优先用记录自身的冗余币种字段（V2.3 已回填），旧档缺失时回退目标币种。
    private var recordCurrency: SavingsCurrency {
        SavingsCurrency(rawValue: record.currency) ?? store.goal(for: record.goalID)?.currency ?? .CNY
    }

    private var accountRoute: String? {
        guard let funding = store.account(record.fundingAccountID), let savings = store.account(record.savingsAccountID) else { return nil }
        return record.kind == .deposit ? "\(funding.name) → \(savings.name)" : "\(savings.name) → \(funding.name)"
    }
}

struct CompactRecordRow: View {
    @EnvironmentObject private var store: SavingsStore
    let record: SavingsRecord

    var body: some View {
        let goal = store.goal(for: record.goalID)
        let color = record.kind == .deposit ? SavingsTheme.teal : SavingsTheme.orange
        HStack(spacing: 10) {
            Image(systemName: record.category.symbol).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.note.isEmpty ? record.category.title : record.note).font(.callout).lineLimit(1)
                Text(goal?.title ?? "历史目标").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(SavingsFormatters.money(
                record.kind == .deposit ? record.amount : -record.amount,
                currency: goal?.currency ?? .CNY, signed: true
            ))
            .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }
}

struct AnalyticsView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @State private var currency: SavingsCurrency = .CNY

    private var months: [(Date, Double)] { store.monthlyDeposits(currency: currency) }
    private var maxMonth: Double { max(1, months.map(\.1).max() ?? 1) }
    private var average: Double { months.isEmpty ? 0 : months.map(\.1).reduce(0, +) / Double(months.count) }
    private var featuredGoal: SavingsGoal? { store.activeGoals.first { $0.currency == currency } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Picker("统计币种", selection: $currency) {
                        ForEach(SavingsCurrency.allCases) { value in Text(value.displayName).tag(value) }
                    }
                    .frame(width: 220)
                    Spacer()
                    Text("不同币种不按未知汇率合并，保证统计真实。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    SavingsStatTile(value: SavingsFormatters.money(average, currency: currency), label: "近六月月均存入", symbol: "chart.bar.fill", color: SavingsTheme.blue)
                    SavingsStatTile(value: "\(store.savingDayCount) 天", label: "累计积蓄天数", symbol: "calendar.badge.checkmark", color: SavingsTheme.teal)
                    SavingsStatTile(value: "\(store.currentSavingStreak) 天", label: "当前连续天数", symbol: "flame.fill", color: SavingsTheme.orange)
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("近六个月存入趋势").font(.headline)
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(Array(months.enumerated()), id: \.offset) { _, item in
                            VStack(spacing: 7) {
                                Text(SavingsFormatters.money(item.1, currency: currency))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(SavingsTheme.blue.gradient)
                                    .frame(height: max(4, 150 * item.1 / maxMonth))
                                Text(monthLabel(item.0)).font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 205, alignment: .bottom)
                }
                .padding(18)
                .savingsPanel()

                HStack(alignment: .top, spacing: 16) {
                    savingsCalendar
                    predictionCard
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .onAppear { currency = settings.defaultCurrency }
    }

    private var savingsCalendar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近 35 天积蓄日历").font(.headline)
            let days = recentDays(35)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 7), spacing: 7) {
                ForEach(days, id: \.self) { day in
                    let amount = deposit(on: day)
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(amount > 0 ? SavingsTheme.teal.opacity(min(1, 0.35 + amount / max(1, maxDayDeposit()) * 0.65)) : Color.secondary.opacity(0.1))
                            .frame(height: 26)
                        Text("\(Calendar.current.component(.day, from: day))").font(.caption2).foregroundStyle(.secondary)
                    }
                    .help(amount > 0 ? "\(SavingsFormatters.day.string(from: day))：\(SavingsFormatters.money(amount, currency: currency))" : SavingsFormatters.day.string(from: day))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
        .savingsPanel()
    }

    private var predictionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目标预测").font(.headline)
            if let goal = featuredGoal {
                let remaining = max(0, goal.targetAmount - store.balance(for: goal))
                let monthsNeeded = average > 0 ? Int(ceil(remaining / average)) : 0
                Label(goal.title, systemImage: goal.symbol).font(.title3.weight(.semibold))
                if remaining <= 0 {
                    Text("已完成🎉").font(.callout.weight(.semibold)).foregroundStyle(SavingsTheme.green)
                } else {
                    Text("还差 \(SavingsFormatters.money(remaining, currency: currency))")
                        .font(.callout).foregroundStyle(.secondary)
                    if average > 0 {
                        Text("按近六个月平均速度，预计还需要约 \(monthsNeeded) 个月。")
                            .font(.callout)
                    } else {
                        Text("积累更多记录后，这里会估算完成时间。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: store.progress(for: goal)).tint(SavingsTheme.purple)
            } else {
                Text("该币种暂无进行中的目标。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .top)
        .savingsPanel()
    }

    private func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "M月"; return formatter.string(from: date)
    }
    private func recentDays(_ count: Int) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
    }
    private func deposit(on day: Date) -> Double {
        store.records.filter { record in
            record.kind == .deposit && Calendar.current.isDate(record.date, inSameDayAs: day) &&
            store.goal(for: record.goalID)?.currency == currency
        }.reduce(0) { $0 + $1.amount }
    }
    private func maxDayDeposit() -> Double { max(1, recentDays(35).map(deposit).max() ?? 1) }
}

struct GoalEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal?

    @State private var title: String
    @State private var targetAmount: Double
    @State private var startingAmount: Double
    @State private var currency: SavingsCurrency
    @State private var deadline: Date
    @State private var symbol: String
    @State private var colorKey: String
    @State private var notes: String
    @State private var savingsAccountID: String

    private let symbols = ["flag.checkered", "airplane", "laptopcomputer", "house.fill", "car.fill", "cross.case.fill", "graduationcap.fill", "gift.fill", "star.fill", "camera.fill"]
    private let colors = ["blue", "teal", "green", "orange", "purple", "red"]

    init(goal: SavingsGoal?) {
        self.goal = goal
        _title = State(initialValue: goal?.title ?? "")
        _targetAmount = State(initialValue: goal?.targetAmount ?? 10_000)
        _startingAmount = State(initialValue: goal?.startingAmount ?? 0)
        _currency = State(initialValue: goal?.currency ?? .CNY)
        _deadline = State(initialValue: goal?.deadline ?? Calendar.current.date(byAdding: .month, value: 6, to: Date())!)
        _symbol = State(initialValue: goal?.symbol ?? "flag.checkered")
        _colorKey = State(initialValue: goal?.colorKey ?? "blue")
        _notes = State(initialValue: goal?.notes ?? "")
        _savingsAccountID = State(initialValue: goal?.savingsAccountID ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal == nil ? "新建攒钱目标" : "编辑攒钱目标").font(.title2.weight(.semibold))
                    Text("绑定存钱罐账户后，积蓄记录会同步生成资产转账。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { saveAndDismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || targetAmount <= 0)
            }
            .padding(22)
            Divider()
            Form {
                TextField("目标名称", text: $title)
                Picker("币种", selection: $currency) {
                    ForEach(SavingsCurrency.allCases) { value in Text(value.displayName).tag(value) }
                }
                TextField("目标金额", value: $targetAmount, format: .number)
                TextField("已有金额", value: $startingAmount, format: .number)
                Picker("存钱罐账户", selection: $savingsAccountID) {
                    Text("记录时选择").tag("")
                    ForEach(store.activeAccounts.filter { $0.currency == currency }) { account in
                        Text("\(account.name) · \(SavingsFormatters.money(store.accountBalance(account), currency: account.currency))").tag(account.id)
                    }
                }
                DatePicker("计划完成日期", selection: $deadline, displayedComponents: .date)
                Picker("图标", selection: $symbol) {
                    ForEach(symbols, id: \.self) { value in Label(value, systemImage: value).tag(value) }
                }
                Picker("颜色", selection: $colorKey) {
                    ForEach(colors, id: \.self) { value in
                        HStack { Circle().fill(SavingsTheme.goalColor(value)).frame(width: 10, height: 10); Text(value) }.tag(value)
                    }
                }
                TextField("为什么想攒下这笔钱（可选）", text: $notes, axis: .vertical).lineLimit(3...5)
            }
            .formStyle(.grouped)
            .padding(18)
        }
        .frame(width: 570, height: 610)
        .onAppear { if goal == nil { currency = settings.defaultCurrency } }
        .onChange(of: currency) { _, _ in
            if store.account(savingsAccountID)?.currency != currency { savingsAccountID = "" }
        }
    }

    private func saveAndDismiss() {
        guard targetAmount > 0, startingAmount >= 0 else { return }
        store.saveGoal(
            existingID: goal?.id, title: title, targetAmount: targetAmount,
            startingAmount: startingAmount, currency: currency, deadline: deadline,
            symbol: symbol, colorKey: colorKey, notes: notes,
            savingsAccountID: savingsAccountID.isEmpty ? nil : savingsAccountID
        )
        dismiss()
    }
}

struct RecordEditorView: View {
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @Environment(\.dismiss) private var dismiss
    let existingRecord: SavingsRecord?

    @State private var goalID: String
    @State private var kind: SavingsRecordKind
    @State private var amount: Double
    @State private var date: Date
    @State private var category: SavingsCategory
    @State private var note: String
    @State private var fundingAccountID: String
    @State private var savingsAccountID: String

    init(existingRecord: SavingsRecord?) {
        self.existingRecord = existingRecord
        _goalID = State(initialValue: existingRecord?.goalID ?? "")
        _kind = State(initialValue: existingRecord?.kind ?? .deposit)
        // 新建时金额留 0 占位：保存按钮在金额 ≤ 0 时禁用，强制用户输入真实金额。
        _amount = State(initialValue: existingRecord?.amount ?? 0)
        _date = State(initialValue: existingRecord?.date ?? Date())
        _category = State(initialValue: existingRecord?.category ?? .scheduled)
        _note = State(initialValue: existingRecord?.note ?? "")
        _fundingAccountID = State(initialValue: existingRecord?.fundingAccountID ?? "")
        _savingsAccountID = State(initialValue: existingRecord?.savingsAccountID ?? "")
    }

    private var selectableGoals: [SavingsGoal] {
        var values = store.activeGoals
        if let existingRecord, let old = store.goal(for: existingRecord.goalID), !values.contains(old) { values.append(old) }
        return values
    }

    private var selectedGoal: SavingsGoal? { store.goal(for: goalID) }
    private var matchingAccounts: [LedgerAccount] {
        guard let goal = selectedGoal else { return [] }
        return store.activeAccounts.filter { $0.currency == goal.currency }
    }
    private var fundingAccounts: [LedgerAccount] { matchingAccounts.filter { $0.id != savingsAccountID } }
    private var savingsAccounts: [LedgerAccount] { matchingAccounts.filter { $0.id != fundingAccountID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(existingRecord == nil ? "记一笔积蓄" : "编辑积蓄记录").font(.title2.weight(.semibold))
                    Text(kind == .deposit ? "从资金账户转入目标存钱罐，并按金额发放星券。" : "从目标存钱罐转回指定账户，不计入日常收支。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { saveAndDismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(goalID.isEmpty || amount <= 0 || fundingAccountID.isEmpty || savingsAccountID.isEmpty)
            }
            .padding(22)
            Divider()
            Form {
                Picker("类型", selection: $kind) {
                    ForEach(SavingsRecordKind.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.segmented)
                Picker("所属目标", selection: $goalID) {
                    ForEach(selectableGoals) { goal in
                        Text("\(goal.title) · \(goal.currency.rawValue)").tag(goal.id)
                    }
                }
                HStack {
                    Text(selectedGoal?.currency.symbol ?? settings.defaultCurrency.symbol)
                        .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("金额", value: $amount, format: .number).font(.title2.monospacedDigit())
                }
                Picker(kind == .deposit ? "转出账户" : "转入账户", selection: $fundingAccountID) {
                    Text("请选择").tag("")
                    ForEach(fundingAccounts) { account in
                        Text("\(account.name) · \(SavingsFormatters.money(store.accountBalance(account), currency: account.currency))").tag(account.id)
                    }
                }
                Picker("目标存钱罐", selection: $savingsAccountID) {
                    Text("请选择").tag("")
                    ForEach(savingsAccounts) { account in
                        Text("\(account.name) · \(SavingsFormatters.money(store.accountBalance(account), currency: account.currency))").tag(account.id)
                    }
                }
                if matchingAccounts.count < 2 {
                    Label("请先在资产账户中创建至少两个与目标同币种的账户。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(SavingsTheme.orange)
                }
                if kind == .withdrawal, let goal = selectedGoal {
                    LabeledContent("当前可用", value: SavingsFormatters.money(store.balance(for: goal), currency: goal.currency))
                }
                Picker("来源分类", selection: $category) {
                    ForEach(SavingsCategory.allCases) { value in Label(value.title, systemImage: value.symbol).tag(value) }
                }
                DatePicker("日期", selection: $date, displayedComponents: .date)
                TextField("备注（可选）", text: $note, axis: .vertical).lineLimit(2...4)
            }
            .formStyle(.grouped)
            .padding(18)
        }
        .frame(width: 580, height: 650)
        .onAppear {
            if goalID.isEmpty { goalID = selectableGoals.first?.id ?? "" }
            syncAccounts()
        }
        .onChange(of: goalID) { _, _ in syncAccounts() }
    }

    private func saveAndDismiss() {
        guard amount > 0, !goalID.isEmpty else { return }
        if kind == .withdrawal, let goal = selectedGoal, existingRecord == nil, amount > store.balance(for: goal) {
            store.notice = "取出金额不能超过该目标的可用积蓄。"; return
        }
        let saved = store.saveRecord(
            existingID: existingRecord?.id, goalID: goalID, kind: kind,
            amount: amount, date: date, category: category, note: note,
            fundingAccountID: fundingAccountID, savingsAccountID: savingsAccountID
        )
        if saved { dismiss() }
    }

    private func syncAccounts() {
        let preferredSavingsID = existingRecord?.goalID == goalID ? existingRecord?.savingsAccountID : selectedGoal?.savingsAccountID
        if let preferredSavingsID, matchingAccounts.contains(where: { $0.id == preferredSavingsID }) { savingsAccountID = preferredSavingsID }
        else if !matchingAccounts.contains(where: { $0.id == savingsAccountID }) { savingsAccountID = matchingAccounts.last?.id ?? "" }
        if !matchingAccounts.contains(where: { $0.id == fundingAccountID && $0.id != savingsAccountID }) {
            fundingAccountID = matchingAccounts.first(where: { $0.id != savingsAccountID })?.id ?? ""
        }
    }
}
