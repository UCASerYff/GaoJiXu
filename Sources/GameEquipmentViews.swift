import SwiftUI

struct EquipmentView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var search = ""
    @State private var slot: EquipmentSlot?
    @State private var rarity: ItemRarity?
    @State private var ownedOnly = true
    @State private var pendingBatchSale: ItemRarity?
    @State private var confirmingDuplicateCleanup = false

    /// 与 SavingsStore.sellEquipment(upTo:) 同一口径：已装备物品保留 1 件。
    private func batchSaleCount(upTo maximumRarity: ItemRarity) -> Int {
        let equippedIDs = Set((store.adventure.equippedItems ?? [:]).values)
        return store.equipment.reduce(0) { partial, owned in
            guard let definition = SavingsCatalog.equipment(owned.definitionID),
                  definition.rarity.rawValue <= maximumRarity.rawValue else { return partial }
            let kept = equippedIDs.contains(definition.id) ? 1 : 0
            return partial + max(0, owned.count - kept)
        }
    }

    /// 与 SavingsStore.sellUnusedDuplicates() 同一口径：每种装备保留 1 件。
    private var duplicateSaleCount: Int {
        store.equipment.reduce(0) { $0 + max(0, $1.count - 1) }
    }

    private var filtered: [EquipmentDefinition] {
        SavingsCatalog.equipment.filter { item in
            (!ownedOnly || store.ownedCount(of: item.id) > 0) &&
            (slot == nil || item.slot == slot) && (rarity == nil || item.rarity == rarity) &&
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.setName.localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            let lhsEquipped = store.equippedItemID(for: lhs.slot) == lhs.id
            let rhsEquipped = store.equippedItemID(for: rhs.slot) == rhs.id
            if lhsEquipped != rhsEquipped { return lhsEquipped }
            if lhs.rarity != rhs.rarity { return lhs.rarity.rawValue > rhs.rarity.rawValue }
            let lhsPower = store.equipmentBattlePower(lhs), rhsPower = store.equipmentBattlePower(rhs)
            if lhsPower != rhsPower { return lhsPower > rhsPower }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CharacterAttributesPanel()

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text("角色装备 · 14 个部位").font(.headline)
                        Spacer()
                        Label("\(store.adventure.stardust) 星尘", systemImage: "sparkles").font(.callout.weight(.semibold)).foregroundStyle(SavingsTheme.purple)
                        VStack(alignment: .leading, spacing: 2) {
                            Button("一键装备") { store.equipBestByBasePower() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Text("按未强化初始战力比较，强化等级不参与")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("清理重复装备") {
                            if duplicateSaleCount > 0 { confirmingDuplicateCleanup = true }
                            else { store.sellUnusedDuplicates() }
                        }.buttonStyle(.bordered).controlSize(.small)
                        Menu("一键出售") {
                            Button("出售所有普通装备") { requestBatchSale(upTo: .common) }
                            Button("出售精良及以下") { requestBatchSale(upTo: .fine) }
                            Button("出售稀有及以下") { requestBatchSale(upTo: .rare) }
                            Button("出售史诗及以下") { requestBatchSale(upTo: .epic) }
                            Button("出售传说及以下") { requestBatchSale(upTo: .legendary) }
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("按所选品质批量出售；所有已装备物品都会保留")
                        Text("点击装备格可卸下").font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 8)], spacing: 8) {
                        ForEach(EquipmentSlot.allCases) { equipmentSlot in
                            let definition = SavingsCatalog.equipment(store.equippedItemID(for: equipmentSlot))
                            LoadoutSlotCard(
                                label: equipmentSlot.title,
                                symbol: definition?.symbol ?? equipmentSlot.symbol,
                                tint: definition?.rarity.color ?? Color.secondary,
                                name: definition?.name ?? "空",
                                detail: definition.map { "+\(store.enhancementLevel(for: $0.id)) · 战力 \(store.equipmentBattlePower($0).formatted())" },
                                detailTint: definition?.rarity.color,
                                action: definition != nil ? { store.unequip(equipmentSlot) } : nil
                            )
                        }
                    }
                }
                .padding(14).savingsPanel()

                WrapLayout(spacing: 10) {
                    TextField("搜索装备或套装", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    Picker("部位", selection: $slot) { Text("全部部位").tag(nil as EquipmentSlot?); ForEach(EquipmentSlot.allCases) { Text($0.title).tag(Optional($0)) } }.frame(width: 140)
                    Picker("品质", selection: $rarity) { Text("全部品质").tag(nil as ItemRarity?); ForEach(ItemRarity.allCases) { Text($0.title).tag(Optional($0)) } }.frame(width: 130)
                    Toggle("只看已拥有", isOn: $ownedOnly).toggleStyle(.switch)
                    Label("已装备优先 · 品质与战力降序", systemImage: "arrow.up.arrow.down").font(.caption).foregroundStyle(.secondary)
                    Text("\(filtered.count) / \(SavingsCatalog.equipment.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }

                if filtered.isEmpty {
                    EmptyStatePanel(
                        icon: "shippingbox",
                        title: ownedOnly ? "当前筛选下还没有装备" : "没有匹配装备",
                        message: "使用免费星券可获得装备；关闭“只看已拥有”可浏览完整图鉴。"
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                        ForEach(filtered) { item in EquipmentCard(definition: item) }
                    }
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .confirmationDialog(
            "一键出售装备？",
            isPresented: Binding(
                get: { pendingBatchSale != nil },
                set: { if !$0 { pendingBatchSale = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rarity = pendingBatchSale {
                Button("出售 \(batchSaleCount(upTo: rarity)) 件", role: .destructive) {
                    store.sellEquipment(upTo: rarity)
                    pendingBatchSale = nil
                }
            }
            Button("取消", role: .cancel) { pendingBatchSale = nil }
        } message: {
            if let rarity = pendingBatchSale {
                Text("将出售 \(batchSaleCount(upTo: rarity)) 件\(rarity.title)及以下的未装备物品并转化为星尘；所有已装备物品都会保留。此操作不可撤销。")
            }
        }
        .confirmationDialog(
            "清理重复装备？",
            isPresented: $confirmingDuplicateCleanup,
            titleVisibility: .visible
        ) {
            Button("出售 \(duplicateSaleCount) 件重复装备", role: .destructive) {
                store.sellUnusedDuplicates()
                confirmingDuplicateCleanup = false
            }
            Button("取消", role: .cancel) { confirmingDuplicateCleanup = false }
        } message: {
            Text("每种装备将保留 1 件，其余 \(duplicateSaleCount) 件会被出售并转化为星尘。此操作不可撤销。")
        }
    }

    private func requestBatchSale(upTo rarity: ItemRarity) {
        if batchSaleCount(upTo: rarity) > 0 { pendingBatchSale = rarity }
        else { store.sellEquipment(upTo: rarity) } // 无符合条件装备时交给 store 提示
    }
}

private struct CharacterAttributesPanel: View {
    @EnvironmentObject private var store: SavingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总战力 \(store.heroBattlePower.formatted())").font(.title3.weight(.black)).foregroundStyle(SavingsTheme.blue)
                    Text("基础 \(store.baseCharacterPower.formatted()) · 装备 \(store.equippedEquipmentPower.formatted()) · 技能 \(store.equippedTechniquePower.formatted()) · 宠物 \(store.equippedPetPower.formatted())")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Text("角色 15 维战斗属性").font(.headline)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 7)], spacing: 7) {
                ForEach(attributeDefinitions(store: store)) { attribute in
                    HStack(spacing: 7) {
                        Image(systemName: attribute.symbol).font(.caption.weight(.semibold)).foregroundStyle(attribute.color).frame(width: 24, height: 24).background(attribute.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) { Text(attribute.total(store)).font(.caption.weight(.semibold)).monospacedDigit(); Text(attribute.title).font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }.padding(7).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            if !store.activeCombatSkills.isEmpty {
                HStack(spacing: 8) {
                    Text("生效词条").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(store.activeCombatSkills, id: \.skill) { item in
                        Label(item.skill.affixName, systemImage: item.skill.symbol)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(SavingsTheme.purple.opacity(0.09), in: Capsule())
                            .help(item.skill.detail(power: item.power))
                    }
                    Spacer()
                }
            }
        }.padding(14).savingsPanel()
    }
}

private struct EquipmentCard: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var showingDetail = false
    let definition: EquipmentDefinition

    private var equipped: Bool { store.equippedItemID(for: definition.slot) == definition.id }

    var body: some View {
        let owned = store.ownedCount(of: definition.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: definition.symbol)
                    .font(.callout.weight(.semibold)).foregroundStyle(owned > 0 ? definition.rarity.color : Color.secondary.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background((owned > 0 ? definition.rarity.color : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(owned > 0 ? definition.name : "未发现装备").font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(definition.slot.title) · \(definition.rarity.title) · +\(store.enhancementLevel(for: definition.id))").font(.caption2).foregroundStyle(definition.rarity.color)
                }
                Spacer()
                if owned > 0 { Text("×\(owned)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            HStack {
                Label("战力 \(store.equipmentBattlePower(definition).formatted())", systemImage: "bolt.shield.fill")
                    .font(.callout.monospacedDigit().weight(.black)).foregroundStyle(definition.rarity.color)
                Spacer()
                Button("详情") { showingDetail = true }.buttonStyle(.plain).foregroundStyle(SavingsTheme.blue)
                if owned > 0 {
                    Button(equipped ? "已装备" : "装备") { store.equip(definition) }
                        .buttonStyle(.bordered).controlSize(.small).disabled(equipped)
                    Menu("出售") {
                        Button("出售 1 件 · +\(store.equipmentSaleStardust(definition)) 星尘") { store.sellEquipment(definition) }
                        if owned > 1 { Button("出售全部 \(owned) 件 · +\(store.equipmentSaleStardust(definition) * owned) 星尘") { store.sellEquipment(definition, count: owned) } }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(equipped)
                }
            }
            .font(.caption2)
            if owned > 0 && !equipped {
                Text("出售可得 \(store.equipmentSaleStardust(definition)) 星尘")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10).frame(minHeight: 86, alignment: .top).savingsPanel(cornerRadius: 9)
        .mythicStroke(definition.rarity)
        .opacity(owned > 0 ? 1 : 0.68)
        .help("\(definition.setName)：\(definition.flavor)")
        .sheet(isPresented: $showingDetail) { EquipmentDetailView(definition: definition) }
    }
}

private struct EquipmentDetailView: View {
    @EnvironmentObject private var store: SavingsStore
    @Environment(\.dismiss) private var dismiss
    let definition: EquipmentDefinition

    private var equipped: Bool { store.equippedItemID(for: definition.slot) == definition.id }
    private var owned: Int { store.ownedCount(of: definition.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: definition.symbol).font(.title).foregroundStyle(definition.rarity.color).frame(width: 54, height: 54).background(definition.rarity.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.name).font(.title2.weight(.semibold))
                    Text("\(definition.slot.title) · \(definition.rarity.title) · \(definition.setName) · 强化 +\(store.enhancementLevel(for: definition.id))")
                        .font(.caption).foregroundStyle(definition.rarity.color)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("战力 \(store.equipmentBattlePower(definition).formatted())", systemImage: "bolt.shield.fill")
                        .font(.title3.monospacedDigit().weight(.black)).foregroundStyle(definition.rarity.color)
                    Text("最高 +\(GameProgression.maximumEquipmentEnhancement) · 后期增幅递增")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Label("\(store.adventure.stardust) 星尘", systemImage: "sparkles").foregroundStyle(SavingsTheme.purple)
                }
                Text(definition.flavor).font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 9)], spacing: 9) {
                    ForEach(attributeDefinitions(store: store)) { attribute in
                        HStack { Image(systemName: attribute.symbol).foregroundStyle(definition.rarity.color).frame(width: 24); VStack(alignment: .leading, spacing: 2) { Text(attribute.enhanced(store, definition)).font(.headline.monospacedDigit()); Text(attribute.title).font(.caption2).foregroundStyle(.secondary) }; Spacer() }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if !definition.uniqueAffixes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("独特词条").font(.headline)
                        ForEach(definition.uniqueAffixes) { affix in
                            HStack(spacing: 9) {
                                Image(systemName: affix.symbol).foregroundStyle(definition.rarity.color).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(affix.name).font(.callout.weight(.semibold))
                                    Text(affix.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Label("拥有 \(owned) 件", systemImage: "shippingbox.fill")
                    Label("出售单价 \(store.equipmentSaleStardust(definition)) 星尘", systemImage: "sparkles")
                    Spacer()
                    if owned > 0 {
                        let cost = store.equipmentEnhancementCost(definition)
                        Button(store.enhancementLevel(for: definition.id) >= GameProgression.maximumEquipmentEnhancement ? "已强化至 +\(GameProgression.maximumEquipmentEnhancement)" : "强化 +1 · \(cost) 星尘") { store.enhanceEquipment(definition) }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.enhancementLevel(for: definition.id) >= GameProgression.maximumEquipmentEnhancement || store.adventure.stardust < cost)
                    }
                    if owned > 0 { Button(equipped ? "已装备" : "装备") { store.equip(definition) }.buttonStyle(.borderedProminent).disabled(equipped) }
                    if owned > 0 { Button("出售 1 件") { store.sellEquipment(definition); if owned <= 1 { dismiss() } }.buttonStyle(.bordered).disabled(equipped) }
                }.font(.callout)
            }.padding(22)
        }.frame(minWidth: 640, idealWidth: 720, maxWidth: 960, minHeight: 560, idealHeight: 680, maxHeight: 900)
    }
}
