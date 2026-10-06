import AppKit
import SwiftUI

private enum SavingsGameAsset {
    static func image(_ name: String) -> NSImage? {
        guard let path = SavingsBundle.bundle.path(forResource: name, ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }
}

private enum MonsterSpriteSheet {
    private static let sprites: [NSImage?] = {
        guard let sheet = SavingsGameAsset.image("MonsterSpriteSheetV16"),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Array(repeating: nil, count: 10) }
        return (0..<10).map { index in
            let column = index % 5, row = index / 5
            let x0 = source.width * column / 5, x1 = source.width * (column + 1) / 5
            let y0 = source.height * row / 2, y1 = source.height * (row + 1) / 2
            guard let crop = source.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return nil }
            return NSImage(cgImage: crop, size: NSSize(width: x1 - x0, height: y1 - y0))
        }
    }()

    static func image(at index: Int) -> NSImage? {
        sprites[max(0, min(9, index))]
    }
}

/// 怪物特性速查表：spriteIndex → 特性机制的数值化文案。
/// ⚠️ 同步约定：本表数值与 SavingsStore 中按 spriteIndex 硬编码的战斗系数一一对应——
/// `currentMonsterAttack`（1/5/7 攻击 ×1.12）、`currentMonsterPhysicalResistance`
/// （2/8/9 基础 +24）、`currentMonsterMagicResistance`（3/7/9 基础 +24）、
/// `performAutoBattleTick`（4 回血、5 追加伤害、6 承伤 ×0.9、7 魔法攻击、9 满血承伤 ×0.8）。
/// 改动 store 系数时必须同步本表文案，反之亦然。
enum MonsterTraits {
    static let details: [Int: String] = [
        0: "无特殊机制，攻防均衡。",
        1: "攻击 ×1.12（关卡成长后再乘算）。",
        2: "物理抗性基础 +24（普通怪 +7），每关再 +2。",
        3: "魔法抗性基础 +24（普通怪 +7），每关再 +2。",
        4: "每回合回复最大生命 1%。",
        5: "攻击 ×1.12；每回合额外追加 关卡÷8 点伤害。",
        6: "受到的玩家伤害 ×0.9。",
        7: "攻击 ×1.12，魔法抗性基础 +24；攻击为魔法伤害，无视防御、受魔法抗性减免。",
        8: "物理抗性基础 +24（普通怪 +7），每关再 +2。",
        9: "物理/魔法抗性基础 +24；满血时受到的玩家伤害 ×0.8。"
    ]

    static func detail(for spriteIndex: Int) -> String? {
        details[spriteIndex]
    }
}

private struct PixelHeroView: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 12, size.height / 16)
            let originX = (size.width - unit * 12) / 2
            let originY = (size.height - unit * 16) / 2
            func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
                context.fill(Path(CGRect(x: originX + x * unit, y: originY + y * unit, width: w * unit, height: h * unit)), with: .color(color))
            }
            block(4, 1, 4, 1, .black.opacity(0.8)); block(3, 2, 6, 3, Color(red: 0.98, green: 0.77, blue: 0.55))
            block(3, 2, 6, 1, Color(red: 0.20, green: 0.14, blue: 0.12)); block(4, 4, 1, 1, .black); block(7, 4, 1, 1, .black)
            block(3, 5, 6, 5, SavingsTheme.blue); block(2, 6, 2, 3, SavingsTheme.blue.opacity(0.85)); block(8, 6, 2, 3, SavingsTheme.blue.opacity(0.85))
            block(4, 10, 2, 4, Color(red: 0.20, green: 0.28, blue: 0.42)); block(7, 10, 2, 4, Color(red: 0.20, green: 0.28, blue: 0.42))
            block(3, 14, 3, 1, Color(red: 0.12, green: 0.15, blue: 0.22)); block(7, 14, 3, 1, Color(red: 0.12, green: 0.15, blue: 0.22))
            block(10, 3, 1, 8, Color.white.opacity(0.92)); block(9, 10, 3, 1, SavingsTheme.orange)
        }
        .accessibilityLabel("像素积蓄勇者")
    }
}

private struct MonsterSpriteView: View {
    let index: Int
    var body: some View {
        Group {
            if let image = MonsterSpriteSheet.image(at: index) {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                Image(systemName: "circle.hexagongrid.fill").resizable().scaledToFit().foregroundStyle(SavingsTheme.red)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PixelSlashView: View {
    var critical: Bool

    var body: some View {
        Canvas { context, size in
            var slash = Path()
            slash.move(to: CGPoint(x: size.width * 0.15, y: size.height * 0.82))
            slash.addLine(to: CGPoint(x: size.width * 0.84, y: size.height * 0.14))
            context.stroke(slash, with: .color(critical ? .yellow : .white), lineWidth: 7)
            context.stroke(slash, with: .color(critical ? SavingsTheme.red : SavingsTheme.blue), lineWidth: 3)
            for offset in [0.28, 0.5, 0.72] {
                let spark = CGRect(x: size.width * offset, y: size.height * (0.92 - offset), width: 5, height: 5)
                context.fill(Path(spark), with: .color(critical ? SavingsTheme.orange : SavingsTheme.teal))
            }
        }
        .rotationEffect(.degrees(-8))
        .accessibilityHidden(true)
    }
}

private struct SimplePixelBattleStage: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compact: Bool
    @State private var striking = false
    @State private var monsterHit = false
    @State private var showImpact = false
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            HStack {
                Label("第 \(store.currentStage) 关", systemImage: "flag.checkered")
                Text("· 第 \((store.currentStage - 1) / 10 + 1) 轮").foregroundStyle(.secondary)
                Spacer()
                Label("每秒自动攻击", systemImage: "forward.fill").foregroundStyle(SavingsTheme.green)
            }
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))

            HStack(spacing: compact ? 18 : 38) {
                VStack(spacing: 4) {
                    PixelHeroView().frame(width: compact ? 58 : 92, height: compact ? 78 : 124)
                        .offset(x: striking ? (compact ? 18 : 34) : 0, y: striking ? -2 : 0)
                        .rotationEffect(.degrees(striking ? 5 : 0), anchor: .bottom)
                    Text("勇者 Lv.\(store.adventure.level)").font(.caption.weight(.semibold))
                    Text("战力 \(store.heroBattlePower.formatted())")
                        .font(.pixel(11, weight: .bold)).foregroundStyle(SavingsTheme.blue)
                }
                Spacer()
                ZStack {
                    if showImpact && !reduceMotion {
                        PixelSlashView(critical: store.lastHitCritical)
                            .frame(width: compact ? 58 : 92, height: compact ? 58 : 92)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: compact ? 58 : 92, height: compact ? 58 : 92)
                Spacer()
                VStack(spacing: 4) {
                    MonsterSpriteView(index: store.currentMonster.spriteIndex).frame(width: compact ? 76 : 126, height: compact ? 84 : 134)
                        .offset(x: monsterHit ? (compact ? 8 : 14) : 0)
                        .rotationEffect(.degrees(monsterHit ? 5 : 0))
                        .overlay(alignment: .top) {
                            if showImpact {
                                Text("\(store.lastHitCritical ? "暴击 " : "")-\(store.lastPlayerDamage)")
                                    .font(.pixel(compact ? 11 : 13, weight: .bold))
                                    .foregroundStyle(store.lastHitCritical ? SavingsTheme.orange : SavingsTheme.red)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.regularMaterial, in: Capsule())
                                    .offset(y: compact ? -10 : -16)
                                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    Text(store.currentMonster.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("战力 \(store.monsterBattlePower.formatted())")
                        .font(.pixel(11, weight: .bold)).foregroundStyle(SavingsTheme.red)
                }
            }
            .padding(.horizontal, compact ? 8 : 28)

            VStack(spacing: 6) {
                battleBar(title: "勇者", value: store.heroHP, total: store.heroMaxHP, color: SavingsTheme.green)
                battleBar(title: "怪物", value: max(0, store.adventure.monsterHP), total: store.currentMonsterMaxHP, color: SavingsTheme.red)
            }
            if !compact {
                HStack(alignment: .top, spacing: 10) {
                    battleStats(
                        title: "勇者详细属性",
                        color: SavingsTheme.blue,
                        items: [
                            ("攻击", store.equippedAttack), ("防御", store.equippedDefense),
                            ("生命", store.heroMaxHP), ("速度", store.equippedSpeed),
                            ("物抗", store.equippedPhysicalResistance), ("魔抗", store.equippedMagicResistance)
                        ]
                    )
                    battleStats(
                        title: "怪物详细属性",
                        color: SavingsTheme.red,
                        items: [
                            ("攻击", store.currentMonsterAttack), ("生命", store.currentMonsterMaxHP),
                            ("物抗", store.currentMonsterPhysicalResistance), ("魔抗", store.currentMonsterMagicResistance),
                            ("轮次", (store.currentStage - 1) / 10 + 1), ("序号", (store.currentStage - 1) % 10 + 1)
                        ]
                    )
                }
            }
            Text(store.lastBattleMessage).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            if !compact {
                let modifiers = store.currentBattlePowerModifiers
                Text("战力校准 · 我方输出 ×\(modifiers.outgoing, specifier: "%.2f") · 我方承伤 ×\(modifiers.incoming, specifier: "%.2f")")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(modifiers.outgoing < 0.75 ? SavingsTheme.red : Color.secondary)
            }
        }
        .padding(compact ? 10 : 16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        .onChange(of: store.adventure.attackCount ?? 0) { _, _ in animateAttack() }
        .onDisappear { animationTask?.cancel() }
    }

    private func battleBar(title: String, value: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption2.weight(.bold)).frame(width: 30, alignment: .leading)
            ProgressView(value: Double(max(0, value)), total: Double(max(1, total))).tint(color)
            Text("\(max(0, value))/\(max(1, total))").font(.caption2.monospacedDigit()).frame(width: compact ? 82 : 112, alignment: .trailing)
        }
    }

    private func battleStats(title: String, color: Color, items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(color)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Text(item.0).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text(item.1.formatted()).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(9).frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 每次攻击触发一段「突进→受击→收招」动画。
    /// 用可取消的 Task 替代链式 asyncAfter：新动画先取消旧 Task，视图消失时也会取消，
    /// 避免旧闭包在视图销毁后继续修改状态。减弱动效开启时只做伤害数字渐隐。
    private func animateAttack() {
        animationTask?.cancel()
        if reduceMotion {
            striking = false
            monsterHit = false
            showImpact = true
            animationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 520_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    showImpact = false
                }
            }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) {
            striking = true
            monsterHit = false
            showImpact = false
        }
        animationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) {
                striking = false
                monsterHit = true
                showImpact = true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                monsterHit = false
                showImpact = false
            }
        }
    }
}

struct AdventureMiniCard: View {
    @EnvironmentObject private var store: SavingsStore
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动冒险").font(.headline)
                Spacer()
                Button("进入地图", action: open).buttonStyle(.plain).foregroundStyle(SavingsTheme.blue)
            }
            AdventureBattleWorld(compact: true)
            Text("战斗持续自动进行；击杀获得金币、悟性与经验，\(GameCopy.ticketPerUnitRule)。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minHeight: 225, alignment: .top)
        .savingsPanel()
    }
}

struct AdventureView: View {
    @EnvironmentObject private var store: SavingsStore
    var openSection: (AdventureHubView.Tab) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AdventureBattleWorld(compact: false)
                AdventureCampWorld(openSection: openSection)

                HStack {
                    SavingsStatTile(value: "Lv.\(store.adventure.level)", label: "勇者等级", symbol: "figure.fencing", color: SavingsTheme.green)
                    SavingsStatTile(value: "\(store.currentStage)", label: "当前关卡", symbol: "flag.checkered", color: SavingsTheme.red)
                    SavingsStatTile(value: "\(store.battleAttempts)", label: "本关重开", symbol: "arrow.counterclockwise", color: SavingsTheme.purple)
                    SavingsStatTile(value: "\(store.adventure.defeatedMonsters)", label: "累计过关", symbol: "forward.fill", color: SavingsTheme.orange)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 13) {
                        Text("无限自动战斗规则").font(.headline)
                        RuleRow(symbol: "forward.fill", title: "持续自动打", detail: "应用运行时每秒攻击，不需要点击或等待攒钱触发", color: SavingsTheme.green)
                        RuleRow(symbol: "flag.checkered", title: "过关就前进", detail: "十种怪物循环登场，关卡没有上限且强度单调提升", color: SavingsTheme.blue)
                        RuleRow(symbol: "arrow.counterclockwise", title: "失败原关重开", detail: "双方恢复生命，继续挑战同一关，直到角色足够强", color: SavingsTheme.red)
                        RuleRow(symbol: "burst.fill", title: "击杀结算奖励", detail: "金币、悟性和经验只在击杀后结算，并有概率掉落装备或技能", color: SavingsTheme.teal)
                        RuleRow(symbol: "arrow.down.circle.fill", title: "积蓄兑换星券", detail: "\(GameCopy.ticketPerUnitRule)，完成目标额外获得 100 张", color: SavingsTheme.blue)
                        RuleRow(symbol: "sparkles", title: "词条与绝技", detail: "装备词条和技能绝技会真实改变攻防、回复与奖励", color: SavingsTheme.orange)
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .top).savingsPanel()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Text("当前怪物").font(.headline)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(store.currentMonster.trait).font(.caption.weight(.semibold)).foregroundStyle(SavingsTheme.purple)
                                if let traitDetail = MonsterTraits.detail(for: store.currentMonster.spriteIndex) {
                                    Text(traitDetail)
                                        .font(.caption2).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        Text("\(store.currentMonster.chapter) · 第 \(store.currentStage) 关").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("最近战报").font(.headline)
                        ForEach(store.rewardEvents.prefix(6)) { event in
                            HStack(spacing: 10) {
                                Image(systemName: event.symbol).foregroundStyle(SavingsTheme.green).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.callout.weight(.medium))
                                    Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .top).savingsPanel()
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}

private struct RuleRow: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(color)
                .frame(width: 34, height: 34).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
