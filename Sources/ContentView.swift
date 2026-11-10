import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let gaojixuNewLedgerEntry = Notification.Name("gaojixu.newLedgerEntry")
    static let gaojixuNewSavingsRecord = Notification.Name("gaojixu.newSavingsRecord")
    static let gaojixuExportBackup = Notification.Name("gaojixu.exportBackup")
    static let gaojixuExportCSV = Notification.Name("gaojixu.exportCSV")
    static let gaojixuImportCSV = Notification.Name("gaojixu.importCSV")
    static let gaojixuRestoreBackup = Notification.Name("gaojixu.restoreBackup")
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
    @State private var showingRecordEditor = false
    @State private var ledgerEditorSession: LedgerEditorSession?
    @State private var restoreCandidateURL: URL?
    @State private var csvImportContext: CSVImportContext?
    @State private var researchFundingRecordID: String?
    @AppStorage(GQNSLanguage.key) private var appLanguage = "system"

    var body: some View {
        ZStack {
            settings.canvasColor(for: colorScheme).ignoresSafeArea()
            VStack(spacing: 0) {
                WorkbenchTopNavigation(selection: $selection)
                Divider().opacity(0.55)
                WorkbenchWorkspaceTabs(selection: $selection)
                detail
            }
        }
        .frame(minWidth: 1040, minHeight: 700)
        .id(appLanguage)
        .environment(\.locale, Locale(identifier: GQNSLanguage.localeIdentifier))
        .toolbar {
            toolbarItemNoChrome(.primaryAction) {
                HStack(spacing: 12) {
                    Button(action: presentNewLedgerEntry) {
                        Label(tS("记一笔", "Record"), systemImage: "plus")
                    }
                    .buttonStyle(ToolbarProminentStyle())

                    Menu {
                        Button(action: presentNewLedgerEntry) { Label(tS("记录收支或转账", "Record income, expense or transfer"), systemImage: "square.and.pencil") }
                        Button { showingRecordEditor = true } label: { Label(tS("分配一笔积蓄", "Allocate savings"), systemImage: "target") }
                            .disabled(store.activeGoals.isEmpty)
                    } label: { Label(tS("更多记录", "More"), systemImage: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showingRecordEditor) {
            RecordEditorView(existingRecord: nil)
                .environmentObject(store)
                .environmentObject(settings)
        }
        .sheet(item: $ledgerEditorSession) { session in
            LedgerEntryEditorView(existingEntry: session.entry)
                .id(session.id)
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
            Text(tS("将用备份“\(restoreCandidateURL?.lastPathComponent ?? "")”覆盖当前全部数据，包括流水、账户、目标与冒险进度。此操作不可撤销。",
                    "The backup “\(restoreCandidateURL?.lastPathComponent ?? "")” will replace all current data — transactions, accounts, goals and adventure progress. This cannot be undone."))
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuNewLedgerEntry)) { _ in presentNewLedgerEntry() }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuNewSavingsRecord)) { _ in
            guard !store.activeGoals.isEmpty else {
                store.notice = tS("还没有进行中的攒钱目标，请先在「攒钱目标」中创建一个目标。", "No active savings goal yet — create one in Goals first.")
                return
            }
            showingRecordEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("gaojixu.autoLedgerEntry"))) { note in
            guard let info = note.userInfo, let paymentID = info["paymentID"] as? String else { return }
            PendingAutoLedger.recordConfirmed(paymentID, store: store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuExportBackup)) { _ in exportBackup() }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuExportCSV)) { _ in exportLedgerCSV() }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuImportCSV)) { _ in importLedgerCSV() }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuRestoreBackup)) { _ in restoreBackup() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.savings.game"))) { _ in selection = .adventure }
        .onReceive(NotificationCenter.default.publisher(for: .gaojixuSelectSection)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = SavingsSection(rawValue: rawValue) else { return }
            selection = section
        }
        .disabled(store.loadFailed)
        .overlay(alignment: .top) {
            if store.loadFailed { Text("资料库只读保护").padding(12).background(.regularMaterial, in: Capsule()) }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.loadFailed, let message = store.widgetSnapshotError {
                Label(message, systemImage: "arrow.clockwise.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
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
        case "fixed-income": selection = .fixedIncome
        case "fixed-expenses", "today": selection = .fixedExpenses
        case "benefits": selection = .benefits
        case "research-funding":
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            researchFundingRecordID = values.first(where: { $0.name == "id" || $0.name == "sourceID" })?.value
            selection = .researchFunding
        default: break
        }
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
        case .fixedIncome, .fixedExpenses, .benefits: FixedFinanceWorkspace(selection: $selection)
        case .researchFunding: ResearchFundingView(recordID: researchFundingRecordID)
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

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.title = tS("选择搞积蓄完整备份", "Choose a Gao Savings Backup")
        panel.allowedContentTypes = [UTType(exportedAs: "com.gaojixu.backup", conformingTo: .archive)]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreCandidateURL = url
    }

    private func performRestore(from url: URL) {
        do { try store.restore(from: Data(contentsOf: url)) }
        catch { store.notice = tS("备份恢复失败：\(error.localizedDescription)", "Backup restore failed: \(error.localizedDescription)") }
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
                    ? tS("CSV 中没有可识别的流水行（\(outcome.skippedLines) 行无法解析）。请确认是「导出流水 CSV」生成的格式。", "No recognizable rows in the CSV (\(outcome.skippedLines) lines could not be parsed). Make sure it was produced by “Export Transactions CSV”.")
                    : tS("CSV 文件是空的。", "The CSV file is empty.")
                return
            }
            let plan = LedgerCSVImporter.plan(rows: outcome.rows, accounts: store.accounts, existingEntries: store.ledgerEntries)
            csvImportContext = CSVImportContext(fileName: url.lastPathComponent, plan: plan, parseSkipped: outcome.skippedLines)
        } catch {
            store.notice = tS("CSV 读取失败：\(error.localizedDescription)", "Could not read the CSV: \(error.localizedDescription)")
        }
    }

    private func syncWidgetSnapshotCurrency() {
        store.setWidgetCurrency(settings.defaultCurrency.rawValue)
    }

    private func presentNewLedgerEntry() {
        guard ledgerEditorSession == nil else { return }
        ledgerEditorSession = .init(entry: nil)
    }
}

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
                    ForEach(SavingsCurrency.allCases) { currency in Text(currency.displayName).tag(currency) }
                }
                Toggle(tS("预算滚存上月结余", "Roll over last month's budget surplus"), isOn: Binding(
                    get: { settings.budgetRolloverEnabled }, set: { settings.budgetRolloverEnabled = $0 }
                ))
                HStack {
                    ColorPicker(tS("画布色调", "Canvas tint"), selection: Binding(
                        get: { settings.backgroundPickerColor }, set: { settings.setBackgroundColor($0) }
                    ))
                    if !settings.backgroundHex.isEmpty { Button(tS("恢复默认", "Reset")) { settings.resetBackgroundColor() } }
                }
                Section(tS("隐私与资金安全", "Privacy & Safety")) {
                    Label(tS("无需登录，不收集账号或行为数据", "No sign-in; no account or behavior data collected"), systemImage: "person.crop.circle.badge.checkmark")
                    Label(tS("所有记录只保存在本机", "Everything stays on this Mac"), systemImage: "internaldrive.fill")
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

@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content).sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

private struct ToolbarProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(SavingsTheme.teal.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .foregroundStyle(.white)
    }
}
