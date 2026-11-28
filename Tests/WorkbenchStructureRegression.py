#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def text(relative: str) -> str:
    path = ROOT / relative
    require(path.is_file(), f"缺少 {relative}")
    return path.read_text(encoding="utf-8")


def test_workspace_navigation() -> None:
    navigation = text("Sources/WorkspaceNavigation.swift")
    content = text("Sources/ContentView.swift")
    for case in ("overview", "finances", "savings", "adventure"):
        require(f"case {case}" in navigation, f"缺少主工作区 {case}")
    require("case research" not in navigation, "科研工作区仍残留")
    require("researchFunding" not in navigation, "科研栏目映射仍残留")
    for section in (
        "overview", "ledger", "accounts", "budgets", "reports", "goals", "records",
        "analytics", "fixedIncome", "fixedExpenses", "adventure",
    ):
        require(f".{section}" in navigation, f"工作区未映射原栏目 {section}")
    for route in (
        'case "ledger"', 'case "overview"', 'case "budgets"', 'case "fixed-income"',
        'case "fixed-expenses", "today", "benefits": selection = .fixedExpenses',
    ):
        require(route in content, f"旧深链分支被移除：{route}")
    require('case "research-funding"' not in content, "科研深链仍残留")
    require("ResearchFundingView" not in content, "科研页面仍残留")
    for deleted in (
        "Sources/ResearchFundingModels.swift", "Sources/ResearchFundingStore.swift",
        "Sources/ResearchFundingImport.swift", "Sources/ResearchFundingView.swift",
    ):
        require(not (ROOT / deleted).exists(), f"科研源码仍存在：{deleted}")
    require("WorkbenchTopNavigation" in content, "缺少四项顶部导航")
    require("WorkbenchWorkspaceTabs" in content, "缺少页内子导航")
    require("sidebar" not in content.lower(), "旧侧栏仍残留")
    for deleted in (
        "Tests/ResearchFundingRegression.swift", "Tests/run_research_funding.zsh",
        "Tests/Fixtures/ResearchFunding",
    ):
        require(not (ROOT / deleted).exists(), f"科研测试仍存在：{deleted}")
    migration = text("Sources/FinanceIntegrationMigration.swift")
    for forbidden in ("ResearchInput", "ResearchFunding", "targetResearchDirectory"):
        require(forbidden not in migration, f"科研迁移仍残留：{forbidden}")


def test_retired_benefits_entry_points() -> None:
    content = text("Sources/ContentView.swift")
    sections = text("Sources/Models.swift")
    navigation = text("Sources/WorkspaceNavigation.swift")
    monthly = text("Sources/MonthlyFinanceViews.swift") + text("Sources/MonthlyFinanceEditors.swift")
    bundle = text("Widgets/GaoJiXuWidgets.swift")
    expense_widget = text("Widgets/IntegratedFinanceWidgets.swift")
    require('@SceneStorage("gqns.page.Savings")' in content, "现有场景记忆键被更改")
    require("SavingsSection.restoring(storedSection)" in content, "场景记忆未经过兼容入口")
    require('value == "benefits" ? .fixedExpenses' in sections, "旧权益场景未回落固定支出")
    require(".benefits" not in sections + navigation + content, "旧权益栏目仍可选")
    for kept in ("SavingsSection.fixedIncome", "SavingsSection.fixedExpenses"):
        require(f".tag({kept})" in navigation, f"固定收支切换丢失入口 {kept}")
    for retired in ("MonthlyBenefitsView", "MonthlyFinanceClaimHistory", "MonthlyFinanceBenefitEditor"):
        require(retired not in monthly, f"旧权益界面仍残留 {retired}")
    for kept in ("MonthlyFinanceCalendarWidget()", "NetWorthWidget()", "SavingsFixedExpenseWidget()"):
        require(kept in bundle, f"保留的小组件未注册 {kept}")
    for kept in ('"GaoJiXuFixedExpense"', '"gaojixu://fixed-expenses"'):
        require(kept in expense_widget, f"固定支出小组件入口发生变化 {kept}")
    for retired in ("SavingsMonthlyBenefitsWidget", "GaoJiXuMonthlyBenefits", "SavingsClaimBenefitIntent"):
        require(retired not in bundle + expense_widget, f"旧权益小组件入口仍残留 {retired}")


def test_visual_system() -> None:
    theme = text("Sources/AppTheme.swift")
    components = text("Sources/WorkbenchComponents.swift")
    accounting = text("Sources/AccountingViews.swift")
    navigation = text("Sources/WorkspaceNavigation.swift")
    require("static let accent" in theme, "缺少墨绿主色")
    require("static func canvas" in theme, "缺少动态画布色")
    for symbol in ("WorkbenchPageHeader", "WorkbenchCard", "WorkbenchStatusPill", "WorkbenchEditorScaffold"):
        require(f"struct {symbol}" in components, f"缺少统一组件 {symbol}")
    require("WorkbenchPageHeader" in accounting, "总览未使用统一标题")
    require("SavingsTheme.accent" in navigation, "顶部导航未使用新主色")
    require('Text(section.title).font(.pixel' not in theme, "财务标题仍使用像素字体")


def test_records_and_editors() -> None:
    accounting = text("Sources/AccountingViews.swift")
    finance = text("Sources/FinanceViews.swift")
    fixed_income = text("Sources/FixedIncomeView.swift")
    monthly = text("Sources/MonthlyFinanceEditors.swift")
    require("LedgerDayGroup" in accounting, "流水未按日期分组")
    require("SavingsDayGroup" in finance, "积蓄记录未按日期分组")
    for name, source in (
        ("记账", accounting), ("积蓄", finance), ("固定收入", fixed_income),
        ("固定支出", monthly),
    ):
        require("WorkbenchEditorScaffold" in source, f"{name}编辑器未使用统一骨架")
    for preserved in (
        "store.saveLedgerEntry", "store.saveRecord", "store.confirmFixedIncome",
        "MonthlyFinanceEngine.savePayment", "MonthlyFinanceEngine.saveSubscription",
    ):
        require(preserved in accounting + finance + fixed_income + monthly, f"原保存流程丢失：{preserved}")


def test_backup_removal() -> None:
    active = "\n".join(
        path.read_text(encoding="utf-8")
        for folder in ("Host", "Sources", "scripts")
        for path in (ROOT / folder).rglob("*")
        if path.is_file() and path.suffix in (".swift", ".sh", ".py")
    )
    for forbidden in (
        "AppBackupExport", "AppBackupRestore", "gaojixu.exportBackup", "gaojixu.restoreBackup",
        "rollback.noindex", "previous-program.zip", "ReconciliationBackups", "migration-backup",
    ):
        require(forbidden not in active, f"备份或回滚功能仍残留：{forbidden}")
    for deleted in (
        "Host/AppBackupExport.swift", "Host/AppBackupRestore.swift", "Host/BackupIntegrity.swift",
        "Host/DailyBackup.swift", "Tests/BackupSafetyRegression.swift", "scripts/install_safety.py",
    ):
        require(not (ROOT / deleted).exists(), f"旧备份文件仍存在：{deleted}")
    require("func snapshotData()" in active, "内部一致性快照编码入口缺失")
    require("打开数据目录" in active and "打开小组件共享目录" in active, "现用数据目录入口被误删")


def main() -> None:
    test_workspace_navigation()
    test_retired_benefits_entry_points()
    test_visual_system()
    test_records_and_editors()
    test_backup_removal()
    print("Workbench structure regression: PASS")


if __name__ == "__main__":
    main()
