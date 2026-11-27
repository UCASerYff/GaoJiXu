(() => {
  "use strict";

  const h = escapeHTML;
  const number = value => Number(value || 0).toLocaleString(t("zh-CN", "en-US"));
  const asset = name => `/assets/mac/${name}.png`;
  const glyphs = {
    "bolt.fill": "E945", "flag.checkered": "E7C1",
    "shield.fill": "EA18", "shield.lefthalf.filled": "EA18", "checkmark.shield.fill": "E83D",
    "books.vertical.fill": "E82D", "scroll.fill": "E8EF",
    "lightbulb.fill": "EA80", "sparkles": "E734", "tshirt.fill": "E8EC", "dollarsign.circle.fill": "E8C7",
    "bolt.shield.fill": "E945", "lock.fill": "E72E", "checkmark.seal.fill": "E73E", "cart.fill": "E7BF",
    "arrow.counterclockwise": "E72C", "arrow.up.circle.fill": "E74A", "arrow.down.circle.fill": "E74B",
    "square.stack.3d.up.fill": "E7B8", "heart.fill": "EB52", "diamond.fill": "E734", "star.fill": "E735",
    "burst.fill": "E945", "flame.fill": "ECAD", "scope": "E7B7", "person.3.fill": "E902",
    "shippingbox.fill": "E7B8", "circle.hexagongrid.fill": "EA3A", "plus.circle.dashed": "ECC8",
  };
  const pictograms = {"tent.fill": "⛺︎", "forward.fill": "⏩︎", "pawprint.fill": "🐾︎", "trophy.fill": "🏆︎", "gift.fill": "🎁︎"};
  function symbol(name) {
    if (glyphs[name]) return `<span class="ui-icon" aria-hidden="true">&#x${glyphs[name]};</span>`;
    if (pictograms[name]) return `<span class="ui-icon adv-pictogram" aria-hidden="true">${pictograms[name]}</span>`;
    return icon(name);
  }
  const tabs = [
    ["map", "冒险地图", "Adventure Map", "map.fill"], ["equipment", "装备", "Equipment", "shield.lefthalf.filled"],
    ["technique", "技能", "Techniques", "books.vertical.fill"], ["pets", "宠物", "Pets", "pawprint.fill"],
    ["lottery", "祈愿", "Wishes", "gift.fill"], ["achievements", "成就", "Achievements", "trophy.fill"],
  ];
  const rarities = ["", "普通", "精良", "稀有", "史诗", "传说", "神话", "绝世"];
  const guarantees = [["rare", 3, 10], ["epic", 4, 30], ["legendary", 5, 150], ["mythic", 6, 500], ["peerless", 7, 2000]];
  const stageNames = ["幼年体", "成年体", "完全体"];
  const camp = [
    ["equipment", "锻造营", 0], ["technique", "研修塔", 1], ["pets", "灵宠营", 2], ["lottery", "祈愿坛", 3],
  ];
  let current = "map";
  try { const saved = sessionStorage.getItem("gaojixu.adventure.tab"); if (tabs.some(tab => tab[0] === saved)) current = saved; } catch (_) {}
  let pool = "equipment";
  let selectedMonster = false;
  let latestAttack = null;
  let renderedKey = "";
  let notice = "";
  let busy = false;
  let petOrder = [];
  let ownedPetsAtSort = -1;
  let dialog;
  let modalAction;
  const catalogs = {};
  const pendingCatalogs = {};
  const filters = {
    equipment: {search: "", slot: "", rarity: "", owned: true, shown: 60},
    technique: {search: "", school: "", effect: "", owned: true, shown: 60},
  };

  const root = () => document.getElementById("adventure");
  const game = () => state.adventure;
  const resources = () => state.summary;
  const rarityClass = rarity => `adv-rarity-${Number(rarity)}`;
  const btn = (label, action, id = "", options = {}) => `<button type="button" class="adv-button ${options.primary ? "adv-primary" : ""} ${options.plain ? "adv-plain" : ""}" data-adv-action="${action}" data-id="${h(id)}"${options.disabled ? " disabled" : ""}${options.count ? ` data-count="${options.count}"` : ""}>${options.icon ? symbol(options.icon) : ""}${h(label)}</button>`;
  const stat = (label, value, glyph, tone) => `<div class="adv-stat adv-tone-${tone}"><span class="adv-stat-icon">${symbol(glyph)}</span><div><strong>${h(value)}</strong><small>${h(label)}</small></div></div>`;
  const progress = (label, value, maximum) => `<progress aria-label="${h(label)}" max="${Number(maximum) || 1}" value="${Number(value) || 0}"></progress>`;
  const iconTile = (glyph, extra = "") => `<span class="adv-icon-tile ${extra}">${symbol(glyph)}</span>`;
  const eventRow = event => `<div class="adv-event ${event.rarity ? rarityClass(event.rarity) : ""}">${iconTile(event.symbol)}<div><strong>${h(event.title)}</strong><small>${h(event.detail)}</small></div>${event.rarity ? `<span class="adv-event-rarity">${rarities[event.rarity]}</span>` : ""}</div>`;
  const menu = (label, actions) => `<details class="adv-menu"><summary>${h(label)} ${icon("chevron.down")}</summary><div>${actions.join("")}</div></details>`;

  function atlas(name, width, height, x, y, cropWidth, cropHeight, css = "") {
    const posX = x / Math.max(1, width - cropWidth) * 100;
    const posY = y / Math.max(1, height - cropHeight) * 100;
    return `<span aria-hidden="true" class="adv-atlas ${css}" style="aspect-ratio:${cropWidth}/${cropHeight};background-image:url('${asset(name)}');background-size:${width / cropWidth * 100}% ${height / cropHeight * 100}%;background-position:${posX}% ${posY}%"></span>`;
  }

  function petSprite(pet, stage = pet.stage) {
    const row = Math.floor(pet.sprite / 2);
    const col = (pet.sprite % 2) * 3 + stage;
    const top = row === 2 ? 24 : 8;
    return atlas("PetSpriteSheetV16", 1230, 1278, col * 205 + 8, row * 213 + top, 189, 205 - top, "adv-pet-sprite");
  }

  function monsterSprite(picture) {
    const index = Math.max(0, Math.min(9, Number(picture) || 0));
    const column = index % 5;
    const x = Math.floor(1536 * column / 5);
    return atlas("MonsterSpriteSheetV16", 1536, 1024, x, Math.floor(index / 5) * 512,
      Math.floor(1536 * (column + 1) / 5) - x, 512, "adv-monster-art");
  }

  function actor(name, artwork, css, action = "", id = "", position = "") {
    const content = artwork + (name ? `<span class="adv-actor-label">${h(name)}</span>` : "");
    const pressed = id === "monster" ? ` aria-pressed="${selectedMonster}"` : "";
    return action
      ? `<button type="button" class="adv-actor ${css}" ${position} data-adv-action="${action}" data-id="${h(id)}"${pressed}>${content}</button>`
      : `<div class="adv-actor ${css}" ${position}>${content}</div>`;
  }

  function battleActors(data, interactive) {
    const petActors = data.equippedPets.map(id => data.petCatalog.find(item => item.id === id)).filter(Boolean);
    return actor(`勇者 Lv.${data.level}`, `<img src="${asset("AdventureHeroV353")}" alt="">`, "adv-hero") +
      actor(data.monster, monsterSprite(data.monsterSprite), `adv-monster${interactive && selectedMonster ? " selected" : ""}`,
        interactive ? "actor" : "", "monster") +
      petActors.map((pet, index) => actor("", petSprite(pet, pet.stars >= 4 ? 2 : Math.min(1, pet.stage)), "adv-battle-pet", "", "",
        `aria-label="${h(pet.name)}" style="--pet-x:${33 + (index - (petActors.length - 1) / 2) * 9}%"`)).join("");
  }

  function battleScene(data, interactive) {
    return `<div class="adv-world adv-battle-scene" aria-label="${interactive ? "战斗场景" : "自动冒险"}"${interactive ? ' data-adv-click-clear' : ""}>${battleActors(data, interactive)}</div>`;
  }

  function battleInfo(data) {
    return `<div class="adv-health"><div class="adv-tone-green"><div><strong>勇者</strong><span>${number(data.heroHP)} / ${number(data.heroMaxHP)}</span></div>${progress("勇者生命", data.heroHP, data.heroMaxHP)}</div>
      <div class="adv-tone-red"><div><strong>怪物</strong><span>${number(data.monsterHP)} / ${number(data.monsterMaxHP)}</span></div>${progress("怪物生命", data.monsterHP, data.monsterMaxHP)}</div></div>
      <div class="adv-split adv-power"><strong>勇者战力 ${number(data.power)}</strong><strong>敌方战力 ${number(data.monsterPower)}</strong></div>
      <small class="adv-battle-msg">${h(selectedMonster ? `${data.monsterTrait} · ${data.monsterTraitDetail}` : data.message)}</small>`;
  }

  function campScene() {
    const width = 1254;
    const height = 1254;
    const dividerX = Math.round(width * .572);
    const dividerY = Math.round(height * .508);
    return `<div class="adv-world adv-camp-scene">${camp.map(([key, label, index]) => {
      const x = index % 2 ? dividerX : 0;
      const y = index >= 2 ? dividerY : 0;
      const artwork = atlas("AdventureBuildingsV353", width, height, x, y, x ? width - x : dividerX, y ? height - y : dividerY);
      return actor(label, artwork, `adv-camp-building adv-building-${index}`, "tab", key);
    }).join("")}</div>`;
  }

  function battleTotals(data) {
    return [stat("勇者等级", `Lv.${data.level}`, "bolt.fill", "green"), stat("当前关卡", number(data.stage), "flag.checkered", "red"),
      stat("本关重开", number(data.attempts), "arrow.counterclockwise", "purple"), stat("累计过关", number(data.defeated), "forward.fill", "orange")].join("");
  }

  function monsterReport(data) {
    return `<div class="adv-split"><h3>当前怪物</h3><div class="adv-trait"><strong>${h(data.monsterTrait)}</strong><small>${h(data.monsterTraitDetail)}</small></div></div>
      <small>${h(data.monsterChapter)} · 第 ${number(data.stage)} 关</small><hr><h3>最近战报</h3>${data.events.map(eventRow).join("")}`;
  }

  function mapPage(data) {
    const rules = [
      ["持续自动打", "应用运行时每秒攻击，不需要点击或等待攒钱触发", "forward.fill"],
      ["过关就前进", "十种怪物循环登场，关卡没有上限且强度单调提升", "flag.checkered"],
      ["失败原关重开", "双方恢复生命，继续挑战同一关，直到角色足够强", "arrow.counterclockwise"],
      ["击杀结算奖励", "金币、悟性和经验只在击杀后结算，并有概率掉落装备或技能", "burst.fill"],
      ["积蓄兑换星券", "每积蓄 1 个货币单位获得 1 张星券，完成目标额外获得 100 张", "arrow.down.circle.fill"],
      ["词条与绝技", "装备词条和技能绝技会真实改变攻防、回复与奖励", "sparkles"],
    ];
    return `<article class="adv-panel adv-battle"><div class="adv-split adv-world-title"><div><strong>${symbol("flag.checkered")} <span data-adv-stage>第 ${number(data.stage)} 关</span></strong><small data-adv-chapter>${h(data.monsterChapter)}</small></div><small class="adv-tone-green">${symbol("forward.fill")} 每秒自动攻击</small></div>
      ${battleScene(data, true)}<div class="adv-battle-info">${battleInfo(data)}</div></article>
      <article class="adv-panel adv-camp"><div class="adv-split adv-world-title"><strong>${symbol("tent.fill")} 远征营地</strong><small>点击建筑进入装备、技能、宠物或祈愿</small></div>${campScene()}</article>
      <div class="adv-stats adv-battle-totals">${battleTotals(data)}</div>
      <div class="adv-columns"><article class="adv-panel"><h3>无限自动战斗规则</h3>${rules.map(([title, detail, glyph]) => eventRow({title, detail, symbol: glyph})).join("")}</article>
      <article class="adv-panel adv-monster-report">${monsterReport(data)}</article></div>`;
  }

  function selectFilter(key, label, options, currentValue) {
    return `<select aria-label="${h(label)}" data-adv-filter="${key}">${options.map(([id, text]) => `<option value="${h(id)}"${String(id) === currentValue ? " selected" : ""}>${h(text)}</option>`).join("")}</select>`;
  }

  function filterBar(data, kind) {
    const config = filters[kind];
    const gear = kind === "equipment";
    const fields = gear
      ? selectFilter("slot", "部位", [["", "全部部位"], ...data.slots.map(item => [item.id, item.name])], config.slot) +
        selectFilter("rarity", "品质", [["", "全部品质"], ...rarities.slice(1).map((label, index) => [index + 1, label])], config.rarity)
      : selectFilter("school", "流派", [["", "全部流派"], ...data.schools.map(item => [item, item])], config.school) +
        selectFilter("effect", "效果", [["", "全部效果"], ...Object.entries(data.effects)], config.effect);
    const placeholder = gear ? "搜索装备或套装" : "搜索名称、流派或文化";
    return `<div class="adv-filter"><label class="adv-search">${icon("magnifyingglass")}<input type="search" aria-label="${placeholder}" placeholder="${placeholder}" data-adv-filter="search" value="${h(config.search)}"></label>
      ${fields}<label class="adv-check"><input type="checkbox" data-adv-filter="owned"${config.owned ? " checked" : ""}>${gear ? "只看已拥有" : "只看已学"}</label>
      <small>${gear ? "已装备优先 · 品质与战力降序" : "已装配优先 · 品质降序"}</small><small class="adv-result-count" aria-live="polite"></small></div>`;
  }

  function rarityMenu(title, action, prefix, suffix) {
    return menu(title, rarities.slice(1, 6).map((name, index) => btn(index === 0 ? `${prefix}所有普通${suffix}` : `${prefix}${name}及以下`, action, index + 1)));
  }

  function attributes(rows) {
    return `<div class="adv-attributes">${rows.map(item => `<div>${symbol(item.symbol)}<span><strong>${typeof item.value === "number" ? number(item.value) : h(item.value)}</strong><small>${h(item.name)}</small></span></div>`).join("")}</div>`;
  }

  function equipmentPage(data) {
    const breakdown = data.powerBreakdown;
    const gear = Object.fromEntries(data.gear.map(item => [item.id, item]));
    return `<article class="adv-panel"><div class="adv-split adv-character-heading"><h3>角色 15 维战斗属性</h3><div><strong>总战力 ${number(data.power)}</strong><small>基础 ${number(breakdown.base)} · 装备 ${number(breakdown.equipment)} · 技能 ${number(breakdown.techniques)} · 宠物 ${number(breakdown.pets)}</small></div></div>
      ${attributes(data.attributes)}${data.affixes.length ? `<h4>生效词条</h4><div class="adv-affix-list">${data.affixes.map(item => `<span title="${h(item.detail)}">${symbol(item.symbol)} ${h(item.name)} · ${h(item.detail)}</span>`).join("")}</div>` : ""}</article>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><h3>角色装备 · 14 个部位</h3><div class="adv-actions"><span class="adv-tone-purple">${symbol("sparkles")} ${number(resources().stardust)} 星尘</span>
      ${btn("一键装备", "equip-best", "", {primary: true})}${btn("清理重复装备", "request-duplicates")}${rarityMenu("一键出售", "request-sale", "出售", "装备")}</div></div>
      <small>一键装备按未强化初始战力比较 · 点击装备格可卸下</small>
      <div class="adv-slots">${data.slots.map(slot => loadoutSlot(slot.name, gear[data.equipped[slot.id]], slot.symbol, "空", "unequip", slot.id, true)).join("")}</div></article>
      ${filterBar(data, "equipment")}<div data-adv-collection></div>`;
  }

  function loadoutSlot(label, item, glyph, empty, action, id, gear = false) {
    const name = item?.name || empty;
    const detail = gear && item ? `<small>+${item.enhancement} · 战力 ${number(item.power)}</small>` : "";
    return `<button type="button" class="adv-slot ${item ? rarityClass(item.rarity) : ""}" data-adv-action="${action}" data-id="${h(id)}"${item ? "" : " disabled"}>${iconTile(item?.symbol || glyph)}<span><small>${h(label)}</small><strong>${h(name)}</strong>${detail}</span></button>`;
  }

  function gearCard(item, data) {
    const equipped = data.equipped[item.slot] === item.id;
    const slot = data.slots.find(row => row.id === item.slot)?.name;
    return `<article class="adv-panel adv-catalog-card ${rarityClass(item.rarity)} ${item.count ? "" : "adv-locked"}" title="${h(`${item.setName}：${item.flavor}`)}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(item.count ? item.name : "未发现装备")}</strong><small>${h(slot)} · ${rarities[item.rarity]} · +${item.enhancement}</small></div>${item.count ? `<small>×${number(item.count)}</small>` : ""}</div>
      <div class="adv-card-row"><strong>${symbol("bolt.shield.fill")} 战力 ${number(item.power)}</strong><div class="adv-actions">${btn("详情", "detail", item.id, {plain: true})}${item.count ? btn(equipped ? "已装备" : "装备", "equip", item.id, {disabled: equipped}) : ""}
      ${item.count && !equipped ? menu("出售", [btn(`出售 1 件 · +${number(item.sale)} 星尘`, "sell", item.id, {count: 1}), ...(item.count > 1 ? [btn(`出售全部 ${number(item.count)} 件`, "sell", item.id, {count: item.count})] : [])]) : ""}</div></div>
      ${item.count && !equipped ? `<small>出售可得 ${number(item.sale)} 星尘</small>` : ""}</article>`;
  }

  function techniquePage(data) {
    const learned = Object.fromEntries(data.techniques.map(item => [item.id, item]));
    return `<div class="adv-stats">${stat("可用悟性", number(resources().insight), "lightbulb.fill", "purple")}${stat("已学 / 总技能", `${data.techniques.length}/${data.techniqueCount}`, "scroll.fill", "orange")}${stat("装配技能战力", number(data.powerBreakdown.techniques), "bolt.shield.fill", "red")}${stat("已装配流派", `${data.equippedTechniques.length}/12`, "square.grid.2x2.fill", "green")}</div>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><h3>当前构筑 · 最多 12 门</h3><div class="adv-actions">${btn("一键装配", "technique-best", "", {primary: true})}${rarityMenu("一键遗忘", "request-forget", "遗忘", "技能")}</div></div>
      <small>按 1 重初始战力选择 · 只有装配的技能会生效</small><div class="adv-slots">${Array.from({length: 12}, (_, index) => {
        const id = data.equippedTechniques[index] || "";
        return loadoutSlot(`第 ${index + 1} 格`, learned[id], "plus", "空技能位", "unequip-technique", id);
      }).join("")}</div></article>${filterBar(data, "technique")}<div data-adv-collection></div>`;
  }

  function techniqueCard(item, data) {
    const equipped = data.equippedTechniques.includes(item.id);
    return `<article class="adv-panel adv-catalog-card ${rarityClass(item.rarity)} ${item.level ? "" : "adv-locked"}" title="${h(item.description)}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(item.level ? item.name : "未悟得技能")}</strong><small>${h(item.culture)} · ${h(item.school)} · ${rarities[item.rarity]}</small></div>${item.level ? `<small>${item.level} 重</small>` : ""}</div>
      <div class="adv-card-row"><small>${h(item.effectDisplay)}</small><strong>${symbol("bolt.fill")} 战力 ${number(item.power)}</strong>${item.level ? btn(equipped ? "卸下" : "装配", equipped ? "unequip-technique" : "technique", item.id) : ""}</div>
      <small>${symbol(item.signature.symbol)} 绝技·${h(item.signature.name)}：${h(item.signature.detail)}</small>
      ${item.level ? `<div class="adv-card-row"><small>最高 99 重 · 后期增幅递增</small>${btn(item.upgradeCost ? `参悟 ${number(item.upgradeCost)}` : "已满级", "upgrade-technique", item.id, {primary: true, disabled: !item.upgradeCost || resources().insight < item.upgradeCost})}</div>` : ""}</article>`;
  }

  function renderCollection() {
    const target = root().querySelector("[data-adv-collection]");
    if (!target || !filters[current]) return;
    const data = game();
    const kind = current;
    const gear = kind === "equipment";
    const config = filters[kind];
    const owned = gear ? data.gear : data.techniques;
    const equipped = new Set(gear ? Object.values(data.equipped) : data.equippedTechniques);
    const total = gear ? data.gearCount : data.techniqueCount;
    const count = root().querySelector(".adv-result-count");
    if (!config.owned && !catalogs[kind]) {
      count.textContent = `0 / ${total}`;
      target.innerHTML = '<div class="adv-panel adv-empty" role="status">正在读取图鉴…</div>';
      if (!pendingCatalogs[kind]) {
        pendingCatalogs[kind] = get(`/api/adventure/catalog?kind=${kind}`).then(response => {
          catalogs[kind] = response.result;
          if (current === kind) renderCollection();
        }).catch(error => {
          if (current === kind) target.innerHTML = `<div class="adv-panel adv-empty">${h(error.message)}${btn("重新载入", "reload-catalog")}</div>`;
        }).finally(() => delete pendingCatalogs[kind]);
      }
      return;
    }
    const ownedById = Object.fromEntries(owned.map(item => [item.id, item]));
    const source = config.owned ? owned : catalogs[kind].map(item => ownedById[item.id] || (gear ? {...item, count: 0, enhancement: 0} : {...item, level: 0}));
    const query = config.search.trim().toLowerCase();
    const matches = source.filter(item => {
      const searchable = gear ? [item.name, item.setName] : [item.name, item.school, item.culture];
      const combined = !query || searchable.some(value => value.toLowerCase().includes(query));
      return combined && (gear ? (!config.slot || item.slot === config.slot) && (!config.rarity || item.rarity === Number(config.rarity))
        : (!config.school || item.school === config.school) && (!config.effect || item.effect === config.effect));
    }).sort((a, b) => Number(equipped.has(b.id)) - Number(equipped.has(a.id)) || b.rarity - a.rarity ||
      (gear ? b.power - a.power : b.level - a.level) || a.name.localeCompare(b.name, "zh-CN"));
    count.textContent = `${matches.length} / ${total}`;
    if (!matches.length) {
      const title = config.owned ? (gear ? "当前筛选下还没有装备" : "当前筛选下还没有已学技能") : (gear ? "没有匹配装备" : "没有匹配技能");
      target.innerHTML = `<div class="adv-panel adv-empty">${iconTile(gear ? "shippingbox.fill" : "books.vertical.fill")}<strong>${title}</strong><small>${gear ? "使用免费星券可获得装备；关闭‘只看已拥有’可浏览完整图鉴。" : `关闭‘只看已学’可浏览 ${total} 门原创技能图鉴。`}</small></div>`;
      return;
    }
    const more = matches.length > config.shown ? `<div class="adv-collection-more">${btn(`显示更多 · ${matches.length - config.shown} 件`, "more")}</div>` : "";
    target.innerHTML = `<div class="adv-card-grid">${matches.slice(0, config.shown).map(item => gear ? gearCard(item, data) : techniqueCard(item, data)).join("")}</div>${more}`;
  }

  function petsPage(data) {
    const team = data.equippedPets;
    const pets = Object.fromEntries(data.petCatalog.map(item => [item.id, item]));
    if (ownedPetsAtSort !== data.pets.length || !petOrder.length) {
      petOrder = [...data.petCatalog].sort((a, b) => Number(b.stars > 0) - Number(a.stars > 0) ||
        Number(team.includes(b.id)) - Number(team.includes(a.id)) || b.power - a.power || a.name.localeCompare(b.name, "zh-CN")).map(item => item.id);
      ownedPetsAtSort = data.pets.length;
    }
    const hatch = data.latestPetHatch;
    return `<div class="adv-stats">${stat("可用金币", number(resources().coins), "dollarsign.circle.fill", "orange")}${stat("宠物图鉴", `${data.pets.length} / ${data.petCatalog.length}`, "pawprint.fill", "teal")}${stat("上阵宠物", `${team.length} / 4`, "person.3.fill", "blue")}${stat("宠物总战力", number(data.powerBreakdown.pets), "bolt.shield.fill", "red")}</div>
      <article class="adv-panel adv-pet-hatch"><div><h3>${symbol("circle.hexagongrid.fill")} 宠物蛋孵化</h3><p>每枚宠物蛋消耗 10,000 金币，十二种伙伴等概率出现。</p><small>重复宠物自动升星：1 星幼年体、2 星成年体、3–99 星完全体；99 星后再重复转化为 10,000 金币。</small></div>
      ${hatch && pets[hatch.petID] ? `<div class="adv-latest-pet">${petSprite(pets[hatch.petID])}<div><small>最新孵化</small><strong>${h(hatch.name)}</strong><small>${h(hatch.result)}</small></div></div>` : ""}
      ${btn("孵化一枚", "request-hatch", "", {primary: true, icon: "sparkles", disabled: resources().coins < 10000})}</article>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><div><h3>出战队伍 · 最多 4 只</h3><small>宠物属性和战力直接计入角色总战力。</small></div>${btn("一键上阵", "pet-best", "", {primary: true})}</div>
      <div class="adv-team">${Array.from({length: 4}, (_, index) => {
        const pet = pets[team[index]];
        return pet ? `<button type="button" class="adv-pet-slot" data-adv-action="unequip-pet" data-id="${h(pet.id)}">${petSprite(pet)}<span><strong>${h(pet.name)}</strong><small>★${pet.stars} · ${number(pet.power)}</small><small>点击下阵</small></span></button>`
          : `<div class="adv-pet-slot adv-pet-empty">${symbol("plus.circle.dashed")} <small>宠物位 ${index + 1}</small></div>`;
      }).join("")}</div></article>
      <div class="adv-split adv-pet-catalog-heading"><h3>宠物背包与图鉴</h3><small>已拥有和已上阵优先显示 · 每升 1 星，战力增幅都会提高</small></div>
      <div class="adv-card-grid adv-pet-grid">${petOrder.map(id => {
        const pet = pets[id];
        const equipped = team.includes(pet.id);
        return `<article class="adv-panel adv-pet-card ${pet.stars ? "" : "adv-locked"}">${petSprite(pet)}<div><strong>${h(pet.name)} ${equipped ? '<span class="adv-badge">上阵</span>' : ""}</strong>
          <small>${pet.stars ? `${pet.stars} 星 · ${stageNames[pet.stage]}` : "未解锁"} · ${h(pet.role)}</small><strong class="adv-tone-red">${symbol("bolt.shield.fill")} 战力 ${number(pet.power)}</strong><small>${h(pet.flavor)}</small></div>
          ${pet.stars ? btn(equipped ? "下阵" : "上阵", equipped ? "unequip-pet" : "pet", pet.id) : ""}</article>`;
      }).join("")}</div>`;
  }

  function pity(data) {
    return `<div class="adv-pity"><div>${guarantees.map(([key, rarity, limit]) => {
      const value = data.pity[pool][key];
      return `<div class="${rarityClass(rarity)}"><div class="adv-split"><strong>${rarities[rarity]}</strong><small>差 ${number(limit - value)} 抽</small></div>${progress(`${rarities[rarity]}保底`, value, limit)}<small>${number(value)} / ${number(limit)}</small></div>`;
    }).join("")}</div><small>抽到该品质或更高时，会重置该档及更低档计数；更高档进度继续保留。</small></div>`;
  }

  function lotteryPage(data) {
    const label = pool === "equipment" ? "装备" : "技能";
    const balance = resources();
    const rates = ["", "其余", "32%", "14%", "5%", "1%", "0.01%", "0.0001%"];
    return `<article class="adv-panel adv-lottery">${iconTile("gift.fill", "adv-lottery-icon")}<h2>积蓄祈愿</h2>
      <p>装备池和技能池相互独立。每积蓄 1 个货币单位获得 1 张星券，完成目标额外获得 100 张，也可用击杀所得金币购买。</p>
      <div class="adv-segments adv-pool" aria-label="祈愿池">${[["equipment", "装备池", "shield.fill"], ["technique", "技能池", "books.vertical.fill"]].map(([key, text, glyph]) => `<button type="button" data-adv-action="pool" data-id="${key}" aria-pressed="${key === pool}">${symbol(glyph)} ${text}</button>`).join("")}</div>
      <div class="adv-actions adv-wish-actions">${btn(`${label}单抽 · 1 星券`, "draw", 1, {primary: true, icon: "gift.fill", disabled: balance.tickets < 1})}
      ${btn(`${label}十连 · 10 星券`, "draw", 10, {icon: "sparkles", disabled: balance.tickets < 10})}${btn(`${label}百连 · 100 星券`, "draw", 100, {icon: "square.grid.2x2.fill", disabled: balance.tickets < 100})}
      ${balance.coins >= 500 ? menu("金币商店", [btn("500 金币 → 1 星券", "exchange", "tickets"), btn("500 金币 → 50 悟性", "exchange", "insight"), btn("500 金币 → 50 星尘", "exchange", "stardust")]) : btn("金币商店", "exchange", "", {icon: "cart.fill", disabled: true})}</div>
      <div class="adv-actions adv-wish-totals"><strong class="adv-tone-orange">${symbol("ticket.fill")} 持有 ${number(balance.tickets)} 张</strong><strong class="adv-tone-blue">${symbol("dollarsign.circle.fill")} ${number(balance.coins)} 金币</strong><strong class="adv-tone-purple">${symbol("shield.fill")} ${label}池独立累计</strong></div>
      ${pity(data)}</article>
      <div class="adv-columns"><article class="adv-panel adv-drop-rules"><h3>掉落说明</h3>${[7, 6, 5, 4, 3, 2, 1].map(item => `<div class="adv-drop ${rarityClass(item)}"><strong><i></i>${rarities[item]}</strong><small>${rarities[item]}${label}</small><b>${rates[item]}</b></div>`).join("")}
      <small>${pool === "equipment" ? "装备池只产出装备；重复装备自动转化为星尘。" : "技能池只产出技能；重复技能按品质自动转化为悟性。"}五档保底分别独立累计。</small><small>单抽、十连与百连结果均按品质从高到低排列。</small></article>
      <article class="adv-panel"><h3>最近获得</h3>${data.history.length ? data.history.map(eventRow).join("") : '<p class="adv-empty">还没有抽取记录。</p>'}</article></div>`;
  }

  function achievementsPage(data) {
    return `<div class="adv-stats adv-achievement-stats">${stat("已解锁成就", `${data.achievements.filter(item => item.unlocked).length}/${data.achievements.length}`, "trophy.fill", "orange")}${stat("留下足迹的天数", number(data.savingDays), "calendar", "teal")}${stat("冒险胜利次数", number(data.defeated), "burst.fill", "green")}</div>
      <div class="adv-card-grid adv-achievement-grid">${data.achievements.map(item => `<article class="adv-panel adv-achievement adv-tone-${item.color} ${item.unlocked ? "" : "adv-locked"}">
      ${iconTile(item.unlocked ? item.symbol : "lock.fill")}<h3>${h(item.unlocked ? item.title : "尚未解锁")}</h3><small>${h(item.detail)}</small>
      ${item.unlocked ? `<strong>${symbol("checkmark.seal.fill")} 已获得</strong>` : `<div class="adv-achievement-progress">${progress(item.detail, item.current, item.total)}<small>${item.current}/${item.total}</small></div>`}</article>`).join("")}</div>`;
  }

  function sceneKey(data, interactive) {
    return JSON.stringify([data.level, data.monster, data.monsterSprite, data.equippedPets.map(id => [id, data.petCatalog.find(pet => pet.id === id)?.stars]), interactive && selectedMonster]);
  }

  function updateScene(scene, data, interactive) {
    if (!scene) return;
    const key = sceneKey(data, interactive);
    if (scene.dataset.scenery !== key) {
      const focused = scene.contains(document.activeElement);
      scene.innerHTML = battleActors(data, interactive);
      scene.dataset.scenery = key;
      if (focused) scene.querySelector("button")?.focus({preventScroll: true});
    }
    if (scene.dataset.attack !== String(data.attackCount)) {
      const animate = interactive && scene.dataset.attack !== undefined && data.attackCount > Number(scene.dataset.attack);
      scene.dataset.attack = data.attackCount;
      if (animate) {
        scene.classList.remove("adv-strike");
        void scene.offsetWidth;
        scene.classList.add("adv-strike");
      }
    }
  }

  function updateMap(force = false) {
    const base = root();
    const data = game();
    const scene = base.querySelector(".adv-battle-scene");
    if (!scene) return;
    updateScene(scene, data, true);
    if (!force && latestAttack === data.attackCount) return;
    latestAttack = data.attackCount;
    base.querySelector("[data-adv-stage]").textContent = `第 ${number(data.stage)} 关`;
    base.querySelector("[data-adv-chapter]").textContent = data.monsterChapter;
    base.querySelector(".adv-battle-info").innerHTML = battleInfo(data);
    base.querySelector(".adv-battle-totals").innerHTML = battleTotals(data);
    const report = base.querySelector(".adv-monster-report");
    const reportKey = `${data.stage} ${data.events.map(event => event.id).join(" ")}`;
    if (report.dataset.report !== reportKey) {
      report.dataset.report = reportKey;
      report.innerHTML = monsterReport(data);
    }
  }

  function renderStatus() {
    const area = root().querySelector(".adv-status");
    if (area) { area.textContent = notice; area.hidden = !notice; }
  }

  function stableViewKey(data) {
    const balance = resources();
    if (current === "equipment") return JSON.stringify([data.equipped, data.gear, data.affixes, data.attributes, data.power, balance.stardust]);
    if (current === "technique") return JSON.stringify([data.techniques, data.equippedTechniques, data.powerBreakdown.techniques, balance.insight]);
    if (current === "pets") return JSON.stringify([data.equippedPets, data.pets, data.latestPetHatch, balance.coins]);
    if (current === "lottery") return JSON.stringify([pool, data.pity, data.history, balance.coins, balance.tickets]);
    return JSON.stringify([data.achievements, data.defeated, data.savingDays]);
  }

  window.renderAdventure = () => {
    const data = state?.adventure;
    const base = root();
    if (!base || !data) return;
    const language = state.settings?.language || "system";
    const sameTab = base.dataset.advTab === current && base.dataset.advLanguage === language && base.firstElementChild;
    const focus = base.contains(document.activeElement) ? document.activeElement : null;
    const focusFilter = focus?.dataset.advFilter;
    const selection = focus?.type === "search" ? [focus.selectionStart, focus.selectionEnd] : null;
    const pages = {map: mapPage, equipment: equipmentPage, technique: techniquePage, pets: petsPage, lottery: lotteryPage, achievements: achievementsPage};
    if (!sameTab) {
      base.dataset.advTab = current;
      base.dataset.advLanguage = language;
      base.innerHTML = `<div class="adv-shell"><nav class="adv-segments" aria-label="冒险板块">${tabs.map(([id, zh, en, glyph]) => `<button type="button" data-adv-action="tab" data-id="${id}" aria-current="${id === current ? "page" : "false"}">${symbol(glyph)} ${h(t(zh, en))}</button>`).join("")}</nav>
      <div class="adv-status" role="status" hidden></div><div class="adv-page"></div></div>`;
    }
    const key = current === "map" ? "map" : stableViewKey(data);
    if (!sameTab || renderedKey !== key) {
      base.querySelector(".adv-page").innerHTML = pages[current](data);
      renderedKey = key;
      if (filters[current]) renderCollection();
      if (focusFilter) {
        const replacement = base.querySelector(`[data-adv-filter="${focusFilter}"]`);
        replacement?.focus({preventScroll: true});
        if (replacement && selection) replacement.setSelectionRange(...selection);
      }
    }
    if (current === "map") updateMap(true);
    renderStatus();
  };

  window.refreshAdventure = () => {
    if (!state?.adventure || !root()) return;
    if (current === "map") updateMap();
    else if (!root().querySelector("details[open]") && !dialog?.open && renderedKey !== stableViewKey(game())) window.renderAdventure();
  };

  window.renderAdventureObservation = (container, data) => {
    if (!container || !data) return;
    let scene = container.querySelector(".adv-battle-scene");
    if (!scene) {
      container.classList.add("adv-observation");
      container.innerHTML = battleScene(data, false);
      scene = container.querySelector(".adv-battle-scene");
    }
    updateScene(scene, data, false);
  };

  function setTab(id) {
    if (!tabs.some(tab => tab[0] === id)) return;
    if (current !== id) {
      current = id;
      notice = "";
      selectedMonster = false;
      if (id === "pets") petOrder = [];
      if (id === "lottery") pool = "equipment";
      try { sessionStorage.setItem("gaojixu.adventure.tab", id); } catch (_) {}
      window.renderAdventure();
      window.scrollTo(0, 0);
      root().querySelector(`nav [data-id="${id}"]`)?.focus({preventScroll: true});
    }
  }

  function initDialog() {
    if (dialog) return;
    dialog = document.createElement("dialog");
    dialog.className = "adv-dialog";
    dialog.setAttribute("aria-labelledby", "adv-modal-title");
    document.body.append(dialog);
  }

  function showDialog(title, body, buttons, action = null, className = "") {
    initDialog();
    modalAction = action;
    dialog.className = `adv-dialog ${className}`;
    dialog.innerHTML = `<header class="adv-split"><h2 id="adv-modal-title">${h(title)}</h2>${btn("完成", "close-modal")}</header><div class="adv-dialog-content">${body}</div>${buttons ? `<footer class="adv-actions">${buttons}</footer>` : ""}`;
    if (!dialog.open) dialog.showModal();
  }

  function confirmAction(title, body, label, operation) {
    showDialog(title, `<p>${h(body)}</p>`, btn("取消", "close-modal") + btn(label, "confirm-modal", "", {primary: true}), operation, "adv-confirm");
  }

  async function showGear(id) {
    const {result: item} = await get(`/api/adventure/gear-details?id=${encodeURIComponent(id)}`);
    if (!item || current !== "equipment" || root().hidden) return;
    const data = game();
    const equipped = data.equipped[item.slot] === id;
    const slot = data.slots.find(row => row.id === item.slot)?.name;
    const affixes = item.affixes.length ? `<h3>独特词条</h3>${item.affixes.map(entry => eventRow({title: entry.name, detail: entry.detail, symbol: entry.symbol})).join("")}` : "";
    const body = `<div class="adv-gear-detail ${rarityClass(item.rarity)}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(slot)} · ${rarities[item.rarity]} · ${h(item.setName)} · 强化 +${item.enhancement}</strong><small>${h(item.flavor)}</small></div></div>
      <div class="adv-card-row"><strong>战力 ${number(item.power)}</strong><small>最高 +99 · 后期增幅递增</small><small>${number(resources().stardust)} 星尘</small></div>${attributes(item.attributes)}${affixes}
      <div class="adv-card-row"><small>拥有 ${item.count} 件</small><small>出售单价 ${number(item.sale)} 星尘</small></div></div>`;
    const actions = item.count ? btn(item.enhanceCost ? `强化 +1 · ${number(item.enhanceCost)} 星尘` : "已强化至 +99", "detail-enhance", id,
        {primary: true, disabled: !item.enhanceCost || resources().stardust < item.enhanceCost}) +
      btn(equipped ? "已装备" : "装备", "detail-equip", id, {disabled: equipped}) +
      btn("出售 1 件", "detail-sell", id, {disabled: equipped, count: item.count}) : "";
    showDialog(item.name, body, actions);
  }

  function showReveals(results) {
    if (!results.length || root().hidden) return;
    const title = results.length > 1 ? `${results.length} 抽结果 · 高品质优先` : "获得新收藏";
    const cards = results.map((item, index) => `<article class="adv-panel adv-reveal ${rarityClass(item.rarity)}" style="--reveal-delay:${Math.min(30, 1500 / results.length) * index}ms">
      ${iconTile(item.symbol)}<strong>${h(item.title)}</strong><small>${h(item.detail)}</small><strong>${rarities[item.rarity]}</strong></article>`).join("");
    showDialog(title, `<div class="adv-reveals">${cards}</div>`, btn("收下", "close-modal", "", {primary: true}), null, results.length === 1 ? "adv-single-reveal" : "adv-multi-reveal");
  }

  const request = (route, payload) => api(`/api/adventure/${route}`, payload || {});

  async function sellGroup(id, duplicates) {
    const data = game();
    const rarity = Number(id);
    const equipped = new Set(Object.values(data.equipped));
    const count = data.gear.reduce((total, item) => (duplicates || item.rarity <= rarity)
      ? total + Math.max(0, item.count - Number(duplicates || equipped.has(item.id))) : total, 0);
    const operation = async () => {
      const result = await request("sell-group", duplicates ? {} : {rarity});
      notice = `出售 ${number(result.count)} 件，获得 ${number(result.earned)} 星尘。`;
    };
    if (!count) return operation();
    confirmAction(duplicates ? "清理重复装备？" : "一键出售装备？", duplicates
      ? `每种装备将保留 1 件，其余 ${count} 件会被出售并转化为星尘。此操作不可撤销。`
      : `将出售 ${count} 件${rarities[rarity]}及以下的未装备物品并转化为星尘。此操作不可撤销。`, `出售 ${count} 件`, operation);
  }

  async function forgetGroup(id) {
    const data = game();
    const rarity = Number(id);
    const count = data.techniques.filter(item => item.rarity <= rarity && !data.equippedTechniques.includes(item.id)).length;
    const operation = async () => {
      const result = await request("forget-techniques", {rarity});
      notice = `遗忘 ${number(result.count)} 门技能，返还 ${number(result.earned)} 悟性。`;
    };
    if (!count) return operation();
    confirmAction("一键遗忘技能？", `将遗忘 ${count} 门${rarities[rarity]}及以下的未装配技能，返还基础价值与已投入的参悟悟性；已装配技能会保留。此操作不可撤销。`, `遗忘 ${count} 门技能`, operation);
  }

  const actionHandlers = {
    tab: id => setTab(id),
    actor: () => { selectedMonster = true; updateMap(true); },
    pool: id => { pool = id; window.renderAdventure(); },
    more: () => { filters[current].shown += 60; renderCollection(); },
    "reload-catalog": () => renderCollection(),
    "close-modal": () => dialog.close(),
    "confirm-modal": async () => { await modalAction?.(); dialog.close(); },
    detail: id => showGear(id),
    "detail-enhance": async id => { await request("enhance", {id}); await showGear(id); },
    "detail-equip": async id => { await request("equip", {id}); await showGear(id); },
    "detail-sell": async (id, count) => {
      const receipt = await request("sell", {id, count: 1});
      notice = `出售成功，获得 ${number(receipt.earned)} 星尘。`;
      if (count <= 1) dialog.close(); else await showGear(id);
    },
    "request-sale": id => sellGroup(id, false),
    "request-duplicates": () => sellGroup("", true),
    "request-forget": id => forgetGroup(id),
    "request-hatch": () => confirmAction("孵化一枚宠物蛋？", `将立即扣除 10,000 金币（当前持有 ${number(resources().coins)}），随机孵化十二种伙伴之一；重复宠物自动升星。`, "消耗 10,000 金币并孵化", () => request("hatch")),
    draw: async id => { const result = await request("draw", {count: Number(id), pool}); showReveals(result.reveals); },
    exchange: id => request("exchange", {resource: id}),
    unequip: slot => request("unequip", {slot}),
    "equip-best": async () => { const result = await request("equip-best"); notice = `已按初始战力选择 ${result.count} 个部位。`; },
    "technique-best": async () => { const result = await request("technique-best"); notice = `已按 1 重初始战力装配 ${result.count} 门技能。`; },
    "pet-best": async () => { const result = await request("pet-best"); notice = `已按当前战力选择 ${result.count} 只宠物。`; },
    sell: async (id, count) => { const receipt = await request("sell", {id, count}); notice = `出售成功，获得 ${number(receipt.earned)} 星尘。`; },
  };
  const directActions = new Set(["equip", "technique", "unequip-technique", "upgrade-technique", "pet", "unequip-pet"]);

  document.addEventListener("click", async event => {
    const control = event.target.closest("[data-adv-action]");
    if (!control || (!root()?.contains(control) && !dialog?.contains(control))) {
      if (selectedMonster && event.target.closest("[data-adv-click-clear]")) { selectedMonster = false; updateMap(true); }
      return;
    }
    const action = control.dataset.advAction;
    if (busy) return;
    const id = control.dataset.id;
    if (!actionHandlers[action] && !directActions.has(action)) return;
    control.closest("details")?.removeAttribute("open");
    notice = "";
    busy = true;
    try {
      if (actionHandlers[action]) await actionHandlers[action](id, Number(control.dataset.count) || 1);
      else await request(action, {id});
    } catch (error) {
      if (dialog?.open) showError(error);
      else notice = error.message;
    } finally {
      busy = false;
      renderStatus();
    }
  });

  document.addEventListener("input", event => {
    const control = event.target;
    const key = control.dataset.advFilter;
    if (!key || !root()?.contains(control) || !filters[current]) return;
    filters[current][key] = control.type === "checkbox" ? control.checked : control.value;
    filters[current].shown = 60;
    renderCollection();
  });
})();
