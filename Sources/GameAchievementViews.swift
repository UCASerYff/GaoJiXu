import SwiftUI

private struct AchievementDefinition: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    let unlocked: Bool
    /// 可量化成就的 当前值/目标值；nil 表示无法量化，锁定状态保持原文案。
    let progress: (current: Int, total: Int)?
}

struct AchievementsView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var cachedAchievements: [AchievementDefinition] = []

    /// 成就判定的全部输入快照。只有输入变化才重建成就列表，
    /// 避免 body 每次求值（自动战斗每秒刷新）都重算全部成就。
    private struct AchievementInputs: Equatable {
        var depositCount: Int
        var completedGoals: Int
        var streakDays: Int
        var bestGoalPermille: Int
        var defeatedMonsters: Int
        var heroLevel: Int
        var rarePlusOwned: Int
        var legendaryPlusOwned: Int
        var learnedTechniques: Int
    }

    private var achievementInputs: AchievementInputs {
        let ownedDefinitions = store.equipment.compactMap { SavingsCatalog.equipment($0.definitionID) }
        let bestProgress = store.goals.map { store.progress(for: $0) }.max() ?? 0
        return AchievementInputs(
            depositCount: store.records.filter { $0.kind == .deposit }.count,
            completedGoals: store.goals.filter { $0.status == .completed }.count,
            streakDays: store.currentSavingStreak,
            bestGoalPermille: Int((bestProgress * 1000).rounded()),
            defeatedMonsters: store.adventure.defeatedMonsters,
            heroLevel: store.adventure.level,
            rarePlusOwned: ownedDefinitions.filter { $0.rarity.rawValue >= ItemRarity.rare.rawValue }.count,
            legendaryPlusOwned: ownedDefinitions.filter { $0.rarity.rawValue >= ItemRarity.legendary.rawValue }.count,
            learnedTechniques: store.techniques.filter { $0.level > 0 }.count
        )
    }

    /// 每个成就的解锁判定与 progress/total 集中在这里，保证两处口径一致。
    private static func makeAchievements(from inputs: AchievementInputs) -> [AchievementDefinition] {
        func quantified(_ current: Int, _ total: Int) -> (current: Int, total: Int)? {
            (min(current, total), total)
        }
        return [
            .init(id: "first", title: "第一枚硬币", detail: "完成第一笔有效存入", symbol: "circle.fill", color: SavingsTheme.orange,
                  unlocked: inputs.depositCount >= 1, progress: quantified(inputs.depositCount, 1)),
            .init(id: "five", title: "积少成多", detail: "完成 5 笔有效存入", symbol: "square.stack.3d.up.fill", color: SavingsTheme.teal,
                  unlocked: inputs.depositCount >= 5, progress: quantified(inputs.depositCount, 5)),
            .init(id: "twenty", title: "长期主义者", detail: "完成 20 笔有效存入", symbol: "calendar.badge.checkmark", color: SavingsTheme.blue,
                  unlocked: inputs.depositCount >= 20, progress: quantified(inputs.depositCount, 20)),
            .init(id: "streak", title: "七日不断", detail: "连续 7 天记录积蓄", symbol: "flame.fill", color: SavingsTheme.red,
                  unlocked: inputs.streakDays >= 7, progress: quantified(inputs.streakDays, 7)),
            .init(id: "half", title: "半程灯火", detail: "任一目标达到 50%（当前最佳 \(inputs.bestGoalPermille / 10)%）", symbol: "moonphase.first.quarter", color: SavingsTheme.purple,
                  unlocked: inputs.bestGoalPermille >= 500, progress: quantified(inputs.bestGoalPermille / 10, 50)),
            .init(id: "goal", title: "愿望落地", detail: "完成第一个攒钱目标", symbol: "trophy.fill", color: SavingsTheme.orange,
                  unlocked: inputs.completedGoals >= 1, progress: quantified(inputs.completedGoals, 1)),
            .init(id: "monster", title: "初战告捷", detail: "击败第一只怪物", symbol: "burst.fill", color: SavingsTheme.green,
                  unlocked: inputs.defeatedMonsters >= 1, progress: quantified(inputs.defeatedMonsters, 1)),
            .init(id: "chapter", title: "百战积蓄", detail: "累计击败 8 只怪物", symbol: "shield.checkered", color: SavingsTheme.blue,
                  unlocked: inputs.defeatedMonsters >= 8, progress: quantified(inputs.defeatedMonsters, 8)),
            .init(id: "level5", title: "渐入佳境", detail: "勇者达到 5 级", symbol: "arrow.up.circle.fill", color: SavingsTheme.green,
                  unlocked: inputs.heroLevel >= 5, progress: quantified(inputs.heroLevel, 5)),
            .init(id: "rare", title: "稀有收藏家", detail: "获得一件稀有或更高装备", symbol: "diamond.fill", color: SavingsTheme.purple,
                  unlocked: inputs.rarePlusOwned >= 1, progress: quantified(inputs.rarePlusOwned, 1)),
            .init(id: "legend", title: "传说相伴", detail: "获得一件传说或更高装备", symbol: "star.fill", color: SavingsTheme.orange,
                  unlocked: inputs.legendaryPlusOwned >= 1, progress: quantified(inputs.legendaryPlusOwned, 1)),
            .init(id: "kungfu", title: "心法初成", detail: "修炼 3 门不同技能", symbol: "scroll.fill", color: SavingsTheme.purple,
                  unlocked: inputs.learnedTechniques >= 3, progress: quantified(inputs.learnedTechniques, 3))
        ]
    }

    private func recalculate() {
        cachedAchievements = Self.makeAchievements(from: achievementInputs)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    SavingsStatTile(value: "\(cachedAchievements.filter(\.unlocked).count)/\(cachedAchievements.count)", label: "已解锁成就", symbol: "trophy.fill", color: SavingsTheme.orange)
                    SavingsStatTile(value: "\(store.savingDayCount)", label: "留下足迹的天数", symbol: "calendar", color: SavingsTheme.teal)
                    SavingsStatTile(value: "\(store.adventure.defeatedMonsters)", label: "冒险胜利次数", symbol: "burst.fill", color: SavingsTheme.green)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 13)], spacing: 13) {
                    ForEach(cachedAchievements) { achievement in
                        VStack(spacing: 12) {
                            Image(systemName: achievement.unlocked ? achievement.symbol : "lock.fill")
                                .font(.system(size: 27)).foregroundStyle(achievement.unlocked ? achievement.color : Color.secondary)
                                .frame(width: 62, height: 62)
                                .background((achievement.unlocked ? achievement.color : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            Text(achievement.unlocked ? achievement.title : "尚未解锁").font(.headline)
                            Text(achievement.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if achievement.unlocked {
                                Label("已获得", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(achievement.color)
                            } else if let progress = achievement.progress {
                                VStack(spacing: 4) {
                                    ProgressView(value: Double(progress.current), total: Double(progress.total))
                                        .tint(achievement.color)
                                    Text("\(progress.current)/\(progress.total)")
                                        .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 130)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, minHeight: 165).savingsPanel()
                        .opacity(achievement.unlocked ? 1 : 0.62)
                    }
                }
            }
            .frame(maxWidth: 1080)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .onAppear { recalculate() }
        .onChange(of: achievementInputs) { _, _ in recalculate() }
    }
}
