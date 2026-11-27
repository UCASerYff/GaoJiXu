import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CSVReviewWindowState {
    private(set) static var hasDraft = false

    static func update(hasDraft: Bool) {
        self.hasDraft = hasDraft
    }
}

@MainActor
struct CSVReviewInbox: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var detail: CSVReviewDetail?
    @State private var decisions: [String: CSVReviewDecision] = [:]
    @State private var edits: [String: CSVReviewFields] = [:]
    @State private var duplicateOverrides: Set<String> = []
    @State private var selectedPairs: Set<String> = []
    @State private var showingFileImporter = false
    @State private var showingAllRows = false
    @State private var editor: RowEditor?
    @State private var editorHasDraft = false
    @State private var confirmation: Confirmation?
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let maxFileBytes = 8 * 1024 * 1024
    private var hasDraft: Bool { !decisions.isEmpty || !edits.isEmpty || !selectedPairs.isEmpty || !duplicateOverrides.isEmpty }
    private var pendingCount: Int { detail?.rows.filter { $0.row.status == .pending }.count ?? 0 }
    private var entryCount: Int { decisions.values.filter { $0 == .apply }.count }
    private var skippedCount: Int { decisions.values.filter { $0 == .skip }.count }
    private var hasChangesToSave: Bool { entryCount > 0 || skippedCount > 0 || !edits.isEmpty || !selectedPairs.isEmpty }
    private var pairs: [CSVReviewPair] { detail?.pairs ?? [] }
    private var matches: [CSVReviewPair] { pairs.filter { selectedPairs.contains($0.id) } }
    private var missingDuplicateConfirmation: Bool {
        let pairedRows = Set(matches.flatMap { [$0.expenseID, $0.incomeID] })
        let unconfirmedRow = detail?.rows.contains {
            (decisions[$0.id] == .apply || pairedRows.contains($0.id))
                && !$0.duplicates.isEmpty && !duplicateOverrides.contains($0.id)
        } ?? false
        let unconfirmedPair = matches.contains {
            !$0.duplicates.isEmpty
                && (!duplicateOverrides.contains($0.expenseID) || !duplicateOverrides.contains($0.incomeID))
        }
        return unconfirmedRow || unconfirmedPair
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    batchControls
                    if let detail {
                        batchContent(detail)
                    } else {
                        Text(tS("尚无导入批次。选择一份 UTF-8 CSV 开始审核。", "No batches. Choose a UTF-8 CSV to begin."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 470, idealWidth: 790, maxWidth: 980, minHeight: 410, idealHeight: 660, maxHeight: 800)
        .onAppear { if detail == nil { reload(preferred: nil) } }
        .onChange(of: hasDraft || editorHasDraft, initial: true) { _, dirty in
            CSVReviewWindowState.update(hasDraft: dirty)
        }
        .onDisappear { CSVReviewWindowState.update(hasDraft: false) }
        .interactiveDismissDisabled(hasDraft || editor != nil)
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            stageFile(result)
        }
        .sheet(item: $editor, onDismiss: { editorHasDraft = false }) { request in
            CSVReviewRowEditor(request: request, onChange: { editorHasDraft = $0 }) { fields in
                edits[request.id] = fields
                decisions.removeValue(forKey: request.id)
                duplicateOverrides.remove(request.id)
            }
        }
        .alert(item: $confirmation) { action in
            let button: Alert.Button = action.destructive
                ? .destructive(Text(action.button), action: { perform(action) })
                : .default(Text(action.button), action: { perform(action) })
            return Alert(title: Text(action.title), message: Text(action.message), primaryButton: button,
                         secondaryButton: .cancel(Text(tS("返回", "Go Back"))))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tS("导入审核箱", "Import Review")).font(.title2.weight(.semibold))
                Text(tS("先核对 CSV 流水，再选择哪些要记入账本。", "Review CSV rows before recording them in your ledger."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(tS("关闭", "Close")) { request(.close) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private var batchControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                batchMenu
                Spacer(minLength: 0)
                batchButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                batchMenu
                batchButtons
            }
        }
    }

    private var batchMenu: some View {
        Menu {
            ForEach(store.csvReviewBatches, id: \.id) { batch in
                Button {
                    request(.open(batch.id))
                } label: {
                    let pending = batch.rows.filter { $0.status == .pending }.count
                    Text(tS("\(batch.name) · \(pending) 待确认", "\(batch.name) · \(pending) pending"))
                }
            }
        } label: {
            Label(detail?.batch.name ?? tS("导入批次", "Import Batches"), systemImage: "tray.full")
                .lineLimit(1)
        }
        .disabled(store.csvReviewBatches.isEmpty)
        .accessibilityLabel(tS("选择导入批次", "Choose Import Batch"))
        .accessibilityValue(detail?.batch.name ?? "")
    }

    private var batchButtons: some View {
        HStack(spacing: 8) {
            Button { request(.refresh) } label: {
                Label(tS("刷新", "Refresh"), systemImage: "arrow.clockwise")
            }
            Button { request(.pickFile) } label: {
                Label(tS("选择 CSV 文件", "Choose CSV"), systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func batchContent(_ detail: CSVReviewDetail) -> some View {
        let visible = detail.rows.filter { showingAllRows || $0.row.status == .pending }
        let rowLines = Dictionary(uniqueKeysWithValues: detail.rows.map { ($0.id, $0.row.line) })
        return Group {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.batch.name).font(.headline).textSelection(.enabled)
                Text(detail.batch.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text(tS("待确认 \(pendingCount) · 疑似重复 \(detail.rows.filter { !$0.duplicates.isEmpty }.count)", "\(pendingCount) pending · \(detail.rows.filter { !$0.duplicates.isEmpty }.count) possible duplicates"))
                    .font(.callout.monospacedDigit())
            }
            if !detail.pairs.isEmpty { transferSuggestions(detail.pairs, rowLines: rowLines) }
            Picker(tS("显示流水", "Show Rows"), selection: $showingAllRows) {
                Text(tS("待确认", "Pending")).tag(false)
                Text(tS("全部行", "All Rows")).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 310, alignment: .leading)
            if visible.isEmpty {
                Text(tS("没有符合筛选的流水。", "No rows match this filter."))
                    .foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(visible, id: \.id) { row in reviewRow(row) }
        }
    }

    private func transferSuggestions(_ suggestions: [CSVReviewPair], rowLines: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(tS("同币种转账建议", "Same-Currency Transfer Matches"), systemImage: "arrow.left.arrow.right")
                .font(.headline)
            Text(tS("日期、币种与金额匹配，方向相反，且有明确转账线索。勾选后，两行将合并为一笔转账。", "The date, currency, and amount match, the directions oppose, and the rows identify a transfer. Select a match to record one transfer."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(suggestions, id: \.id) { pair in
                Toggle(isOn: Binding(
                    get: { selectedPairs.contains(pair.id) },
                    set: { value in
                        if value { selectedPairs.insert(pair.id) }
                        else { selectedPairs.remove(pair.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(pair.sourceName) → \(pair.targetName) · \(SavingsFormatters.money(pair.amount, currency: pair.currency))")
                            .monospacedDigit()
                        if let outflow = rowLines[pair.expenseID], let inflow = rowLines[pair.incomeID] {
                            Text(tS("第 \(outflow)、\(inflow) 行", "Rows \(outflow) and \(inflow)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(hasIndividualDecision(pair.expenseID) || hasIndividualDecision(pair.incomeID))
                if selectedPairs.contains(pair.id) {
                    reasons(pair.duplicates, icon: "doc.on.doc", warning: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SavingsTheme.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reviewRow(_ assessment: CSVReviewRowAssessment) -> some View {
        let row = assessment.row
        let fields = edits[row.id] ?? row.fields
        let matched = matches.first { $0.expenseID == row.id || $0.incomeID == row.id }
        let working = row.status == .pending
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tS("第 \(row.line) 行", "Row \(row.line)")).font(.caption).foregroundStyle(.secondary)
                Text(statusTitle(row.status)).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Text([fields.currency, fields.amount].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            if !fields.accountName.isEmpty {
                Text(fields.targetAccountName.isEmpty ? fields.accountName : "\(fields.accountName) → \(fields.targetAccountName)")
                    .font(.callout.weight(.medium))
            }
            Text([fields.date, kindTitle(fields.kind), fields.categoryName].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let zone = row.timeZoneIdentifier, edits[row.id] == nil {
                Text(tS("未注明偏移时采用 \(zone)", "Unspecified offset interpreted in \(zone)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !fields.targetAmount.isEmpty {
                Text(tS("实际转入 \(fields.targetCurrency) \(fields.targetAmount)", "Actual receipt \(fields.targetCurrency) \(fields.targetAmount)"))
                    .font(.caption).monospacedDigit()
            }
            if !fields.note.isEmpty { Text(fields.note).font(.callout).textSelection(.enabled) }
            if working {
                if edits[row.id] != nil {
                    Label(tS("保存审核后将重新检查此行。", "Save the review to recheck this row."), systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    if matched == nil { reasons(assessment.problems, icon: "exclamationmark.circle", warning: true) }
                    reasons(assessment.duplicates, icon: "doc.on.doc", warning: true)
                    reasons(assessment.notices, icon: "info.circle", warning: false)
                }
                if matched != nil {
                    Label(tS("已选合并转账", "Selected for a transfer"), systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    rowButtons(assessment)
                }
                if !assessment.duplicates.isEmpty || matched?.duplicates.isEmpty == false {
                    Toggle(tS("已核对，仍然保留", "Reviewed, keep it anyway"), isOn: override(for: row.id))
                        .toggleStyle(.checkbox)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func rowButtons(_ assessment: CSVReviewRowAssessment) -> some View {
        HStack(spacing: 10) {
            Picker(tS("审核第 \(assessment.row.line) 行", "Review Row \(assessment.row.line)"), selection: Binding(
                get: { decisions[assessment.id] ?? CSVReviewDecision.pending },
                set: { value in
                    if value == .pending { decisions.removeValue(forKey: assessment.id) }
                    else { decisions[assessment.id] = value }
                    if value != .apply { duplicateOverrides.remove(assessment.id) }
                }
            )) {
                Text(tS("保留待确认", "Keep Pending")).tag(CSVReviewDecision.pending)
                if assessment.canApply && edits[assessment.id] == nil {
                    Text(tS("确认入账", "Record")).tag(CSVReviewDecision.apply)
                }
                Text(tS("跳过", "Skip")).tag(CSVReviewDecision.skip)
            }
            .labelsHidden()
            .fixedSize()
            Button(tS("修改", "Edit")) {
                editor = RowEditor(id: assessment.id, line: assessment.row.line, fields: edits[assessment.id] ?? assessment.row.fields)
            }
        }
    }

    private func reasons(_ messages: [String], icon: String, warning: Bool) -> some View {
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: icon)
                .font(.caption)
                .foregroundStyle(warning ? Color.primary : Color.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(SavingsTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if missingDuplicateConfirmation {
                Text(tS("保留疑似重复项前，请逐行确认。", "Confirm each possible duplicate before keeping it."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if detail?.batch.canUndo == true {
                    Button(tS("撤销本批入账", "Undo Batch Entries")) { confirmation = .undo }.disabled(hasDraft)
                }
                Spacer()
                Button(entryCount > 0 || !selectedPairs.isEmpty ? tS("确认入账", "Review and Record") : tS("保存审核", "Save Review")) {
                    confirmation = .submit(entries: entryCount, pairs: selectedPairs.count, skips: skippedCount)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChangesToSave || missingDuplicateConfirmation)
            }
        }
        .padding(14)
    }

    private func override(for rowID: String) -> Binding<Bool> {
        Binding(get: { duplicateOverrides.contains(rowID) }, set: { value in
            if value { duplicateOverrides.insert(rowID) }
            else { duplicateOverrides.remove(rowID) }
        })
    }

    private func hasIndividualDecision(_ rowID: String) -> Bool {
        decisions[rowID] != nil || edits[rowID] != nil
    }

    private func request(_ action: Confirmation) {
        if hasDraft { confirmation = action }
        else { perform(action) }
    }

    private func perform(_ action: Confirmation) {
        confirmation = nil
        errorMessage = nil
        switch action {
        case .close: dismiss()
        case .pickFile: showingFileImporter = true
        case .refresh: reload(preferred: detail?.batch.id)
        case let .open(id): reload(preferred: id)
        case .submit: submit()
        case .undo: undo()
        }
    }

    private func reload(preferred: String?) {
        let batches = store.csvReviewBatches
        let selected = batches.first { $0.id == preferred }
            ?? batches.first { batch in batch.rows.contains { $0.status == .pending } } ?? batches.first
        do {
            if let selected { reset(try store.csvReviewDetail(selected.id)) }
            else { detail = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    private func stageFile(_ result: Result<URL, Error>) {
        do {
            errorMessage = nil
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= maxFileBytes {
                let requested = min(65_536, maxFileBytes + 1 - data.count)
                guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            guard data.count <= maxFileBytes else {
                errorMessage = tS("请选择 8 MiB 以内的 CSV。", "Choose a CSV no larger than 8 MiB.")
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                errorMessage = tS("请将文件另存为 UTF-8 CSV 后重试。", "Save the file as UTF-8 CSV and try again.")
                return
            }
            reset(try store.stageCSVReview(text: text, name: url.lastPathComponent))
            statusMessage = tS("已打开审核批次。账本没有变化。", "Review batch opened. The ledger is unchanged.")
        } catch {
            let failure = error as NSError
            guard failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func submit() {
        guard let detail else { return }
        do {
            reset(try store.applyCSVReview(batchID: detail.batch.id, revision: detail.revision, decisions: decisions,
                                           edits: edits, pairs: selectedPairs, overrideDuplicates: duplicateOverrides,
                                           confirmed: true))
            statusMessage = tS("审核结果已保存。", "Review saved.")
        } catch { errorMessage = error.localizedDescription }
    }

    private func undo() {
        guard let detail else { return }
        do {
            reset(try store.undoCSVReview(batchID: detail.batch.id, revision: detail.revision, confirmed: true))
            showingAllRows = true
            statusMessage = tS("本批入账已撤销。", "Entries from this batch were undone.")
        } catch { errorMessage = error.localizedDescription }
    }

    private func reset(_ result: CSVReviewDetail) {
        detail = result
        decisions.removeAll()
        edits.removeAll()
        selectedPairs.removeAll()
        duplicateOverrides.removeAll()
        showingAllRows = !result.rows.contains { $0.row.status == .pending }
        statusMessage = nil
    }

    private func kindTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "income", "收入": return tS("收入", "Income")
        case "expense", "支出": return tS("支出", "Expense")
        case "transfer", "转账": return tS("转账", "Transfer")
        default: return value
        }
    }

    private func statusTitle(_ status: CSVReviewStatus) -> String {
        switch status {
        case .pending: return tS("待确认", "Pending")
        case .applied: return tS("已入账", "Recorded")
        case .skipped: return tS("已跳过", "Skipped")
        case .undone: return tS("已撤销", "Undone")
        }
    }
}

private struct RowEditor: Identifiable {
    let id: String
    let line: Int
    let fields: CSVReviewFields
}

@MainActor
private struct CSVReviewRowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fields: CSVReviewFields
    let request: RowEditor
    let onChange: (Bool) -> Void
    let save: (CSVReviewFields) -> Void

    init(request: RowEditor, onChange: @escaping (Bool) -> Void, save: @escaping (CSVReviewFields) -> Void) {
        self.request = request
        self.onChange = onChange
        self.save = save
        _fields = State(initialValue: request.fields)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tS("修改待确认流水", "Edit Pending Row")).font(.title2.weight(.semibold))
                    Text(tS("CSV 第 \(request.line) 行", "CSV row \(request.line)")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tS("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tS("保留修改", "Keep Changes")) {
                    if fields != request.fields { save(fields) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            Form {
                Section {
                    TextField(tS("日期时间", "Date and Time"), text: $fields.date)
                    Text(tS("使用 YYYY-MM-DD 或带 UTC 偏移的 ISO 日期时间。", "Use YYYY-MM-DD or an ISO timestamp with a UTC offset."))
                        .font(.caption).foregroundStyle(.secondary)
                    TextField(tS("类型", "Type"), text: $fields.kind, prompt: Text(tS("收入、支出或转账", "income, expense or transfer")))
                    TextField(tS("账户", "Account"), text: $fields.accountName)
                    TextField(tS("金额", "Amount"), text: $fields.amount)
                    TextField(tS("币种", "Currency"), text: $fields.currency, prompt: Text("CNY"))
                    TextField(tS("分类", "Category"), text: $fields.categoryName)
                    TextField(tS("备注", "Note"), text: $fields.note, axis: .vertical).lineLimit(2...4)
                }
                Section(tS("转账", "Transfer")) {
                    TextField(tS("转入账户", "Destination Account"), text: $fields.targetAccountName)
                    TextField(tS("转入币种", "Destination Currency"), text: $fields.targetCurrency)
                    TextField(tS("实际转入金额", "Actual Amount Received"), text: $fields.targetAmount)
                    Text(tS("跨币种转账须核实实际到账金额。", "Verify the actual amount received for cross-currency transfers."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 450, idealWidth: 570, maxWidth: 700, minHeight: 440, idealHeight: 620, maxHeight: 760)
        .onChange(of: fields, initial: true) { _, values in onChange(values != request.fields) }
    }
}

private enum Confirmation: Identifiable {
    case close, pickFile, refresh, open(String), submit(entries: Int, pairs: Int, skips: Int), undo

    var id: String {
        switch self {
        case .close: return "close"
        case .pickFile: return "file"
        case .refresh: return "refresh"
        case let .open(id): return id
        case .submit: return "save"
        case .undo: return "undo"
        }
    }

    var title: String {
        switch self {
        case .submit: return tS("确认审核结果", "Confirm Review")
        case .undo: return tS("撤销本批入账？", "Undo This Batch?")
        default: return tS("放弃未提交的审核？", "Discard Unsubmitted Review?")
        }
    }

    var message: String {
        switch self {
        case let .submit(entries, pairs, skips):
            if entries == 0 && pairs == 0 {
                return tS("保存修改并跳过 \(skips) 行。其他流水仍待确认。", "Save changes and skip \(skips) rows. Other rows remain pending.")
            }
            return tS("将记入 \(entries) 笔流水和 \(pairs) 笔匹配转账，跳过 \(skips) 行。其余流水保留待确认。",
                      "Record \(entries) transactions and \(pairs) matched transfers, and skip \(skips) rows. Other rows remain pending.")
        case .undo:
            return tS("撤销将移除本批入账的流水。已创建的账户会保留。若原流水已变更，撤销会停止。",
                      "Undo removes entries from this batch. Created accounts are kept. If any imported entry has changed, the undo stops.")
        default:
            return tS("本次选择和修改尚未提交。原有批次仍保存在审核箱。",
                      "Unsubmitted changes will be discarded. Existing batches will stay in the inbox.")
        }
    }

    var button: String {
        switch self {
        case .submit: return tS("确认", "Confirm")
        case .undo: return tS("撤销", "Undo")
        default: return tS("放弃修改", "Discard Changes")
        }
    }

    var destructive: Bool {
        if case .submit = self { return false }
        return true
    }
}
