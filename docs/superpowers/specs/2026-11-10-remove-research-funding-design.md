# 搞积蓄删除科研模块设计

日期：2026-11-10
状态：用户已确认“只删科研、不动月供”的范围

## 目标

从搞积蓄中完整移除科研资金功能，并删除本机科研专属资料。顶部工作台由“总览、收支、攒钱、科研、冒险”改为“总览、收支、攒钱、冒险”。版本由 V4.05（构建 6）升级为 V4.06（构建 7）。

## 明确范围

### 删除

- `SavingsSection.researchFunding`、科研工作区、科研页面和科研深链分支。
- 科研模型、存储、导入及界面源码：
  - `Sources/ResearchFundingModels.swift`
  - `Sources/ResearchFundingStore.swift`
  - `Sources/ResearchFundingImport.swift`
  - `Sources/ResearchFundingView.swift`
- 科研迁移输入、科研附件处理和科研提交分支；迁移 CLI 不再接受科研请求字段或科研目标目录。
- 科研专用回归、运行脚本和 fixture。
- 本机 `~/Library/Application Support/GaoSeries/Savings/ResearchFunding/` 整个目录。当前盘点仅包含 `authority.json` 与 `library.json`，没有附件；执行前重新核对目录内容，若出现无法读取或意外对象则停止。

### 保留且不得改动

- 月供、固定收入、固定支出、权益及其 SQLite、账户绑定和自动记账任务。
- 个人账本、账户、目标、积蓄记录、预算、游戏进度、设置、钥匙串和小组件现用快照。
- 月供现用的 `authority.json` 与共享 `IntegratedFinance/Migrations/.../committed.json`，不删除、不改写。
- 科研以外的源码、文档和公开资源。

## 架构调整

1. `Models.swift`、`WorkspaceNavigation.swift` 和 `ContentView.swift` 删除科研路由及视图分支；未知旧科研深链不执行任何业务操作。
2. `FinanceIntegrationMigration.swift` 改为仅处理月供。科研专用附件、模型和导入逻辑全部删除。
3. 将月供迁移仍使用的通用文件、目录、摘要与路径安全检查留在迁移实现中，或抽取为不含科研语义的通用迁移辅助代码，不能因删除科研模型而失去安全检查。
4. `FinanceAuthority` 仅允许月供作为可运行、可创建的金融模块。为保持现有月供只读兼容，验证旧凭据时仍接受历史联合模块清单中的 `research-funding` 字符串；该字符串不构成科研功能，不读取或创建科研目录，也不改写共享凭据。
5. 设置页和 README 删除科研功能说明，更新四项导航及当前版本。

## 数据处理与失败规则

- 先完成源码回归、构建和发行包核验，再正常退出旧程序并安装 V4.06。
- 安装前后分别只读核验科研以外的现用资料；无法读取不得视为空白。
- 新版本安装成功后，按精确路径删除 `ResearchFunding`；不创建备份、导出、升级快照或回滚副本。
- 删除后确认科研目录不存在，月供数据库 `PRAGMA integrity_check` 为 `ok`，其他业务资料未发生意外变化。
- 任一步骤失败即停止并如实报告，不自动恢复、不新造备份。

## 验证

- 工作台结构回归确认四项导航、无科研入口、无科研编辑器，旧科研路由不会打开业务页面。
- 金融迁移回归改为月供专用，并验证历史联合提交标记仍能解锁月供；科研模块不能初始化或写入。
- 运行小组件契约、存储、金融整合和结构回归，完成 Apple Silicon 构建、签名和 ZIP 校验。
- 安装后核对个人账务、月供、固定收支、游戏和小组件数据；真实界面捕获不可用时明确保留验收限制，不把启动成功当作视觉验收。
- 清理构建目录、旧发行包及临时副本，确保 Spotlight 和 LaunchServices 只保留 `/Applications/搞积蓄.app` 的有效应用入口。
- 推送源码及 V4.06 安装包；上传失败时保留实际状态，不宣称 Release 已发布。
