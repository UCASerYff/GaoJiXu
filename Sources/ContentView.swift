import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// 菜单栏 Commands 与 ContentView 之间的统一通信通道（GaoJiXuApp 发布，ContentView 订阅）。
/// 后续如需「从 CSV 导出流水」等新命令，照此模式新增常量即可。
extension Notification.Name {
    /// 打开「记一笔账」编辑器。
    static let gaojixuNewLedgerEntry = Notification.Name("gaojixu.newLedgerEntry")
    /// 打开「分配一笔积蓄」编辑器。
    static let gaojixuNewSavingsRecord = Notification.Name("gaojixu.newSavingsRecord")
    /// 弹出导出完整备份面板。
    static let gaojixuExportBackup = Notification.Name("gaojixu.exportBackup")
    /// 弹出导出流水 CSV 面板。
    static let gaojixuExportCSV = Notification.Name("gaojixu.exportCSV")
    /// 弹出从 CSV 导入流水流程（含预览确认）。
    static let gaojixuImportCSV = Notification.Name("gaojixu.importCSV")
    /// 弹出从备份恢复流程（含覆盖确认）。
    static let gaojixuRestoreBackup = Notification.Name("gaojixu.restoreBackup")
    /// 切换侧栏板块；userInfo["section"] 为 SavingsSection.rawValue。
    static let gaojixuSelectSection = Notification.Name("gaojixu.selectSection")
}

struct ContentView: View {
    var route: URL? = nil
    var routeRevision: Int = 0
    @State private var handledRouteRevision = 0
    @EnvironmentObject private var store: SavingsStore
    @EnvironmentObject private var settings: SavingsSettings
    @Environment(\.colorScheme) private var colorScheme
    @SceneStorage("gqns.page.Savings") private var selection: SavingsSection = .overview
    /// 侧栏隐藏/显示（场景级记忆；键全 app 唯一）。只有 隐藏↔显示 两态，无「收起成图标栏」。
    @SceneStorage("gqns.sidebarHidden.savings") private var sidebarHidden = false
    /// 自绘侧栏导航行的 hover 跟踪（浅灰反馈，与词元一致）。
    @State private var hoveredSection: SavingsSection?
    @State private var showingRecordEditor = false
    @State private var showingLedgerEditor = false
    @State private var restoreCandidateURL: URL?
    @State private var csvImportContext: CSVImportContext?
    /// 订阅 app 级语言键：值变化时整个模块重渲染（.id 见 body）。
    @AppStorage(GQNSLanguage.key) private var appLanguage = "system"


    var body: some View {
        // 侧栏重设计（对齐词元 2.2/2.3 标杆）：弃用系统 NavigationSplitView 列表侧栏，
        // 改 HStack 自绘——品牌头部 + 浮动卡片选中态导航行 + hover 反馈 + 状态底卡。
        // 统一工具栏契约：.navigation 恰好一个 28×28 侧栏切换按钮（⌃⌘S）；
        // 原有 trailing 按钮全部保留，包在固定宽 360 的右对齐容器里。
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebar
                // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            }
            ZStack {
                settings.canvasColor(for: colorScheme).ignoresSafeArea()
                VStack(spacing: 0) {
                    SavingsSectionHeader(section: selection)
                    detail
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .animation(.easeInOut(duration: 0.22), value: sidebarHidden)
        // app 级语言切换时整体重建；locale 注入供系统控件（日期/数字格式）跟随。
        .id(appLanguage)
        .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
        .toolbar {
            toolbarItemNoChrome(.navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarHidden.toggle() }
                } label: {
                    SidebarToggleIcon()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarHidden ? tS("显示侧边栏", "Show Sidebar") : tS("隐藏侧边栏", "Hide Sidebar"))
            }
            toolbarItemNoChrome(.primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        showingLedgerEditor = true
                    } label: {
                        Label(tS("记一笔账", "New Entry"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(ToolbarProminentStyle())

                    Menu {
                        Button { showingLedgerEditor = true } label: { Label(tS("记录收支或转账", "Record income, expense or transfer"), systemImage: "square.and.pencil") }
                        Button { showingRecordEditor = true } label: { Label(tS("分配一笔积蓄", "Allocate savings"), systemImage: "target") }
                            .disabled(store.activeGoals.isEmpty)
                    } label: { Label(tS("更多记录", "More"), systemImage: "plus.circle") }
                }
                .frame(width: 360, alignment: .trailing)
            }
        }
        .sheet(isPresented: $showingRecordEditor) {
            RecordEditorView(existingRecord: nil)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showingLedgerEditor) {
            LedgerEntryEditorView(existingEntry: nil)
                .environmentObject(store)
        }
        .sheet(item: $csvImportContext) { context in
            CSVImportPreviewView(context: context)
                .environmentObject(store)
        }
        .alert(tS("搞积蓄", "Gao Savings"), isPresented: Binding(
            get: { store.notice != nil },
            set: { if !$0 { store.notice = nil } }
        )) {
            Button(tS("知道了", "OK")) { store.notice = nil }
        } message: {
            Text(store.notice ?? "")
        }
        .confirmationDialog(
            tS("从备份恢复？", "Restore from backup?"),
            isPresented: Binding(
                get: { restoreCandidateURL != nil },
                set: { if !$0 { restoreCandidateURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(tS("覆盖并恢复", "Overwrite and Restore"), role: .destructive) {
                if let url = restoreCandidateURL {
                    restoreCandidateURL = nil
                    performRestore(from: url)
                }
            }
            Button(tS("取消", "Cancel"), role: .cancel) { restoreCandidateURL = nil }
        } message: {
            Text(tS("将用备份“\(restoreCandidateURL?.lastPathComponent ?? "")”覆盖当前全部数据，包括流水、账户、目标与冒险进度。此操作不可撤销，建议先导出一份当前备份。",
                    "The backup “\(restoreCandidateURL?.lastPathComponent ?? "")” will replace all current data — transactions, accounts, goals and adventure progress. This cannot be undone; consider exporting a current backup first."))
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuNewLedgerEntry)) { _ in
            showingLedgerEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuNewSavingsRecord)) { _ in
            guard !store.activeGoals.isEmpty else {
                store.notice = tS("还没有进行中的攒钱目标，请先在「攒钱目标」中创建一个目标。",
                                  "No active savings goal yet — create one in Goals first.")
                return
            }
            showingRecordEditor = true
        }
        // 联动①：月供扣款自动记账（静默写入，防重与写入细节见 store.recordAutoLedgerEntry）。
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("gaojixu.autoLedgerEntry"))) { note in
            guard let info = note.userInfo,
                  let paymentID = info["paymentID"] as? String,
                  let title = info["title"] as? String,
                  let amount = info["amount"] as? Double,
                  let currency = info["currency"] as? String,
                  let date = info["date"] as? Date else { return }
            store.recordAutoLedgerEntry(paymentID: paymentID, title: title, amount: amount, currency: currency, date: date)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuExportBackup)) { _ in
            exportBackup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuExportCSV)) { _ in
            exportLedgerCSV()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuImportCSV)) { _ in
            importLedgerCSV()
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuRestoreBackup)) { _ in
            restoreBackup()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.savings.game"))) { _ in selection = .adventure }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuSelectSection)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = SavingsSection(rawValue: rawValue) else { return }
            selection = section
        }
        .disabled(store.loadFailed)
        .overlay(alignment: .top) { if store.loadFailed { Text("资料库只读保护 · 请在设置中恢复备份").padding(12).background(.regularMaterial,in:Capsule()) } }
        // 小组件深链：gaojixu://ledger 打开记账页，gaojixu://overview 打开财务总览，
        // gaojixu://budgets 打开预算页；其余地址忽略。深链由主 app 统一路由（route/routeRevision），
        // 模块内不再挂 onOpenURL，避免执行两遍。
        .onAppear(perform: handleIntegratedRoute)
        .onChange(of: routeRevision) { _, _ in handleIntegratedRoute() }
        .onAppear { syncWidgetSnapshotCurrency() }
        .onChange(of: settings.defaultCurrency) { _, _ in syncWidgetSnapshotCurrency() }
    }

    private func handleIntegratedRoute() {
        guard routeRevision > handledRouteRevision, let route else { return }
        handledRouteRevision = routeRevision
        handleRoute(route)
    }

    private func handleRoute(_ url: URL) {
        guard url.scheme == "gaojixu" else { return }
        switch url.host {
        case "ledger": selection = .ledger
        case "overview": selection = .overview
        case "budgets": selection = .budgets
        default: break
        }
    }

    // MARK: 自绘侧边栏（词元标杆）：品牌头部 + 浮动卡片选中态导航行 + 冒险状态（冒险页）+ 状态底卡

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sidebarSection(tS("财务管理", "Finance"), sections: [.overview, .ledger, .accounts, .budgets, .reports])
                    sidebarSection(tS("积蓄计划", "Savings Plan"), sections: [.goals, .records, .analytics])
                    sidebarSection(tS("冒险成长", "Adventure"), sections: [.adventure])
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if selection == .adventure {
                VStack(spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 7) {
                        Label("Lv.\(store.adventure.level)", systemImage: "figure.fencing")
                            .foregroundStyle(SavingsTheme.green)
                        Label("\(store.adventure.tickets)", systemImage: "ticket.fill")
                            .foregroundStyle(SavingsTheme.orange)
                        Label("\(store.adventure.insight)", systemImage: "lightbulb.fill")
                            .foregroundStyle(SavingsTheme.purple)
                        Label("\(store.coins)", systemImage: "dollarsign.circle.fill")
                            .foregroundStyle(SavingsTheme.blue)
                        Label("\(store.adventure.stardust)", systemImage: "sparkles")
                            .foregroundStyle(SavingsTheme.purple)
                        Label(store.heroBattlePower.formatted(), systemImage: "bolt.shield.fill")
                            .foregroundStyle(SavingsTheme.red)
                    }
                    .font(.pixel(12, weight: .semibold))
                    ProgressView(value: Double(store.adventure.experience), total: Double(max(1, store.experienceNeeded)))
                        .tint(SavingsTheme.green)
                    .help(tS("冒险经验 \(store.adventure.experience)/\(store.experienceNeeded)",
                             "Adventure XP \(store.adventure.experience)/\(store.experienceNeeded)"))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            statusFooter
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            if let image = NSImage(contentsOf: SavingsBundle.bundle.url(forResource: "GaoJiXuIcon", withExtension: "png") ?? URL(fileURLWithPath: "")) {
                Image(nsImage: image).resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tS("搞积蓄", "Gao Savings")).font(.headline)
                Text(tS("记账、预算与攒钱目标", "Ledger, budgets and savings goals")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func sidebarSection(_ title: String, sections: [SavingsSection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(sections) { sidebarRow($0) }
        }
    }

    /// 浮动卡片选中态导航行：accent 底白字 + 柔和投影（深色下投影 opacity 调高），hover 浅灰反馈；流水计数角标保留。
    private func sidebarRow(_ section: SavingsSection) -> some View {
        let selected = selection == section
        let hovered = hoveredSection == section
        let count = section == .ledger ? store.ledgerEntries.count : nil
        return Button { selection = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.callout)
                    .frame(width: 20)
                Text(section.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SavingsTheme.blue)
                        .shadow(color: SavingsTheme.blue.opacity(colorScheme == .dark ? 0.45 : 0.32), radius: 5, y: 2)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredSection = hovering ? section : nil }
        .help(section.subtitle)
    }

    /// 状态底卡（词元 statusFooter 风格）：账本规模 + 存储说明。
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(SavingsTheme.teal).frame(width: 7, height: 7)
                Text(tS("\(store.ledgerEntries.count) 条流水 · \(store.accounts.count) 个账户",
                        "\(store.ledgerEntries.count) entries · \(store.accounts.count) accounts")).font(.caption)
                Spacer(minLength: 0)
            }
            Text(tS("本地存储 · 可手动导出备份", "Stored locally · Export anytime")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview: FinancialOverviewView(selection: $selection)
        case .ledger: LedgerView()
        case .accounts: AccountsView()
        case .budgets: BudgetsView()
        case .reports: ReportsView()
        case .goals: GoalsView()
        case .records: RecordsView()
        case .analytics: AnalyticsView()
        case .adventure: AdventureHubView()
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = tS("导出搞积蓄完整备份", "Export Full Gao Savings Backup")
        panel.nameFieldStringValue = "搞积蓄备份-\(backupDateString()).gaojixu"
        panel.allowedContentTypes = [UTType(exportedAs: "com.gaojixu.backup", conformingTo: .archive)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.backupData().write(to: url, options: .atomic)
            store.notice = tS("完整备份已经导出。", "Full backup exported.")
        } catch {
            store.notice = tS("备份导出失败：\(error.localizedDescription)", "Backup export failed: \(error.localizedDescription)")
        }
    }

    /// 只负责选文件；真正的覆盖恢复必须先经过确认对话框（见 restoreCandidateURL）。
    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = tS("选择搞积蓄完整备份", "Choose a Gao Savings Backup")
        panel.allowedContentTypes = [UTType(exportedAs: "com.gaojixu.backup", conformingTo: .archive)]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreCandidateURL = url
    }

    private func performRestore(from url: URL) {
        do {
            try store.restore(from: Data(contentsOf: url))
        } catch {
            store.notice = tS("备份恢复失败：\(error.localizedDescription)", "Backup restore failed: \(error.localizedDescription)")
        }
    }

    private func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    private func exportLedgerCSV() {
        let panel = NSSavePanel()
        panel.title = tS("导出流水 CSV", "Export Transactions CSV")
        panel.nameFieldStringValue = "搞积蓄流水-\(csvDateString()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LedgerCSVExporter.makeCSV(entries: store.ledgerEntries, accounts: store.accounts)
                .write(to: url, atomically: true, encoding: .utf8)
            store.notice = tS("流水 CSV 已导出。", "Transactions CSV exported.")
        } catch {
            store.notice = tS("流水 CSV 导出失败：\(error.localizedDescription)", "CSV export failed: \(error.localizedDescription)")
        }
    }

    private func csvDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    /// 只负责选文件并解析出导入计划；真正写入必须等预览 sheet 里点「确认导入」。
    private func importLedgerCSV() {
        let panel = NSOpenPanel()
        panel.title = tS("选择流水 CSV 文件", "Choose a Transactions CSV")
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let outcome = LedgerCSVImporter.parse(text)
            guard !outcome.rows.isEmpty else {
                store.notice = outcome.skippedLines > 0
                    ? tS("CSV 中没有可识别的流水行（\(outcome.skippedLines) 行无法解析）。请确认是「导出流水 CSV」生成的格式。",
                         "No recognizable rows in the CSV (\(outcome.skippedLines) lines could not be parsed). Make sure it was produced by “Export Transactions CSV”.")
                    : tS("CSV 文件是空的。", "The CSV file is empty.")
                return
            }
            let plan = LedgerCSVImporter.plan(rows: outcome.rows, accounts: store.accounts, existingEntries: store.ledgerEntries)
            csvImportContext = CSVImportContext(fileName: url.lastPathComponent, plan: plan, parseSkipped: outcome.skippedLines)
        } catch {
            store.notice = tS("CSV 读取失败：\(error.localizedDescription)", "Could not read the CSV: \(error.localizedDescription)")
        }
    }

    /// 小组件快照币种跟随「新目标默认币种」。
    /// 已核实：flushSave() 在无脏数据时是 no-op，而快照只在财务脏或文件缺失时重写，
    /// 直接调用不会更新币种。因此币种变化时先删除旧快照文件，再走 persistNow 的
    /// 「快照缺失」分支立即重建（save() 标记脏数据，flushSave() 同步落盘）。
    private func syncWidgetSnapshotCurrency() {
        let code = settings.defaultCurrency.rawValue
        guard store.widgetCurrencyCode != code else { return }
        store.widgetCurrencyCode = code
        for url in [GaoJiXuWidgetSnapshot.fileURL, GaoJiXuWidgetSnapshot.fallbackFileURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        store.save()
        store.flushSave()
    }
}

/// 搞积蓄设置页内容（app 级设置中心经 SavingsSettingsView 嵌入；模块内不再有独立入口）。
/// 原名 private SavingsSettingsView，V1.9 起让名给 public 契约符号。
struct SavingsSettingsPanelView: View {
    @EnvironmentObject private var settings: SavingsSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tS("设置", "Settings")).font(.title2.weight(.semibold))
                    Text(tS("外观、默认币种与本地数据说明", "Appearance, default currency and local data"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tS("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(22)
            Divider()

            Form {
                Picker(tS("新目标默认币种", "Default currency for new goals"), selection: $settings.defaultCurrency) {
                    ForEach(SavingsCurrency.allCases) { currency in
                        Text(currency.displayName).tag(currency)
                    }
                }

                Toggle(tS("预算滚存上月结余", "Roll over last month's budget surplus"), isOn: Binding(
                    get: { settings.budgetRolloverEnabled },
                    set: { settings.budgetRolloverEnabled = $0 }
                ))

                HStack {
                    ColorPicker(tS("画布色调", "Canvas tint"), selection: Binding(
                        get: { settings.backgroundPickerColor },
                        set: { settings.setBackgroundColor($0) }
                    ))
                    if !settings.backgroundHex.isEmpty {
                        Button(tS("恢复默认", "Reset")) { settings.resetBackgroundColor() }
                    }
                }

                Section(tS("隐私与资金安全", "Privacy & Safety")) {
                    Label(tS("无需登录，不收集账号或行为数据", "No sign-in; no account or behavior data collected"), systemImage: "person.crop.circle.badge.checkmark")
                    Label(tS("所有记录只保存在本机，可手动导出备份", "Everything stays on this Mac; export a backup anytime"), systemImage: "internaldrive.fill")
                    Label(tS("本应用不连接银行，不会发起真实银行交易", "No bank connections; never initiates real transactions"), systemImage: "lock.shield.fill")
                    Label(tS("免费抽奖只消耗游戏星券，不支持充值", "Free draws spend in-game tickets only; no purchases"), systemImage: "ticket.fill")
                }
            }
            .formStyle(.grouped)
            .padding(18)
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 760, minHeight: 490, idealHeight: 510, maxHeight: 760)
    }
}

// MARK: - 工具栏项 chrome 隐藏（macOS 26 起工具栏项带 sharedBackground 玻璃胶囊，
// 自绘的侧栏切换按钮与固定宽 360 trailing 容器会被罩上多余色块；只去底色，不改几何与交互）
@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

/// 侧栏切换按钮图标：chrome 隐藏后补轻量 hover 底色，保证图标清晰、反馈合理。
private struct SidebarToggleIcon: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "sidebar.left")
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// 工具栏 prominent 按钮样式：macOS 26 隐藏工具栏 sharedBackground 后，.borderedProminent
/// 的白字依赖那层胶囊底色，会直接隐形；此样式自绘 accent 胶囊底（按下变暗），任何上下文可见。
private struct ToolbarProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .foregroundStyle(.white)
    }
}
