(() => {
  const e = escapeHTML;
  const title = {
    calendar:["每日收支与积蓄","Daily cash flow and savings"],
    "net-worth":["净资产","Net worth"], expenses:["固定支出","Fixed expenses"],
    benefits:["权益打卡","Benefits"], adventure:["勇者冒险","Hero adventure"]
  };
  const destination = {calendar:"ledger","net-worth":"overview",expenses:"fixed-expenses",benefits:"benefits",adventure:"adventure"};
  const candidate = new URLSearchParams(location.search).get("desktop") || "";
  const lease = title[gallery] && /^[a-f0-9]{32}$/.test(candidate) ? candidate : "";
  let desktop = {available:false,windows:{}};
  let statusTask = null;
  let checkedAt = 0;
  let signature = "";

  function routeLink(type) {
    return '<a class="widget-open" data-window-route="' + type + '" href="/#' + destination[type] + '"' + (gallery ? ' target="_blank" rel="noopener"' : "") +
      ' aria-label="' + t("打开搞积蓄","Open Gao Savings") + '">' + icon("chevron.right") + "</a>";
  }
  function desktopControls(type) {
    if (lease) {
      return '<button type="button" class="ghost widget-window-button" data-window-pin="' + type + '" hidden></button>' +
        '<button type="button" class="ghost widget-window-button" data-window-close="' + type + '" hidden aria-label="' +
        t("关闭小组件","Close widget") + '">' + icon("xmark") + "</button>";
    }
    return '<button type="button" class="ghost widget-window-button" data-window-open="' + type + '" hidden></button>' +
      (gallery ? "" : '<a class="widget-open" data-window-fallback href="/?widget=' + type + '" target="_blank" rel="noopener">' +
        t("单独打开","Open separately") + "</a>");
  }
  function tile(type, content, footer) {
    return '<article class="card widget-tile widget-' + type + '"><div class="widget-title"><h2>' + t(...title[type]) + "</h2>" +
      '<div class="widget-window-actions">' + desktopControls(type) + routeLink(type) + "</div></div>" +
      content + (footer ? '<small class="widget-footer">' + e(footer) + "</small>" : "") + "</article>";
  }
  function moneyShort(amount, prefix, code) {
    if (Math.abs(amount) < .005) return "·";
    const normalized = Number(amount);
    const decimals = ["JPY","KRW"].includes(code) || Math.abs(normalized) >= 100 ? 0 : 2;
    return prefix + (normalized < 0 ? "−" : "") + Math.abs(normalized).toFixed(decimals);
  }
  function footer() {
    return state.financeUpdatedAt ? t("资料时间 ","Data ") + state.financeUpdatedAt : t("当前资料库","Current library");
  }
  function calendar() {
    const currency = state.currency;
    const month = state.summary.monthKey;
    const firstDay = new Date(month + "-01T12:00:00").getDay();
    const labels = t("日一二三四五六","SMTWTFS").split("");
    const headers = labels.map(label => '<span class="widget-weekday">' + label + "</span>").join("");
    const padding = '<span aria-hidden="true"></span>'.repeat(firstDay);
    const cells = state.days.map(day => {
      const details = [
        money(day.expense,currency) + " " + t("支出","expense"),
        money(day.income,currency) + " " + t("收入","income"),
        money(day.saving,currency) + " " + t("积蓄","saved")
      ];
      return '<div class="widget-day" aria-label="' + e(day.day + ": " + details.join(", ")) + '" title="' +
        e(details.join(" · ")) + '"><b>' + day.day + '</b><div class="widget-expense">' +
        moneyShort(day.expense,"−",currency) + '</div><div class="widget-income">' + moneyShort(day.income,"+",currency) +
        '</div><div class="widget-saving">' + moneyShort(day.saving,"∼",currency) + "</div></div>";
    }).join("");
    const monthText = new Intl.DateTimeFormat(t("zh-CN","en-US"),{month:"long",year:"numeric"}).format(new Date(month + "-01T12:00:00"));
    return tile("calendar",'<div class="widget-month"><strong>' + e(monthText) + "</strong><span>" + e(currency) + '</span></div><div class="widget-legend">' +
      '<span class="widget-expense">• ' + t("支出","Expense") + '</span><span class="widget-income">• ' + t("收入","Income") +
      '</span><span class="widget-saving">• ' + t("积蓄","Saved") + '</span></div><div class="widget-calendar-grid">' + headers + padding + cells + "</div>",footer());
  }
  function netWorth() {
    const currency = state.currency;
    const accounts = state.accounts.filter(account => account.currency === currency && account.includeInNetWorth && !account.archived)
      .sort((a,b) => Math.abs(Number(b.contribution)) - Math.abs(Number(a.contribution))).slice(0,2);
    const worth = Number(state.summary.netWorth);
    const displayed = Math.abs(worth) >= 100000 ? new Intl.NumberFormat(t("zh-CN","en-US"),{
      style:"currency",currency,maximumFractionDigits:0,minimumFractionDigits:0
    }).format(worth) : money(worth,currency);
    return tile("net-worth",'<div class="widget-value" title="' + e(money(worth,currency)) + '">' + displayed + '</div><div class="widget-rows">' +
      (accounts.map(account => '<div class="widget-line"><span>' + icon(account.symbol) + " " + e(account.name) +
        "</span><span>" + money(account.contribution,currency) + "</span></div>").join("") ||
        '<span class="muted">' + t("计入净资产的账户","Accounts included in net worth") + "</span>") + "</div>",footer());
  }
  function expenses() {
    const monthly = state.monthly;
    if (!["ready","readonly"].includes(monthly.status)) return tile("expenses",'<p class="muted">' +
      e(t(monthly.notice,"Fixed-expense data is unavailable. Open Gao Savings to check your library.")) + "</p>");
    const upper = new Date(monthly.today + "T12:00:00Z");
    upper.setUTCDate(upper.getUTCDate() + 30);
    const key = upper.toISOString().slice(0,10);
    const pending = (monthly.bills || []).filter(bill => bill.due <= key);
    const privacy = monthly.preferences?.privacy;
    const items = pending.slice(0,4).map((bill,index) => '<div class="widget-line" data-compact-hide="' + (index >= 2) + '"><div><strong>' +
      (privacy ? t("固定支出待核实","Pending expense") : e(bill.name)) + '</strong><div class="muted">' + e(bill.due) +
      (privacy ? "" : " · " + money(bill.price,bill.currency)) + "</div></div></div>").join("");
    return tile("expenses",'<div class="widget-rows">' + (items || '<p class="muted">' + t("本期无待核实账期","No expenses to verify") + "</p>") +
      moreCount(pending.length,4) + (pending.length ? '<small class="muted">' +
        t("预计账期，确认支付后才记账","Forecasts are recorded only after you verify payment.") + "</small>" : "") +
      "</div>",monthly.updatedAt ? t("资料更新 ","Updated ") + monthly.updatedAt : "");
  }
  function benefits() {
    const monthly = state.monthly;
    if (!["ready","readonly"].includes(monthly.status)) return tile("benefits",'<p class="muted">' +
      e(t(monthly.notice,"Benefit data is unavailable. Open Gao Savings to check your library.")) + "</p>");
    const active = monthly.benefits.filter(benefit => benefit.periodKey);
    const open = active.filter(benefit => !benefit.claimed);
    const privacy = monthly.preferences?.privacy;
    const controls = open.slice(0,4).map((benefit,index) => '<div class="widget-line" data-compact-hide="' + (index >= 2) +
      '"><span>' + (privacy ? t("本期权益","Current benefit") : e(benefit.name)) +
      '</span><button class="ghost widget-claim" type="button" data-benefit="' + e(benefit.id) + '" data-period="' + e(benefit.periodKey) +
      '" data-timezone="' + e(monthly.preferences?.timezone || "") + '" title="' +
      t("标记已领取","Mark claimed") + '" aria-label="' + t("标记已领取","Mark claimed") + '"' + (monthly.status === "ready" ? "" : " disabled") + ">" +
      icon("checkmark") + "</button></div>").join("");
    return tile("benefits",'<div class="widget-rows">' + (controls || '<p class="muted">' + (active.length ?
      t("本期权益均已记录","All benefits recorded") : t("暂无可记录的权益","No benefits to record")) + "</p>") +
      moreCount(open.length,4) + "</div>",monthly.updatedAt ? t("资料更新 ","Updated ") + monthly.updatedAt : "");
  }
  function moreCount(total, defaultLimit) {
    return [defaultLimit,2].filter(limit => total > limit).map(limit =>
      '<small class="muted widget-overflow widget-overflow-' + limit + '">' +
      t("另有 " + (total-limit) + " 项，打开查看",(total-limit) + " more · Open to view") + "</small>"
    ).join("");
  }
  function adventure() {
    return tile("adventure",'<div id="widget-adventure-stage" aria-hidden="true"></div><div id="widget-adventure-detail" class="widget-line"></div>' +
      '<progress class="widget-adventure-hp" max="100" aria-label="' + t("勇者生命","Hero health") + '"></progress>');
  }
  const makers = {calendar,"net-worth":netWorth,expenses,benefits,adventure};
  function updateAdventure(root) {
    const scene = root.querySelector("#widget-adventure-stage");
    const details = root.querySelector("#widget-adventure-detail");
    if (!scene || !state.adventure) return;
    window.renderAdventureObservation?.(scene,state.adventure);
    const game = state.adventure;
    details.textContent = "Lv. " + (game.level ?? state.summary.level) + " · " + t("金币","Gold") + " " + Number(game.coins ?? state.summary.coins ?? 0).toLocaleString() +
      " · " + t("星券","Tickets") + " " + Number(game.tickets ?? state.summary.tickets ?? 0).toLocaleString();
    const health = root.querySelector(".widget-adventure-hp");
    health.value = Math.max(0, Math.min(100, 100 * game.heroHP / (game.heroMaxHP || 1)));
  }
  async function desktopRequest(command, widget, fields = {}) {
    const response = await fetch("/api/desktop/widgets", {
      method:"POST",headers,body:JSON.stringify({command,widget,lease,...fields})
    });
    const json = await response.json();
    if (!response.ok || !json.ok) throw new Error(json.error || t("无法更新桌面窗口","Could not update the desktop widget"));
    return json.result;
  }
  function updateControls(root) {
    for (const button of root.querySelectorAll("[data-window-open]")) {
      const info = desktop.windows[button.dataset.windowOpen];
      button.hidden = !desktop.available;
      button.disabled = !!info?.attaching;
      button.textContent = info?.attaching ? t("正在打开…","Opening…") :
        info?.open ? t("显示桌面窗口","Show window") : t("在桌面打开","Open on desktop");
    }
    for (const link of root.querySelectorAll("[data-window-fallback]")) link.hidden = desktop.available;
    for (const button of root.querySelectorAll("[data-window-pin]")) {
      const info = desktop.windows[button.dataset.windowPin];
      button.hidden = !desktop.currentAttached;
      button.setAttribute("aria-pressed",String(!!info?.pinned));
      button.textContent = info?.pinned ? t("取消置顶","Unpin") : t("置顶","Pin");
    }
    for (const button of root.querySelectorAll("[data-window-close]")) button.hidden = !desktop.currentAttached;
  }
  function refreshWindows(force = false) {
    if (statusTask || (!force && Date.now() - checkedAt < 900)) return;
    checkedAt = Date.now();
    statusTask = desktopRequest("status",gallery).then(result => {
      desktop = result;
      const root = document.getElementById("widgets");
      updateControls(root);
      if (lease) document.title = windowTitle(t("搞积蓄","Gao Savings"),false);
    }).catch(() => {}).finally(() => { statusTask = null; });
  }
  function windowTitle(appName, refresh = true) {
    if (!title[gallery]) return "";
    if (lease && refresh) refreshWindows();
    return appName + " · " + t(...title[gallery]) + (lease && !desktop.currentAttached ? " [GJX:" + lease + "]" : "");
  }
  function connection(healthy) {
    const note = document.getElementById("widget-connection");
    if (note) note.hidden = healthy;
  }
  function activate(event) {
    const native = event.target.closest("[data-window-open],[data-window-pin],[data-window-close],[data-window-route]");
    if (native?.dataset.windowOpen) {
      native.disabled = true;
      desktopRequest("open",native.dataset.windowOpen).catch(showError).finally(() => refreshWindows(true));
      return;
    }
    if (native && desktop.currentAttached) {
      if (native.dataset.windowPin) {
        const kind = native.dataset.windowPin;
        native.disabled = true;
        desktopRequest("pin",kind,{pinned:!desktop.windows[kind]?.pinned}).catch(showError).finally(() => {
          native.disabled = false;
          refreshWindows(true);
        });
      } else if (native.dataset.windowClose) {
        desktopRequest("close",native.dataset.windowClose).catch(showError);
      } else if (native.dataset.windowRoute && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        desktopRequest("route",native.dataset.windowRoute).catch(showError);
      }
      return;
    }
    const claim = event.target.closest("[data-benefit]");
    if (!claim || claim.disabled) return;
    claim.disabled = true;
    api("/api/monthly/claim",{id:claim.dataset.benefit,periodKey:claim.dataset.period,expectedTimezone:claim.dataset.timezone}).catch(error => {
      claim.disabled = false;
      showError(error);
    });
  }
  function render(size) {
    const selected = makers[size] ? [size] : Object.keys(makers);
    const root = document.getElementById("widgets");
    const latest = JSON.stringify([selected,state.financeRevision,state.summary.monthKey,state.currency,state.settings.language,state.monthly]);
    if (latest !== signature || !root.hasChildNodes()) {
      signature = latest;
      root.innerHTML = (gallery ? "" : '<div class="workbench-header"><div><h1>' + t("小组件","Widgets") + '</h1></div></div>') +
        '<p id="widget-connection" class="banner" hidden role="status">' + t("连接中断，显示上次刷新结果。","Disconnected. Showing the last update.") + "</p>" +
        '<div class="widget-grid ' + (selected.length === 1 ? "widget-single" : "") + '">' + selected.map(type => makers[type]()).join("") + "</div>";
      root.onclick = activate;
    }
    updateControls(root);
    refreshWindows();
    updateAdventure(root);
  }
  window.GaoWidgets = {render,windowTitle,connection};
})();
