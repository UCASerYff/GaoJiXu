# 搞积蓄删除科研模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从搞积蓄删除科研功能及本机科研专属资料，发布 V4.06（构建 7），同时保证月供和其他用户业务不受影响。

**Architecture:** 顶层改为四项工作台，科研模型、存储、界面、导入和测试全部删除。离线迁移收拢为月供单模块；`FinanceAuthority` 只允许月供运行和初始化，但仅在验证旧月供联合提交凭据时兼容 `research-funding` 历史标识。共享月供凭据和提交标记保持原字节不变。

**Tech Stack:** Swift 5、SwiftUI、AppKit、SQLite、CryptoKit、Python 3 结构回归、zsh 构建脚本、GitHub Releases。

## Global Constraints

- 版本只升级为 `4.05 → 4.06`，构建号只升级为 `6 → 7`，主程序与 Widget 同步。
- 只删除科研及 `ResearchFunding`；不得改动月供、个人账本、固定收支、游戏、设置、钥匙串或小组件现用资料。
- 不创建或保留备份、导出副本、升级快照、旧程序或回滚副本；失败即停止并报告。
- 所有 `.app` 构建与展开副本在生成前位于 `.noindex` 容器，正式入口仅为 `/Applications/搞积蓄.app`。
- 不运行通用冒烟，不制造真实测试流水；测试窗口随用随关。

---

### Task 1: 删除科研路由、界面和业务源码

**Files:**
- Modify: `Tests/WorkbenchStructureRegression.py`
- Modify: `Sources/Models.swift`
- Modify: `Sources/WorkspaceNavigation.swift`
- Modify: `Sources/ContentView.swift`
- Modify: `Host/Settings.swift`
- Delete: `Sources/ResearchFundingModels.swift`
- Delete: `Sources/ResearchFundingStore.swift`
- Delete: `Sources/ResearchFundingImport.swift`
- Delete: `Sources/ResearchFundingView.swift`

**Interfaces:**
- Consumes: 现有 `SavingsSection`、`SavingsWorkspace` 和 `ContentView.detail` 路由。
- Produces: 仅 `overview / finances / savings / adventure` 四项工作区；不再有科研视图或科研记录 ID 状态。

- [ ] **Step 1: 先写失败的结构回归**

将 `test_workspace_navigation()` 的工作区列表改为：

```python
for case in ("overview", "finances", "savings", "adventure"):
    require(f"case {case}" in navigation, f"缺少主工作区 {case}")
require("case research" not in navigation, "科研工作区仍残留")
require("researchFunding" not in navigation, "科研栏目映射仍残留")
require('case "research-funding"' not in content, "科研深链仍残留")
require("ResearchFundingView" not in content, "科研页面仍残留")
for deleted in (
    "Sources/ResearchFundingModels.swift", "Sources/ResearchFundingStore.swift",
    "Sources/ResearchFundingImport.swift", "Sources/ResearchFundingView.swift",
):
    require(not (ROOT / deleted).exists(), f"科研源码仍存在：{deleted}")
```

从栏目映射与保留深链列表中删除 `researchFunding` 和 `case "research-funding"`，将“五项顶部导航”断言改为“四项顶部导航”。从 `test_records_and_editors()` 删除科研源码读取、科研编辑器断言及 `store.save(` 科研保存断言。

- [ ] **Step 2: 运行回归并确认失败**

Run: `python3 Tests/WorkbenchStructureRegression.py`
Expected: FAIL，提示科研工作区、深链或科研源码仍存在。

- [ ] **Step 3: 删除路由及四个科研源码文件**

在 `SavingsSection` 中删除 `researchFunding` 及其标题、说明、图标分支；在 `SavingsWorkspace` 删除 `case research` 的全部映射。在 `ContentView` 删除 `researchFundingRecordID`、科研深链分支和 `ResearchFundingView` 分支。设置页文案改为：

```swift
Text("账本、固定收支、游戏进度与附件继续保存在原位置。此处仅提供目录入口，不复制或改写资料。")
```

执行：

```bash
git rm -- Sources/ResearchFundingModels.swift Sources/ResearchFundingStore.swift \
  Sources/ResearchFundingImport.swift Sources/ResearchFundingView.swift
```

- [ ] **Step 4: 运行结构回归并确认通过**

Run: `python3 Tests/WorkbenchStructureRegression.py`
Expected: `Workbench structure regression: PASS`

- [ ] **Step 5: 提交**

```bash
git add -- Tests/WorkbenchStructureRegression.py Sources/Models.swift \
  Sources/WorkspaceNavigation.swift Sources/ContentView.swift Host/Settings.swift
git commit -m "Remove research workspace and business module"
```

### Task 2: 将迁移和权威校验收拢为月供专用

**Files:**
- Modify: `Sources/FinanceIntegrationMigration.swift`
- Modify: `Shared/FinanceAuthority.swift`
- Modify: `Tools/IntegrateFinance.swift`
- Modify: `scripts/test_finance_integration.sh`
- Modify: `Tests/FinanceIntegrationMigrationRegression.swift`
- Modify: `Tests/WorkbenchStructureRegression.py`
- Delete: `Tests/ResearchFundingRegression.swift`
- Delete: `Tests/run_research_funding.zsh`
- Delete: `Tests/Fixtures/ResearchFunding/research-funding-v1.json`

**Interfaces:**
- Consumes: `FinanceIntegrationMigration.run(_:)`、`FinanceAuthority.require(module:directory:)`。
- Produces: `Request` 仅含月供输入及月供目标目录；`FinanceAuthority` 对 `module == "monthly"` 保持现有签名，对科研模块拒绝运行或初始化。

- [ ] **Step 1: 把迁移回归改为月供专用并加入旧联合凭据兼容测试**

删除科研 fixture、附件、科研输入、科研目录和科研重放断言。请求构造统一为：

```swift
func request(_ label: String, _ tx: String = UUID().uuidString, frozen: Bool = true)
  -> Migration.Request {
  let dir = root.appendingPathComponent(label)
  return .init(
    schemaVersion: 1, txnID: tx, writersFrozen: frozen, targetWritersStopped: true,
    monthly: inp,
    targetMonthlyDirectory: dir.appendingPathComponent("group/Monthly").path,
    journalDirectory: dir.appendingPathComponent("private/journal").path,
    commitMarkerPath: dir.appendingPathComponent("group/Migrations/" + tx + "/committed.json").path)
}
```

保留月供冻结、暂存、提交、幂等、冲突、缺失输入、降级标记拒绝和中断恢复测试。将正常提交标记明确写成 `modules = ["monthly"]`，再增加独立旧凭据兼容用例：

```swift
let legacyReceipt = FinanceAuthorityReceipt(
  module: "monthly", transactionID: r.txnID,
  sourceBundleID: "com.gaoseries.GaoYueGong", sourceRevision: sha(payload),
  sourceFrozen: true, mode: "migrated", activatedAt: Date(),
  commitMarkerPath: FinanceAuthority.markerReference(for: marker),
  expectedModules: ["monthly", "research-funding"])
var legacyMarker = try JSONDecoder().decode(FinanceCommitMarker.self, from: Data(contentsOf: marker))
legacyMarker.modules = ["monthly", "research-funding"]
try JSONEncoder().encode(legacyReceipt).write(to: m.appendingPathComponent("authority.json"), options: .atomic)
try JSONEncoder().encode(legacyMarker).write(to: marker, options: .atomic)
_ = try FinanceAuthority.require(module: "monthly", directory: m)
try rejects("research module cannot run") {
  _ = try FinanceAuthority.require(module: "research-funding", directory: m)
}
```

在结构回归中新增：

```python
for deleted in (
    "Tests/ResearchFundingRegression.swift", "Tests/run_research_funding.zsh",
    "Tests/Fixtures/ResearchFunding/research-funding-v1.json",
):
    require(not (ROOT / deleted).exists(), f"科研测试仍存在：{deleted}")
migration = text("Sources/FinanceIntegrationMigration.swift")
for forbidden in ("ResearchInput", "ResearchFunding", "targetResearchDirectory"):
    require(forbidden not in migration, f"科研迁移仍残留：{forbidden}")
```

- [ ] **Step 2: 运行回归并确认失败**

Run: `./scripts/test_finance_integration.sh migration`
Expected: FAIL，新月供专用 `Request` 与当前科研字段不匹配，或旧联合凭据兼容断言失败。

- [ ] **Step 3: 实现月供单模块迁移**

`Request` 改为：

```swift
struct Request: Codable, Equatable {
  let schemaVersion: Int, txnID: String, writersFrozen: Bool, targetWritersStopped: Bool
  let monthly: MonthlyInput?
  let targetMonthlyDirectory: String, journalDirectory: String, commitMarkerPath: String
}
```

删除 `ResearchInput`、科研目标 URL、科研模块追加、科研附件清单/验证/归档/导入及科研当前目录校验。`Module.archiveName` 固定为 `snapshot.sqlite`。提交模块清单固定由月供输入产生：

```swift
expectedModules: [j.request.monthly == nil ? nil : "monthly"].compactMap { $0 }
```

新增私有辅助，替代科研文件工具：

```swift
private static func requireDirectory(_ url: URL) throws {
  guard let st = try status(url), (st.st_mode & S_IFMT) == S_IFDIR else {
    throw Failure("迁移目录不存在或不是普通目录。")
  }
}
private static func validDigest(_ value: String) -> Bool {
  value.utf8.count == 64 && value.utf8.allSatisfy {
    (48...57).contains($0) || (97...102).contains($0)
  }
}
```

将迁移内 `ResearchFundingFiles.requireDirectory(...)` 全部改为 `requireDirectory(...)`，将 `ResearchFundingFormat.digest(...)` 改为 `validDigest(...)`；删除其余科研专用调用。输入仍为必填的规范绝对路径，摘要、来源修订、冻结状态和事务 UUID 校验不得放宽。

`FinanceAuthority` 使用：

```swift
static let modules: Set<String> = ["monthly"]
private static let legacyCommittedModules: Set<String> = ["monthly", "research-funding"]
```

`require` 的来源校验只接受月供来源 `com.gaoseries.GaoYueGong`；`expectedModules` 必须包含 `monthly` 且是 `legacyCommittedModules` 子集，标记模块仍须与 `expectedModules` 完全相等。删除科研生产目录路径和科研本地目录特判。`createNew` 继续通过 `modules.contains(module)` 限制为月供。

CLI 只允许 `monthly`、`targetMonthlyDirectory`、`journalDirectory`、`commitMarkerPath` 及公共事务字段，帮助文本明确 `monthly:{snapshotPath,artifactSHA256,sourceRevision}` 为必需输入。`test_finance_integration.sh` 删除 research stage、科研源码数组和科研编译分支，迁移及 CLI 编译只加入 `Sources/FinanceIntegrationMigration.swift`。

删除科研测试：

```bash
git rm -- Tests/ResearchFundingRegression.swift Tests/run_research_funding.zsh \
  Tests/Fixtures/ResearchFunding/research-funding-v1.json
```

- [ ] **Step 4: 运行全部相关回归**

Run:

```bash
python3 Tests/WorkbenchStructureRegression.py
./scripts/test_finance_integration.sh all
```

Expected: 结构回归 `PASS`；月供迁移、固定收入、自动任务和 CLI 全部 `PASS`，脚本不再出现 research stage。

- [ ] **Step 5: 提交**

```bash
git add -- Sources/FinanceIntegrationMigration.swift Shared/FinanceAuthority.swift \
  Tools/IntegrateFinance.swift scripts/test_finance_integration.sh \
  Tests/FinanceIntegrationMigrationRegression.swift Tests/WorkbenchStructureRegression.py
git commit -m "Limit finance migration and authority to monthly"
```

### Task 3: 升级 V4.06、更新文档并构建发行包

**Files:**
- Modify: `Info.plist`
- Modify: `Widgets/Info.plist`
- Modify: `README.md`
- Modify: `AGENTS.md`（仅在需要记录无科研范围时）
- Test: `Tests/WorkbenchStructureRegression.py`

**Interfaces:**
- Consumes: Task 1–2 的四项工作台与月供专用迁移。
- Produces: 可安装的 V4.06（构建 7）签名 ZIP 和对应 SHA-256。

- [ ] **Step 1: 更新版本与公开说明**

主程序和 Widget 均设置：

```xml
<key>CFBundleShortVersionString</key>
<string>4.06</string>
<key>CFBundleVersion</key>
<string>7</string>
```

README 当前版本改为 V4.06（构建 7），导航改为“总览、收支、攒钱、冒险”，删除科研功能、科研数据路径和科研迁移说明；金融迁移只描述月供。新增版本记录：

```markdown
V4.06（构建 7）：完整移除科研资金入口、业务逻辑、迁移和测试；本机科研专属资料按用户确认删除。月供及其联合提交凭据保持兼容，个人账务、固定收支、游戏和小组件不受影响。
```

- [ ] **Step 2: 运行最终源码回归与构建**

Run:

```bash
python3 Tests/WorkbenchStructureRegression.py
./scripts/test_widget_contract.sh
./scripts/test_widget_store.sh
./scripts/test_finance_integration.sh all
./scripts/build.sh
./scripts/package.sh
(cd dist && shasum -a 256 -c 搞积蓄-4.06.zip.sha256)
```

Expected: 所有测试 `PASS`，生成签名有效的 `dist/搞积蓄-4.06.zip` 且 SHA-256 为 `OK`。

- [ ] **Step 3: 提交**

```bash
git add -- Info.plist Widgets/Info.plist README.md AGENTS.md
git commit -m "Release V4.06 without research module"
```

### Task 4: 安装 V4.06 并精确删除科研资料

**Files:**
- Delete: `~/Library/Application Support/GaoSeries/Savings/ResearchFunding/`（仅用户明确授权的科研专属目录）
- Preserve: 其他 `Savings` 与 App Group 现用资料，尤其 `IntegratedFinance/Monthly/` 和共享提交标记。

**Interfaces:**
- Consumes: Task 3 的已校验 ZIP。
- Produces: `/Applications/搞积蓄.app` 为 V4.06（构建 7），科研目录不存在，月供和其他业务可读。

- [ ] **Step 1: 安装前只读核验**

记录两个现用资料根目录的文件数、逐文件 SHA-256、mtime 和 SQLite 完整性；单独列出科研目录内容。若科研目录出现符号链接、无法读取对象或超出当前两份 JSON 的意外内容，停止并报告，不扩大删除范围。正常退出 V4.05。

- [ ] **Step 2: 无备份安装并核验其他资料未变**

Run: `./scripts/install.sh`
Expected: 安装 V4.06 build 7，签名验证通过，未创建程序或资料副本。安装后、启动前重新计算非科研资料摘要，必须与安装前一致。

- [ ] **Step 3: 删除科研专属目录并验证保留业务**

仅当 Step 1 已确认精确身份后执行：

```bash
rm -rf -- "$HOME/Library/Application Support/GaoSeries/Savings/ResearchFunding"
```

随后确认该目录不存在；对月供数据库运行只读 `PRAGMA integrity_check`，要求 `ok`；核对月供 `authority.json`、共享 `committed.json`、`monthly.sqlite`、个人 `library.json`、账户绑定、自动任务及科研外附件仍存在且安装阶段未被改写。不得删除共享提交标记。

- [ ] **Step 4: 定向运行验收**

启动 V4.06，确认窗口标题和四项导航；如捕获服务可用，依次打开四项工作区并取消编辑器，不保存测试内容，验证月供和固定收支页面。若仍返回无显示内容，明确记录真实界面验收未完成。关闭本轮测试窗口。

### Task 5: 清理、推送和发布

**Files:**
- Keep: `dist/搞积蓄-4.06.zip`、`dist/搞积蓄-4.06.zip.sha256`
- Create: `dist/GaoJiXu-4.06-source.zip`、`dist/GaoJiXu-4.06-source.zip.sha256`
- Delete: V4.05 本地发行包、`build.noindex/`、`.install.noindex/`、`.release.noindex/` 和其他中间产物。

**Interfaces:**
- Consumes: 已安装并验证的 V4.06 与干净 Git 工作区。
- Produces: 远端 `main` 和 `v4.06` Release；网络或界面阻塞必须单独保留，不能算作完成。

- [ ] **Step 1: 清理并核对唯一入口**

删除旧发行包及中间目录，运行 `mdfind 'kMDItemCFBundleIdentifier == "com.gaojixu.savings"'` 和 LaunchServices 核验。唯一有效应用路径必须是 `/Applications/搞积蓄.app`，版本 4.06、构建 7。

- [ ] **Step 2: 生成公开源码包并推送**

从最终提交执行 `git archive`，生成源码 ZIP 和 SHA-256；检查不含 `ResearchFunding` 用户目录、个人 JSON、SQLite、附件、备份、凭据或私有验证资料。推送 `main` 到 `UCASerYff/GaoJiXu`。

- [ ] **Step 3: 创建并回查 V4.06 Release**

上传程序 ZIP、源码 ZIP 和对应校验文件，回查资产名称、大小、状态和 Release 非草稿状态。大型资产上传若再次超时，先读取实际 Release 状态，不盲目重试；保留草稿或缺失状态并如实报告。

- [ ] **Step 4: 最终复核**

重新运行结构、金融、小组件和存储回归，清理测试产生的 `build.noindex/`。确认 Git 工作区干净、远端 `main` 与本地 HEAD 一致、安装包校验通过、科研目录不存在、其他现用资料可读。只有所有要求均有本轮证据时才声明全部完成。
