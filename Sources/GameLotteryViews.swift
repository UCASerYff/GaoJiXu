import SwiftUI

struct LotteryView: View {
    @EnvironmentObject private var store: SavingsStore
    @State private var showingResults = false
    @State private var drawPool: DrawPool = .equipment

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 16) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 44)).foregroundStyle(SavingsTheme.orange)
                        .frame(width: 86, height: 86)
                        .background(SavingsTheme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                    Text("积蓄祈愿").font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("装备池和技能池相互独立。\(GameCopy.ticketPerUnitRule)，完成目标额外获得 100 张，也可用击杀所得金币购买。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 650)
                    Picker("祈愿池", selection: $drawPool) {
                        ForEach(DrawPool.allCases) { pool in
                            Label(pool.title, systemImage: pool.symbol).tag(pool)
                        }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 440)
                    HStack(spacing: 14) {
                        Button {
                            store.draw(count: 1, pool: drawPool); showingResults = !store.drawReveals.isEmpty
                        } label: {
                            Label("\(drawPool.shortTitle)单抽 · 1 星券", systemImage: drawPool.symbol)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(store.adventure.tickets < 1)
                        Button {
                            store.draw(count: 10, pool: drawPool); showingResults = !store.drawReveals.isEmpty
                        } label: {
                            Label("\(drawPool.shortTitle)十连 · 10 星券", systemImage: "sparkles.rectangle.stack.fill")
                        }
                        .buttonStyle(.bordered).controlSize(.large).disabled(store.adventure.tickets < 10)
                        Button {
                            store.draw(count: 100, pool: drawPool); showingResults = !store.drawReveals.isEmpty
                        } label: {
                            Label("\(drawPool.shortTitle)百连 · 100 星券", systemImage: "square.grid.3x3.square")
                        }
                        .buttonStyle(.bordered).controlSize(.large).tint(SavingsTheme.purple).disabled(store.adventure.tickets < 100)
                        Menu {
                            Button("500 金币 → 1 星券") { store.exchangeCoinsForTicket() }
                            Button("500 金币 → 50 悟性") { store.exchangeCoinsForInsight() }
                            Button("500 金币 → 50 星尘") { store.exchangeCoinsForStardust() }
                        } label: {
                            Label("金币商店", systemImage: "cart.fill")
                        }
                        .buttonStyle(.bordered).controlSize(.large).disabled(store.coins < 500)
                    }
                    HStack(spacing: 18) {
                        Label("持有 \(store.adventure.tickets) 张", systemImage: "ticket.fill").foregroundStyle(SavingsTheme.orange)
                        Label("\(store.coins) 金币", systemImage: "dollarsign.circle.fill").foregroundStyle(SavingsTheme.blue)
                        Label("\(drawPool.title)独立累计", systemImage: "shield.checkered").foregroundStyle(SavingsTheme.purple)
                    }
                    .font(.callout.weight(.semibold))
                    PityProgressView(pool: drawPool)
                }
                .padding(28).frame(maxWidth: .infinity).savingsPanel(cornerRadius: 16)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("掉落说明").font(.headline)
                        DrawRuleRow(rarity: .peerless, probability: "0.0001%", detail: "绝世\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .mythic, probability: "0.01%", detail: "神话\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .legendary, probability: "1%", detail: "传说\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .epic, probability: "5%", detail: "史诗\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .rare, probability: "14%", detail: "稀有\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .fine, probability: "32%", detail: "精良\(drawPool.shortTitle)")
                        DrawRuleRow(rarity: .common, probability: "其余", detail: "普通\(drawPool.shortTitle)")
                        Text(drawPool == .equipment
                             ? "装备池只产出装备；重复装备自动转化为星尘。五档保底分别独立累计。"
                             : "技能池只产出技能；重复技能按品质自动转化为悟性。五档保底分别独立累计。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        Text("单抽、十连与百连结果均按品质从高到低排列。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .top).savingsPanel()

                    VStack(alignment: .leading, spacing: 11) {
                        Text("最近获得").font(.headline)
                        if store.drawHistory.isEmpty {
                            Text("还没有抽取记录。新用户自带 10 张免费星券。")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
                        } else {
                            ForEach(store.drawHistory.prefix(7)) { entry in
                                HStack {
                                    Image(systemName: entry.symbol).foregroundStyle(entry.rarity.color).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).font(.callout.weight(.medium))
                                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(entry.rarity.title).font(.caption.weight(.semibold)).foregroundStyle(entry.rarity.color)
                                }
                            }
                        }
                    }
                    .padding(17).frame(maxWidth: .infinity, alignment: .top).savingsPanel()
                }
            }
            .frame(maxWidth: 1050)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showingResults) {
            DrawResultsView(reveals: store.drawReveals)
        }
    }
}

private struct PityProgressView: View {
    @EnvironmentObject private var store: SavingsStore
    let pool: DrawPool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ItemRarity.guaranteedTiers) { rarity in
                    let threshold = rarity.guaranteeDraws ?? 1
                    let progress = store.pityCount(for: pool, rarity: rarity)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rarity.title).font(.caption.weight(.bold)).foregroundStyle(rarity.gradient)
                            Spacer(minLength: 4)
                            Text("差 \(store.drawsUntilGuarantee(for: pool, rarity: rarity)) 抽")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(progress), total: Double(threshold)).tint(rarity.color)
                        Text("\(progress) / \(threshold)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(rarity.color.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("抽到该品质或更高时，会重置该档及更低档计数；更高档进度继续保留。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DrawRuleRow: View {
    let rarity: ItemRarity
    let probability: String
    let detail: String
    var body: some View {
        HStack {
            Circle().fill(rarity.gradient).frame(width: 9, height: 9)
            Text(rarity.title).font(.callout.weight(.semibold)).foregroundStyle(rarity.gradient)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text(probability).font(.caption.monospacedDigit().weight(.semibold)).frame(width: 58, alignment: .trailing)
        }
    }
}

private struct DrawResultsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reveals: [DrawReveal]
    @State private var revealedCount = 0
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Text(reveals.count > 1 ? "\(reveals.count) 抽结果 · 高品质优先" : "获得新收藏").font(.title2.weight(.bold))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(Array(reveals.enumerated()), id: \.element.id) { index, reveal in
                        let appeared = index < revealedCount
                        VStack(spacing: 10) {
                            Image(systemName: reveal.symbol).font(.system(size: 30)).foregroundStyle(reveal.rarity.gradient)
                                .frame(width: 62, height: 62).background(reveal.rarity.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            Text(reveal.title).font(.headline).multilineTextAlignment(.center).lineLimit(2)
                            Text(reveal.subtitle).font(.caption).foregroundStyle(.secondary)
                            Text(reveal.rarity.title).font(.pixel(12, weight: .bold)).foregroundStyle(reveal.rarity.gradient)
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 170).savingsPanel()
                        .mythicStroke(reveal.rarity, cornerRadius: 12, lineWidth: 2)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.8)
                    }
                }
            }
            Button("收下") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .padding(22)
        .frame(
            minWidth: reveals.count > 1 ? 640 : 340,
            idealWidth: reveals.count > 1 ? 800 : 380,
            maxWidth: reveals.count > 1 ? 1100 : 560,
            minHeight: reveals.count > 1 ? 480 : 320,
            idealHeight: reveals.count > 1 ? 560 : 360,
            maxHeight: reveals.count > 1 ? 900 : 560
        )
        .onAppear(perform: startReveal)
        .onDisappear { revealTask?.cancel() }
    }

    /// 结果卡片按 0.03s 错峰逐个浮现；百连时压缩间隔，总时长封顶约 1.5s。
    /// 减弱动效开启（或只有单抽结果）时直接全部展示。
    private func startReveal() {
        guard !reveals.isEmpty else { return }
        if reduceMotion || reveals.count == 1 {
            revealedCount = reveals.count
            return
        }
        let interval = min(0.03, 1.5 / Double(reveals.count))
        revealTask = Task { @MainActor in
            for _ in reveals {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    revealedCount += 1
                }
            }
        }
    }
}
