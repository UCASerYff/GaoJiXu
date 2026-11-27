(() => {
  "use strict";

  const h = escapeHTML;
  const localized = (row,key) => t(row?.[key],row?.english?.[key]);
  const actionErrors = new Map([
    ["冒险存档缺失，已停止写入。","Adventure data is unavailable."],
    ["星券不足。每积蓄 1 个货币单位获得 1 张星券，也可使用金币兑换。","You need more tickets. Earn them from savings or exchange gold."],
    ["背包里没有这件装备。","This item is absent from your inventory."],
    ["背包中没有这件装备。","This item is absent from your inventory."],
    ["背包里还没有可以装备的物品。","You have no equipment to equip."],
    ["已装备的物品不能出售，请先卸下。","Unequip the item before selling it."],
    ["没有可清理的重复装备；每种装备会保留 1 件。","There are no duplicate items to sell. One of each item is kept."],
    ["需要先获得这门技能。","Learn this technique first."],
    ["还没有已学技能可以装配。","You have no learned techniques to equip."],
    ["需要先孵化这只宠物。","Hatch this pet first."],
    ["宠物背包里还没有伙伴。","Your pet inventory is empty."],
  ]);
  const errorEnglishPatterns = [
    [/^金币不足，.*?([0-9]+) 金币。$/, value=>`You need ${value} gold.`],
    [/^星尘不足，本次强化需要 (\d+) 星尘。$/, value=>`Enhancement requires ${value} stardust.`],
    [/^悟性不足，本次参悟需要 (\d+) 点。$/, value=>`Training requires ${value} insight.`],
    [/^最多同时装配 (\d+) 门技能，请先卸下一门。$/, value=>`You can equip up to ${value} techniques. Remove one first.`],
    [/^最多同时上阵 (\d+) 只宠物。$/, value=>`Your party can hold up to ${value} pets.`],
    [/^没有可出售的(\d+)及以下未装备物品。$/, value=>`No unequipped ${rarityName(value)} or lower items can be sold.`],
    [/^没有可遗忘的(\d+)及以下未装配技能。$/, value=>`No unequipped ${rarityName(value)} or lower techniques can be forgotten.`],
  ];
  function localizedError(error) {
    const message = error.message || String(error);
    if (t("zh","en") === "zh") return message;
    if (actionErrors.has(message)) return actionErrors.get(message);
    for (const [expression,format] of errorEnglishPatterns) {
      const match = expression.exec(message);
      if (match) return format(match[1]);
    }
    return error.english || message;
  }
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
  const rarities = [["",""],["普通","Common"],["精良","Fine"],["稀有","Rare"],["史诗","Epic"],["传说","Legendary"],["神话","Mythic"],["绝世","Peerless"]];
  const rarityName = value => t(...(rarities[value] || rarities[0]));
  const guarantees = [["rare", 3, 10], ["epic", 4, 30], ["legendary", 5, 150], ["mythic", 6, 500], ["peerless", 7, 2000]];
  const stageNames = [["幼年体","Juvenile"],["成年体","Adult"],["完全体","Full Form"]];
  const stageName = value => t(...stageNames[value]);
  const camp = [
    ["equipment", "锻造营", "Forge Camp", 0], ["technique", "研修塔", "Study Tower", 1],
    ["pets", "灵宠营", "Pet Stable", 2], ["lottery", "祈愿坛", "Wishing Altar", 3],
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
  const eventRow = event => `<div class="adv-event ${event.rarity ? rarityClass(event.rarity) : ""}">${iconTile(event.symbol)}<div><strong>${h(localized(event,"title"))}</strong><small>${h(localized(event,"detail"))}</small></div>${event.rarity ? `<span class="adv-event-rarity">${rarityName(event.rarity)}</span>` : ""}</div>`;
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
    return actor(t(`勇者 Lv.${data.level}`, `Hero Lv.${data.level}`), `<img src="${asset("AdventureHeroV353")}" alt="">`, "adv-hero") +
      actor(localized(data,"monster"), monsterSprite(data.monsterSprite), `adv-monster${interactive && selectedMonster ? " selected" : ""}`,
        interactive ? "actor" : "", "monster") +
      petActors.map((pet, index) => actor("", petSprite(pet, pet.stars >= 4 ? 2 : Math.min(1, pet.stage)), "adv-battle-pet", "", "",
        `aria-label="${h(localized(pet,"name"))}" style="--pet-x:${33 + (index - (petActors.length - 1) / 2) * 9}%"`)).join("");
  }

  function battleScene(data, interactive) {
    return `<div class="adv-world adv-battle-scene" aria-label="${interactive ? t("战斗场景", "Battle Scene") : t("自动冒险", "Automatic Adventure")}"${interactive ? ' data-adv-click-clear' : ""}>${battleActors(data, interactive)}</div>`;
  }

  function battleInfo(data) {
    return `<div class="adv-health"><div class="adv-tone-green"><div><strong>${t("勇者", "Hero")}</strong><span>${number(data.heroHP)} / ${number(data.heroMaxHP)}</span></div>${progress(t("勇者生命", "Hero Health"), data.heroHP, data.heroMaxHP)}</div>
      <div class="adv-tone-red"><div><strong>${t("怪物", "Enemy")}</strong><span>${number(data.monsterHP)} / ${number(data.monsterMaxHP)}</span></div>${progress(t("怪物生命", "Enemy Health"), data.monsterHP, data.monsterMaxHP)}</div></div>
      <div class="adv-split adv-power"><strong>${t(`勇者战力 ${number(data.power)}`, `Hero power ${number(data.power)}`)}</strong><strong>${t(`敌方战力 ${number(data.monsterPower)}`, `Enemy power ${number(data.monsterPower)}`)}</strong></div>
      <small class="adv-battle-msg">${h(selectedMonster ? `${localized(data,"monsterTrait")} · ${localized(data,"monsterTraitDetail")}` : localized(data,"message"))}</small>`;
  }

  function campScene() {
    const width = 1254;
    const height = 1254;
    const dividerX = Math.round(width * .572);
    const dividerY = Math.round(height * .508);
    return `<div class="adv-world adv-camp-scene">${camp.map(([key, zh, en, index]) => {
      const x = index % 2 ? dividerX : 0;
      const y = index >= 2 ? dividerY : 0;
      const artwork = atlas("AdventureBuildingsV353", width, height, x, y, x ? width - x : dividerX, y ? height - y : dividerY);
      return actor(t(zh,en), artwork, `adv-camp-building adv-building-${index}`, "tab", key);
    }).join("")}</div>`;
  }

  function battleTotals(data) {
    return [stat(t("勇者等级", "Hero Level"), `Lv.${data.level}`, "bolt.fill", "green"), stat(t("当前关卡", "Current Stage"), number(data.stage), "flag.checkered", "red"),
      stat(t("本关重开", "Stage Retries"), number(data.attempts), "arrow.counterclockwise", "purple"), stat(t("累计过关", "Stages Cleared"), number(data.defeated), "forward.fill", "orange")].join("");
  }

  function monsterReport(data) {
    return `<div class="adv-split"><h3>${t("当前怪物", "Current Enemy")}</h3><div class="adv-trait"><strong>${h(localized(data,"monsterTrait"))}</strong><small>${h(localized(data,"monsterTraitDetail"))}</small></div></div>
      <small>${h(localized(data,"monsterChapter"))} · ${t(`第 ${number(data.stage)} 关`, `Stage ${number(data.stage)}`)}</small><hr><h3>${t("最近战报", "Recent Battle Reports")}</h3>${data.events.map(eventRow).join("")}`;
  }

  function mapPage(data) {
    const rules = [
      [t("持续自动打", "Continuous Attacks"), t("应用运行时每秒攻击，不需要点击或等待攒钱触发", "The hero attacks each second while the app runs."), "forward.fill"],
      [t("过关就前进", "Advance on Victory"), t("十种怪物循环登场，关卡没有上限且强度单调提升", "Ten enemies rotate through unlimited stages of increasing difficulty."), "flag.checkered"],
      [t("失败原关重开", "Retry on Defeat"), t("双方恢复生命，继续挑战同一关，直到角色足够强", "Both sides recover and retry the same stage."), "arrow.counterclockwise"],
      [t("击杀结算奖励", "Victory Rewards"), t("金币、悟性和经验只在击杀后结算，并有概率掉落装备或技能", "Defeat enemies to earn gold, insight, experience, and a chance at loot."), "burst.fill"],
      [t("积蓄兑换星券", "Save to Earn Tickets"), t("每积蓄 1 个货币单位获得 1 张星券，完成目标额外获得 100 张", "Earn 1 ticket per currency unit saved and 100 extra for completing a goal."), "arrow.down.circle.fill"],
      [t("词条与绝技", "Modifiers and Signatures"), t("装备词条和技能绝技会真实改变攻防、回复与奖励", "Equipment modifiers and signature moves affect damage, defense, healing, and rewards."), "sparkles"],
    ];
    return `<article class="adv-panel adv-battle"><div class="adv-split adv-world-title"><div><strong>${symbol("flag.checkered")} <span data-adv-stage>${t(`第 ${number(data.stage)} 关`, `Stage ${number(data.stage)}`)}</span></strong><small data-adv-chapter>${h(localized(data,"monsterChapter"))}</small></div><small class="adv-tone-green">${symbol("forward.fill")} ${t("每秒自动攻击", "Auto-attacks every second")}</small></div>
      ${battleScene(data, true)}<div class="adv-battle-info">${battleInfo(data)}</div></article>
      <article class="adv-panel adv-camp"><div class="adv-split adv-world-title"><strong>${symbol("tent.fill")} ${t("远征营地", "Expedition Camp")}</strong><small>${t("点击建筑进入装备、技能、宠物或祈愿", "Select a building for Equipment, Techniques, Pets, or Wishes")}</small></div>${campScene()}</article>
      <div class="adv-stats adv-battle-totals">${battleTotals(data)}</div>
      <div class="adv-columns"><article class="adv-panel"><h3>${t("无限自动战斗规则", "Automatic Battles")}</h3>${rules.map(([title, detail, glyph]) => eventRow({title, detail, symbol: glyph})).join("")}</article>
      <article class="adv-panel adv-monster-report">${monsterReport(data)}</article></div>`;
  }

  function selectFilter(key, label, options, currentValue) {
    return `<select aria-label="${h(label)}" data-adv-filter="${key}">${options.map(([id, text]) => `<option value="${h(id)}"${String(id) === currentValue ? " selected" : ""}>${h(text)}</option>`).join("")}</select>`;
  }

  function filterBar(data, kind) {
    const config = filters[kind];
    const gear = kind === "equipment";
    const fields = gear
      ? selectFilter("slot", t("部位", "Slot"), [["", t("全部部位", "All Slots")], ...data.slots.map(item => [item.id, localized(item,"name")])], config.slot) +
        selectFilter("rarity", t("品质", "Rarity"), [["", t("全部品质", "All Rarities")], ...rarities.slice(1).map((label, index) => [index + 1, t(...label)])], config.rarity)
      : selectFilter("school", t("流派", "School"), [["", t("全部流派", "All Schools")], ...data.schools.map(item => [item, t(item,data.schoolsEnglish?.[item])])], config.school) +
        selectFilter("effect", t("效果", "Effect"), [["", t("全部效果", "All Effects")], ...Object.entries(t(data.effects,data.effectsEnglish))], config.effect);
    const placeholder = gear ? t("搜索装备或套装", "Search equipment or sets") : t("搜索名称、流派或文化", "Search techniques, schools, or traditions");
    return `<div class="adv-filter"><label class="adv-search">${icon("magnifyingglass")}<input type="search" aria-label="${placeholder}" placeholder="${placeholder}" data-adv-filter="search" value="${h(config.search)}"></label>
      ${fields}<label class="adv-check"><input type="checkbox" data-adv-filter="owned"${config.owned ? " checked" : ""}>${gear ? t("只看已拥有", "Owned Only") : t("只看已学", "Learned Only")}</label>
      <small>${gear ? t("已装备优先 · 品质与战力降序", "Equipped first, then rarity and power") : t("已装配优先 · 品质降序", "Equipped first, then rarity")}</small><small class="adv-result-count" aria-live="polite"></small></div>`;
  }

  function rarityMenu(title, action, equipment) {
    return menu(title, rarities.slice(1,6).map(([zh,en],index) => {
      const verb = equipment ? "出售" : "遗忘";
      const verbEnglish = equipment ? "Sell" : "Forget";
      const type = equipment ? "装备" : "技能";
      const typeEnglish = equipment ? "equipment" : "techniques";
      const label = index === 0 ? t(`${verb}所有普通${type}`, `${verbEnglish} all common ${typeEnglish}`)
        : t(`${verb}${zh}及以下`, `${verbEnglish} ${en.toLowerCase()} or lower`);
      return btn(label,action,index+1);
    }));
  }

  function attributes(rows) {
    return `<div class="adv-attributes">${rows.map(item => `<div>${symbol(item.symbol)}<span><strong>${typeof item.value === "number" ? number(item.value) : h(item.value)}</strong><small>${h(localized(item,"name"))}</small></span></div>`).join("")}</div>`;
  }

  function equipmentPage(data) {
    const breakdown = data.powerBreakdown;
    const gear = Object.fromEntries(data.gear.map(item => [item.id, item]));
    return `<article class="adv-panel"><div class="adv-split adv-character-heading"><h3>${t("角色 15 维战斗属性", "15 Combat Attributes")}</h3><div><strong>${t(`总战力 ${number(data.power)}`, `Total Power ${number(data.power)}`)}</strong><small>${t(`基础 ${number(breakdown.base)} · 装备 ${number(breakdown.equipment)} · 技能 ${number(breakdown.techniques)} · 宠物 ${number(breakdown.pets)}`, `Base ${number(breakdown.base)} · Equipment ${number(breakdown.equipment)} · Techniques ${number(breakdown.techniques)} · Pets ${number(breakdown.pets)}`)}</small></div></div>
      ${attributes(data.attributes)}${data.affixes.length ? `<h4>${t("生效词条", "Active Modifiers")}</h4><div class="adv-affix-list">${data.affixes.map(item => `<span title="${h(localized(item,"detail"))}">${symbol(item.symbol)} ${h(localized(item,"name"))} · ${h(localized(item,"detail"))}</span>`).join("")}</div>` : ""}</article>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><h3>${t("角色装备 · 14 个部位", "Equipment · 14 Slots")}</h3><div class="adv-actions"><span class="adv-tone-purple">${symbol("sparkles")} ${t(`${number(resources().stardust)} 星尘`, `${number(resources().stardust)} stardust`)}</span>
      ${btn(t("一键装备", "Auto-equip"), "equip-best", "", {primary: true})}${btn(t("清理重复装备", "Sell Duplicates"), "request-duplicates")}${rarityMenu(t("一键出售", "Bulk Sell"), "request-sale", true)}</div></div>
      <small>${t("一键装备按未强化初始战力比较 · 点击装备格可卸下", "Auto-equip compares base power. Select an equipped slot to remove its item.")}</small>
      <div class="adv-slots">${data.slots.map(slot => loadoutSlot(localized(slot,"name"), gear[data.equipped[slot.id]], slot.symbol, t("空", "Empty"), "unequip", slot.id, true)).join("")}</div></article>
      ${filterBar(data, "equipment")}<div data-adv-collection></div>`;
  }

  function loadoutSlot(label, item, glyph, empty, action, id, gear = false) {
    const name = item ? localized(item,"name") : empty;
    const detail = gear && item ? `<small>+${item.enhancement} · ${t("战力","Power")} ${number(item.power)}</small>` : "";
    return `<button type="button" class="adv-slot ${item ? rarityClass(item.rarity) : ""}" data-adv-action="${action}" data-id="${h(id)}"${item ? "" : " disabled"}>${iconTile(item?.symbol || glyph)}<span><small>${h(label)}</small><strong>${h(name)}</strong>${detail}</span></button>`;
  }

  function gearCard(item, data) {
    const equipped = data.equipped[item.slot] === item.id;
    const slot = localized(data.slots.find(row => row.id === item.slot),"name");
    return `<article class="adv-panel adv-catalog-card ${rarityClass(item.rarity)} ${item.count ? "" : "adv-locked"}" title="${h(`${localized(item,"setName")}: ${localized(item,"flavor")}`)}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(item.count ? localized(item,"name") : t("未发现装备", "Undiscovered Item"))}</strong><small>${h(slot)} · ${rarityName(item.rarity)} · +${item.enhancement}</small></div>${item.count ? `<small>×${number(item.count)}</small>` : ""}</div>
      <div class="adv-card-row"><strong>${symbol("bolt.shield.fill")} ${t(`战力 ${number(item.power)}`, `Power ${number(item.power)}`)}</strong><div class="adv-actions">${btn(t("详情", "Details"), "detail", item.id, {plain: true})}${item.count ? btn(equipped ? t("已装备", "Equipped") : t("装备", "Equip"), "equip", item.id, {disabled: equipped}) : ""}
      ${item.count && !equipped ? menu(t("出售", "Sell"), [btn(t(`出售 1 件 · +${number(item.sale)} 星尘`, `Sell one · +${number(item.sale)} stardust`), "sell", item.id, {count: 1}), ...(item.count > 1 ? [btn(t(`出售全部 ${number(item.count)} 件`, `Sell all ${number(item.count)}`), "sell", item.id, {count: item.count})] : [])]) : ""}</div></div>
      ${item.count && !equipped ? `<small>${t(`出售可得 ${number(item.sale)} 星尘`, `Sells for ${number(item.sale)} stardust`)}</small>` : ""}</article>`;
  }

  function techniquePage(data) {
    const learned = Object.fromEntries(data.techniques.map(item => [item.id, item]));
    return `<div class="adv-stats">${stat(t("可用悟性", "Available Insight"), number(resources().insight), "lightbulb.fill", "purple")}${stat(t("已学 / 总技能", "Learned / Total"), `${data.techniques.length}/${data.techniqueCount}`, "scroll.fill", "orange")}${stat(t("装配技能战力", "Technique Power"), number(data.powerBreakdown.techniques), "bolt.shield.fill", "red")}${stat(t("已装配流派", "Equipped Techniques"), `${data.equippedTechniques.length}/12`, "square.grid.2x2.fill", "green")}</div>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><h3>${t("当前构筑 · 最多 12 门", "Build · Up to 12 Techniques")}</h3><div class="adv-actions">${btn(t("一键装配", "Auto-equip"), "technique-best", "", {primary: true})}${rarityMenu(t("一键遗忘", "Bulk Forget"), "request-forget", false)}</div></div>
      <small>${t("按 1 重初始战力选择 · 只有装配的技能会生效", "Auto-equip compares rank 1 power. Only equipped techniques are active.")}</small><div class="adv-slots">${Array.from({length: 12}, (_, index) => {
        const id = data.equippedTechniques[index] || "";
        return loadoutSlot(t(`第 ${index + 1} 格`, `Slot ${index + 1}`), learned[id], "plus", t("空技能位", "Empty Slot"), "unequip-technique", id);
      }).join("")}</div></article>${filterBar(data, "technique")}<div data-adv-collection></div>`;
  }

  function techniqueCard(item, data) {
    const equipped = data.equippedTechniques.includes(item.id);
    return `<article class="adv-panel adv-catalog-card ${rarityClass(item.rarity)} ${item.level ? "" : "adv-locked"}" title="${h(localized(item,"description"))}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(item.level ? localized(item,"name") : t("未悟得技能", "Unlearned Technique"))}</strong><small>${h(localized(item,"culture"))} · ${h(localized(item,"school"))} · ${rarityName(item.rarity)}</small></div>${item.level ? `<small>${t(`${item.level} 重`, `Rank ${item.level}`)}</small>` : ""}</div>
      <div class="adv-card-row"><small>${h(localized(item,"effectDisplay"))}</small><strong>${symbol("bolt.fill")} ${t(`战力 ${number(item.power)}`, `Power ${number(item.power)}`)}</strong>${item.level ? btn(equipped ? t("卸下", "Unequip") : t("装配", "Equip"), equipped ? "unequip-technique" : "technique", item.id) : ""}</div>
      <small>${symbol(item.signature.symbol)} ${t("绝技","Signature")}: ${h(localized(item.signature,"name"))} · ${h(localized(item.signature,"detail"))}</small>
      ${item.level ? `<div class="adv-card-row"><small>${t("最高 99 重 · 后期增幅递增", "Rank cap 99. Later ranks boost power faster.")}</small>${btn(item.upgradeCost ? t(`参悟 ${number(item.upgradeCost)}`, `Train · ${number(item.upgradeCost)} insight`) : t("已满级", "Max Rank"), "upgrade-technique", item.id, {primary: true, disabled: !item.upgradeCost || resources().insight < item.upgradeCost})}</div>` : ""}</article>`;
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
      target.innerHTML = `<div class="adv-panel adv-empty" role="status">${t("正在读取图鉴…", "Loading collection…")}</div>`;
      if (!pendingCatalogs[kind]) {
        pendingCatalogs[kind] = get(`/api/adventure/catalog?kind=${kind}`).then(response => {
          catalogs[kind] = response.result;
          if (current === kind) renderCollection();
        }).catch(error => {
          if (current === kind) target.innerHTML = `<div class="adv-panel adv-empty">${h(localizedError(error))}${btn(t("重新载入", "Reload"), "reload-catalog")}</div>`;
        }).finally(() => delete pendingCatalogs[kind]);
      }
      return;
    }
    const ownedById = Object.fromEntries(owned.map(item => [item.id, item]));
    const source = config.owned ? owned : catalogs[kind].map(item => ownedById[item.id] || (gear ? {...item, count: 0, enhancement: 0} : {...item, level: 0}));
    const query = config.search.trim().toLowerCase();
    const matches = source.filter(item => {
      const searchKeys = gear ? ["name","setName"] : ["name","school","culture"];
      const searchable = searchKeys.flatMap(key => [item[key],item.english?.[key] || ""]);
      const combined = !query || searchable.some(value => value.toLowerCase().includes(query));
      return combined && (gear ? (!config.slot || item.slot === config.slot) && (!config.rarity || item.rarity === Number(config.rarity))
        : (!config.school || item.school === config.school) && (!config.effect || item.effect === config.effect));
    }).sort((a, b) => Number(equipped.has(b.id)) - Number(equipped.has(a.id)) || b.rarity - a.rarity ||
      (gear ? b.power - a.power : b.level - a.level) || localized(a,"name").localeCompare(localized(b,"name"), t("zh-CN","en-US")));
    count.textContent = `${matches.length} / ${total}`;
    if (!matches.length) {
      const title = config.owned ? (gear ? t("当前筛选下还没有装备", "No owned equipment matches") : t("当前筛选下还没有已学技能", "No learned techniques match")) : (gear ? t("没有匹配装备", "No matching equipment") : t("没有匹配技能", "No matching techniques"));
      target.innerHTML = `<div class="adv-panel adv-empty">${iconTile(gear ? "shippingbox.fill" : "books.vertical.fill")}<strong>${title}</strong><small>${gear ? t("使用免费星券可获得装备；关闭‘只看已拥有’可浏览完整图鉴。", "Spend free tickets to find equipment. Turn off Owned Only to browse the full collection.") : t(`关闭‘只看已学’可浏览 ${total} 门原创技能图鉴。`, `Turn off Learned Only to browse all ${total} original techniques.`)}</small></div>`;
      return;
    }
    const more = matches.length > config.shown ? `<div class="adv-collection-more">${btn(t(`显示更多 · ${matches.length - config.shown} 件`, `Show more · ${matches.length - config.shown}`), "more")}</div>` : "";
    target.innerHTML = `<div class="adv-card-grid">${matches.slice(0, config.shown).map(item => gear ? gearCard(item, data) : techniqueCard(item, data)).join("")}</div>${more}`;
  }

  function petsPage(data) {
    const team = data.equippedPets;
    const pets = Object.fromEntries(data.petCatalog.map(item => [item.id, item]));
    if (ownedPetsAtSort !== data.pets.length || !petOrder.length) {
      petOrder = [...data.petCatalog].sort((a, b) => Number(b.stars > 0) - Number(a.stars > 0) ||
        Number(team.includes(b.id)) - Number(team.includes(a.id)) || b.power - a.power || localized(a,"name").localeCompare(localized(b,"name"), t("zh-CN","en-US"))).map(item => item.id);
      ownedPetsAtSort = data.pets.length;
    }
    const hatch = data.latestPetHatch;
    return `<div class="adv-stats">${stat(t("可用金币", "Available Gold"), number(resources().coins), "dollarsign.circle.fill", "orange")}${stat(t("宠物图鉴", "Pet Collection"), `${data.pets.length} / ${data.petCatalog.length}`, "pawprint.fill", "teal")}${stat(t("上阵宠物", "Active Pets"), `${team.length} / 4`, "person.3.fill", "blue")}${stat(t("宠物总战力", "Total Pet Power"), number(data.powerBreakdown.pets), "bolt.shield.fill", "red")}</div>
      <article class="adv-panel adv-pet-hatch"><div><h3>${symbol("circle.hexagongrid.fill")} ${t("宠物蛋孵化", "Hatch a Pet Egg")}</h3><p>${t("每枚宠物蛋消耗 10,000 金币，十二种伙伴等概率出现。", "Each egg costs 10,000 gold. All 12 companions are equally likely.")}</p><small>${t("重复宠物自动升星：1 星幼年体、2 星成年体、3–99 星完全体；99 星后再重复转化为 10,000 金币。", "Duplicates increase stars: 1 Juvenile, 2 Adult, 3–99 Full Form. At 99 stars, duplicates convert to 10,000 gold.")}</small></div>
      ${hatch && pets[hatch.petID] ? `<div class="adv-latest-pet">${petSprite(pets[hatch.petID])}<div><small>${t("最新孵化", "Last Hatch")}</small><strong>${h(localized(hatch,"name"))}</strong><small>${h(localized(hatch,"result"))}</small></div></div>` : ""}
      ${btn(t("孵化一枚", "Hatch an Egg"), "request-hatch", "", {primary: true, icon: "sparkles", disabled: resources().coins < 10000})}</article>
      <article class="adv-panel"><div class="adv-split adv-slot-header"><div><h3>${t("出战队伍 · 最多 4 只", "Party · Up to 4 Pets")}</h3><small>${t("宠物属性和战力直接计入角色总战力。", "Pet stats and power contribute directly to your hero’s total.")}</small></div>${btn(t("一键上阵", "Auto-select Party"), "pet-best", "", {primary: true})}</div>
      <div class="adv-team">${Array.from({length: 4}, (_, index) => {
        const pet = pets[team[index]];
        return pet ? `<button type="button" class="adv-pet-slot" data-adv-action="unequip-pet" data-id="${h(pet.id)}">${petSprite(pet)}<span><strong>${h(localized(pet,"name"))}</strong><small>★${pet.stars} · ${number(pet.power)}</small><small>${t("点击下阵", "Select to remove")}</small></span></button>`
          : `<div class="adv-pet-slot adv-pet-empty">${symbol("plus.circle.dashed")} <small>${t(`宠物位 ${index + 1}`, `Pet slot ${index + 1}`)}</small></div>`;
      }).join("")}</div></article>
      <div class="adv-split adv-pet-catalog-heading"><h3>${t("宠物背包与图鉴", "Pets and Collection")}</h3><small>${t("已拥有和已上阵优先显示 · 每升 1 星，战力增幅都会提高", "Owned and active pets appear first. Power increases with each star.")}</small></div>
      <div class="adv-card-grid adv-pet-grid">${petOrder.map(id => {
        const pet = pets[id];
        const equipped = team.includes(pet.id);
        return `<article class="adv-panel adv-pet-card ${pet.stars ? "" : "adv-locked"}">${petSprite(pet)}<div><strong>${h(localized(pet,"name"))} ${equipped ? `<span class="adv-badge">${t("上阵", "In Party")}</span>` : ""}</strong>
          <small>${pet.stars ? t(`${pet.stars} 星 · ${stageName(pet.stage)}`, `${pet.stars} ★ · ${stageName(pet.stage)}`) : t("未解锁", "Locked")} · ${h(localized(pet,"role"))}</small><strong class="adv-tone-red">${symbol("bolt.shield.fill")} ${t(`战力 ${number(pet.power)}`, `Power ${number(pet.power)}`)}</strong><small>${h(localized(pet,"flavor"))}</small></div>
          ${pet.stars ? btn(equipped ? t("下阵", "Remove") : t("上阵", "Add"), equipped ? "unequip-pet" : "pet", pet.id) : ""}</article>`;
      }).join("")}</div>`;
  }

  function pity(data) {
    return `<div class="adv-pity"><div>${guarantees.map(([key, rarity, limit]) => {
      const value = data.pity[pool][key];
      return `<div class="${rarityClass(rarity)}"><div class="adv-split"><strong>${rarityName(rarity)}</strong><small>${t(`差 ${number(limit - value)} 抽`, `${number(limit - value)} left`)}</small></div>${progress(t(`${rarityName(rarity)}保底`, `${rarityName(rarity)} guarantee`), value, limit)}<small>${number(value)} / ${number(limit)}</small></div>`;
    }).join("")}</div><small>${t("抽到该品质或更高时，会重置该档及更低档计数；更高档进度继续保留。", "A draw at or above a tier resets that tier and lower tiers. Higher tiers keep their progress.")}</small></div>`;
  }

  function lotteryPage(data) {
    const label = pool === "equipment" ? t("装备","Equipment") : t("技能","Technique");
    const balance = resources();
    const rates = ["", t("其余", "Remaining"), "32%", "14%", "5%", "1%", "0.01%", "0.0001%"];
    return `<article class="adv-panel adv-lottery">${iconTile("gift.fill", "adv-lottery-icon")}<h2>${t("积蓄祈愿", "Savings Wishes")}</h2>
      <p>${t("装备池和技能池相互独立。每积蓄 1 个货币单位获得 1 张星券，完成目标额外获得 100 张，也可用击杀所得金币购买。", "Equipment and technique pools are independent. Earn 1 ticket per currency unit saved and 100 more for completing a goal. You can also exchange battle gold for tickets.")}</p>
      <div class="adv-segments adv-pool" aria-label="${t("祈愿池","Wish Pools")}">${[["equipment", t("装备池","Equipment Pool"), "shield.fill"], ["technique", t("技能池","Technique Pool"), "books.vertical.fill"]].map(([key, text, glyph]) => `<button type="button" data-adv-action="pool" data-id="${key}" aria-pressed="${key === pool}">${symbol(glyph)} ${text}</button>`).join("")}</div>
      <div class="adv-actions adv-wish-actions">${btn(t(`${label}单抽 · 1 星券`, `${label}: 1 draw · 1 ticket`), "draw", 1, {primary: true, icon: "gift.fill", disabled: balance.tickets < 1})}
      ${btn(t(`${label}十连 · 10 星券`, `${label}: 10 draws · 10 tickets`), "draw", 10, {icon: "sparkles", disabled: balance.tickets < 10})}${btn(t(`${label}百连 · 100 星券`, `${label}: 100 draws · 100 tickets`), "draw", 100, {icon: "square.grid.2x2.fill", disabled: balance.tickets < 100})}
      ${balance.coins >= 500 ? menu(t("金币商店", "Gold Shop"), [btn(t("500 金币 → 1 星券", "500 gold → 1 ticket"), "exchange", "tickets"), btn(t("500 金币 → 50 悟性", "500 gold → 50 insight"), "exchange", "insight"), btn(t("500 金币 → 50 星尘", "500 gold → 50 stardust"), "exchange", "stardust")]) : btn(t("金币商店", "Gold Shop"), "exchange", "", {icon: "cart.fill", disabled: true})}</div>
      <div class="adv-actions adv-wish-totals"><strong class="adv-tone-orange">${symbol("ticket.fill")} ${t(`持有 ${number(balance.tickets)} 张`, `${number(balance.tickets)} tickets`)}</strong><strong class="adv-tone-blue">${symbol("dollarsign.circle.fill")} ${t(`${number(balance.coins)} 金币`, `${number(balance.coins)} gold`)}</strong><strong class="adv-tone-purple">${symbol("shield.fill")} ${t(`${label}池独立累计`, `Separate ${label.toLowerCase()} counter`)}</strong></div>
      ${pity(data)}</article>
      <div class="adv-columns"><article class="adv-panel adv-drop-rules"><h3>${t("掉落说明", "Drop Rates")}</h3>${[7, 6, 5, 4, 3, 2, 1].map(item => `<div class="adv-drop ${rarityClass(item)}"><strong><i></i>${rarityName(item)}</strong><small>${rarityName(item)} ${label}</small><b>${rates[item]}</b></div>`).join("")}
      <small>${pool === "equipment" ? t("装备池只产出装备；重复装备自动转化为星尘。","Equipment duplicates convert to stardust.") : t("技能池只产出技能；重复技能按品质自动转化为悟性。","Technique duplicates convert to insight based on rarity.")} ${t("五档保底分别独立累计。","All five guarantee tiers track draws separately.")}</small><small>${t("单抽、十连与百连结果均按品质从高到低排列。", "Single, 10-draw, and 100-draw results are sorted by rarity.")}</small></article>
      <article class="adv-panel"><h3>${t("最近获得", "Recent Rewards")}</h3>${data.history.length ? data.history.map(eventRow).join("") : `<p class="adv-empty">${t("还没有抽取记录。", "No draw history yet.")}</p>`}</article></div>`;
  }

  function achievementsPage(data) {
    return `<div class="adv-stats adv-achievement-stats">${stat(t("已解锁成就", "Unlocked Achievements"), `${data.achievements.filter(item => item.unlocked).length}/${data.achievements.length}`, "trophy.fill", "orange")}${stat(t("留下足迹的天数", "Days Saved"), number(data.savingDays), "calendar", "teal")}${stat(t("冒险胜利次数", "Adventure Wins"), number(data.defeated), "burst.fill", "green")}</div>
      <div class="adv-card-grid adv-achievement-grid">${data.achievements.map(item => `<article class="adv-panel adv-achievement adv-tone-${item.color} ${item.unlocked ? "" : "adv-locked"}">
      ${iconTile(item.unlocked ? item.symbol : "lock.fill")}<h3>${h(item.unlocked ? localized(item,"title") : t("尚未解锁", "Locked"))}</h3><small>${h(localized(item,"detail"))}</small>
      ${item.unlocked ? `<strong>${symbol("checkmark.seal.fill")} ${t("已获得", "Unlocked")}</strong>` : `<div class="adv-achievement-progress">${progress(localized(item,"detail"), item.current, item.total)}<small>${item.current}/${item.total}</small></div>`}</article>`).join("")}</div>`;
  }

  function sceneKey(data, interactive) {
    return JSON.stringify([t("zh","en"), data.level, data.monster, data.monsterSprite, data.equippedPets.map(id => [id, data.petCatalog.find(pet => pet.id === id)?.stars]), interactive && selectedMonster]);
  }

  function updateScene(scene, data, interactive) {
    if (!scene) return;
    const key = sceneKey(data, interactive);
    if (scene.dataset.scenery !== key) {
      const focused = document.activeElement?.matches("[data-adv-action=actor]") && scene.contains(document.activeElement);
      scene.querySelectorAll(":scope > .adv-actor").forEach(element => element.remove());
      scene.insertAdjacentHTML("beforeend", battleActors(data, interactive));
      scene.dataset.scenery = key;
      if (focused) scene.querySelector("[data-adv-action=actor]")?.focus({preventScroll: true});
    }
    window.GaoAdventureScene?.update(scene, "battle", data, interactive, t, interactive && selectedMonster);
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
    const campView = base.querySelector(".adv-camp-scene");
    if (campView) window.GaoAdventureScene?.update(campView, "camp", data, true, t);
    if (!force && latestAttack === data.attackCount) return;
    latestAttack = data.attackCount;
    base.querySelector("[data-adv-stage]").textContent = t(`第 ${number(data.stage)} 关`, `Stage ${number(data.stage)}`);
    base.querySelector("[data-adv-chapter]").textContent = localized(data,"monsterChapter");
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
      base.innerHTML = `<div class="adv-shell"><nav class="adv-segments" aria-label="${t("冒险板块","Adventure Sections")}">${tabs.map(([id, zh, en, glyph]) => `<button type="button" data-adv-action="tab" data-id="${id}" aria-current="${id === current ? "page" : "false"}">${symbol(glyph)} ${h(t(zh, en))}</button>`).join("")}</nav>
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
    dialog.innerHTML = `<header class="adv-split"><h2 id="adv-modal-title">${h(title)}</h2>${btn(t("完成", "Done"), "close-modal")}</header><div class="adv-dialog-content">${body}</div>${buttons ? `<footer class="adv-actions">${buttons}</footer>` : ""}`;
    if (!dialog.open) dialog.showModal();
  }

  function confirmAction(title, body, label, operation) {
    showDialog(title, `<p>${h(body)}</p>`, btn(t("取消", "Cancel"), "close-modal") + btn(label, "confirm-modal", "", {primary: true}), operation, "adv-confirm");
  }

  async function showGear(id) {
    const {result: item} = await get(`/api/adventure/gear-details?id=${encodeURIComponent(id)}`);
    if (!item || current !== "equipment" || root().hidden) return;
    const data = game();
    const equipped = data.equipped[item.slot] === id;
    const slot = localized(data.slots.find(row => row.id === item.slot),"name");
    const affixes = item.affixes.length ? `<h3>${t("独特词条", "Unique Modifiers")}</h3>${item.affixes.map(entry => eventRow({title: entry.name, detail: entry.detail, symbol: entry.symbol, english: {title:entry.english?.name, detail:entry.english?.detail}})).join("")}` : "";
    const body = `<div class="adv-gear-detail ${rarityClass(item.rarity)}"><div class="adv-card-heading">${iconTile(item.symbol)}<div><strong>${h(slot)} · ${rarityName(item.rarity)} · ${h(localized(item,"setName"))} · ${t("强化","Enhancement")} +${item.enhancement}</strong><small>${h(localized(item,"flavor"))}</small></div></div>
      <div class="adv-card-row"><strong>${t(`战力 ${number(item.power)}`, `Power ${number(item.power)}`)}</strong><small>${t("最高 +99 · 后期增幅递增", "Cap +99. Later enhancements boost power faster.")}</small><small>${t(`${number(resources().stardust)} 星尘`, `${number(resources().stardust)} stardust`)}</small></div>${attributes(item.attributes)}${affixes}
      <div class="adv-card-row"><small>${t(`拥有 ${item.count} 件`, `Owned: ${item.count}`)}</small><small>${t(`出售单价 ${number(item.sale)} 星尘`, `Price: ${number(item.sale)} stardust each`)}</small></div></div>`;
    const actions = item.count ? btn(item.enhanceCost ? t(`强化 +1 · ${number(item.enhanceCost)} 星尘`, `Enhance +1 · ${number(item.enhanceCost)} stardust`) : t("已强化至 +99", "At +99"), "detail-enhance", id,
        {primary: true, disabled: !item.enhanceCost || resources().stardust < item.enhanceCost}) +
      btn(equipped ? t("已装备", "Equipped") : t("装备", "Equip"), "detail-equip", id, {disabled: equipped}) +
      btn(t("出售 1 件", "Sell One"), "detail-sell", id, {disabled: equipped, count: item.count}) : "";
    showDialog(localized(item,"name"), body, actions);
  }

  function showReveals(results) {
    if (!results.length || root().hidden) return;
    const title = results.length > 1 ? t(`${results.length} 抽结果 · 高品质优先`, `${results.length} Draws · Highest Rarity First`) : t("获得新收藏", "New Reward");
    const cards = results.map((item, index) => `<article class="adv-panel adv-reveal ${rarityClass(item.rarity)}" style="--reveal-delay:${Math.min(30, 1500 / results.length) * index}ms">
      ${iconTile(item.symbol)}<strong>${h(localized(item,"title"))}</strong><small>${h(localized(item,"detail"))}</small><strong>${rarityName(item.rarity)}</strong></article>`).join("");
    showDialog(title, `<div class="adv-reveals">${cards}</div>`, btn(t("收下", "Collect"), "close-modal", "", {primary: true}), null, results.length === 1 ? "adv-single-reveal" : "adv-multi-reveal");
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
      notice = t(`出售 ${number(result.count)} 件，获得 ${number(result.earned)} 星尘。`, `Sold ${number(result.count)} items for ${number(result.earned)} stardust.`);
    };
    if (!count) return operation();
    confirmAction(duplicates ? t("清理重复装备？", "Sell duplicate equipment?") : t("一键出售装备？", "Bulk sell equipment?"), duplicates
      ? t(`每种装备将保留 1 件，其余 ${count} 件会被出售并转化为星尘。此操作不可撤销。`, `Keep one of each item and sell the other ${count} for stardust. This action is permanent.`)
      : t(`将出售 ${count} 件${rarityName(rarity)}及以下的未装备物品并转化为星尘。此操作不可撤销。`, `Sell ${count} unequipped ${rarityName(rarity)} or lower items for stardust. This action is permanent.`), t(`出售 ${count} 件`, `Sell ${count} items`), operation);
  }

  async function forgetGroup(id) {
    const data = game();
    const rarity = Number(id);
    const count = data.techniques.filter(item => item.rarity <= rarity && !data.equippedTechniques.includes(item.id)).length;
    const operation = async () => {
      const result = await request("forget-techniques", {rarity});
      notice = t(`遗忘 ${number(result.count)} 门技能，返还 ${number(result.earned)} 悟性。`, `Forgot ${number(result.count)} techniques and recovered ${number(result.earned)} insight.`);
    };
    if (!count) return operation();
    confirmAction(t("一键遗忘技能？", "Bulk forget techniques?"), t(`将遗忘 ${count} 门${rarityName(rarity)}及以下的未装配技能，返还基础价值与已投入的参悟悟性；已装配技能会保留。此操作不可撤销。`, `Forget ${count} unequipped ${rarityName(rarity)} or lower techniques and recover their base value and invested insight. Equipped techniques are kept. This action is permanent.`), t(`遗忘 ${count} 门技能`, `Forget ${count} techniques`), operation);
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
      notice = t(`出售成功，获得 ${number(receipt.earned)} 星尘。`, `Sold for ${number(receipt.earned)} stardust.`);
      if (count <= 1) dialog.close(); else await showGear(id);
    },
    "request-sale": id => sellGroup(id, false),
    "request-duplicates": () => sellGroup("", true),
    "request-forget": id => forgetGroup(id),
    "request-hatch": () => confirmAction(t("孵化一枚宠物蛋？", "Hatch a pet egg?"), t(`将立即扣除 10,000 金币（当前持有 ${number(resources().coins)}），随机孵化十二种伙伴之一；重复宠物自动升星。`, `Spend 10,000 gold (current balance: ${number(resources().coins)}) to hatch one of 12 companions. Duplicates increase stars.`), t("消耗 10,000 金币并孵化", "Spend 10,000 Gold and Hatch"), () => request("hatch")),
    draw: async id => { const result = await request("draw", {count: Number(id), pool}); showReveals(result.reveals); },
    exchange: id => request("exchange", {resource: id}),
    unequip: slot => request("unequip", {slot}),
    "equip-best": async () => { const result = await request("equip-best"); notice = t(`已按初始战力选择 ${result.count} 个部位。`, `Equipped ${result.count} slots by base power.`); },
    "technique-best": async () => { const result = await request("technique-best"); notice = t(`已按 1 重初始战力装配 ${result.count} 门技能。`, `Equipped ${result.count} techniques by rank 1 power.`); },
    "pet-best": async () => { const result = await request("pet-best"); notice = t(`已按当前战力选择 ${result.count} 只宠物。`, `Selected ${result.count} pets by current power.`); },
    sell: async (id, count) => { const receipt = await request("sell", {id, count}); notice = t(`出售成功，获得 ${number(receipt.earned)} 星尘。`, `Sold for ${number(receipt.earned)} stardust.`); },
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
      if (dialog?.open) showError(new Error(localizedError(error)));
      else notice = localizedError(error);
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
