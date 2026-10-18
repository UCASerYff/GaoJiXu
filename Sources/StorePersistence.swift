import Darwin
import Foundation

/// 持久化域：防抖保存、加载、沙盒旧档迁移、迁移前备份、完整备份恢复、小组件快照与事件日志。
extension SavingsStore {
    var libraryDirectory: URL {
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
        if persistedFinancialFingerprint == nil {
            persistedFinancialFingerprint = try financialFingerprint()
            financialRevision = persistedFinancialFingerprint
            financialUpdatedAt = decoded.financialUpdatedAt
        }
        hasLoadedValidLibrary = true
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
        guard saveIsDirty || saveDebounceInterval <= 0 else {
            refreshWidgetSnapshotIfNeeded()
            return true
        }
        let success = persistNow()
        saveIsDirty = !success
        if success { refreshWidgetSnapshotIfNeeded() }
        return success
    }

    private func persistNow() -> Bool {
        do {
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let fingerprint = try financialFingerprint()
            let financialContentChanged = persistedFinancialFingerprint != nil && fingerprint != persistedFinancialFingerprint
            var library = snapshot()
            library.financialRevision = fingerprint
            library.financialUpdatedAt = financialContentChanged ? snapshotNow() : financialUpdatedAt
            let data = try encoder.encode(library), temporary = libraryURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: libraryURL.path) { _ = try FileManager.default.replaceItemAt(libraryURL, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: libraryURL) }
            // Only acknowledge the financial revision after its business library is durable.
            financialRevision = fingerprint
            financialUpdatedAt = library.financialUpdatedAt
            persistedFinancialFingerprint = fingerprint
            financialSourceSavedAt = (try? FileManager.default.attributesOfItem(atPath: libraryURL.path)[.modificationDate]) as? Date
            if financialContentChanged { financesDirty = true; pendingWidgetSnapshot = nil }
            return true
        } catch { notice = "数据保存失败：\(error.localizedDescription)"; return false }
    }

    func load() {
        do {
            try migrateLegacySandboxDataIfNeeded()
            let exists: Bool
            do { _ = try FileManager.default.attributesOfItem(atPath: libraryURL.path); exists = true }
            catch {
                guard Self.isMissingFile(error) else { throw error }
                exists = false
            }
            if !exists {
                // A missing library beside existing data is a failure, never evidence of a new user.
                guard !hasExistingDataEvidence() else { throw CocoaError(.fileReadNoSuchFile) }
                apply(Self.starterLibrary())
                financialRevision = try financialFingerprint()
                persistedFinancialFingerprint = financialRevision
                financialUpdatedAt = nil
                hasLoadedValidLibrary = true
                setLoadFailed(false)
                materializeRecurringTransactions()
                save(); flushSave()
                return
            }
            let decoded = try decoder.decode(SavingsLibrary.self, from: Data(contentsOf: libraryURL))
            guard decoded.version <= Self.currentSchemaVersion else { throw SavingsStoreError.unsupportedVersion }
            apply(decoded)
            // Legacy libraries have no reliable financial modification time. Do not invent one.
            financialRevision = try financialFingerprint()
            persistedFinancialFingerprint = financialRevision
            financialUpdatedAt = decoded.financialUpdatedAt
            financialSourceSavedAt = (try? FileManager.default.attributesOfItem(atPath: libraryURL.path)[.modificationDate]) as? Date
            hasLoadedValidLibrary = true
            setLoadFailed(false)
            materializeRecurringTransactions()
            save(); flushSave()
        } catch {
            // 读取失败时不落盘，避免覆盖原文件。
            setLoadFailed(true)
            hasLoadedValidLibrary = false
            apply(Self.starterLibrary()); notice = "资料库读取失败，已进入只读保护。请从备份恢复；自动保存与战斗已暂停：\(error.localizedDescription)"
        }
    }

    /// 启用沙盒后 applicationSupportDirectory 指向容器，旧存档仍位于真实主目录。
    /// 首次启动只读拷贝旧目录；失败进入保护，不能把未读到的旧资料当成新资料。
    private func migrateLegacySandboxDataIfNeeded() throws {
        if let override = ProcessInfo.processInfo.environment["GAOJIXU_DATA_DIR"], !override.isEmpty { return }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: libraryURL.path) else { return }
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) else { return }
        let legacyDirectory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/GaoJiXu", isDirectory: true)
        do { _ = try fileManager.attributesOfItem(atPath: legacyDirectory.appendingPathComponent("library.json").path) }
        catch { if Self.isMissingFile(error) { return }; throw error }
        do {
            try fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(atPath: legacyDirectory.path) {
                let destination = libraryDirectory.appendingPathComponent(item)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try fileManager.copyItem(at: legacyDirectory.appendingPathComponent(item), to: destination)
            }
        } catch { throw error }
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

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    private func hasExistingDataEvidence() -> Bool {
        let snapshotTargets = widgetSnapshotTargets().compactMap({ $0 })
        let lastValidTargets = snapshotTargets.map { $0.deletingLastPathComponent().appendingPathComponent("gaojixu-widget-last-valid.json") }
        for url in snapshotTargets + lastValidTargets {
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
            catch { if !Self.isMissingFile(error) { return true } }
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
            return files.contains { $0 != ".DS_Store" && !$0.hasPrefix(".com.apple.") }
        } catch { return !Self.isMissingFile(error) }
    }

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
