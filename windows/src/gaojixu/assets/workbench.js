const token = document.querySelector('meta[name="gao-token"]').content;
const version = document.querySelector('meta[name="gao-version"]').content;
const headers = {"Content-Type": "application/json", "X-Gao-Token": token};
const workspaces = [
  ["overview", "总览", "Overview", "square.grid.2x2.fill", ["overview"]],
  ["finances", "收支", "Finances", "arrow.left.arrow.right.circle.fill", ["ledger", "accounts", "budgets", "reports", "fixed-income"]],
  ["savings", "攒钱", "Savings", "target", ["goals", "records", "analytics"]],
  ["adventure", "冒险", "Adventure", "map.fill", ["adventure"]]
];
const sections = {
  ledger: ["流水", "Transactions"], accounts: ["账户", "Accounts"], budgets: ["预算", "Budgets"], reports: ["报表", "Reports"],
  "fixed-income": ["固定收支", "Recurring"], goals: ["攒钱目标", "Goals"], records: ["积蓄记录", "Records"], analytics: ["趋势", "Analytics"]
};
const fixedRoutes = [["fixed-income", "固定收入", "Income"], ["fixed-expenses", "固定支出", "Expenses"], ["benefits", "权益", "Benefits"]];
const gallery = new URLSearchParams(location.search).get("widget");
let state = null;
let route = gallery ? "widgets" : routeFromHash();
let viewRevision = 0;
let pendingMutation = 0;
let liveRefresh = false;
let settingsFocus = false;

function routeFromHash() {
  const candidate = location.hash.slice(1);
  return candidate && document.getElementById(candidate)?.parentElement?.id === "workbench" ? candidate : "overview";
}
function navigate(destination) {
  if (route === destination) return;
  route = destination;
  if (!gallery) history.replaceState(null, "", "#" + destination);
  document.scrollingElement.scrollTop = 0;
  if (destination !== "widgets") window.GaoFixed?.leaveWidget?.();
  render();
}
function t(zh, en) {
  const language = state?.settings?.language ?? "system";
  return language === "en" || (language === "system" && !navigator.language.toLowerCase().startsWith("zh")) ? (en || zh) : zh;
}
function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>"']/g, char => ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"})[char]);
}
function money(value, currency = state?.currency || "CNY") {
  const amount = Number(value ?? 0);
  try {
    return new Intl.NumberFormat(t("zh-CN","en-US"), {style:"currency", currency}).format(amount);
  } catch {
    return escapeHTML(currency) + " " + amount.toFixed(2);
  }
}
const glyphs = {
  "square.grid.2x2.fill": "ECA5", "arrow.left.arrow.right.circle.fill": "E8AB", "target": "E7B7",
  "map.fill": "E826", "plus": "E710", "ellipsis": "E712", "ellipsis.circle": "E712", "gearshape": "E713",
  "calendar": "E787", "calendar.circle": "E787", "wallet.pass": "E8C7", "wallet.pass.fill": "E8C7", "creditcard": "E8C7",
  "creditcard.fill": "E8C7", "banknote.fill": "E8C7", "building.columns.fill": "E825", "repeat": "E8EE",
  "chevron.left": "E76B", "chevron.right": "E76C", "chevron.down": "E70D", "magnifyingglass": "E721",
  "chart.bar": "E9D9", "chart.bar.fill": "E9D9", "chart.line.uptrend.xyaxis": "E9D9", "trash": "E74D",
  "archivebox": "E7B8", "pencil": "E70F", "square.and.pencil": "E70F", "checkmark": "E73E",
  "arrow.up.circle": "E74A", "arrow.down.circle": "E74B", "arrow.up.right": "E74A", "arrow.down.left": "E74B",
  "arrow.left.arrow.right": "E8AB", "arrow.triangle.2.circlepath": "E895", "repeat.circle": "E8EE",
  "tray.full.fill": "E8B7", "list.bullet": "E8FD", "list.bullet.rectangle": "E8FD", "tag": "E8EC",
  "gift": "E7E0", "gift.fill": "E7E0", "bell": "EA8F", "ticket": "EB54", "ticket.fill": "EB54",
  "star": "E734", "shield": "EA18", "exclamationmark.triangle": "E7BA", "xmark": "E711",
  "wallet.pass.fill": "E8C7", "creditcard.fill": "E8C7", "building.columns.fill": "E825", "banknote.fill": "EC9B",
  "gauge.with.dots.needle.67percent": "E9D9", "slider.horizontal.3": "E9E9", "chart.pie.fill": "E9D9",
  "fork.knife": "ED56", "cart.fill": "E7BF", "house.fill": "E80F", "car.fill": "E804", "bolt.fill": "E945",
  "cross.case.fill": "E95E", "graduationcap.fill": "E821", "gamecontroller.fill": "E7FC", "repeat": "E8EE",
  "pawprint.fill": "E91B", "star.fill": "E735", "briefcase.fill": "E821", "checkmark.seal.fill": "E73E", "archivebox.fill": "E7B8",
  "flame.fill": "ECAD", "flag.checkered": "E7C1", "airplane": "E709", "laptopcomputer": "E770", "camera.fill": "E722", "info.circle": "E946"
};
function icon(name) {
  return '<span class="ui-icon" aria-hidden="true">' + (glyphs[name] ? "&#x" + glyphs[name] + ";" : "&#x25CF;") + "</span>";
}

async function get(path) {
  const response = await fetch(path, {headers});
  const result = await response.json();
  if (!response.ok || result.ok === false) throw new Error(result.error || t("没有完成", "Could not complete the request"));
  return result;
}
async function api(path, body) {
  pendingMutation++;
  viewRevision++;
  try {
    const response = await fetch(path, {method:"POST", headers, body:JSON.stringify(body || {})});
    const data = await response.json();
    if (!response.ok || !data.ok) throw new Error(data.error || t("没有完成", "Could not complete the request"));
    if (data.state) {
      state = data.state;
      render();
    }
    return data.result;
  } finally {
    viewRevision++;
    pendingMutation--;
  }
}
async function refresh(background = false) {
  const revision = viewRevision;
  const current = await get("/api/state");
  if (revision !== viewRevision || pendingMutation) return;
  state = current;
  if (background && route === "adventure" && window.refreshAdventure) window.refreshAdventure();
  else render();
}
async function refreshGame(observation) {
  const revision = viewRevision;
  const active = route;
  const current = await get("/api/adventure/state");
  if (revision !== viewRevision || pendingMutation || route !== active) return;
  state.adventure = current.adventure;
  Object.assign(state.summary, current.resources);
  if (route === "adventure") window.refreshAdventure?.();
  if (observation?.isConnected) {
    window.renderAdventureObservation?.(observation, state.adventure);
    const description = observation.nextElementSibling;
    description?.querySelector("strong")?.replaceChildren(t("等级 ", "Level ") + state.adventure.level + " · " + state.adventure.monster);
    description?.querySelector("small")?.replaceChildren(t(
      "金币 " + state.summary.coins + " · 星券 " + state.summary.tickets,
      state.summary.coins + " coins · " + state.summary.tickets + " tickets"
    ));
  }
}
function showError(error) {
  alert(error?.message || String(error));
}
function navButton(id, title, current, symbol) {
  return '<button type="button" data-route="' + id + '" class="' + (current ? "active" : "") + '"' + (current ? ' aria-current="page"' : "") + ">" +
    (symbol ? icon(symbol) : "") + escapeHTML(title) + "</button>";
}
function render() {
  const ready = state?.status === "ready";
  const workspace = workspaces.find(item => item[4].includes(route) || (item[0] === "finances" && fixedRoutes.some(f => f[0] === route))) || workspaces[0];
  const inFixed = fixedRoutes.some(item => item[0] === route);
  const canonical = inFixed ? "fixed-income" : route;
  document.documentElement.lang = t("zh-CN", "en-US");
  document.body.dataset.theme = state?.settings?.appearance || "system";
  document.body.classList.toggle("widget-mode", Boolean(gallery));
  const tint = state?.settings?.backgroundHex || "";
  const root = document.documentElement;
  if (/^#[\dA-Fa-f]{6}$/.test(tint)) root.style.setProperty("--user-tint", tint);
  else root.style.removeProperty("--user-tint");
  const appName = t("搞积蓄", "Gao Savings");
  document.title = appName + " V" + version.split("+")[0];
  document.getElementById("brand-name").textContent = appName;
  document.getElementById("brand-tagline").textContent = t("我的财务工作台", "My finance workspace");
  document.getElementById("workspaces").innerHTML = workspaces.map(item => navButton(item[4][0], t(item[1], item[2]), item === workspace && route !== "widgets", item[3])).join("");
  const showSections = workspace[4].length > 1;
  document.getElementById("subbar").hidden = !showSections;
  document.getElementById("sections").innerHTML = showSections ? workspace[4].map(id => navButton(id, t(...sections[id]), id === canonical)).join("") : "";
  document.getElementById("fixed-bar").hidden = !inFixed;
  document.getElementById("fixed-sections").innerHTML = inFixed ? fixedRoutes.map(([id, zh, en]) => navButton(id, t(zh, en), id === route)).join("") : "";
  renderToolbar(ready);
  const banner = document.getElementById("banner");
  banner.hidden = !state || (ready && !state.notice);
  if (!banner.hidden) {
    banner.innerHTML = ready ? escapeHTML(state.notice) :
      "<strong>" + (state.status === "missing" ? t("还没有资料库", "No library yet") : t("资料库只读保护", "Library protected")) + "</strong>" +
      (state.notice ? "<p>" + escapeHTML(state.notice) + "</p>" : "") +
      (state.status === "missing" && !gallery ? '<p><button data-workbench="create">' + t("创建我的资料库", "Create my library") + "</button></p>" : "");
  }
  for (const section of document.querySelectorAll("#workbench > section")) section.hidden = !ready || section.id !== route;
  if (!ready) return;
  if (inFixed) window.GaoFixed?.render(route);
  else if (route === "adventure") window.renderAdventure?.();
  else if (route === "widgets") window.GaoWidgets?.render(gallery || "all");
  else window.GaoFinance?.render(route);
}
function renderToolbar(ready) {
  const node = document.getElementById("toolbar");
  const wasOpen = node.querySelector("details")?.open;
  node.innerHTML = (ready ? '<button class="record-button" data-workbench="record">' + icon("plus") + t("记一笔", "Record") + "</button>" : "") +
    '<details class="toolbar-menu"><summary aria-label="' + t("更多", "More") + '" title="' + t("更多", "More") + '">' + icon("ellipsis.circle") + "</summary>" +
    '<div class="menu-panel">' +
    (ready ? '<button data-workbench="record">' + t("记录收支或转账", "Record income, expense or transfer") + '</button><button data-workbench="savings"' +
      ((state.goals || []).some(goal => goal.status === "active") ? "" : " disabled") + ">" + t("分配一笔积蓄", "Allocate savings") +
      '</button><hr><button data-workbench="import">' + t("导入流水 CSV", "Import Transactions CSV") + '</button><button data-workbench="export">' +
      t("导出流水 CSV", "Export Transactions CSV") + '</button><button data-workbench="widgets">' + t("小组件", "Widgets") + "</button><hr>" : "") +
    (ready ? '<button data-workbench="settings">' + t("设置", "Settings") + "</button>" : "") +
    '<button data-workbench="quit">' + t("退出搞积蓄", "Quit Gao Savings") + "</button></div></details>";
  if (wasOpen) node.querySelector("details").open = true;
}
function openEditor({title, subtitle = "", body, submitLabel, onSubmit, onOpen, width}) {
  const dialog = document.getElementById("editor");
  if (width) dialog.style.setProperty("--editor-width", typeof width === "number" ? width + "px" : width);
  else dialog.style.removeProperty("--editor-width");
  const form = document.getElementById("editor-form");
  document.getElementById("editor-title").textContent = title;
  const description = document.getElementById("editor-subtitle");
  description.hidden = !subtitle;
  description.textContent = subtitle;
  const content = document.getElementById("editor-content");
  if (body instanceof Node) content.replaceChildren(body);
  else content.innerHTML = body;
  const submit = document.getElementById("editor-submit");
  submit.hidden = !onSubmit;
  submit.disabled = false;
  submit.textContent = submitLabel || t("保存", "Save");
  document.getElementById("editor-cancel").textContent = onSubmit ? t("取消", "Cancel") : t("完成", "Done");
  const error = document.getElementById("editor-error");
  error.hidden = true;
  form.onsubmit = async event => {
    event.preventDefault();
    if (!onSubmit || submit.disabled) return;
    submit.disabled = true;
    error.hidden = true;
    try {
      if (await onSubmit(form) !== false) closeEditor();
    } catch (failure) {
      error.textContent = failure?.message || String(failure);
      error.hidden = false;
    } finally {
      submit.disabled = false;
    }
  };
  if (!dialog.open) {
    dialog.returnValue = "";
    dialog.showModal();
  }
  content.scrollTop = 0;
  onOpen?.(form);
  return form;
}
function closeEditor() {
  document.getElementById("editor").close();
}
function openSettings() {
  if (state?.status !== "ready") return;
  const current = state.settings;
  const appearance = [["system","跟随系统","System"],["light","浅色","Light"],["dark","深色","Dark"]];
  const languages = [["system","跟随系统","System"],["zh","简体中文","Simplified Chinese"],["en","英文","English"]];
  const choose = (items, val) => items.map(([id, zh, en]) => '<option value="' + id + '"' + (val === id ? " selected" : "") + ">" + t(zh,en) + "</option>").join("");
  const colors = state.currencies.map(row => '<option value="' + row.id + '"' + (state.currency === row.id ? " selected" : "") + ">" + escapeHTML(row.name + " · " + row.id) + "</option>").join("");
  const tint = /^#[\dA-Fa-f]{6}$/.test(current.backgroundHex || "") ? current.backgroundHex : "";
  settingsFocus = true;
  openEditor({
    title:t("设置","Settings"), width:720,
    body:'<div class="segmented settings-tabs" role="group" aria-label="' + t("设置分类","Settings sections") + '">' +
      '<button type="button" class="active" data-settings="module">' + t("模块设置","Module settings") + '</button>' +
      '<button type="button" data-settings="appearance">' + t("外观","Appearance") + '</button>' +
      '<button type="button" data-settings="data">' + t("数据","Data") + '</button></div>' +
      '<div data-settings-panel="module"><div class="form-section settings-fields"><label>' + t("新目标默认币种","Default currency for new goals") + '<select name="currency">' + colors +
      '</select></label><label class="check-row"><input type="checkbox" name="budgetRollover"' + (current.budgetRolloverEnabled ? " checked" : "") + ">" +
      t("预算滚存上月结余","Roll over last month’s budget surplus") + '</label><div class="row"><label>' + t("画布色调","Canvas tint") +
      '<input type="color" name="tint" value="' + (tint || "#f6f3ea") + '"></label><input type="hidden" name="backgroundHex" value="' + tint +
      '"><button type="button" id="reset-tint" class="ghost">' + t("恢复默认","Reset") + '</button></div></div><div class="form-section"><h3>' +
      t("隐私与资金安全","Privacy & Safety") + '</h3><p>' + t("所有记录只保存在本机。无需登录。", "Everything stays on this PC. No sign-in is required.") +
      '</p><p>' + t("本应用不连接银行，不会发起真实银行交易。", "The app never connects to banks or initiates real transactions.") +
      '</p><p>' + t("免费抽奖只消耗游戏星券。", "Free draws spend in-game tickets.") + '</p></div></div>' +
      '<div data-settings-panel="appearance" hidden><div class="form-section settings-fields"><label>' + t("语言","Language") + '<select name="language">' +
      choose(languages,current.language) + '</select></label><label>' + t("外观","Appearance") + '<select name="appearance">' +
      choose(appearance,current.appearance) + '</select></label><div>' + t("版本","Version") + " " + escapeHTML(version) + "</div></div></div>" +
      '<div data-settings-panel="data" hidden><div class="form-section"><h3>' + t("现用资料","Active files") + "</h3><p>" +
      t("账本、固定收支、游戏进度及小组件快照都保存在本机。","Your ledger, recurring finances, game progress, and widget snapshots stay on this PC.") +
      '</p><div class="row settings-location"><button type="button" class="ghost" data-folder="library">' + t("打开数据目录","Open data folder") +
      '</button><button type="button" class="ghost" data-folder="widgets">' + t("打开小组件共享目录","Open widget snapshot folder") +
      '</button></div></div><div class="form-section"><h3>' + t("隐私","Privacy") + "</h3><p>" +
      t("源码与安装包不包含本机业务记录。","The source and installer contain no personal records.") + "</p></div></div>",
    submitLabel:t("完成","Done"),
    onOpen(form) {
      for (const tab of form.querySelectorAll("[data-settings]")) {
        tab.onclick = () => {
          for (const button of form.querySelectorAll("[data-settings]")) {
            button.classList.toggle("active", button === tab);
            button.setAttribute("aria-pressed", String(button === tab));
          }
          for (const panel of form.querySelectorAll("[data-settings-panel]")) panel.hidden = panel.dataset.settingsPanel !== tab.dataset.settings;
        };
      }
      for (const button of form.querySelectorAll("[data-folder]")) {
        button.onclick = () => api("/api/settings/folder",{folder:button.dataset.folder}).catch(showError);
      }
      const color = form.elements.tint;
      color.oninput = () => form.elements.backgroundHex.value = color.value;
      form.querySelector("#reset-tint").onclick = () => {
        form.elements.backgroundHex.value = "";
        color.value = "#f6f3ea";
      };
    },
    async onSubmit(form) {
      const data = Object.fromEntries(new FormData(form));
      data.budgetRollover = form.elements.budgetRollover.checked;
      await api("/api/settings", data);
    }
  });
}
document.addEventListener("click", event => {
  const nav = event.target.closest("#workspaces [data-route], #sections [data-route], #fixed-sections [data-route]");
  if (nav && !nav.classList.contains("active")) navigate(nav.dataset.route);
  const command = event.target.closest("[data-workbench]");
  const details = document.querySelector(".toolbar-menu");
  if (details && (!details.contains(event.target) || command)) details.open = false;
  if (!command) return;
  const actions = {
    create: () => api("/api/library/create", {}),
    record: () => window.GaoFinance?.openLedger(),
    savings: () => window.GaoFinance?.openRecord(),
    import: () => window.GaoFinance?.importCSV(),
    export: () => window.GaoFinance?.exportCSV(),
    widgets: () => navigate("widgets"),
    settings: openSettings,
    async quit() {
      await api("/api/shutdown");
      document.getElementById("workbench").textContent = t("搞积蓄已退出。","Gao Savings has closed.");
      document.querySelector(".app-chrome").hidden = true;
    }
  };
  Promise.resolve().then(actions[command.dataset.workbench]).catch(showError);
});
document.addEventListener("keydown", event => {
  if (!event.ctrlKey || event.altKey || event.metaKey || event.repeat) return;
  if (event.key === "," || (event.key.toLowerCase() === "n" && state?.status === "ready")) {
    event.preventDefault();
    if (!document.getElementById("editor").open) {
      if (event.key === ",") openSettings();
      else if (event.shiftKey) window.GaoFinance?.openRecord();
      else window.GaoFinance?.openLedger();
    }
  }
});
document.addEventListener("DOMContentLoaded", () => {
  document.getElementById("editor-cancel").onclick = closeEditor;
  document.getElementById("editor").addEventListener("close", () => { settingsFocus = false; });
  refresh().catch(error => {
    const banner = document.getElementById("banner");
    banner.textContent = error.message;
    banner.hidden = false;
  });
  if (gallery) document.getElementById("toolbar").hidden = true;
  let ticks = 0;
  setInterval(async () => {
    if (document.hidden || !state || state.status !== "ready" || pendingMutation || settingsFocus || liveRefresh) return;
    const observation = route === "overview" ? document.querySelector("[data-adventure-observation]") : null;
    if (!(route === "adventure" || observation || (route === "widgets" && ++ticks % 3 === 0))) return;
    liveRefresh = true;
    try {
      if (route === "widgets") await refresh(true);
      else await refreshGame(observation);
    } catch {
      // Keep the most recent scene until the local service responds.
    } finally {
      liveRefresh = false;
    }
  }, 1000);
});
window.addEventListener("hashchange", () => { if (!gallery) navigate(routeFromHash()); });
