import SwiftUI

struct AdventureBattleWorld: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let compact: Bool
    private let yaw = 0.0
    private let zoom = 4.8
    @State private var selectedID: String?

    private var items: [GQWorldItem] {
        var result = [
            GQWorldItem(id: "stage", title: "", kind: "__world", level: store.currentStage, x: 0, z: 0, movable: false),
            GQWorldItem(id: "hero", title: "勇者 Lv.\(store.adventure.level)",
                        kind: "hero-weapon\(store.adventure.equippedWeaponID == nil ? 0 : 1)-armor\(store.adventure.equippedArmorID == nil ? 0 : 1)",
                        level: store.adventure.level, x: -3.4, z: 0, movable: false),
            GQWorldItem(id: "monster", title: store.currentMonster.name, kind: "monster:\(store.currentMonster.spriteIndex)",
                        level: store.currentStage, x: 3.3, z: 0, movable: false)
        ]
        let pets = store.equippedPetPairs
        result += pets.enumerated().map { index, pair in
            GQWorldItem(id: "pet:\(pair.0.id)", title: pair.0.name, kind: "pet:\(pair.0.spriteIndex)",
                        level: pair.1, x: -3.4 + (Double(index) - Double(pets.count - 1) / 2) * 1.6, z: 2.8, movable: false)
        }
        return result
    }

    var overviewOnly = false
    @ViewBuilder var body: some View {
        if overviewOnly {
            GQWorldScene(mode:"battle",items:items,selectedID:nil,yaw:yaw,zoom:zoom,observationOnly:true,onSelect:{_ in},onMove:{_,_,_ in})
        } else { interactiveBody }
    }
    private var interactiveBody: some View {
        VStack(spacing: 10) {
            HStack {
                Label("第 \(store.currentStage) 关", systemImage: "flag.checkered").font(.headline)
                Text(store.currentMonster.chapter).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Label("每秒自动攻击", systemImage: "forward.fill").font(.caption).foregroundStyle(SavingsTheme.green)
            }
            ZStack(alignment: .topTrailing) {
                GQWorldScene(mode: "battle", items: items, selectedID: selectedID, yaw: yaw, zoom: zoom,
                             animationToken: reduceMotion ? 0 : (store.adventure.attackCount ?? 0),
                             onSelect: { selectedID = $0 }, onMove: { _, _, _ in })
            }
            .frame(height: compact ? 260 : 480)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 15) {
                hpBar("勇者", store.heroHP, store.heroMaxHP, SavingsTheme.green)
                hpBar("怪物", max(0, store.adventure.monsterHP), store.currentMonsterMaxHP, SavingsTheme.red)
            }
            HStack {
                Text("勇者战力 \(store.heroBattlePower.formatted())")
                Spacer()
                Text("敌方战力 \(store.monsterBattlePower.formatted())")
            }
            .font(.caption.weight(.semibold))
            Text(selectedID == "monster" ? "\(store.currentMonster.trait) · \(MonsterTraits.detail(for: store.currentMonster.spriteIndex) ?? "")" : store.lastBattleMessage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 10 : 16)
        .savingsPanel()
    }

    private func hpBar(_ title: String, _ value: Int, _ maximum: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text("\(value)/\(maximum)").monospacedDigit() }
                .font(.caption2.weight(.semibold))
            ProgressView(value: Double(value), total: Double(max(1, maximum))).tint(tint)
        }
    }
}

struct AdventureCampWorld: View {
    @EnvironmentObject private var store: SavingsStore
    let openSection: (AdventureHubView.Tab) -> Void
    private let yaw = 0.0
    private let zoom = 5.8
    @State private var selectedID: String?

    private var items: [GQWorldItem] {
        [
            GQWorldItem(id: "forge", title: "锻造营", kind: "forge", level: max(1, store.equippedDefinitions.count), x: -4.5, z: -2.8, movable: false),
            GQWorldItem(id: "study", title: "研修塔", kind: "study", level: max(1, store.equippedTechniqueIDs.count), x: 4.5, z: -2.8, movable: false),
            GQWorldItem(id: "stable", title: "灵宠营", kind: "stable", level: max(1, store.equippedPetPairs.count), x: -4.5, z: 3.1, movable: false),
            GQWorldItem(id: "altar", title: "祈愿坛", kind: "altar", level: max(1, store.adventure.level / 10), x: 4.5, z: 3.1, movable: false)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("远征营地", systemImage: "tent.fill").font(.headline)
                Spacer()
                Text("点击建筑进入装备、技能、宠物或祈愿").font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .topTrailing) {
                GQWorldScene(mode: "camp", items: items, selectedID: selectedID, yaw: yaw, zoom: zoom,
                             onSelect: { id in
                    selectedID = id
                    switch id {
                    case "forge": openSection(.equipment)
                    case "study": openSection(.techniques)
                    case "stable": openSection(.pets)
                    case "altar": openSection(.lottery)
                    default: break
                    }
                }, onMove: { _, _, _ in })
            }
            .frame(height: 500)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .savingsPanel()
    }
}
