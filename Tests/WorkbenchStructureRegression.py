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
    for case in ("overview", "finances", "savings", "research", "adventure"):
        require(f"case {case}" in navigation, f"缺少主工作区 {case}")
    for section in (
        "overview", "ledger", "accounts", "budgets", "reports", "goals", "records",
        "analytics", "fixedIncome", "fixedExpenses", "benefits", "researchFunding", "adventure",
    ):
        require(f".{section}" in navigation, f"工作区未映射原栏目 {section}")
    for route in (
        'case "ledger"', 'case "overview"', 'case "budgets"', 'case "fixed-income"',
        'case "fixed-expenses", "today"', 'case "benefits"', 'case "research-funding"',
    ):
        require(route in content, f"旧深链分支被移除：{route}")
    require("WorkbenchTopNavigation" in content, "缺少五项顶部导航")
    require("WorkbenchWorkspaceTabs" in content, "缺少页内子导航")
    require("sidebar" not in content.lower(), "旧侧栏仍残留")


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


def main() -> None:
    test_workspace_navigation()
    test_visual_system()
    print("Workbench structure regression: PASS")


if __name__ == "__main__":
    main()
