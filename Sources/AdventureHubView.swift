import SwiftUI

/// V2.2 侧栏整合：原侧栏六个游戏板块（冒险地图/装备/技能/宠物/祈愿/成就）
/// 收拢为侧栏单一「冒险成长」入口，本视图以分段页签承载六个原视图。
/// 页签选择通过 @SceneStorage 持久化，切出板块再回来不丢失。
struct AdventureHubView: View {
    enum Tab: Int, CaseIterable, Identifiable {
        case map, equipment, techniques, pets, lottery, achievements

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .map: "冒险地图"
            case .equipment: "装备"
            case .techniques: "技能"
            case .pets: "宠物"
            case .lottery: "祈愿"
            case .achievements: "成就"
            }
        }
        var symbol: String {
            switch self {
            case .map: "map.fill"
            case .equipment: "shield.lefthalf.filled"
            case .techniques: "books.vertical.fill"
            case .pets: "pawprint.fill"
            case .lottery: "gift.fill"
            case .achievements: "trophy.fill"
            }
        }
    }

    @SceneStorage("gaojixu.adventureHub.tab") private var tabRawValue = Tab.map.rawValue

    private var tab: Binding<Tab> {
        Binding(
            get: { Tab(rawValue: tabRawValue) ?? .map },
            set: { tabRawValue = $0.rawValue }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("冒险板块", selection: tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .frame(maxWidth: 1100)

            switch tab.wrappedValue {
            case .map: AdventureView(openSection: { tabRawValue = $0.rawValue })
            case .equipment: EquipmentView()
            case .techniques: TechniquesView()
            case .pets: PetShopView()
            case .lottery: LotteryView()
            case .achievements: AchievementsView()
            }
        }
    }
}
