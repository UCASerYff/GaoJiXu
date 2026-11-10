import SwiftUI

/// 顶层工作台。旧 SavingsSection 保留为业务路由，避免破坏通知、深链和场景记忆。
enum SavingsWorkspace: String, CaseIterable, Identifiable {
    case overview
    case finances
    case savings
    case research
    case adventure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: tS("总览", "Overview")
        case .finances: tS("收支", "Finances")
        case .savings: tS("攒钱", "Savings")
        case .research: tS("科研", "Research")
        case .adventure: tS("冒险", "Adventure")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .finances: "arrow.left.arrow.right.circle.fill"
        case .savings: "target"
        case .research: "building.columns.fill"
        case .adventure: "map.fill"
        }
    }

    var sections: [SavingsSection] {
        switch self {
        case .overview: [.overview]
        case .finances: [.ledger, .accounts, .budgets, .reports, .fixedIncome]
        case .savings: [.goals, .records, .analytics]
        case .research: [.researchFunding]
        case .adventure: [.adventure]
        }
    }

    var defaultSection: SavingsSection {
        switch self {
        case .overview: .overview
        case .finances: .ledger
        case .savings: .goals
        case .research: .researchFunding
        case .adventure: .adventure
        }
    }

    static func containing(_ section: SavingsSection) -> SavingsWorkspace {
        switch section {
        case .overview: .overview
        case .ledger, .accounts, .budgets, .reports, .fixedIncome, .fixedExpenses, .benefits: .finances
        case .goals, .records, .analytics: .savings
        case .researchFunding: .research
        case .adventure: .adventure
        }
    }

    func displays(_ section: SavingsSection) -> Bool {
        switch self {
        case .finances:
            return [.ledger, .accounts, .budgets, .reports, .fixedIncome, .fixedExpenses, .benefits].contains(section)
        default:
            return sections.contains(section)
        }
    }

    /// 固定收支三项共用一个二级入口，在工作区内部再切换。
    func canonicalSection(for section: SavingsSection) -> SavingsSection {
        if self == .finances, [.fixedIncome, .fixedExpenses, .benefits].contains(section) { return .fixedIncome }
        return section
    }
}

struct WorkbenchTopNavigation: View {
    @Binding var selection: SavingsSection
    @State private var hovered: SavingsWorkspace?

    private var workspace: SavingsWorkspace { .containing(selection) }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 11) {
                if let url = SavingsBundle.bundle.url(forResource: "GaoJiXuIcon", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(tS("搞积蓄", "Gao Savings")).font(.system(size: 17, weight: .bold))
                    Text(tS("我的财务工作台", "My finance workspace")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 174, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(SavingsWorkspace.allCases) { item in
                    let selected = workspace == item
                    Button {
                        guard !selected || item != .overview else { return }
                        if !selected { selection = item.defaultSection }
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.callout.weight(selected ? .semibold : .medium))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 13)
                            .frame(minHeight: 38)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(SavingsTheme.accent.gradient)
                                        .shadow(color: SavingsTheme.accent.opacity(0.22), radius: 8, y: 3)
                                } else if hovered == item {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055))
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in hovered = hovering ? item : nil }
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }
}

struct WorkbenchWorkspaceTabs: View {
    @Binding var selection: SavingsSection

    private var workspace: SavingsWorkspace { .containing(selection) }

    var body: some View {
        if workspace.sections.count > 1 {
            HStack {
                Picker(tS("工作区内容", "Workspace content"), selection: Binding(
                    get: { workspace.canonicalSection(for: selection) },
                    set: { selection = $0 }
                )) {
                    ForEach(workspace.sections) { section in
                        Text(section == .fixedIncome ? tS("固定收支", "Recurring") : section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: workspace == .finances ? 650 : 390)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 12)
        }
    }
}

struct FixedFinanceWorkspace: View {
    @Binding var selection: SavingsSection

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(tS("固定收支类型", "Recurring finance type"), selection: $selection) {
                    Text(tS("固定收入", "Income")).tag(SavingsSection.fixedIncome)
                    Text(tS("固定支出", "Expenses")).tag(SavingsSection.fixedExpenses)
                    Text(tS("权益", "Benefits")).tag(SavingsSection.benefits)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 390)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 10)

            switch selection {
            case .fixedExpenses: FixedExpenseView()
            case .benefits: MonthlyBenefitsView()
            default: FixedIncomeView()
            }
        }
    }
}
