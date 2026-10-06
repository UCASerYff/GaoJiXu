import Darwin
import Foundation
#if !SMOKE_TEST
import AppKit
import WidgetKit
#endif

/// 持久化域：防抖保存、加载、沙盒旧档迁移、迁移前备份、完整备份恢复、小组件快照与事件日志。
extension SavingsStore {
    private var libraryDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GaoSeries/Savings", isDirectory: true)
    }

    private var libraryURL: URL { libraryDirectory.appendingPathComponent("library.json") }

    private var monthlyBindingsURL:URL { libraryDirectory.appendingPathComponent("monthly-account-bindings.json") }
    func monthlyAccountBinding(_ key:String)->String? {
        guard let data=try? Data(contentsOf:monthlyBindingsURL),let values=try? decoder.decode([String:String].self,from:data) else { return nil }
        return values[key]
    }
    func bindMonthlyAccount(_ id:String,key:String) throws {
        var values:[String:String]=[:]
        if FileManager.default.fileExists(atPath:monthlyBindingsURL.path) { values=try decoder.decode([String:String].self,from:Data(contentsOf:monthlyBindingsURL)) }
        values[key]=id
        try encoder.encode(values).write(to:monthlyBindingsURL,options:.atomic)
    }
    func protectLedgerBeforeReconciliation() throws {
        let destination = libraryDirectory.appendingPathComponent("ReconciliationBackups",isDirectory:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        let backup = destination.appendingPathComponent("ledger-" + UUID().uuidString + ".json")
        try encoder.encode(snapshot()).write(to:backup,options:.atomic)
    }
    func backupData() throws -> Data { try encoder.encode(snapshot()) }
    func restore(from data: Data) throws {
        let decoded = try decoder.decode(SavingsLibrary.self, from: data)
        guard decoded.version <= Self.currentSchemaVersion else { throw SavingsStoreError.unsupportedVersion }
        setLoadFailed(false)
        apply(decoded)
        // 恢复的备份可能含有已到期的周期规则：与启动加载一致，恢复后立即物化一次。
        materializeRecurringTransactions()
        save()
        guard flushSave() else { throw CocoaError(.fileWriteUnknown) }
        notice = "完整备份已经恢复。"
    }

    /// 轻量保存入口：标记脏数据并按防抖间隔合并写盘。
    /// 防抖间隔为 0 时保持同步立即写（测试与调试兼容）。
    func save() {
        guard !loadFailed else { return }
        rewardEvents = Array(rewardEvents.prefix(300))
        drawHistory = Array(drawHistory.prefix(200))
        guard saveDebounceInterval > 0 else { saveIsDirty = true; flushSave(); return }
        saveIsDirty = true
        guard pendingSaveWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSaveWorkItem = nil
            self.flushSave()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    /// 有脏数据时立即同步落盘；应用退出前由 willTerminate 观察者调用。
    @discardableResult func flushSave() -> Bool {
        guard !loadFailed else { return false }
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        guard saveIsDirty || saveDebounceInterval <= 0 else { return true }
        let success = persistNow()
        saveIsDirty = !success
        return success
    }

    private func persistNow() -> Bool {
        do {
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot()), temporary = libraryURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: libraryURL.path) { _ = try FileManager.default.replaceItemAt(libraryURL, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: libraryURL) }
            #if !SMOKE_TEST
            // 小组件快照重算昂贵（O(账户×流水×天数)）：仅财务口径变化或快照缺失时才重写。
            let snapshotTargets = [GaoJiXuWidgetSnapshot.fileURL, GaoJiXuWidgetSnapshot.fallbackFileURL].compactMap { $0 }
            let snapshotMissing = snapshotTargets.contains { !FileManager.default.fileExists(atPath: $0.path) }
            if financesDirty || snapshotMissing {
                writeWidgetSnapshot()
                WidgetCenter.shared.reloadAllTimelines()
                financesDirty = false
            }
            #endif
            return true
        } catch { notice = "数据保存失败：\(error.localizedDescription)"; return false }
    }

    func load() {
        migrateLegacySandboxDataIfNeeded()
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            apply(Self.starterLibrary())
            // 启动加载完成后物化一次到期的周期记账（幂等，规则为空时无操作）。
            materializeRecurringTransactions()
            save(); flushSave()
            return
        }
        do {
            let decoded = try decoder.decode(SavingsLibrary.self, from: Data(contentsOf: libraryURL))
            guard decoded.version <= Self.currentSchemaVersion else { throw SavingsStoreError.unsupportedVersion }
            apply(decoded)
            setLoadFailed(false)
            materializeRecurringTransactions()
            save(); flushSave()
        } catch {
            // 读取失败时不落盘，避免覆盖原文件。
            setLoadFailed(true)
            apply(Self.starterLibrary()); notice = "资料库读取失败，已进入只读保护。请从备份恢复；自动保存与战斗已暂停：\(error.localizedDescription)"
        }
    }

    /// 启用沙盒后 applicationSupportDirectory 指向容器，旧存档仍位于真实主目录。
    /// 首次启动时把旧数据目录整体只读拷贝过来；任何失败都静默回退到原有逻辑（绝不动旧文件）。
    private func migrateLegacySandboxDataIfNeeded() {
        if let override = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"], !override.isEmpty { return }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: libraryURL.path) else { return }
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) else { return }
        let legacyDirectory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/GaoJiXu", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyDirectory.appendingPathComponent("library.json").path) else { return }
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(atPath: legacyDirectory.path) {
                let destination = libraryDirectory.appendingPathComponent(item)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.copyItem(at: legacyDirectory.appendingPathComponent(item), to: destination)
            }
        } catch {
            // 尽力而为的增强：失败不影响后续 starter library 回退。
        }
    }

    /// 版本迁移写盘前，把磁盘上的旧存档留一份只读拷贝（已存在则不覆盖）。
    func backupLibraryBeforeMigration(fromVersion version: Int) {
        guard version < Self.currentSchemaVersion else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryURL.path) else { return }
        let backupURL = libraryDirectory.appendingPathComponent("library.migration-backup-v\(version).json")
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try? fileManager.copyItem(at: libraryURL, to: backupURL)
    }

    #if !SMOKE_TEST
    private func writeWidgetSnapshot() {
        let currency = SavingsCurrency(rawValue: widgetCurrencyCode) ?? .CNY
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: components) else { return }
        let monthTitle = SavingsFormatters.month.string(from: monthStart)
        let currencyAccounts = netWorthAccounts(currency: currency)
        let days = dailyFinanceSummary(currency: currency, month: now)
        // 本月预算（快照统计币种口径）：未设预算时写 nil，小组件显示「未设预算」态。
        let monthKey = SavingsFormatters.monthKey(now)
        let budgetTotalValue = totalBudget(monthKey: monthKey, currency: currency)
        let budgetTotal: Double? = budgetTotalValue > 0 ? budgetTotalValue : nil
        let budgetSpent: Double? = budgetTotal.map { _ in totalBudgetSpent(monthKey: monthKey, currency: currency) }
        let snapshot = GaoJiXuWidgetSnapshot(
            updatedAt: now,
            monthStart: monthStart,
            monthTitle: monthTitle,
            currencyCode: currency.rawValue,
            currencySymbol: currency.symbol,
            days: days,
            netWorth: netWorth(currency: currency),
            accounts: currencyAccounts.map {
                .init(id: $0.id, name: $0.name, balance: netWorthContribution(for: $0), symbol: $0.symbol)
            },
            currency: currency.rawValue,
            budgetTotal: budgetTotal,
            budgetSpent: budgetSpent
        )
        do {
            let data = try encoder.encode(snapshot)
            for url in [GaoJiXuWidgetSnapshot.fileURL, GaoJiXuWidgetSnapshot.fallbackFileURL].compactMap({ $0 }) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // A widget snapshot is auxiliary; a failure must never block the finance save.
        }
    }
    #endif

    // MARK: - Reward event log

    func addEvent(title: String, detail: String, symbol: String) {
        rewardEvents.insert(.init(id: UUID().uuidString, date: Date(), title: title, detail: detail, symbol: symbol), at: 0); rewardEvents = Array(rewardEvents.prefix(300))
    }

    /// 迁移事件幂等：恢复旧备份会重放迁移链，已存在的同标题迁移事件不再重复插入。
    func addMigrationEvent(title: String, detail: String, symbol: String) {
        guard !rewardEvents.contains(where: { $0.title == title }) else { return }
        addEvent(title: title, detail: detail, symbol: symbol)
    }
}
