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
const fixedRoutes = [["fixed-income", "固定收入", "Income"], ["fixed-expenses", "固定支出", "Expenses"]];
const query = new URLSearchParams(location.search);
const gallery = query.get("widget") === "benefits" ? "expenses" : query.get("widget");
const lease = /^[a-f0-9]{32}$/.test(query.get("workbench") ?? "") ? query.get("workbench") : "";
const desktopMarker = lease ? " [GJX:" + lease + "]" : "";
let desktopAttached = false;
let desktopRoute = "";
let editorDirty = false;
let quitPending = false;
if (lease) document.title += desktopMarker;
let state = null;
let route = gallery ? "widgets" : routeFromHash();
let viewRevision = 0;
let pendingMutation = 0;
let liveRefresh = false;
let settingsFocus = false;
const markupCache = new WeakMap();

function updateMarkup(node, markup) {
  if (markupCache.get(node) === markup) return;
  node.innerHTML = markup;
  markupCache.set(node, markup);
}

function routeFromHash() {
  const candidate = location.hash.slice(1);
  if (candidate === "benefits") {
    history.replaceState(null, "", "#fixed-expenses");
    return "fixed-expenses";
  }
  const section = candidate && document.getElementById(candidate);
  return section?.tagName === "SECTION" && section.parentElement?.id === "workbench" ? candidate : "overview";
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
  if (!response.ok || result.ok === false) throw requestError(path, result.error, result.code);
  return result;
}
async function api(path, body) {
  pendingMutation++;
  viewRevision++;
  try {
    const response = await fetch(path, {method:"POST", headers, body:JSON.stringify(body || {})});
    const data = await response.json();
    if (!response.ok || !data.ok) throw requestError(path, data.error, data.code);
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
function requestError(path, text, code) {
  const description = text || t("没有完成", "Could not complete the request");
  const localized = path.startsWith("/api/csv/review") ? window.GaoCSVReview?.localError(description, code) :
    window.GaoFixed?.localError(path, description);
  return new Error(localized ?? description);
}
async function refreshIfMonthlyChanged() {
  const generation = state?.monthlyIntegration?.generation;
  const revision = viewRevision;
  const active = route;
  const status = await get("/api/monthly/integration");
  if (revision === viewRevision && route === active && status.generation !== generation &&
      !document.getElementById("editor").open && document.activeElement?.id !== "fixed-sub-search") {
    await refresh();
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
    const monster = t(state.adventure.monster, state.adventure.english?.monster);
    description?.querySelector("strong")?.replaceChildren(t("等级 ", "Level ") + state.adventure.level + " · " + monster);
    description?.querySelector("small")?.replaceChildren(t(
      "金币 " + state.summary.coins + " · 星券 " + state.summary.tickets,
      state.summary.coins + " coins · " + state.summary.tickets + " tickets"
    ));
  }
}
function showError(error) {
  const message = error?.message || String(error);
  const opened = document.querySelector("dialog[open]:not(#decision)");
  if (opened) {
    let inline = opened.querySelector("#editor-error, .dialog-notice");
    if (!inline) {
      inline = document.createElement("p");
      inline.className = "dialog-notice";
      inline.setAttribute("role", "alert");
      opened.append(inline);
    }
    inline.textContent = message;
    inline.hidden = false;
    return;
  }
  document.getElementById("feedback-title").textContent = t("操作未完成", "Action incomplete");
  document.getElementById("feedback-content").textContent = message;
  document.getElementById("feedback-dismiss").setAttribute("aria-label",t("关闭","Close"));
  document.getElementById("feedback").hidden = false;
}
function confirmAction(message, {title, label, destructive = true} = {}) {
  const dialog = document.getElementById("decision");
  if (dialog.open) return Promise.resolve(false);
  document.getElementById("decision-title").textContent = title || t("确认操作", "Confirm action");
  document.getElementById("decision-content").textContent = message;
  document.getElementById("decision-cancel").textContent = t("取消", "Cancel");
  const button = document.getElementById("decision-confirm");
  button.textContent = label || t("确认", "Confirm");
  button.classList.toggle("danger", destructive);
  dialog.returnValue = "";
  return new Promise(resolve => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), {once:true});
    dialog.showModal();
  });
}
function preventDraftLoss(event) {
  event.preventDefault();
  event.returnValue = "";
}
function markEditorDirty(dirty) {
  if (editorDirty === dirty) return;
  editorDirty = dirty;
  if (dirty) window.addEventListener("beforeunload", preventDraftLoss);
  else window.removeEventListener("beforeunload", preventDraftLoss);
}
function requestQuit() {
  const dialog = document.getElementById("app-exit");
  if (dialog.open || quitPending) return;
  quitPending = true;
  function showWhenReady() {
    if (pendingMutation || document.getElementById("editor-form").hasAttribute("aria-busy")) {
      setTimeout(showWhenReady, 100);
      return;
    }
    quitPending = false;
    const hasDraft = editorDirty || window.GaoCSVReview?.hasDraft();
    document.getElementById("app-exit-title").textContent = t("退出搞积蓄？", "Quit Gao Savings?");
    document.getElementById("app-exit-text").textContent = hasDraft
      ? t("当前编辑尚未保存。可返回编辑保存，或放弃本次修改并退出。",
          "The current edit is unsaved. Return to save it, or discard it and quit.")
      : t("退出将关闭工作台和桌面小组件，并停止后台服务。", "Quitting closes the workbench and widgets and stops the background service.");
    dialog.querySelector("[data-exit-cancel]").textContent = hasDraft ? t("返回编辑", "Return to edit") : t("取消", "Cancel");
    dialog.querySelector("[data-exit-confirm]").textContent = hasDraft ? t("放弃并退出", "Discard and quit") : t("退出", "Quit");
    dialog.returnValue = "";
    dialog.showModal();
  }
  showWhenReady();
}
async function pollDesktop() {
  if (document.body.dataset.session === "closed") return;
  try {
    const event = await get("/api/desktop/events?lease=" + lease);
    if (event.attached && !desktopAttached) {
      desktopAttached = true;
      document.title = document.title.replace(desktopMarker, "");
    }
    if (event.route) desktopRoute = event.route;
    if (event.quit) requestQuit();
    if (desktopRoute && !document.querySelector("dialog[open]") && !pendingMutation && !quitPending) {
      navigate(desktopRoute);
      desktopRoute = "";
    }
  } catch {
    // The controlled window closes with the service on exit.
  } finally {
    setTimeout(pollDesktop, 650);
  }
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
  document.title = window.GaoWidgets?.windowTitle(appName) ||
    appName + " V" + version.split("+")[0] + (desktopAttached ? "" : desktopMarker);
  document.getElementById("brand-name").textContent = appName;
  document.getElementById("context-workspace").textContent = route === "widgets" ? t("小组件", "Widgets") : t(workspace[1],workspace[2]);
  const context = document.getElementById("context-section");
  context.hidden = !(inFixed || sections[route]);
  const fixedNames = fixedRoutes.find(item => item[0] === route)?.slice(1);
  context.textContent = fixedNames ? t(...fixedNames) : sections[route] ? t(...sections[route]) : "";
  const workspaceNav = document.getElementById("workspaces");
  const subbar = document.getElementById("subbar");
  const workspaceMarkup = workspaces.map(item => navButton(item[4][0], t(item[1], item[2]), item === workspace && route !== "widgets", item[3])).join("");
  if (markupCache.get(workspaceNav) !== workspaceMarkup) {
    subbar.remove();
    updateMarkup(workspaceNav, workspaceMarkup);
    const selected = workspaceNav.querySelector("button.active");
    if (selected) selected.after(subbar);
    else workspaceNav.append(subbar);
  }
  const showSections = workspace[4].length > 1;
  subbar.hidden = !showSections;
  updateMarkup(document.getElementById("sections"), showSections ? workspace[4].map(id => navButton(id, t(...sections[id]), id === canonical)).join("") : "");
  document.getElementById("fixed-bar").hidden = !inFixed;
  updateMarkup(document.getElementById("fixed-sections"), inFixed ? fixedRoutes.map(([id, zh, en]) => navButton(id, t(zh, en), id === route)).join("") : "");
  const tools = document.getElementById("rail-tools");
  tools.hidden = !ready || Boolean(gallery);
  updateMarkup(tools,
    '<button type="button" data-workbench="widgets" class="' + (route === "widgets" ? "active" : "") + '">' +
    icon("square.grid.2x2.fill") + t("桌面小组件", "Desktop widgets") + '</button><button type="button" data-workbench="settings">' +
    icon("gearshape") + t("设置", "Settings") + "</button>");
  renderToolbar(ready);
  const banner = document.getElementById("banner");
  banner.hidden = !state || (ready && !state.notice);
  if (!banner.hidden) {
    const symbol = state.status === "missing" ? "tray.full.fill" : "shield";
    banner.innerHTML = ready ? icon("info.circle") + "<strong>" + escapeHTML(state.notice) + "</strong>" :
      icon(symbol) + "<div><strong>" + (state.status === "missing" ? t("创建资料库", "Create a library") : t("资料库只读保护", "Library protected")) + "</strong>" +
      (state.notice ? "<p>" + escapeHTML(state.notice) + "</p>" : "") +
      (state.status === "missing" && !gallery ? '<button data-workbench="create">' + t("创建我的资料库", "Create my library") + "</button>" : "") +
      (gallery ? '<p><a href="/" target="_blank" rel="noopener">' + t("打开搞积蓄", "Open Gao Savings") + "</a></p>" : "") + "</div>";
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
  updateMarkup(node,(ready ? '<button class="record-button" data-workbench="record">' + icon("plus") + t("记一笔", "Record") + "</button>" : "") +
    '<details class="toolbar-menu"><summary aria-label="' + t("更多", "More") + '" title="' + t("更多", "More") + '">' + icon("ellipsis.circle") + "</summary>" +
    '<div class="menu-panel">' +
    (ready ? '<button data-workbench="record">' + t("记录收支或转账", "Record income, expense or transfer") + '</button><button data-workbench="savings"' +
      ((state.goals || []).some(goal => goal.status === "active") ? "" : " disabled") + ">" + t("分配一笔积蓄", "Allocate savings") +
      '</button><hr><button data-workbench="import">' + t("导入审核箱", "Import inbox") + '</button><button data-workbench="export">' +
      t("导出流水 CSV", "Export Transactions CSV") + '</button><button data-workbench="widgets">' + t("小组件", "Widgets") + "</button><hr>" : "") +
    (ready ? '<button data-workbench="settings">' + t("设置", "Settings") + "</button>" : "") +
    '<button data-workbench="quit">' + t("退出搞积蓄", "Quit Gao Savings") + "</button></div></details>");
  if (wasOpen) node.querySelector("details").open = true;
}
function openEditor({title, subtitle = "", body, submitLabel, onSubmit, onOpen, width}) {
  const dialog = document.getElementById("editor");
  markEditorDirty(false);
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
  const normalLabel = submitLabel || t("保存", "Save");
  submit.textContent = normalLabel;
  document.getElementById("editor-cancel").textContent = onSubmit ? t("取消", "Cancel") : t("完成", "Done");
  document.getElementById("editor-close").setAttribute("aria-label",t("关闭","Close"));
  const error = document.getElementById("editor-error");
  error.hidden = true;
  form.onsubmit = async event => {
    event.preventDefault();
    if (!onSubmit || submit.disabled) return;
    submit.disabled = true;
    const savingLabel = t("处理中…","Working…");
    submit.textContent = savingLabel;
    form.setAttribute("aria-busy","true");
    error.hidden = true;
    try {
      if (await onSubmit(form) !== false) closeEditor();
    } catch (failure) {
      error.textContent = failure?.message || String(failure);
      error.hidden = false;
    } finally {
      submit.disabled = false;
      if (submit.textContent === savingLabel) submit.textContent = normalLabel;
      form.removeAttribute("aria-busy");
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
  markEditorDirty(false);
  document.getElementById("editor").close();
}
function openSettings() {
  if (state?.status !== "ready") return;
  const current = state.settings;
  const appearance = [["system","跟随系统","System"],["light","浅色","Light"],["dark","深色","Dark"]];
  const languages = [["system","跟随系统","System"],["zh","简体中文","Simplified Chinese"],["en","英文","English"]];
  const choose = (items, val) => items.map(([id, zh, en]) => '<option value="' + id + '"' + (val === id ? " selected" : "") + ">" + t(zh,en) + "</option>").join("");
  const displayCurrency = new Intl.DisplayNames(["en"], {type:"currency"});
  const colors = state.currencies.map(row => '<option value="' + row.id + '"' + (state.currency === row.id ? " selected" : "") + ">" +
    escapeHTML(t(row.name,displayCurrency.of(row.id)) + " · " + row.id) + "</option>").join("");
  const tint = /^#[\dA-Fa-f]{6}$/.test(current.backgroundHex || "") ? current.backgroundHex : "";
  settingsFocus = true;
  openEditor({
    title:t("设置","Settings"), width:690,
    body:`<div class="settings-layout">
      <div class="segmented settings-tabs" role="group" aria-label="${t("设置分类","Settings sections")}">
        <button type="button" class="active" aria-pressed="true" data-settings="module">${icon("slider.horizontal.3")}${t("记账","Ledger")}</button>
        <button type="button" aria-pressed="false" data-settings="appearance">${icon("square.grid.2x2.fill")}${t("外观","Appearance")}</button>
        <button type="button" aria-pressed="false" data-settings="data">${icon("tray.full.fill")}${t("资料","Data")}</button>
      </div>
      <div class="settings-tab-content">
        <div data-settings-panel="module">
          <div class="form-section settings-fields">
            <label class="field-wide">${t("新目标默认币种","Default currency for new goals")}<select name="currency">${colors}</select></label>
            <label class="check-row field-wide"><input type="checkbox" name="budgetRollover"${current.budgetRolloverEnabled ? " checked" : ""}>
              ${t("预算滚存上月结余","Roll over last month’s budget surplus")}</label>
          </div>
        </div>
        <div data-settings-panel="appearance" hidden>
          <div class="form-section settings-fields">
            <label>${t("界面语言","Language")}<select name="language">${choose(languages,current.language)}</select></label>
            <label>${t("显示主题","Theme")}<select name="appearance">${choose(appearance,current.appearance)}</select></label>
            <div class="settings-row field-wide">
              <strong>${t("工作区底色","Workspace tint")}</strong>
              <div class="settings-tint">
                <input aria-label="${t("工作区底色","Workspace tint")}" type="color" name="tint" value="${tint || "#f2f6f5"}">
                <input type="hidden" name="backgroundHex" value="${tint}">
                <button type="button" id="reset-tint" class="ghost">${t("恢复默认","Reset")}</button>
              </div>
            </div>
          </div>
        </div>
        <div data-settings-panel="data" hidden>
          <div class="form-section">
            <div class="settings-row"><div><strong>${t("业务资料","App data")}</strong><p class="muted">${t("账本、固定收支和冒险进度","Ledger, recurring finances and game progress")}</p></div>
              <button type="button" class="ghost" data-folder="library">${t("打开目录","Open folder")}</button></div>
            <div class="settings-row"><div><strong>${t("小组件快照","Widget snapshots")}</strong><p class="muted">${t("桌面小组件的财务快照","Financial snapshots for desktop widgets")}</p></div>
              <button type="button" class="ghost" data-folder="widgets">${t("打开目录","Open folder")}</button></div>
          </div>
          <p class="muted">${t("业务资料仅保存在本机，不连接银行。","Your records stay on this PC. The app has no bank connection.")}</p>
        </div>
        <small class="settings-version">V${escapeHTML(version)}</small>
      </div>
    </div>`,
    submitLabel:t("保存设置","Save settings"),
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
        color.value = "#f2f6f5";
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
  for (const menu of document.querySelectorAll(".fixed-item-menu[open]")) {
    if (!menu.contains(event.target)) menu.open = false;
  }
  const nav = event.target.closest("#workspaces [data-route], #sections [data-route], #fixed-sections [data-route]");
  if (nav && !nav.classList.contains("active")) {
    const group = nav.parentElement;
    const destination = nav.dataset.route;
    navigate(destination);
    if (event.detail === 0) group.querySelector("[data-route].active")?.focus();
  }
  const command = event.target.closest("[data-workbench]");
  const details = document.querySelector(".toolbar-menu");
  if (details && (!details.contains(event.target) || command)) details.open = false;
  if (!command) return;
  const actions = {
    create: () => api("/api/library/create", {}),
    record: () => window.GaoFinance?.openLedger(),
    savings: () => window.GaoFinance?.openRecord(),
    import: () => window.GaoCSVReview?.open(),
    export: () => window.GaoFinance?.exportCSV(),
    widgets: () => navigate("widgets"),
    settings: openSettings,
    retry: loadWorkbench,
    quit: requestQuit
  };
  Promise.resolve().then(actions[command.dataset.workbench]).catch(showError);
});
document.addEventListener("keydown", event => {
  if (event.key === "Escape") {
    const menu = document.querySelector(".toolbar-menu[open], .fixed-item-menu[open]");
    if (menu) {
      menu.open = false;
      menu.querySelector("summary")?.focus();
    }
  }
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
function loadWorkbench() {
  const banner = document.getElementById("banner");
  banner.hidden = false;
  banner.innerHTML = '<span class="state-spinner" aria-hidden="true"></span><strong>' + t("正在读取资料…","Loading records…") + "</strong>";
  return refresh().catch(error => {
    banner.innerHTML = icon("exclamationmark.triangle") + "<div><strong>" + t("无法连接到本机服务","Local service unavailable") +
      "</strong><p>" + escapeHTML(error.message) + '</p><button data-workbench="retry">' + t("重新读取","Retry") + "</button></div>";
  });
}
document.addEventListener("DOMContentLoaded", () => {
  document.getElementById("editor-cancel").onclick = closeEditor;
  document.getElementById("editor-close").onclick = closeEditor;
  document.getElementById("feedback-dismiss").onclick = () => { document.getElementById("feedback").hidden = true; };
  document.getElementById("editor").addEventListener("close", () => { settingsFocus = false; markEditorDirty(false); });
  const editor = document.getElementById("editor-form");
  for (const type of ["input", "change"]) {
    editor.addEventListener(type, () => {
      if (!document.getElementById("editor-submit").hidden) markEditorDirty(true);
    });
  }
  const exit = document.getElementById("app-exit");
  exit.addEventListener("close", async () => {
    if (exit.returnValue !== "confirm") return;
    try {
      await api("/api/shutdown");
      markEditorDirty(false);
      document.getElementById("workbench").textContent = t("搞积蓄已退出。","Gao Savings has closed.");
      document.querySelector(".app-chrome").hidden = true;
      document.body.dataset.session = "closed";
    } catch (error) {
      showError(error);
    }
  });
  loadWorkbench();
  if (lease) pollDesktop();
  if (gallery) document.getElementById("toolbar").hidden = true;
  setInterval(() => {
    if (!document.hidden && state?.status === "ready" && !pendingMutation && !liveRefresh &&
        (fixedRoutes.some(item => item[0] === route) || route === "overview" || route === "ledger")) {
      refreshIfMonthlyChanged().catch(() => {});
    }
  }, 3000);
  let ticks = 0;
  setInterval(async () => {
    if (document.hidden || pendingMutation || settingsFocus || liveRefresh || (route !== "widgets" && state?.status !== "ready")) return;
    const observation = route === "overview" ? document.querySelector("[data-adventure-observation]") : null;
    if (!(route === "adventure" || observation || (route === "widgets" && ++ticks % 3 === 0))) return;
    liveRefresh = true;
    try {
      if (route === "widgets") await refresh(true);
      else await refreshGame(observation);
      if (route === "widgets") window.GaoWidgets?.connection(true);
    } catch {
      // Keep the most recent scene until the local service responds.
      if (route === "widgets") window.GaoWidgets?.connection(false);
    } finally {
      liveRefresh = false;
    }
  }, 1000);
});
window.addEventListener("hashchange", () => { if (!gallery) navigate(routeFromHash()); });
