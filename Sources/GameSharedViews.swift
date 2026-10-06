import SwiftUI

// MARK: - 共享文案

/// 游戏域共享文案。凡是多处出现的规则文案都收敛到这里，避免口径漂移。
enum GameCopy {
    /// 星券兑换规则。与 SavingsStore.grantSavingsGrowth 的结算口径一致
    /// （每 1 个货币单位 → 1 张星券，完成目标额外 +100 张）；改动时需同步。
    static let ticketPerUnitRule = "每积蓄 1 个货币单位获得 1 张星券"
}

// MARK: - 15 维战斗属性定义

/// 15 维战斗属性的统一条目：名称/图标/颜色 + 两种取值口径。
/// `total` 用于 CharacterAttributesPanel（角色总属性），
/// `enhanced` 用于 EquipmentDetailView（单件装备按当前强化等级折算）。
struct AttributeDefinition: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    let color: Color
    let total: @MainActor (SavingsStore) -> String
    let enhanced: @MainActor (SavingsStore, EquipmentDefinition) -> String
}

/// 15 维战斗属性定义表。CharacterAttributesPanel 与 EquipmentDetailView 共用，
/// 保证两处属性的顺序、名称、图标和取值口径一致。
/// `store` 参数保留给未来需要按 store 状态裁剪维度的场景；当前实现与其无关。
@MainActor
func attributeDefinitions(store: SavingsStore) -> [AttributeDefinition] {
    [
        .init(title: "攻击", symbol: "bolt.fill", color: SavingsTheme.orange,
              total: { "\($0.equippedAttack)" },
              enhanced: { "\($0.enhanced($1.attack, for: $1))" }),
        .init(title: "防御", symbol: "shield.fill", color: SavingsTheme.blue,
              total: { "\($0.equippedDefense)" },
              enhanced: { "\($0.enhanced($1.defense, for: $1))" }),
        .init(title: "生命", symbol: "heart.fill", color: SavingsTheme.red,
              total: { "\($0.equippedVitality)" },
              enhanced: { "\($0.enhanced($1.vitality, for: $1))" }),
        .init(title: "暴击率", symbol: "burst.fill", color: SavingsTheme.purple,
              total: { "\(Int($0.equippedCritical * 100))%" },
              enhanced: { "\(Int($0.enhanced($1.critical, for: $1) * 100))%" }),
        .init(title: "暴击效果", symbol: "sparkles", color: SavingsTheme.orange,
              total: { "\(Int($0.equippedCriticalDamage * 100))%" },
              enhanced: { "+\(Int($0.enhanced($1.criticalDamage, for: $1) * 100))%" }),
        .init(title: "吸血", symbol: "drop.fill", color: SavingsTheme.red,
              total: { "\(Int($0.equippedLifesteal * 100))%" },
              enhanced: { "\(Int($0.enhanced($1.lifesteal, for: $1) * 100))%" }),
        .init(title: "速度", symbol: "wind", color: SavingsTheme.teal,
              total: { "\($0.equippedSpeed)" },
              enhanced: { "\($0.enhanced($1.speed, for: $1))" }),
        .init(title: "物理抗性", symbol: "shield.lefthalf.filled", color: SavingsTheme.blue,
              total: { "\($0.equippedPhysicalResistance)" },
              enhanced: { "\($0.enhanced($1.physicalResistance, for: $1))" }),
        .init(title: "魔法抗性", symbol: "wand.and.stars", color: SavingsTheme.purple,
              total: { "\($0.equippedMagicResistance)" },
              enhanced: { "\($0.enhanced($1.magicResistance, for: $1))" }),
        .init(title: "物理伤害", symbol: "hammer.fill", color: SavingsTheme.orange,
              total: { "\($0.equippedPhysicalDamage)" },
              enhanced: { "\($0.enhanced($1.physicalDamage, for: $1))" }),
        .init(title: "魔法伤害", symbol: "flame.fill", color: SavingsTheme.purple,
              total: { "\($0.equippedMagicDamage)" },
              enhanced: { "\($0.enhanced($1.magicDamage, for: $1))" }),
        .init(title: "真实伤害", symbol: "scope", color: SavingsTheme.red,
              total: { "\($0.equippedTrueDamage)" },
              enhanced: { "\($0.enhanced($1.trueDamage, for: $1))" }),
        .init(title: "伤害减免", symbol: "checkmark.shield.fill", color: SavingsTheme.green,
              total: { "\(Int($0.equippedDamageReduction * 100))%" },
              enhanced: { "\(Int($0.enhanced($1.damageReduction, for: $1) * 100))%" }),
        .init(title: "护盾", symbol: "hexagon.fill", color: SavingsTheme.blue,
              total: { "\($0.equippedShield)" },
              enhanced: { "\($0.enhanced($1.shield, for: $1))" }),
        .init(title: "幸运", symbol: "star.circle.fill", color: SavingsTheme.green,
              total: { "\($0.equippedFortune)" },
              enhanced: { "\($0.enhanced($1.fortune, for: $1))" })
    ]
}

// MARK: - 神话/绝世渐变描边

private struct MythicStrokeModifier: ViewModifier {
    let rarity: ItemRarity
    let cornerRadius: CGFloat
    /// 达到神话/绝世品质时的描边宽度；未达标时描边宽度为 0（无描边）。
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(rarity.gradient, lineWidth: rarity.rawValue >= ItemRarity.mythic.rawValue ? lineWidth : 0)
        )
    }
}

extension View {
    /// 神话/绝世品质装备与技能卡片的渐变描边。EquipmentCard / TechniqueCard /
    /// DrawResultsView 共用，未达神话品质时不描边。
    func mythicStroke(_ rarity: ItemRarity, cornerRadius: CGFloat = 9, lineWidth: CGFloat = 1.5) -> some View {
        modifier(MythicStrokeModifier(rarity: rarity, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

// MARK: - 空状态面板

/// 列表空状态统一面板（装备/技能等列表筛选无结果时使用）。
struct EmptyStatePanel: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(title)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .savingsPanel()
    }
}

// MARK: - 装配槽位卡

/// 已装配槽位卡（装备部位格 / 技能装配格共用）。
/// 展示槽位名、图标与已装配物；`action` 为 nil 时表示空槽不可点击。
/// 宠物上阵位（PetDeploymentSlot）因含像素立绘与空槽虚线样式，差异过大，不在此抽象内。
struct LoadoutSlotCard: View {
    let label: String
    let symbol: String
    let tint: Color
    let name: String
    var detail: String? = nil
    var detailTint: Color? = nil
    let action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(detailTint ?? Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(8).frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

// MARK: - 自适应换行布局

/// 简易换行布局（macOS 13+ Layout 协议）：子视图按自身理想宽度依次排列，
/// 一行放不下时整体换到下一行。用于筛选栏等「窗口变窄不允许截断」的工具行。
struct WrapLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
