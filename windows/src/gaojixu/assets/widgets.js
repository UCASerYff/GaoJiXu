(() => {
  const e = escapeHTML;
  const title = {
    calendar:["每日收支与积蓄","Daily cash flow and savings"],
    "net-worth":["净资产","Net worth"], expenses:["固定支出","Fixed expenses"],
    adventure:["勇者冒险","Hero adventure"]
  };
  const destination = {calendar:"ledger","net-worth":"overview",expenses:"fixed-expenses",adventure:"adventure"};
  const candidate = new URLSearchParams(location.search).get("desktop") || "";
  const lease = title[gallery] && /^[a-f0-9]{32}$/.test(candidate) ? candidate : "";
  let desktop = {available:false,windows:{}};
  let statusTask = null;
  let checkedAt = 0;
  let signature = "";
  let selectedDay = "";

  function routeLink(type) {
    const caption = t("在搞积蓄中查看","Open in Gao Savings");
    return '<a class="widget-open" data-window-route="' + type + '" href="/#' + destination[type] + '"' + (gallery ? ' target="_blank" rel="noopener"' : "") +
      ' title="' + caption + '" aria-label="' + caption + '">' + icon("chevron.right") + "</a>";
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
    const symbols = {calendar:"calendar","net-worth":"building.columns.fill",expenses:"repeat",adventure:"map.fill"};
    return '<article class="card widget-tile widget-' + type + '"><div class="widget-title"><h2>' + icon(symbols[type]) + t(...title[type]) + "</h2>" +
      '<div class="widget-window-actions">' + desktopControls(type) + routeLink(type) + "</div></div>" +
      '<div class="widget-body">' + content + '</div>' + (footer ? '<small class="widget-footer">' + e(footer) + "</small>" : "") + "</article>";
  }
  function moneyShort(amount, sign, code) {
    if (!Number(amount)) return "";
    const value = Math.abs(Number(amount));
    const abbreviated = value >= 1000 && value < 10000;
    const suffix = abbreviated ? t("千","k") : "";
    const formatter = new Intl.NumberFormat(t("zh-CN","en-US"),{
      notation: value >= 10000 ? "compact" : "standard", useGrouping:false,
      maximumFractionDigits: value >= 1000 ? 1 : ["JPY","KRW"].includes(code) ? 0 : 2
    });
    return (amount < 0 ? "−" : sign) + formatter.format(abbreviated ? value / 1000 : value) + suffix;
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
    const currentDay = state.today?.startsWith(month) ? state.today : "";
    if (!selectedDay.startsWith(month)) selectedDay = currentDay || month + "-01";
    const cells = state.days.map(day => {
      const key = month + "-" + String(day.day).padStart(2,"0");
      const details = [
        money(day.expense,currency) + " " + t("支出","expense"),
        money(day.income,currency) + " " + t("收入","income"),
        money(day.saving,currency) + " " + t("积蓄","saved")
      ];
      return '<button type="button" class="widget-day" data-calendar-day="' + e(key) + '" aria-pressed="' + String(selectedDay === key) +
        '"' + (key === currentDay ? ' aria-current="date"' : "") + ' aria-label="' + e(key + " · " + details.join(" · ")) +
        '" title="' + e(details.join(" · ")) + '"><b>' + day.day + '</b><span class="widget-expense">' +
        moneyShort(day.expense,"−",currency) + '</span><span class="widget-income">' + moneyShort(day.income,"+",currency) +
        '</span><span class="widget-saving">' + moneyShort(day.saving,"+",currency) + "</span></button>";
    }).join("");
    const monthText = new Intl.DateTimeFormat(t("zh-CN","en-US"),{month:"long",year:"numeric"}).format(new Date(month + "-01T12:00:00"));
    return tile("calendar",'<div class="widget-month"><strong>' + e(monthText) + "</strong><span>" + e(currency) + '</span></div>' +
      '<div class="widget-calendar-grid">' + headers + padding + cells + '</div>' +
      '<div class="widget-calendar-summary" aria-live="polite">' + daySummary() + "</div>",footer());
  }
  function daySummary() {
    const dayNumber = Number(selectedDay.slice(-2));
    const day = state.days.find(item => item.day === dayNumber);
    if (!day) return "";
    const date = new Intl.DateTimeFormat(t("zh-CN","en-US"),{month:"short",day:"numeric"})
      .format(new Date(selectedDay + "T12:00:00"));
    return '<strong>' + e(date) + '</strong><div class="widget-day-totals">' + [
      ["expense",t("支出","Expense"),day.expense,"−"], ["income",t("收入","Income"),day.income,"+"],
      ["saving",t("积蓄","Saved"),day.saving,"+"]
    ].map(([kind,label,amount,positiveSign]) => {
      const sign = amount < 0 ? "−" : amount > 0 ? positiveSign : "";
      return '<span><small>' + label + '</small><b class="widget-' + kind + '">' +
        sign + e(money(Math.abs(amount),state.currency)) + '</b></span>';
    }).join("") + "</div>";
  }
  function netWorth() {
    const currency = state.currency;
    const accounts = state.accounts.filter(account => account.currency === currency && account.includeInNetWorth && !account.archived)
      .sort((a,b) => Math.abs(Number(b.contribution)) - Math.abs(Number(a.contribution)));
    const worth = Number(state.summary.netWorth);
    const displayed = e(money(worth,currency));
    return tile("net-worth",'<div class="widget-worth-total"><small>' + e(currency) + '</small><strong class="widget-value" title="' +
      displayed + '">' + displayed + '</strong></div><div class="widget-rows">' +
      (accounts.slice(0,2).map(account => '<div class="widget-line"><span>' + icon(account.symbol) + " " + e(account.name) +
        '</span><b class="widget-amount">' + e(money(account.contribution,currency)) + "</b></div>").join("") ||
        '<p class="widget-empty">' + t("没有计入的账户","No accounts included") + "</p>") +
      (accounts.length > 2 ? '<small class="widget-overflow">' +
        t(`另有 ${accounts.length - 2} 个账户`,`${accounts.length - 2} more accounts`) + "</small>" : "") + "</div>",footer());
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
      (privacy ? t("固定支出待核实","Pending expense") : e(bill.name)) +
      '</strong><time datetime="' + e(bill.due) + '">' + e(bill.due) + '</time></div>' +
      (privacy ? "" : '<div class="widget-expense-amount"><b class="widget-amount">' + e(money(bill.price,bill.currency)) +
        '</b><small>' + t("预计","Forecast") + "</small></div>") + "</div>").join("");
    return tile("expenses",'<div class="widget-rows">' + (items || '<p class="widget-empty">' + t("本期无待核实账期","No expenses to verify") + "</p>") +
      moreCount(pending.length,4) +
      "</div>",monthly.updatedAt ? t("资料更新 ","Updated ") + monthly.updatedAt : "");
  }
  function moreCount(total, defaultLimit) {
    return [defaultLimit,2].filter(limit => total > limit).map(limit =>
      '<small class="muted widget-overflow widget-overflow-' + limit + '">' +
      t("另有 " + (total-limit) + " 项，打开查看",(total-limit) + " more · Open to view") + "</small>"
    ).join("");
  }
  function adventure() {
    return tile("adventure",'<div id="widget-adventure-stage" aria-hidden="true"></div><div class="widget-adventure-meta">' +
      '<div id="widget-adventure-detail" class="widget-line"><strong></strong><small></small></div>' +
      '<div class="widget-adventure-vitals"><progress class="widget-adventure-hp" max="100" aria-label="' + t("勇者生命","Hero health") +
      '"></progress><small></small></div></div>');
  }
  const makers = {calendar,"net-worth":netWorth,expenses,adventure};
  function updateAdventure(root) {
    const scene = root.querySelector("#widget-adventure-stage");
    const details = root.querySelector("#widget-adventure-detail");
    if (!scene || !state.adventure) return;
    window.renderAdventureObservation?.(scene,state.adventure);
    const game = state.adventure;
    details.querySelector("strong").textContent = t(`第 ${game.stage} 关`,`Stage ${game.stage}`);
    const number = value => Number(value ?? 0).toLocaleString(t("zh-CN","en-US"));
    details.querySelector("small").textContent = `Lv. ${game.level ?? state.summary.level} · ` +
      t("金币","Gold") + " " + number(game.coins ?? state.summary.coins) + " · " +
      t("星券","Tickets") + " " + number(game.tickets ?? state.summary.tickets);
    const health = root.querySelector(".widget-adventure-hp");
    health.value = Math.max(0, Math.min(100, 100 * game.heroHP / (game.heroMaxHP || 1)));
    health.nextElementSibling.textContent = `${number(game.heroHP)} / ${number(game.heroMaxHP)}`;
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
  function actionFeedback(error) {
    const note = document.getElementById("widget-action-error");
    if (note) {
      note.hidden = !error;
      note.textContent = error ? error.message : "";
    }
  }
  function activate(event) {
    const date = event.target.closest("[data-calendar-day]");
    if (date) {
      selectedDay = date.dataset.calendarDay;
      const calendarTile = date.closest(".widget-calendar");
      for (const cell of calendarTile.querySelectorAll("[data-calendar-day]")) {
        cell.setAttribute("aria-pressed",String(cell === date));
      }
      calendarTile.querySelector(".widget-calendar-summary").innerHTML = daySummary();
      return;
    }
    const native = event.target.closest("[data-window-open],[data-window-pin],[data-window-close],[data-window-route]");
    if (native) actionFeedback();
    if (native?.dataset.windowOpen) {
      native.disabled = true;
      desktopRequest("open",native.dataset.windowOpen).catch(actionFeedback).finally(() => refreshWindows(true));
      return;
    }
    if (native && desktop.currentAttached) {
      if (native.dataset.windowPin) {
        const kind = native.dataset.windowPin;
        native.disabled = true;
        desktopRequest("pin",kind,{pinned:!desktop.windows[kind]?.pinned}).catch(actionFeedback).finally(() => {
          native.disabled = false;
          refreshWindows(true);
        });
      } else if (native.dataset.windowClose) {
        desktopRequest("close",native.dataset.windowClose).catch(actionFeedback);
      } else if (native.dataset.windowRoute && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        desktopRequest("route",native.dataset.windowRoute).catch(actionFeedback);
      }
      return;
    }
  }
  function render(size) {
    const selected = makers[size] ? [size] : Object.keys(makers);
    const root = document.getElementById("widgets");
    const latest = JSON.stringify([selected,state.financeRevision,state.summary.monthKey,state.currency,state.settings.language,state.monthly]);
    if (latest !== signature || !root.hasChildNodes()) {
      const previousFocus = root.contains(document.activeElement) ? document.activeElement : null;
      const focusKey = ["data-calendar-day","data-window-pin","data-window-close","data-window-open","data-window-route"]
        .find(key => previousFocus?.hasAttribute(key));
      signature = latest;
      root.innerHTML = (gallery ? "" : '<div class="workbench-header"><div><h1>' + t("小组件","Widgets") + '</h1></div></div>') +
        '<p id="widget-connection" class="banner" hidden role="status">' + t("连接中断，显示上次刷新结果。","Disconnected. Showing the last update.") + "</p>" +
        '<p id="widget-action-error" class="widget-action-error" hidden role="alert"></p>' +
        '<div class="widget-grid ' + (selected.length === 1 ? "widget-single" : "") + '">' + selected.map(type => makers[type]()).join("") + "</div>";
      root.onclick = activate;
      updateControls(root);
      if (focusKey) root.querySelector(`[${focusKey}="${CSS.escape(previousFocus.getAttribute(focusKey))}"]`)?.focus({preventScroll:true});
    }
    updateControls(root);
    refreshWindows();
    updateAdventure(root);
  }
  window.GaoWidgets = {render,windowTitle,connection};
})();
