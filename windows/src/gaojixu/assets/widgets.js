(() => {
  const e = escapeHTML;
  const title = {
    calendar:["每日收支与积蓄","Daily cash flow and savings"],
    "net-worth":["净资产","Net worth"], expenses:["固定支出","Fixed expenses"],
    benefits:["权益打卡","Benefits"], adventure:["勇者冒险","Hero adventure"]
  };
  const destination = {calendar:"ledger","net-worth":"overview",expenses:"fixed-expenses",benefits:"benefits",adventure:"adventure"};
  let signature = "";

  function routeLink(type) {
    return '<a class="widget-open" href="/#' + destination[type] + '"' + (gallery ? ' target="_blank" rel="noopener"' : "") +
      ' aria-label="' + t("打开搞积蓄","Open Gao Savings") + '">' + icon("chevron.right") + "</a>";
  }
  function tile(type, content, footer) {
    return '<article class="card widget-tile widget-' + type + '"><div class="widget-title"><h2>' + t(...title[type]) + "</h2>" +
      routeLink(type) + "</div>" + content + (footer ? '<small class="widget-footer">' + e(footer) + "</small>" : "") + "</article>";
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
    const cells = state.days.map(day => '<div class="widget-day"><b>' + day.day + '</b><div class="widget-expense">' +
      moneyShort(day.expense,"−",currency) + '</div><div class="widget-income">' + moneyShort(day.income,"+",currency) +
      '</div><div class="widget-saving">' + moneyShort(day.saving,"∼",currency) + "</div></div>").join("");
    const monthText = new Intl.DateTimeFormat(t("zh-CN","en-US"),{month:"long",year:"numeric"}).format(new Date(month + "-01T12:00:00"));
    return tile("calendar",'<div class="widget-month"><strong>' + e(monthText) + "</strong><span>" + e(currency) + '</span></div><div class="widget-legend">' +
      '<span class="widget-expense">• ' + t("支出","Expense") + '</span><span class="widget-income">• ' + t("收入","Income") +
      '</span><span class="widget-saving">• ' + t("积蓄","Saved") + '</span></div><div class="widget-calendar-grid">' + headers + padding + cells + "</div>",footer());
  }
  function netWorth() {
    const currency = state.currency;
    const accounts = state.accounts.filter(account => account.currency === currency && account.includeInNetWorth && !account.archived)
      .sort((a,b) => Math.abs(Number(b.contribution)) - Math.abs(Number(a.contribution))).slice(0,2);
    return tile("net-worth",'<div class="widget-value">' + money(state.summary.netWorth,currency) + '</div><div class="widget-rows">' +
      (accounts.map(account => '<div class="widget-line"><span>' + icon(account.symbol) + " " + e(account.name) +
        "</span><span>" + money(account.contribution,currency) + "</span></div>").join("") ||
        '<span class="muted">' + t("计入净资产的账户","Accounts included in net worth") + "</span>") + "</div>",footer());
  }
  function expenses() {
    const monthly = state.monthly;
    if (!["ready","readonly"].includes(monthly.status)) return tile("expenses",'<p class="muted">' + e(monthly.notice) + "</p>");
    const upper = new Date(monthly.today + "T12:00:00Z");
    upper.setUTCDate(upper.getUTCDate() + 30);
    const key = upper.toISOString().slice(0,10);
    const pending = (monthly.bills || []).filter(bill => bill.due <= key);
    const privacy = monthly.preferences?.privacy;
    const items = pending.slice(0,4).map(bill => '<div class="widget-line"><div><strong>' +
      (privacy ? t("固定支出待核实","Pending expense") : e(bill.name)) + '</strong><div class="muted">' + e(bill.due) +
      (privacy ? "" : " · " + money(bill.price,bill.currency)) + "</div></div></div>").join("");
    return tile("expenses",'<div class="widget-rows">' + (items || '<p class="muted">' + t("本期无待核实账期","No expenses to verify") + "</p>") +
      (pending.length > 4 ? '<small class="muted">' + t("打开查看其余 ", "Open to view remaining ") + (pending.length-4) + "</small>" : "") +
      "</div>",monthly.updatedAt ? t("资料更新 ","Updated ") + monthly.updatedAt : "");
  }
  function benefits() {
    const monthly = state.monthly;
    if (!["ready","readonly"].includes(monthly.status)) return tile("benefits",'<p class="muted">' + e(monthly.notice) + "</p>");
    const active = monthly.benefits.filter(benefit => benefit.periodKey);
    const open = active.filter(benefit => !benefit.claimed);
    const privacy = monthly.preferences?.privacy;
    const controls = open.slice(0,4).map(benefit => '<div class="widget-line"><span>' + (privacy ? t("本期权益","Current benefit") : e(benefit.name)) +
      '</span><button class="ghost widget-claim" type="button" data-benefit="' + e(benefit.id) + '" data-period="' + e(benefit.periodKey) + '" title="' +
      t("标记已领取","Mark claimed") + '" aria-label="' + t("标记已领取","Mark claimed") + '"' + (monthly.status === "ready" ? "" : " disabled") + ">" +
      icon("checkmark") + "</button></div>").join("");
    return tile("benefits",'<div class="widget-rows">' + (controls || '<p class="muted">' + (active.length ?
      t("本期权益均已记录","All benefits recorded") : t("暂无可记录的权益","No benefits to record")) + "</p>") +
      "</div>",monthly.updatedAt ? t("资料更新 ","Updated ") + monthly.updatedAt : "");
  }
  function adventure() {
    return tile("adventure",'<div id="widget-adventure-stage"></div><div id="widget-adventure-detail" class="widget-line"></div>');
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
  }
  function render(size) {
    const selected = makers[size] ? [size] : Object.keys(makers);
    const root = document.getElementById("widgets");
    const latest = JSON.stringify([selected,state.financeRevision,state.summary.monthKey,state.currency,state.settings.language,state.monthly]);
    if (latest !== signature || !root.hasChildNodes()) {
      signature = latest;
      root.innerHTML = (gallery ? "" : '<div class="workbench-header"><div><h1>' + t("小组件","Widgets") + '</h1></div></div>') +
        '<div class="widget-grid ' + (selected.length === 1 ? "widget-single" : "") + '">' + selected.map(type => makers[type]()).join("") + "</div>";
      root.onclick = event => {
        const claim = event.target.closest("[data-benefit]");
        if (!claim || claim.disabled) return;
        claim.disabled = true;
        api("/api/monthly/claim",{id:claim.dataset.benefit,periodKey:claim.dataset.period}).catch(error => {
          claim.disabled = false;
          showError(error);
        });
      };
    }
    updateAdventure(root);
  }
  window.GaoWidgets = {render};
})();
