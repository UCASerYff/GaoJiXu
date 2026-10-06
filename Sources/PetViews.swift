import AppKit
import SwiftUI

private enum PetSpriteSheet {
    /// 各行顶部裁切 inset（pt）。未列出的行使用 `defaultRowTopInset`。
    /// 兔/猫头鹰行（第 2 行）向下溢出，其下一行（龟/仓鼠）需要更大的顶部 inset。
    /// 换图集时只需修改本表与下面的默认 inset，无需改动切片逻辑。
    private static let rowTopInsets: [Int: CGFloat] = [2: 24]
    private static let defaultRowTopInset: CGFloat = 8
    /// 左右与底部的统一安全 inset，防止相邻格子的抗锯齿像素越界。
    private static let horizontalInset: CGFloat = 8
    private static let bottomInset: CGFloat = 8

    private static let sprites: [[NSImage?]] = {
        guard let path = SavingsBundle.bundle.path(forResource: "PetSpriteSheetV16", ofType: "png"),
              let sheet = NSImage(contentsOfFile: path),
              let source = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Array(repeating: Array(repeating: nil, count: 3), count: 12)
        }
        return (0..<12).map { petIndex in
            let row = petIndex / 2
            let firstColumn = (petIndex % 2) * 3
            return (0..<3).map { stageColumn in
                let column = firstColumn + stageColumn
                let x0 = source.width * column / 6
                let x1 = source.width * (column + 1) / 6
                let y0 = source.height * row / 6
                let y1 = source.height * (row + 1) / 6
                // The generated sprites intentionally fill most of each cell. A small safe inset
                // prevents antialias pixels from a neighbouring form leaking across a grid edge.
                // Row-specific top insets are configured in `rowTopInsets` above.
                let topInset = rowTopInsets[row] ?? defaultRowTopInset
                let cropX = CGFloat(x0) + horizontalInset
                let cropY = CGFloat(y0) + topInset
                let cropWidth = CGFloat(x1 - x0) - horizontalInset * 2
                let cropHeight = CGFloat(y1 - y0) - topInset - bottomInset
                let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
                guard let crop = source.cropping(to: cropRect) else { return nil }
                return NSImage(cgImage: crop, size: NSSize(width: x1 - x0, height: y1 - y0))
            }
        }
    }()

    static func image(petIndex: Int, stage: PetLifeStage) -> NSImage? {
        guard sprites.indices.contains(petIndex) else { return nil }
        return sprites[petIndex][stage.spriteColumn]
    }
}

private struct PetSpriteView: View {
    let definition: PetDefinition
    let stage: PetLifeStage

    var body: some View {
        Group {
            if let image = PetSpriteSheet.image(petIndex: definition.spriteIndex, stage: stage) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(SavingsTheme.orange)
                    .padding(14)
            }
        }
        .accessibilityLabel("\(definition.name)\(stage.title)")
    }
}

struct PetShopView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var confirmingHatch = false
    /// 排序结果缓存：只在 onAppear 与宠物数量变化时重排。
    /// 上阵/下阵只更新卡片原位状态，不再触发整表重排，避免列表跳动。
    @State private var cachedSortedPets: [PetDefinition] = []

    private func refreshSort() {
        cachedSortedPets = SavingsCatalog.pets.sorted { lhs, rhs in
            let lhsOwned = store.petStars(lhs.id) > 0
            let rhsOwned = store.petStars(rhs.id) > 0
            if lhsOwned != rhsOwned { return lhsOwned }
            let lhsEquipped = store.isPetEquipped(lhs.id)
            let rhsEquipped = store.isPetEquipped(rhs.id)
            if lhsEquipped != rhsEquipped { return lhsEquipped }
            let lhsPower = lhs.battlePower(stars: max(1, store.petStars(lhs.id)))
            let rhsPower = rhs.battlePower(stars: max(1, store.petStars(rhs.id)))
            if lhsPower != rhsPower { return lhsPower > rhsPower }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 185), spacing: 10)], spacing: 10) {
                    SavingsStatTile(value: store.coins.formatted(), label: "可用金币", symbol: "dollarsign.circle.fill", color: SavingsTheme.orange)
                    SavingsStatTile(value: "\(store.pets.count) / \(SavingsCatalog.pets.count)", label: "宠物图鉴", symbol: "pawprint.fill", color: SavingsTheme.teal)
                    SavingsStatTile(value: "\(store.equippedPetIDs.count) / \(SavingsStore.maximumPetSlots)", label: "上阵宠物", symbol: "person.3.fill", color: SavingsTheme.blue)
                    SavingsStatTile(value: store.equippedPetPower.formatted(), label: "宠物总战力", symbol: "bolt.shield.fill", color: SavingsTheme.red)
                }

                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("宠物蛋孵化", systemImage: "circle.hexagongrid.fill")
                            .font(.title3.weight(.bold))
                        Text("每枚宠物蛋消耗 \(GameProgression.petEggCost.formatted()) 金币，十二种伙伴等概率出现。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("重复宠物自动升星：1 星幼年体、2 星成年体、3–99 星完全体；99 星后再重复转化为 10,000 金币。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let hatch = store.latestPetHatch, let definition = SavingsCatalog.pet(hatch.petID) {
                        HStack(spacing: 10) {
                            PetSpriteView(definition: definition, stage: PetLifeStage.stage(for: hatch.stars))
                                .frame(width: 62, height: 62)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最新孵化").font(.caption).foregroundStyle(.secondary)
                                Text(definition.name).font(.headline)
                                Text(hatch.result).font(.caption).foregroundStyle(SavingsTheme.orange)
                            }
                        }
                    }
                    Button {
                        confirmingHatch = true
                    } label: {
                        Label("孵化一枚", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.coins < GameProgression.petEggCost)
                }
                .padding(16).savingsPanel()
                .confirmationDialog(
                    "孵化一枚宠物蛋？",
                    isPresented: $confirmingHatch,
                    titleVisibility: .visible
                ) {
                    Button("消耗 \(GameProgression.petEggCost.formatted()) 金币并孵化") {
                        store.hatchPetEgg()
                        confirmingHatch = false
                    }
                    Button("取消", role: .cancel) { confirmingHatch = false }
                } message: {
                    Text("将立即扣除 \(GameProgression.petEggCost.formatted()) 金币（当前持有 \(store.coins.formatted())），随机孵化十二种伙伴之一；重复宠物自动升星。")
                }

                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("出战队伍 · 最多 4 只").font(.headline)
                            Text("宠物属性和战力直接计入角色总战力。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("一键上阵") { store.equipBestPets() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        ForEach(0..<SavingsStore.maximumPetSlots, id: \.self) { index in
                            PetDeploymentSlot(index: index)
                        }
                    }
                }
                .padding(14).savingsPanel()

                HStack {
                    Text("宠物背包与图鉴").font(.headline)
                    Text("已拥有和已上阵优先显示").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("每升 1 星，战力增幅都会提高").font(.caption).foregroundStyle(SavingsTheme.orange)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 10)], spacing: 10) {
                    ForEach(cachedSortedPets) { definition in
                        PetCard(definition: definition)
                    }
                }
            }
            .frame(maxWidth: 1120)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .onAppear { refreshSort() }
        .onChange(of: store.pets.count) { _, _ in refreshSort() }
    }
}

private struct PetDeploymentSlot: View {
    @EnvironmentObject private var store: SavingsStore
    let index: Int

    var body: some View {
        Group {
            if store.equippedPetIDs.indices.contains(index),
               let definition = SavingsCatalog.pet(store.equippedPetIDs[index]) {
                Button { store.unequipPet(definition) } label: {
                    HStack(spacing: 8) {
                        PetSpriteView(definition: definition, stage: store.petLifeStage(definition))
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(definition.name).font(.caption.weight(.bold)).lineLimit(1)
                            Text("★\(store.petStars(definition.id)) · \(store.petBattlePower(definition).formatted())")
                                .font(.caption2.monospacedDigit()).foregroundStyle(SavingsTheme.orange)
                            Text("点击下阵").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(SavingsTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(SavingsTheme.blue.opacity(0.35)))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "plus.circle.dashed").foregroundStyle(.tertiary)
                    Text("宠物位 \(index + 1)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 68)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
        }
    }
}

private struct PetCard: View {
    @EnvironmentObject private var store: SavingsStore
    let definition: PetDefinition

    private var stars: Int { store.petStars(definition.id) }
    private var isOwned: Bool { stars > 0 }
    private var stage: PetLifeStage { PetLifeStage.stage(for: max(1, stars)) }

    var body: some View {
        HStack(spacing: 12) {
            PetSpriteView(definition: definition, stage: stage)
                .frame(width: 74, height: 74)
                .opacity(isOwned ? 1 : 0.28)
                .grayscale(isOwned ? 0 : 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(definition.name).font(.headline)
                    if store.isPetEquipped(definition.id) {
                        Text("上阵").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(SavingsTheme.blue, in: Capsule())
                    }
                }
                Text(isOwned ? "\(stars) 星 · \(stage.title) · \(definition.role)" : "未解锁 · \(definition.role)")
                    .font(.caption).foregroundStyle(.secondary)
                Label("战力 \((isOwned ? store.petBattlePower(definition) : definition.baseBattlePower).formatted())", systemImage: "bolt.shield.fill")
                    .font(.callout.monospacedDigit().weight(.bold)).foregroundStyle(isOwned ? SavingsTheme.red : .secondary)
                Text(definition.flavor).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if isOwned {
                Button(store.isPetEquipped(definition.id) ? "下阵" : "上阵") {
                    if store.isPetEquipped(definition.id) { store.unequipPet(definition) }
                    else { store.equipPet(definition) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .savingsPanel()
    }
}
