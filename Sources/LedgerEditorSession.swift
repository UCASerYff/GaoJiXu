import Foundation

/// 一次打开对应一份草稿；编辑目标与表单身份一起确定。
struct LedgerEditorSession: Identifiable {
    let id = UUID()
    let entry: LedgerEntry?
}
