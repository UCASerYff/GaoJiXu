# 搞积蓄财务工作台 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将搞积蓄 V4.05 改造成五项顶部导航的现代财务工作台，重做主要记录界面并彻底移除备份功能，随后无备份安装和发布。

**Architecture:** 保留 `SavingsSection` 作为深链兼容路由，在其上增加主工作区与页内子导航映射。新增统一视觉组件承载标题、卡片、状态胶囊、工具栏和编辑器骨架，各业务 Store 与数据格式不变；宿主备份代码与安装回滚逻辑独立移除。

**Tech Stack:** Swift 5、SwiftUI、AppKit、Python 3 结构回归、zsh 构建脚本、SQLite、GitHub Releases。

## Global Constraints

- 版本仅由 V4.04 / build 5 升为 V4.05 / build 6；Bundle ID、App Group、数据路径和钥匙串服务不变。
- 不改变财务计算、业务模型、游戏进度、附件、小组件快照契约或旧 `gaojixu://` 深链目标。
- 不创建或保留任何程序/资料备份、恢复副本、升级快照或旧安装包；失败停止并如实报告。
- 所有构建和暂存 App 在生成前位于 `.noindex` 容器；测试窗口随用随关，不默认运行通用冒烟。
- 正式入口仅为 `/Applications/搞积蓄.app`；GitHub 只上传源码和最新安装包，不上传用户数据、附件、备份或凭据。

---

### Task 1: 工作区路由与顶部导航

**Files:**
- Create: `Sources/WorkspaceNavigation.swift`
- Create: `Tests/WorkbenchStructureRegression.py`
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/Models.swift`

**Interfaces:**
- Produces: `SavingsWorkspace`、`SavingsWorkspace.finances`、`SavingsWorkspace.savings`、主工作区到 `SavingsSection` 的映射，以及 `SavingsWorkspaceTab` 通用页内选择器。
- Consumes: 现有 `SavingsSection`、`gaojixuSelectSection`、`route` 和 `routeRevision`。

- [ ] **Step 1: 写失败的结构回归**
  新建 Python 回归，读取 `WorkspaceNavigation.swift` 和 `ContentView.swift`，断言五个 `SavingsWorkspace` case、旧 13 个 `SavingsSection` 的映射、顶部 `记一笔` 操作和旧深链分支均存在；初次运行因文件不存在而 FAIL。
- [ ] **Step 2: 运行失败测试**
  Run: `python3 Tests/WorkbenchStructureRegression.py`
  Expected: FAIL，提示缺少 `Sources/WorkspaceNavigation.swift`。
- [ ] **Step 3: 实现路由和导航**
  定义 `SavingsWorkspace: String, CaseIterable, Identifiable` 的 `overview/finances/savings/research/adventure`；用 `sections` 和 `defaultSection` 明确映射。`ContentView` 用顶部品牌、五项导航和主操作替代侧栏，页内 `Picker(.segmented)` 只展示当前工作区子项；固定收支内部复用原 `SavingsSection.fixedIncome/fixedExpenses/benefits`。
- [ ] **Step 4: 验证路由与编译**
  Run: `python3 Tests/WorkbenchStructureRegression.py && ./scripts/build.sh`
  Expected: 结构回归 PASS，Swift 编译和签名验证成功。
- [ ] **Step 5: 提交**
  `git add Sources/WorkspaceNavigation.swift Sources/ContentView.swift Sources/Models.swift Tests/WorkbenchStructureRegression.py && git commit -m "Refactor savings navigation into five workspaces"`

### Task 2: 统一视觉系统与总览

**Files:**
- Modify: `Sources/AppTheme.swift`
- Create: `Sources/WorkbenchComponents.swift`
- Modify: `Sources/AccountingViews.swift`

**Interfaces:**
- Produces: `SavingsTheme.accent/canvas/panel`、`WorkbenchPageHeader`、`WorkbenchCard`、`WorkbenchStatusPill`、`WorkbenchEditorScaffold` 和 `savingsPanel()` 新样式。
- Consumes: Task 1 的五个工作区与现有 `SavingsSettings.canvasColor(for:)`。

- [ ] **Step 1: 扩展失败结构回归**
  断言暖白/墨绿色板、现代标题字体、统一卡片与编辑器骨架被总览和导航引用；运行 Python 回归，预期因符号缺失 FAIL。
- [ ] **Step 2: 实现视觉组件**
  用动态 `NSColor` 提供深浅色暖白/墨绿层级；财务标题改为系统字体，像素字体仅保留游戏组件。统一 16–18 点圆角、细边框、轻阴影、金额等宽数字和可访问标签。
- [ ] **Step 3: 重排总览**
  保留 `PendingAutoLedgerBanner`、四项统计、账户/预算、最近流水/目标、冒险、月历和 `AutoLedgerReconciliationCard`，将净资产设为视觉主卡片，其余按两列自适应排布，不删任何数据判断。
- [ ] **Step 4: 验证**
  Run: `python3 Tests/WorkbenchStructureRegression.py && ./scripts/build.sh`
  Expected: PASS，编译无新增错误。
- [ ] **Step 5: 提交**
  `git add Sources/AppTheme.swift Sources/WorkbenchComponents.swift Sources/AccountingViews.swift Tests/WorkbenchStructureRegression.py && git commit -m "Apply workbench visual system and overview"`

### Task 3: 重做记录列表与编辑器

**Files:**
- Modify: `Sources/AccountingViews.swift`
- Modify: `Sources/FinanceViews.swift`
- Modify: `Sources/FixedIncomeView.swift`
- Modify: `Sources/MonthlyFinanceViews.swift`
- Modify: `Sources/MonthlyFinanceEditors.swift`
- Modify: `Sources/ResearchFundingView.swift`

**Interfaces:**
- Consumes: Task 2 的 `WorkbenchPageHeader`、`WorkbenchStatusPill`、`WorkbenchEditorScaffold`。
- Produces: 日期分组流水/积蓄记录、统一状态行和一致编辑器容器；原 Store 保存函数签名不变。

- [ ] **Step 1: 写失败结构回归**
  断言流水和积蓄记录使用日期分组组件，主要编辑器不再直接以系统 `Form` 作为外层视觉容器，且 `saveLedgerEntry`、`saveRecord`、`confirmFixedIncome`、`MonthlyFinanceEngine` 和科研 `store.save` 调用仍保留。
- [ ] **Step 2: 实现日期分组记录**
  用 `Dictionary(grouping:)` 和 `Calendar.startOfDay` 分组，组内按原时间倒序；保留搜索、类型筛选、100 条分页、单击编辑、右键菜单、余额调整/积蓄转账受管提示和删除确认。
- [ ] **Step 3: 重做编辑器**
  记账与积蓄编辑器采用大金额卡片和底部分栏操作；目标、账户、预算、固定收入、月供和科研编辑器使用统一标题/内容/底部操作骨架。所有原校验、保存并再记一笔、跨币种金额、确认到账和附件逻辑原样接入。
- [ ] **Step 4: 验证**
  Run: `python3 Tests/WorkbenchStructureRegression.py && ./scripts/build.sh && swiftc -parse Sources/MonthlyFinanceEditors.swift Sources/ResearchFundingView.swift`
  Expected: 结构回归和完整构建 PASS；单文件 parse 只检查语法，不作为链接验证。
- [ ] **Step 5: 提交**
  `git add Sources/AccountingViews.swift Sources/FinanceViews.swift Sources/FixedIncomeView.swift Sources/MonthlyFinanceViews.swift Sources/MonthlyFinanceEditors.swift Sources/ResearchFundingView.swift Tests/WorkbenchStructureRegression.py && git commit -m "Redesign finance records and editors"`

### Task 4: 移除备份与无回滚安装流程

**Files:**
- Modify: `Host/AppMain.swift`
- Modify: `Host/Settings.swift`
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/StorePersistence.swift`
- Modify: `Tools/StageWidgetSnapshot.swift`
- Modify: `scripts/install.sh`
- Modify: `Info.plist`
- Delete: `Host/AppBackupExport.swift`, `Host/AppBackupRestore.swift`, `Host/BackupIntegrity.swift`, `Host/DailyBackup.swift`, `Tests/BackupSafetyRegression.swift`, `scripts/install_safety.py`, `scripts/install_registration.py`, `scripts/install_provenance.py`, `Tests/InstallWidgetElectionRegression.py`, `Tests/InstallRegistrationFlowRegression.py`, `Tests/InstallInventoryRegression.py`, `Tests/InstallRegistrationRegression.py`, `Tests/InstallSafetyRegression.py`。
- Test: `Tests/WorkbenchStructureRegression.py`

**Interfaces:**
- Produces: 无备份菜单、设置入口、启动恢复、文件类型声明和回滚副本的安装流程。
- Consumes: 现有 `SavingsModuleRuntime.flush()`、打包校验、开发签名和唯一 Bundle ID。

- [ ] **Step 1: 写失败回归**
  断言活跃 Host、Sources、scripts 不含 `AppBackupExport/AppBackupRestore/gaojixu.exportBackup/gaojixu.restoreBackup/rollback.noindex/previous-program.zip`，设置仅保留数据目录入口；初跑 FAIL。
- [ ] **Step 2: 删除备份功能**
  删除 Host 备份实现和旧测试，移除通知、菜单、恢复确认、UTType 与启动恢复。把仅供内部一致性比较的 `backupData()` 重命名为 `snapshotData()`，同步 `StageWidgetSnapshot`；不删除现用快照、科研回收站或业务数据。
- [ ] **Step 3: 重写安装器**
  安装器先验证 ZIP、签名、Team ID、Bundle ID、版本与构建号，在 `.install.noindex` 解压并再次校验；确认主程序退出后，只注销精确旧路径，删除 `/Applications/搞积蓄.app`，再安装候选。失败退出并报告，不创建安全副本或回滚目录。
- [ ] **Step 4: 验证**
  Run: `python3 Tests/WorkbenchStructureRegression.py && zsh -n scripts/install.sh && ./scripts/build.sh`
  Expected: PASS；构建产物仍只在 `build.noindex`。
- [ ] **Step 5: 提交**
  `git add -A Host Sources/ContentView.swift Sources/StorePersistence.swift Tools/StageWidgetSnapshot.swift scripts Tests Info.plist && git commit -m "Remove backup and rollback facilities"`

### Task 5: 版本、隔离回归与真实资料核验

**Files:**
- Modify: `Info.plist`
- Modify: `Widgets/Info.plist`（若独立版本文件存在）
- Modify: `README.md`
- Modify: `AGENTS.md`（仅移除与最新无备份规则冲突的旧说明）

**Interfaces:**
- Produces: V4.05 / build 6 发行源码与准确使用说明。

- [ ] **Step 1: 升版本并更新说明**
  设置 `CFBundleShortVersionString=4.05`、`CFBundleVersion=6`，文档说明五项导航、新记录界面和不再提供备份/恢复；不得写成保留或创建备份。
- [ ] **Step 2: 跑隔离回归**
  Run: `./scripts/test_widget_contract.sh && ./scripts/test_widget_store.sh && ./scripts/test_finance_integration.sh`
  Expected: 全部 PASS，测试只写隔离目录。
- [ ] **Step 3: 核验真实资料**
  在只读条件下记录 `~/Library/Application Support/GaoSeries/Savings`、App Group 和钥匙串服务存在性；逐文件列出附件与数据库，SQLite 只读 `PRAGMA integrity_check`，记录升级前文件大小/mtime/SHA-256 清单到标准输出，不写项目目录。
- [ ] **Step 4: 构建发行包**
  Run: `./scripts/build.sh && ./scripts/package.sh && (cd dist && shasum -a 256 -c 搞积蓄-4.05.zip.sha256)`
  Expected: V4.05 ZIP 与校验文件生成，签名和包内容核验通过。
- [ ] **Step 5: 提交**
  `git add Info.plist Widgets README.md AGENTS.md && git commit -m "Release V4.05 workbench refresh"`

### Task 6: 安装验收、精确清理与 GitHub 发布

**Files:**
- Runtime only: `/Applications/搞积蓄.app`、两个现用数据目录、`dist/搞积蓄-4.05.zip*`。
- No private verification file is added to the repository.

**Interfaces:**
- Consumes: Task 5 已校验发行包与真实资料清单。

- [ ] **Step 1: 安装并核验**
  正常退出旧主程序，运行 `./scripts/install.sh`；检查安装包与正式 App 的签名、版本、Bundle ID 和字节内容。启动新版，依次观察五个工作区，打开主要编辑器后取消，不保存测试记录；验证旧深链、原记录、附件、游戏进度和小组件。测试窗口随用随关。
- [ ] **Step 2: 对比资料**
  重跑只读资料清单与 SQLite 检查，确认现用数据库、设置、附件、游戏进度和钥匙串未丢失；若无法读取立即停止，不以空白库覆盖。
- [ ] **Step 3: 删除旧件、备份与中间产物**
  只删除识别为备份/恢复/旧程序/旧安装包的精确路径，以及 `build.noindex`、`.release.noindex`、`.install.noindex`、旧 `rollback.noindex`、旧 dist 包和临时副本。保留 V4.05 ZIP/SHA-256、源码、现用业务数据与系统钥匙串。
- [ ] **Step 4: 核验唯一入口**
  用 `mdfind`、LaunchServices 和真实文件路径逐项记录本 Bundle ID/应用名结果；所有有效结果只指向 `/Applications/搞积蓄.app`。无法取得真实用户会话结果时不得标记完成。
- [ ] **Step 5: 推送 GitHub**
  检查 `git status` 与公开文件清单，推送 `main` 到 `UCASerYff/GaoJiXu`，创建 `v4.05` Release，上传 `dist/搞积蓄-4.05.zip`、`.sha256` 和仅含公开源码的源码包；重新读取 Release 资产名称、大小和摘要，确认没有用户资料或备份。
