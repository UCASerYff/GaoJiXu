import SwiftUI

struct TechniquesView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var search = ""
    @State private var school = "全部流派"
    @State private var effect: TechniqueEffect?
    @State private var learnedOnly = true
    @State private var pendingForget: ItemRarity?

    /// 与 SavingsStore.forgetTechniques(upTo:) 同一口径：已装配技能保留。
    private func forgettableCount(upTo maximumRarity: ItemRarity) -> Int {
        let equippedIDs = Set(store.equippedTechniqueIDs)
        return store.techniques.filter { progress in
            guard progress.level > 0,
                  !equippedIDs.contains(progress.techniqueID),
                  let definition = SavingsCatalog.technique(progress.techniqueID) else { return false }
            return definition.rarity.rawValue <= maximumRarity.rawValue
        }.count
    }

    private func requestForget(upTo rarity: ItemRarity) {
        if forgettableCount(upTo: rarity) > 0 { pendingForget = rarity }
        else { store.forgetTechniques(upTo: rarity) } // 无符合条件技能时交给 store 提示
    }

    private var schools: [String] { ["全部流派"] + Array(Set(SavingsCatalog.techniques.map(\.school))).sorted() }
    private var filtered: [TechniqueDefinition] {
        SavingsCatalog.techniques.filter { item in
            (!learnedOnly || store.techniqueLevel(item.id) > 0) &&
            (school == "全部流派" || item.school == school) && (effect == nil || item.effect == effect) &&
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.school.localizedCaseInsensitiveContains(search) || item.culture.localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            let lhsEquipped = store.isTechniqueEquipped(lhs.id)
            let rhsEquipped = store.isTechniqueEquipped(rhs.id)
            if lhsEquipped != rhsEquipped { return lhsEquipped }
            if lhs.rarity != rhs.rarity { return lhs.rarity.rawValue > rhs.rarity.rawValue }
            let lhsLevel = store.techniqueLevel(lhs.id), rhsLevel = store.techniqueLevel(rhs.id)
            if lhsLevel != rhsLevel { return lhsLevel > rhsLevel }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SavingsStatTile(value: "\(store.adventure.insight)", label: "可用悟性", symbol: "lightbulb.fill", color: SavingsTheme.purple)
                    SavingsStatTile(value: "\(store.techniques.filter { $0.level > 0 }.count)/\(SavingsCatalog.techniques.count)", label: "已学 / 总技能", symbol: "scroll.fill", color: SavingsTheme.orange)
                    SavingsStatTile(value: store.equippedTechniquePower.formatted(), label: "装配技能战力", symbol: "bolt.shield.fill", color: SavingsTheme.red)
                    SavingsStatTile(value: "\(store.equippedTechniqueIDs.count)/\(SavingsStore.maximumTechniqueSlots)", label: "已装配流派", symbol: "square.grid.3x3.fill", color: SavingsTheme.green)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text("当前构筑 · 最多 \(SavingsStore.maximumTechniqueSlots) 门").font(.headline)
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Button("一键装配") { store.equipBestTechniquesByBasePower() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Text("按未参悟 1 重初始战力选择最强 \(SavingsStore.maximumTechniqueSlots) 门，参悟等级不参与")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Menu("一键遗忘") {
                            Button("遗忘所有普通技能") { requestForget(upTo: .common) }
                            Button("遗忘精良及以下") { requestForget(upTo: .fine) }
                            Button("遗忘稀有及以下") { requestForget(upTo: .rare) }
                            Button("遗忘史诗及以下") { requestForget(upTo: .epic) }
                            Button("遗忘传说及以下") { requestForget(upTo: .legendary) }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("批量遗忘所选品质及以下技能；已装配技能会保留，并返还基础价值与已投入的参悟悟性")
                        Text("只有装配的技能会生效").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                        ForEach(0..<SavingsStore.maximumTechniqueSlots, id: \.self) { index in
                            let definition = index < store.equippedTechniqueIDs.count ? SavingsCatalog.technique(store.equippedTechniqueIDs[index]) : nil
                            LoadoutSlotCard(
                                label: "第 \(index + 1) 格",
                                symbol: definition?.symbol ?? "plus",
                                tint: definition?.rarity.color ?? Color.secondary,
                                name: definition?.name ?? "空技能位",
                                action: definition.map { d in { store.toggleTechnique(d) } }
                            )
                        }
                    }
                }.padding(14).savingsPanel()

                WrapLayout(spacing: 10) {
                    TextField("搜索名称、流派或文化", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    Picker("流派", selection: $school) { ForEach(schools, id: \.self) { Text($0).tag($0) } }.frame(width: 140)
                    Picker("效果", selection: $effect) { Text("全部效果").tag(nil as TechniqueEffect?); ForEach(TechniqueEffect.allCases) { Text($0.title).tag(Optional($0)) } }.frame(width: 145)
                    Toggle("只看已学", isOn: $learnedOnly).toggleStyle(.switch)
                    Label("已装配优先 · 品质降序", systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
                    Text("\(filtered.count) / \(SavingsCatalog.techniques.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                if filtered.isEmpty {
                    EmptyStatePanel(
                        icon: "books.vertical",
                        title: learnedOnly ? "当前筛选下还没有已学技能" : "没有匹配技能",
                        message: "关闭“只看已学”可浏览 \(SavingsCatalog.techniques.count) 门原创技能图鉴。"
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 8)], spacing: 8) {
                        ForEach(filtered) { definition in TechniqueCard(definition: definition) }
                    }
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .confirmationDialog(
            "一键遗忘技能？",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rarity = pendingForget {
                Button("遗忘 \(forgettableCount(upTo: rarity)) 门技能", role: .destructive) {
                    store.forgetTechniques(upTo: rarity)
                    pendingForget = nil
                }
            }
            Button("取消", role: .cancel) { pendingForget = nil }
        } message: {
            if let rarity = pendingForget {
                Text("将遗忘 \(forgettableCount(upTo: rarity)) 门\(rarity.title)及以下的未装配技能，返还基础价值与已投入的参悟悟性；已装配技能会保留。此操作不可撤销。")
            }
        }
    }
}

private struct TechniqueCard: View {
    @EnvironmentObject private var store: SavingsStore
    let definition: TechniqueDefinition
    private var progress: TechniqueProgress { store.techniqueProgress(definition.id) }
    var body: some View {
        let unlocked = progress.level > 0
        let upgradeCost = store.techniqueUpgradeCost(definition)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: definition.symbol)
                    .font(.callout.weight(.semibold)).foregroundStyle(unlocked ? definition.rarity.color : Color.secondary)
                    .frame(width: 34, height: 34).background((unlocked ? definition.rarity.color : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(unlocked ? definition.name : "未悟得技能").font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(definition.culture) · \(definition.school) · \(definition.rarity.title)").font(.caption2).foregroundStyle(definition.rarity.color).lineLimit(1)
                }
                Spacer()
                if unlocked { Text("\(progress.level)重").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(definition.rarity.color) }
            }
            HStack {
                Label(definition.effectDetail(level: max(1, progress.level)), systemImage: definition.effect.symbol).lineLimit(1)
                Spacer()
                Label("战力 \(store.techniqueBattlePower(definition).formatted())", systemImage: "bolt.fill")
                    .fontWeight(.semibold).foregroundStyle(definition.rarity.color)
                if unlocked { Button(store.isTechniqueEquipped(definition.id) ? "卸下" : "装配") { store.toggleTechnique(definition) }.buttonStyle(.bordered).controlSize(.small) }
            }.font(.caption2)
            Label("绝技·\(definition.signatureSkill.affixName)：\(definition.signatureDetail(level: max(1, progress.level)))", systemImage: definition.signatureSkill.symbol)
                .font(.caption2.weight(.medium)).foregroundStyle(unlocked ? definition.rarity.color : Color.secondary).lineLimit(1)
            if unlocked {
                HStack {
                    Text("最高 \(GameProgression.maximumTechniqueLevel) 重 · 后期增幅递增").foregroundStyle(.secondary)
                    Spacer()
                    Button(progress.level >= GameProgression.maximumTechniqueLevel ? "已满级" : "参悟 \(upgradeCost)") { store.upgradeTechnique(definition) }
                        .buttonStyle(.borderedProminent).controlSize(.mini)
                        .disabled(progress.level >= GameProgression.maximumTechniqueLevel || store.adventure.insight < upgradeCost)
                }.font(.caption2)
            }
        }
        .padding(10).frame(minHeight: 112, alignment: .top).savingsPanel(cornerRadius: 9)
        .mythicStroke(definition.rarity)
        .opacity(unlocked ? 1 : 0.66)
        .help(definition.description)
    }
}
