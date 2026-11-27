(() => {
  "use strict";
  const h = escapeHTML;
  const viewOptions = {overview: {}, ledger: {}, budgets: {}, reports: {}, records: {}, analytics: {}};
  const requests = new Map();
  let selectedCalendarDay = "";
  const colors = ["blue", "teal", "green", "orange", "purple", "red"];
  const goalSymbols = [["flag.checkered", "目标", "Goal"], ["airplane", "旅行", "Travel"], ["laptopcomputer", "电脑", "Computer"],
    ["house.fill", "住房", "Home"], ["car.fill", "汽车", "Car"], ["cross.case.fill", "健康", "Health"], ["graduationcap.fill", "学业", "Education"],
    ["gift.fill", "礼物", "Gift"], ["star.fill", "星星", "Star"], ["camera.fill", "相机", "Camera"]];
  const savingsCategories = [["salary", "工资结余", "Pay savings"], ["savedExpense", "少花一笔", "Avoided expense"], ["extraIncome", "额外收入", "Extra income"],
    ["scheduled", "固定储蓄", "Scheduled savings"], ["gift", "红包礼金", "Gift money"], ["other", "其他", "Other"]];
  const ledgerKinds = [["expense", "支出", "Expense"], ["income", "收入", "Income"], ["transfer", "转账", "Transfer"]];
  const recordKinds = [["deposit", "存入", "Deposit"], ["withdrawal", "取出", "Withdrawal"]];
  const goalStates = [["active", "进行中", "Active"], ["paused", "已暂停", "Paused"], ["completed", "已完成", "Completed"], ["archived", "已归档", "Archived"]];
  const ruleFrequencies = [["daily", "每天", "Daily"], ["weekly", "每周", "Weekly"], ["monthly", "每月", "Monthly"], ["yearly", "每年", "Yearly"]];
  const categoryInfo = {
    food: ["Dining", "fork.knife", "orange"], groceries: ["Shopping", "cart.fill", "teal"], housing: ["Housing", "house.fill", "blue"],
    transport: ["Transport", "car.fill", "blue"], utilities: ["Utilities", "bolt.fill", "purple"], health: ["Health", "cross.case.fill", "red"],
    education: ["Education", "graduationcap.fill", "teal"], entertainment: ["Entertainment", "gamecontroller.fill", "purple"], family: ["Family & gifts", "gift.fill", "orange"],
    subscription: ["Subscriptions", "repeat", "teal"], pet: ["Pets", "pawprint.fill", "green"], "other-expense": ["Other expenses", "ellipsis.circle", "blue"],
    "salary-income": ["Salary", "banknote.fill", "green"], "bonus-income": ["Bonus", "star.fill", "orange"], "side-income": ["Side income", "briefcase.fill", "teal"],
    "investment-income": ["Investment income", "chart.line.uptrend.xyaxis", "blue"], "gift-income": ["Gift money", "gift.fill", "red"],
    "other-income": ["Other income", "ellipsis.circle", "purple"], "account-transfer": ["Account transfer", "arrow.left.arrow.right", "blue"],
    "savings-goal-transfer": ["Savings transfer", "target", "purple"], "balance-adjustment": ["Balance adjustment", "slider.horizontal.3", "blue"]
  };
  const accountEnglish = {cash: "Cash", bank: "Bank", ewallet: "Digital wallet", credit: "Credit", investment: "Investment", other: "Other"};
  const activeAccounts = () => (state.accounts || []).filter(account => !account.archived);
  const accountByID = id => state.accounts?.find(account => account.id === id);
  const categoryByID = id => state.categories?.find(category => category.id === id);
  const categoryName = (id, fallback) => id === "balance-adjustment" ? t("余额调整", "Balance adjustment") : t(categoryByID(id)?.name || fallback || "—", categoryInfo[id]?.[0] || fallback || "—");
  const accountType = id => t(state.accountTypes.find(item => item.id === id)?.name || id, accountEnglish[id] || id);
  const enumTitle = (values, id) => {const option = values.find(row => row[0] === id); return option ? t(option[1], option[2]) : id || "—";};
  const colorKey = color => colors.includes(color) ? color : "blue";
  const accountLabel = account => `${account.name} · ${account.currency}`;
  const moneySigned = (value, currency) => `${value > 0 ? "+" : ""}${money(value, currency)}`;
  const today = () => state.today || localDate(new Date());
  const dateInput = value => String(value || "").slice(0, 10);
  function localDate(date) {
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  }
  function offsetDay(value, offset) {
    const date = new Date(`${dateInput(value)}T12:00:00`);
    date.setDate(date.getDate() + offset);
    return localDate(date);
  }
  function offsetMonth(value, offset) {
    const [year, month] = value.split("-").map(Number);
    return localDate(new Date(year, month - 1 + offset, 1)).slice(0, 7);
  }
  function monthLabel(month, long = false) {
    const date = new Date(`${month}-01T12:00:00`);
    return new Intl.DateTimeFormat(t("zh-CN", "en-US"), long ? {month:"long", year:"numeric"} : {month:"short"}).format(date);
  }
  function options(rows, selected, empty) {
    return (empty === undefined ? "" : `<option value="">${h(empty)}</option>`) + rows.map(([id, name]) => `<option value="${h(id)}"${id === selected ? " selected" : ""}>${h(name)}</option>`).join("");
  }
  const localizedOptions = (rows, value) => options(rows.map(([id, zh, en]) => [id, t(zh, en)]), value);
  const accountOptions = (rows, value, empty = t("请选择", "Choose an account")) => options(rows.map(account => [account.id, accountLabel(account)]), value, empty);
  const currencyOptions = (value, compact = false) => options(state.currencies.map(item => [item.id, compact ? item.id : `${t(item.name, item.id)} · ${item.id}`]), value);
  const input = (name, value = "", attributes = "") => `<input name="${h(name)}" value="${h(value)}" ${attributes}>`;
  const select = (name, body, attributes = "") => `<select name="${h(name)}" ${attributes}>${body}</select>`;
  const field = (label, body, type = "") => `<label class="finance-field ${type}"><span>${h(label)}</span>${body}</label>`;
  const formSection = (title, body, classes = "") => `<section class="finance-form-section ${classes}"><h3>${h(title)}</h3>${body}</section>`;
  const action = (id, label, symbol = "", css = "ghost", value = "") => `<button type="button" class="${css}" data-finance="${id}"${value !== "" ? ` data-value="${h(value)}"` : ""}>${symbol ? icon(symbol) : ""}${h(label)}</button>`;
  const link = (route, name = t("查看", "View")) => action("go", name, "", "ghost finance-link", route);
  const empty = (title, detail = "", symbol = "target", extra = "") => `<div class="finance-empty">${icon(symbol)}<strong>${h(title)}</strong>${detail ? `<span>${h(detail)}</span>` : ""}${extra}</div>`;
  const heading = (title, subtitle = "", accessory = "") => `<div class="workbench-header finance-heading"><div><h1>${h(title)}</h1>${subtitle ? `<p>${h(subtitle)}</p>` : ""}</div>${accessory ? `<div class="finance-tools">${accessory}</div>` : ""}</div>`;
  const tile = (label, value, symbol, color) => `<div class="card finance-tile tone-${colorKey(color)}"><span class="finance-icon">${icon(symbol)}</span><div><small>${h(label)}</small><strong>${h(value)}</strong></div></div>`;
  const tiles = content => `<div class="finance-tiles">${content}</div>`;
  const panel = (title, symbol, content, accessory = "", extra = "") => `<article class="card finance-panel ${extra}"><div class="finance-panel-title"><h2>${symbol ? icon(symbol) : ""}${h(title)}</h2>${accessory}</div>${content}</article>`;
  const progress = (value, color = "blue") => `<progress class="tone-${colorKey(color)}" max="1" value="${Math.max(0, Math.min(1, value || 0))}"></progress>`;
  const badge = (text, color = "blue") => `<span class="pill finance-badge tone-${colorKey(color)}">${h(text)}</span>`;
  const labelForDay = day => day === today() ? t(`今天 · ${day}`, `Today · ${day}`) : day === offsetDay(today(), -1) ? t(`昨天 · ${day}`, `Yesterday · ${day}`) : day;
  const currencyPicker = (view, compact = false) => select("finance-currency", currencyOptions(viewOptions[view].currency || state.currency, compact), `aria-label="${h(t("统计币种", "Currency"))}"`);
  const switchCurrency = (root, view) => root.querySelector('[name="finance-currency"]')?.addEventListener("change", event => {
    viewOptions[view].currency = event.target.value;
    render(view);
    root.querySelector('[name="finance-currency"]')?.focus({preventScroll:true});
  });

  async function readView(root, view, apply) {
    const parameters = new URLSearchParams({route: view, currency: state.currency, ...viewOptions[view]});
    const key = `${state.financeRevision || ""}:${state.today || ""}:${parameters}`;
    const ticket = {};
    root.financeTicket = ticket;
    try {
      if (!requests.has(key)) {
        const pending = get(`/api/finance/view?${parameters}`).catch(error => {requests.delete(key); throw error;});
        requests.set(key, pending);
        if (requests.size > 40) requests.delete(requests.keys().next().value);
      }
      const result = await requests.get(key);
      if (root.financeTicket === ticket && !root.hidden) apply(result);
    } catch (error) {
      if (root.financeTicket === ticket && !root.hidden) apply(null, error);
    }
  }
  const loading = () => `<div class="card finance-loading" role="status"><span aria-hidden="true"></span>${t("正在读取本地账目…", "Reading local records…")}</div>`;
  const viewFailure = error => `<div class="card finance-failed" role="status">${empty(t("无法读取数据", "Could not load data"), error?.message,
    "exclamationmark.triangle",action("retry",t("重试","Retry"),"","ghost"))}</div>`;

  const calendarDate = (month, day) => `${month}-${String(day).padStart(2, "0")}`;
  const calendarMovements = [
    ["income", "收入", "Income", "green", "+"],
    ["expense", "支出", "Expense", "red", "−"],
    ["saving", "积蓄", "Savings", "teal", ""]
  ];

  function movementAmount(value, currency, positive) {
    const sign = value < 0 ? "−" : Math.abs(value) < 0.001 ? "" : positive;
    return sign + money(Math.abs(value), currency);
  }

  function calendarDaySummary(model, currency) {
    const values = model.days.find(row => calendarDate(model.calendarMonth, row.day) === selectedCalendarDay);
    return `<div class="finance-calendar-selected-date"><strong>${h(labelForDay(selectedCalendarDay))}</strong>
      ${action("calendar-ledger", t("查看当天流水", "Transactions on this date"), "list.bullet", "ghost finance-calendar-link")}</div>
      <div class="finance-calendar-day-totals">${calendarMovements.map(([key, zh, en, color, sign]) =>
        `<div><span>${t(zh,en)}</span><strong class="finance-movement tone-${color}">${h(movementAmount(values?.[key] ?? 0,currency,sign))}</strong></div>`).join("")}</div>`;
  }

  function financeCalendar(model, currency) {
    const month = model.calendarMonth;
    const weekdays = t(["周日", "周一", "周二", "周三", "周四", "周五", "周六"], ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]);
    const firstDay = new Date(`${month}-01T12:00:00`).getDay();
    const dayLabels = new Intl.DateTimeFormat(t("zh-CN","en-US"), {dateStyle:"full"});
    const smallAmount = new Intl.NumberFormat(t("zh-CN","en-US"), {maximumFractionDigits:["JPY","KRW","VND"].includes(currency) ? 0 : 2});
    const compactAmount = new Intl.NumberFormat(t("zh-CN","en-US"), {notation:"compact", maximumFractionDigits:1});
    const direction = [
      ["calendar-prev", "chevron.left", t("上个月", "Previous month")],
      ["calendar-next", "chevron.right", t("下个月", "Next month")]
    ];
    const steps = direction.map(([id,symbol,label]) => `<button class="ghost finance-calendar-step" type="button" aria-label="${h(label)}" title="${h(label)}" data-finance="${id}">${icon(symbol)}</button>`);
    return `<div class="finance-calendar-header"><h2>${t("收支月历", "Cash flow calendar")}</h2><div class="finance-calendar-controls">
      ${steps[0]}<strong class="finance-calendar-month">${h(monthLabel(month,true))}</strong>${steps[1]}
      ${action("calendar-today",t("今天","Today"),"","ghost finance-calendar-today")}</div></div>
      <div class="finance-calendar-calendar" role="group" aria-label="${h(t("选择日期","Choose a date"))}">${weekdays.map(day =>
        `<span class="finance-calendar-weekday" aria-hidden="true">${h(day)}</span>`).join("")}${'<span aria-hidden="true"></span>'.repeat(firstDay)}${model.days.map(day => {
      const date = calendarDate(month,day.day);
      const active = date === selectedCalendarDay;
      const amountLabel = calendarMovements.map(([key,zh,en,,sign]) => `${t(zh,en)} ${movementAmount(day[key],currency,sign)}`).join(" · ");
      const label = `${dayLabels.format(new Date(`${date}T12:00:00`))} · ${amountLabel}`;
      return `<button class="finance-calendar-day${date === model.date ? " is-today" : ""}${date > model.date ? " is-future" : ""}" type="button" data-finance="calendar-day" data-value="${h(date)}"
        aria-label="${h(label)}" title="${h(label)}" aria-pressed="${active}" tabindex="${active ? 0 : -1}"${date === model.date ? ' aria-current="date"' : ""}>
        <span class="finance-calendar-number">${day.day}</span><span class="finance-calendar-activity" aria-hidden="true">${calendarMovements.map(([key,,,color,sign]) => {
          const number = day[key];
          if (!number) return "";
          const format = Math.abs(number) >= 10000 ? compactAmount : smallAmount;
          return `<span class="finance-calendar-mark tone-${color}"><i></i><span>${h((number < 0 ? "−" : sign) + format.format(Math.abs(number)))}</span></span>`;
        }).join("")}</span></button>`;
    }).join("")}</div><div class="finance-calendar-selection" data-calendar-selection>${calendarDaySummary(model,currency)}</div>`;
  }

  function selectCalendarDay(root, model, currency, date, focus = false) {
    const next = root.querySelector(`[data-finance="calendar-day"][data-value="${date}"]`);
    if (!next) return;
    const current = root.querySelector('[data-finance="calendar-day"][aria-pressed="true"]');
    if (current) {current.setAttribute("aria-pressed","false"); current.tabIndex = -1;}
    selectedCalendarDay = date;
    next.setAttribute("aria-pressed","true");
    next.tabIndex = 0;
    root.querySelector("[data-calendar-selection]").innerHTML = calendarDaySummary(model,currency);
    if (focus) next.focus({preventScroll:true});
  }

  function rootActions(root, handlers) {
    root.onclick = event => {
      const button = event.target.closest("[data-finance]");
      if (!button || !root.contains(button) || button.disabled) return;
      if (button.dataset.finance === "go") {navigate(button.dataset.value); return;}
      if (button.dataset.finance === "retry") {render(root.id); return;}
      const handler = handlers[button.dataset.finance];
      if (handler) Promise.resolve().then(() => handler(button.dataset.value, button)).catch(showError);
    };
  }

  function overviewSummary(model, currency) {
    return `<article class="card finance-summary">
      <div class="finance-summary-primary"><span>${t("净资产", "Net worth")}</span><strong>${h(money(model.netWorth,currency))}</strong></div>
      <dl class="finance-summary-metrics">
        <div><dt>${t("本月收入", "Income this month")}</dt><dd class="finance-movement tone-green">${h(movementAmount(model.income,currency,"+"))}</dd></div>
        <div><dt>${t("本月支出", "Expenses this month")}</dt><dd class="finance-movement tone-red">${h(movementAmount(model.expense,currency,"−"))}</dd></div>
        <div><dt>${t("已分配积蓄", "Allocated savings")}</dt><dd>${h(money(model.allocated,currency))}</dd></div>
      </dl></article>`;
  }

  function overviewBudget(model,currency) {
    if (!model.budget) return `<div class="finance-brief"><span class="muted">${t("本月尚未设置额度", "No budget set for this month")}</span>${link("budgets",t("设置预算","Set a budget"))}</div>`;
    const remaining = model.budget - model.expense;
    const color = remaining < 0 ? "red" : "teal";
    return `<div class="finance-brief"><span class="muted">${remaining < 0 ? t("超出预算","Over budget") : t("剩余额度","Available")}</span>
      <strong class="finance-movement tone-${color}">${h(money(Math.abs(remaining),currency))}</strong></div>
      ${progress(model.expense/model.budget,color)}<div class="finance-brief muted"><span>${t("已使用", "Spent")} ${h(money(model.expense,currency))}</span><span>${t("预算", "Budget")} ${h(money(model.budget,currency))}</span></div>`;
  }

  function renderOverview(root, focus = "") {
    root.innerHTML = heading(t("财务总览", "Financial overview"), "", currencyPicker("overview", true)) +
      '<div data-finance-result class="finance-stack">' + loading() + '</div>';
    switchCurrency(root, "overview");
    readView(root, "overview", (model, error) => {
      const output = root.querySelector("[data-finance-result]");
      if (!model) {output.innerHTML = viewFailure(error); return;}
      const currency = viewOptions.overview.currency || state.currency;
      const worthAccounts = activeAccounts().filter(account => account.currency === currency && account.includeInNetWorth).sort((a,b) => b.contribution - a.contribution);
      const goal = activeGoals().find(item => item.currency === currency);
      const reward = state.adventure;
      const month = model.calendarMonth;
      if (!selectedCalendarDay.startsWith(month + "-")) selectedCalendarDay = model.date.startsWith(month + "-") ? model.date : month + "-01";

      const budget = panel(t("本月预算", "Monthly budget"), "", overviewBudget(model,currency), model.budget ? link("budgets",t("预算明细","Budget details")) : "");
      const accounts = panel(t("账户余额", "Account balances"), "", worthAccounts.length ? worthAccounts.slice(0,4).map(account => `<div class="finance-account-mini"><span class="finance-icon tone-${colorKey(account.colorKey)}">${icon(account.symbol)}</span><strong>${h(account.name)}</strong><span class="finance-number">${h(money(account.contribution,currency))}</span></div>`).join("") :
        `<p class="muted">${t("当前币种没有计入净资产的账户。", "No accounts are included in net worth for this currency.")}</p>`, link("accounts",t("账户管理","Manage accounts")));
      const goalSummary = panel(t("攒钱进度", "Savings progress"), "", goal ? `<div class="finance-brief"><strong>${h(goal.title)}</strong><strong class="finance-number">${Math.trunc(goal.progress*100)}%</strong></div>${progress(goal.progress,goal.colorKey)}
        <div class="finance-brief muted"><span>${h(money(goal.balance,goal.currency))}</span><span>${h(money(goal.targetAmount,goal.currency))}</span></div>` :
        `<p class="muted">${t("当前币种没有进行中的目标。", "No active savings goals in this currency.")}</p>`, link("goals",t("攒钱目标","Savings goals")));
      const adventure = reward ? panel(t("勇者冒险", "Hero adventure"), "", `<div class="finance-adventure-scene" data-adventure-observation></div><div class="finance-adventure"><div><strong>${h(t(`等级 ${reward.level} · ${reward.monster || ""}`, `Level ${reward.level} · ${reward.english?.monster || reward.monster || ""}`))}</strong><small class="muted">${h(t(`金币 ${state.summary.coins || 0} · 星券 ${state.summary.tickets || 0}`, `${state.summary.coins || 0} coins · ${state.summary.tickets || 0} tickets`))}</small></div></div>`,
        link("adventure",t("打开冒险","Open adventure")), "finance-observation") : "";
      const recent = panel(t("最近流水", "Recent transactions"), "", model.recent.length ?
        `<div class="finance-recent-list">${model.recent.map(row => ledgerRow(row,true)).join("")}</div>` :
        empty(t("还没有流水", "No transactions yet"), "", "square.and.pencil", action("overview-record",t("记一笔账", "New transaction"),"plus","ghost")), link("ledger",t("全部流水","All transactions")), "finance-recent");
      output.innerHTML = overviewSummary(model,currency) + (window.GaoFixed?.pending?.() || "") +
        `<div class="finance-overview-grid"><div class="finance-overview-main">
          <article class="card finance-panel finance-calendar-card">${financeCalendar(model,currency)}</article>${recent}</div>
          <aside class="finance-overview-side" aria-label="${t("财务概况", "Financial details")}">${budget}${accounts}${goalSummary}${adventure}</aside></div>` +
        (window.GaoFixed?.reconciliation?.() || "");
      window.GaoFixed?.bindReconciliation?.(output);
      const observation = output.querySelector("[data-adventure-observation]");
      if (observation && reward) window.renderAdventureObservation?.(observation, reward);

      const showMonth = (next, focus) => {
        viewOptions.overview.calendarMonth = next;
        if (next === model.date.slice(0,7)) selectedCalendarDay = model.date;
        renderOverview(root,focus);
      };
      rootActions(root,{
        "calendar-day": date => selectCalendarDay(root,model,currency,date),
        "calendar-prev": () => showMonth(offsetMonth(month,-1),"calendar-prev"),
        "calendar-next": () => showMonth(offsetMonth(month,1),"calendar-next"),
        "calendar-today": () => showMonth(model.date.slice(0,7),"calendar-today"),
        "calendar-ledger": () => {
          Object.assign(viewOptions.ledger,{day:selectedCalendarDay,q:"",kind:"",page:0});
          navigate("ledger");
        },
        "overview-record": () => openLedger(),
        "overview-transaction": id => showLedger(model.recent.find(row => row.id === id))
      });
      root.onkeydown = event => {
        if (!event.target.matches('[data-finance="calendar-day"]') || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
        const offsets = {ArrowLeft:-1,ArrowRight:1,ArrowUp:-7,ArrowDown:7};
        const offset = offsets[event.key];
        if (offset === undefined) return;
        event.preventDefault();
        selectCalendarDay(root,model,currency,offsetDay(event.target.dataset.value,offset),true);
      };
      if (focus) root.querySelector(`[data-finance="${focus}"]`)?.focus({preventScroll:true});
    });
    rootActions(root,{});
  }

  function filters(items, current, allLabel) {
    return `<div class="segmented finance-filters" role="group" aria-label="${t("类型", "Type")}">${[["", allLabel, allLabel], ...items].map(([id, zh, en]) =>
      `<button type="button" class="${id === current ? "active" : ""}" data-finance="filter" data-value="${id}" aria-pressed="${id === current}">${h(t(zh,en))}</button>`).join("")}</div>`;
  }
  function pager(model) {
    const pages = Math.ceil(model.total / 100);
    if (pages <= 1) return "";
    return `<div class="finance-pager" role="group" aria-label="${t("翻页", "Pagination")}"><button type="button" class="ghost" data-finance="page" data-value="${model.page-1}"${model.page === 0 ? " disabled" : ""}>‹ ${t("上一页", "Previous")}</button><span>${h(t(`第 ${model.page+1} / ${pages} 页`, `Page ${model.page+1} of ${pages}`))}</span><button type="button" class="ghost" data-finance="page" data-value="${model.page+1}"${model.page+1 === pages ? " disabled" : ""}>${t("下一页", "Next")} ›</button></div>`;
  }
  function groupDays(rows, renderRow) {
    const groups = new Map();
    for (const row of rows) {
      const day = dateInput(row.date);
      if (!groups.has(day)) groups.set(day, []);
      groups.get(day).push(row);
    }
    return Array.from(groups, ([date, items]) => `<details class="finance-day-group" open>
      <summary><time datetime="${h(date)}">${h(labelForDay(date))}</time><span>${h(t(`${items.length} 笔`, `${items.length} entries`))}</span>${icon("chevron.down")}</summary>
      <div class="finance-day-rows">${items.map(row => renderRow(row)).join("")}</div>
    </details>`).join("");
  }
  function rowMenu(items) {
    return `<details class="finance-menu"><summary aria-label="${t("操作", "Actions")}" title="${t("操作", "Actions")}">${icon("ellipsis.circle")}</summary><div class="card finance-menu-popup">${items}</div></details>`;
  }
  function historyCells(symbol, color, title, note, account, time, amount, amountColor, status = "") {
    return `<span class="finance-icon tone-${color}">${icon(symbol)}</span><span class="finance-row-text">
      <strong>${h(title)}</strong>${note ? `<small>${h(note)}</small>` : ""}${status}
      <small class="finance-row-secondary">${h([account,time].filter(Boolean).join(" · "))}</small></span>
      <span class="finance-row-account" title="${h(account)}">${h(account)}</span>
      <time class="finance-row-time">${h(time)}</time>
      <span class="finance-row-amount tone-${amountColor}">${h(amount)}</span>`;
  }

  function ledgerRow(row, compact = false) {
    const title = categoryName(row.categoryID,row.categoryName);
    const editable = !row.balanceAdjustment && !row.savings;
    const accountPath = row.kind === "transfer" ? `${row.accountName} → ${row.targetAccountName || t("已归档账户", "Archived account")}` : row.accountName;
    const [,,color] = categoryInfo[row.categoryID] || ["", "tag", "blue"];
    const sign = row.kind === "expense" ? "−" : row.kind === "income" ? "+" : "";
    const cross = row.kind === "transfer" && row.targetCurrency && row.targetCurrency !== row.currency;
    const amount = `${sign}${money(row.amount, row.currency)}${cross ? ` → ${money(row.targetAmount,row.targetCurrency)}` : ""}`;
    const tone = row.kind === "income" ? "green" : row.kind === "expense" ? "red" : "blue";
    const managed = row.balanceAdjustment ? `<span class="finance-row-status">${t("余额调整", "Balance adjustment")}</span>` :
      row.savings ? `<span class="finance-row-status">${t("积蓄转账", "Savings transfer")}</span>` : "";
    const timestamp = row.date ? row.date.slice(compact ? 5 : 11,16) : "";
    const cells = historyCells(categoryInfo[row.categoryID]?.[1] || "tag",color,title,row.note,accountPath,timestamp,amount,tone,managed);
    if (compact) return `<div class="finance-list-row compact"><button class="finance-row-main" type="button" data-finance="overview-transaction" data-value="${h(row.id)}">${cells}</button></div>`;
    return `<div class="finance-list-row finance-editable" data-row="${h(row.id)}"><button type="button" class="finance-row-main" data-finance="edit-ledger" data-value="${h(row.id)}">${cells}</button>${rowMenu(action("edit-ledger", editable ? t("编辑", "Edit") : t("查看说明", "Details"), "", "ghost", row.id) + (editable ? action("delete-ledger", t("删除", "Delete"), "trash", "ghost tone-red", row.id) : ""))}</div>`;
  }

  function showLedger(row) {
    if (!row) return;
    if (row.balanceAdjustment) openEditor({title:t("余额调整", "Balance adjustment"),body:`<p>${t("请在资产账户中通过再次修改余额更正。", "To correct this transaction, adjust the balance in Accounts.")}</p>`});
    else if (row.savings) openEditor({title:t("积蓄转账", "Savings transfer"),body:`<p>${t("这笔转账由积蓄计划管理，请在积蓄记录中编辑。", "This transfer is managed in Savings Records.")}</p>`});
    else openLedger(row);
  }

  function historySummary(model,isLedger) {
    const count = t(`${model.total} 笔`, `${model.total} entries`);
    const subtotals = Object.entries(model.subtotals);
    return `<div class="finance-history-summary"><span data-count>${h(count)}</span>${isLedger && subtotals.length ? `<div class="finance-history-totals">${subtotals.map(([currency,values]) =>
      `<span><strong>${h(currency)}</strong><span class="finance-movement tone-green">${h(t("收入", "Income")+" "+movementAmount(values.income,currency,"+"))}</span><span class="finance-movement tone-red">${h(t("支出", "Expenses")+" "+movementAmount(values.expense,currency,"−"))}</span></span>`).join("")}</div>` : ""}</div>`;
  }

  function renderHistory(root, type) {
    const choice = viewOptions[type];
    const isLedger = type === "ledger";
    const dateLabel = t("按日期筛选", "Filter by date");
    const controls = isLedger ? action("csv-review",t("导入审核箱","Import inbox"),"tray.full.fill") + action("rules",t("周期记账","Recurring rules"),"repeat") + action("new-ledger",t("记此日","Record on this date"),"plus","") :
      action("new-record",t("记一笔积蓄","New savings record"),"plus","");
    const searchField = isLedger ? `<label class="finance-search">${icon("magnifyingglass")}${input("ledger-query", choice.q || "",
      `type="search" placeholder="${h(t("搜索备注、分类、账户或金额", "Search notes, categories, accounts or amounts"))}" aria-label="${h(t("搜索流水", "Search transactions"))}"`)}</label>` : "";
    root.innerHTML = heading(isLedger ? t("流水", "Transactions") : t("积蓄记录", "Savings records"), "", controls) +
      `<div class="card finance-history-toolbar"><div class="finance-history-filters">
      ${filters(isLedger ? ledgerKinds : recordKinds,choice.kind || "",isLedger ? t("全部", "All") : t("全部记录", "All records"))}
      <div class="finance-history-inputs">${searchField}<div class="finance-history-date">${input("history-day",choice.day || "",`type="date" aria-label="${h(dateLabel)}" title="${h(dateLabel)}"`)}
      ${action("clear-day",t("清除日期", "Clear date"),"","ghost finance-clear-day")}</div></div></div></div>
      <div data-finance-result aria-live="polite">${loading()}</div>`;
    let current = [];
    const output = root.querySelector("[data-finance-result]");
    const search = root.querySelector("[name=ledger-query]");
    const date = root.querySelector("[name=history-day]");
    const clear = root.querySelector("[data-finance=clear-day]");
    const recordDate = root.querySelector(".finance-heading [data-finance=new-ledger]");
    function refreshHistory() {
      root.querySelectorAll("[data-finance=filter]").forEach(button => {
        const selected = (button.dataset.value || "") === (choice.kind || "");
        button.classList.toggle("active",selected);
        button.setAttribute("aria-pressed",selected);
      });
      clear.hidden = !choice.day;
      if (recordDate) recordDate.hidden = !choice.day;
      output.setAttribute("aria-busy","true");
      readView(root,type,(model,error) => {
        output.removeAttribute("aria-busy");
        if (!model) {output.innerHTML = viewFailure(error); return;}
        choice.page = model.page;
        current = model.items;
        const emptyResults = choice.q || choice.kind || choice.day ?
          empty(t("没有符合条件的记录", "No matching records"), "", "magnifyingglass",action("clear-history",t("清除筛选", "Clear filters"),"","ghost")) :
          isLedger ? empty(t("还没有流水", "No transactions yet"), "", "square.and.pencil",action("new-ledger",t("记一笔账", "New transaction"),"plus","")) :
          empty(t("还没有积蓄记录", "No savings records yet"), "", "list.bullet.rectangle",action("new-record",t("记录第一笔", "Make your first record"),"plus",""));
        const table = current.length ? `<div class="card finance-history-table"><div class="finance-history-columns" aria-hidden="true">
          <span>${isLedger ? t("分类和备注","Category and note") : t("目标和备注","Goal and note")}</span><span>${t("账户","Account")}</span><span>${t("时间","Time")}</span><span>${t("金额","Amount")}</span></div>
          ${groupDays(current, isLedger ? ledgerRow : recordRow)}</div>` : `<div class="card finance-history-table">${emptyResults}</div>`;
        output.innerHTML = historySummary(model,isLedger) + table + pager(model);
      });
    }
    let searchTimer;
    if (search) search.oninput = () => {
      clearTimeout(searchTimer);
      choice.q = search.value;
      choice.page = 0;
      searchTimer = setTimeout(() => {if (search.isConnected && !root.hidden) refreshHistory();}, 170);
    };
    date.onchange = () => {choice.day = date.value; choice.page = 0; refreshHistory();};
    const find = id => current.find(item => item.id === id);
    rootActions(root, {
      filter: value => {choice.kind = value || ""; choice.page = 0; refreshHistory();},
      page: value => {choice.page = Number(value); refreshHistory();},
      "clear-day": () => {date.value = ""; choice.day = ""; choice.page = 0; refreshHistory(); date.focus();},
      "clear-history": () => {
        if (search) search.value = "";
        date.value = "";
        Object.assign(choice,{q:"",day:"",kind:"",page:0});
        refreshHistory();
      },
      "csv-review": () => window.GaoCSVReview.open(),
      rules: openRules, "new-ledger": () => openLedger(undefined,{date:choice.day || undefined}), "new-record": () => openRecord(undefined,{date:choice.day || undefined}),
      "edit-ledger": id => showLedger(find(id)),
      "delete-ledger": id => confirmAction(t("删除这笔账？", "Delete this transaction?"), t("本次操作会移除所选流水。", "This removes the selected transaction."), () => api("/api/ledger/delete",{id})),
      "edit-record": id => {const row = find(id); if (row) openRecord(row);},
      "delete-record": id => confirmAction(t("删除这条记录？", "Delete this record?"),t("记录会从目标和统计中移除；已经获得的游戏成长不会被扣除。", "The record will be removed from the goal and statistics. Earned game progress is retained."), () => api("/api/records/delete",{id}))
    });
    root.oncontextmenu = event => {
      const row = event.target.closest("[data-row]");
      if (!row) return;
      event.preventDefault();
      const menu = row.querySelector("details");
      if (menu) menu.open = !menu.open;
    };
    refreshHistory();
  }

  function confirmAction(title, detail, onSubmit) {
    openEditor({title, body: `<p>${h(detail)}</p>`, submitLabel:t("确认", "Confirm"), onSubmit, width: 440});
  }
  const formPayload = form => Object.fromEntries(new FormData(form));
  function amountPreview(value) {
    const text = String(value).replaceAll(" ", "").replace(/[×÷−]/g, key => ({"×":"*","÷":"/","−":"-"}[key]));
    if (!text || text.length > 120) return null;
    const numberPattern = /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)/y;
    let index = 0;
    function atom() {
      numberPattern.lastIndex = index;
      const match = numberPattern.exec(text);
      if (!match || match[0].replace(/\D/g, "").length > 16) return NaN;
      index = numberPattern.lastIndex;
      return Number(match[0]);
    }
    function term() {
      let total = atom();
      while (text[index] === "*" || text[index] === "/") {
        const operator = text[index++];
        const next = atom();
        if (!Number.isFinite(next)) return NaN;
        total = operator === "*" ? total * next : total / next;
      }
      return total;
    }
    let total = term();
    while (index < text.length && Number.isFinite(total)) {
      const operator = text[index++];
      if (operator !== "+" && operator !== "-") return null;
      const next = term();
      total = operator === "+" ? total + next : total - next;
    }
    if (!Number.isFinite(total) || Math.abs(total) > 999999999999.99) return null;
    return Math.sign(total) * Math.round((Math.abs(total)+Number.EPSILON)*100)/100;
  }

  function openLedger(entry, defaults = {}) {
    const accounts = activeAccounts();
    const kind = entry?.kind || defaults.kind || "expense";
    const category = {};
    if (entry?.categoryID) category[kind] = entry.categoryID;
    const source = entry?.accountID || defaults.accountID || state.lastLedgerAccountID || accounts[0]?.id;
    const editDay = dateInput(entry?.date) || defaults.date || today();
    const data = form => {
      const payload = formPayload(form);
      if (entry) payload.id = entry.id;
      if (entry && payload.date === editDay) payload.date = entry.timestamp ?? entry.date;
      else if (payload.date === today()) delete payload.date;
      return payload;
    };
    let evaluated = false;
    const keypad = ["C", "⌫", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "−", "1", "2", "3", "+", "00", "0", ".", "="];
    const kindControl = `<div class="finance-radio-segments">${ledgerKinds.map(([id,zh,en]) => `<label><input type="radio" name="kind" value="${id}"${id===kind ? " checked" : ""}>${h(t(zh,en))}</label>`).join("")}</div>`;
    openEditor({title:entry ? t("编辑流水", "Edit transaction") : t("记一笔账", "New transaction"), width:740,
      body: `<div class="finance-ledger-editor"><div class="finance-ledger-amount">${formSection(t("类型与金额", "Type and amount"),kindControl +
        field(t("金额（可输入算式）", "Amount or expression"),input("amountExpression",entry?.amount ?? "",'class="finance-amount-input" inputmode="decimal" maxlength="120" required autocomplete="off"')) +
        `<div class="finance-expression-help"><output data-preview aria-live="polite"></output></div><details class="finance-calculator"><summary>${t("计算器", "Calculator")}</summary>
        <div class="finance-keypad">${keypad.map(key => `<button type="button" class="ghost" data-key="${h(key)}">${h(key)}</button>`).join("")}</div></details>
        <div class="finance-transfer-amount" data-converted hidden>${field(t("实际转入", "Received amount"),input("targetAmount",entry?.targetAmount ?? "",'type="number" min="0.01" step="0.01"'))}<div data-rate></div></div>`)}</div>
        <div class="finance-ledger-details">${formSection(t("账户", "Accounts"),`<div class="finance-form-grid">${field(t("使用账户", "Source account"),select("accountID",accountOptions(accounts,source),"required"))}<div data-target hidden>${field(t("转入账户", "Destination account"),select("targetAccountID",""))}</div></div>`)}
        <div data-ledger-category>${formSection(t("分类", "Category"),'<div class="finance-categories" data-choices></div>')}</div>
        ${formSection(t("日期与备注", "Date and note"),`<div class="finance-tools finance-date-input">${field(t("日期", "Date"),input("date",editDay,'type="date" required'))}<button class="ghost" type="button" data-day="-1">${t("昨天", "Yesterday")}</button><button class="ghost" type="button" data-day="-2">${t("前天", "Two days ago")}</button></div>
          ${field(t("备注（可选）", "Note (optional)"),input("note",entry?.note || "",'list="finance-note-suggestions"')+'<datalist id="finance-note-suggestions"></datalist>')}`)}</div></div>`,
      onSubmit: async form => {
        await api("/api/ledger/save", data(form));
        if (form.dataset.continueLedger !== "yes") return;
        form.elements.amountExpression.value = "";
        form.elements.targetAmount.value = "";
        form.elements.note.value = "";
        form.elements.amountExpression.dispatchEvent(new Event("input"));
        form.elements.amountExpression.focus();
        return false;
      },
      onOpen: form => {
        const fields = form.elements;
        const operation = fields.amountExpression;
        const target = fields.targetAccountID;
        let wantedTarget = entry?.targetAccountID || defaults.targetAccountID || accounts.find(account => account.id !== source)?.id;
        const submit = document.getElementById("editor-submit");
        const actionArea = submit.parentElement;
        actionArea.querySelector(".finance-continue")?.remove();
        form.dataset.continueLedger = "";
        if (!entry) {
          const keep = document.createElement("button");
          keep.type = "button";
          keep.className = "ghost finance-continue";
          keep.textContent = t("保存并再记一笔", "Save and add another");
          keep.onclick = () => {form.dataset.continueLedger = "yes"; form.requestSubmit(submit);};
          submit.onclick = () => {form.dataset.continueLedger = "";};
          actionArea.insertBefore(keep,submit);
          form.closest("dialog").addEventListener("close", () => {keep.remove(); submit.onclick = null; delete form.dataset.continueLedger;}, {once:true});
        }
        const update = () => {
          const current = fields.kind.value;
          const from = accountByID(fields.accountID.value);
          const to = accountByID(target.value);
          const cross = current === "transfer" && from && to && from.currency !== to.currency;
          form.querySelector("[data-converted]").hidden = !cross;
          fields.targetAmount.disabled = !cross;
          fields.targetAmount.required = Boolean(cross);
          target.disabled = current !== "transfer";
          target.required = current === "transfer";
          form.querySelector("[data-target]").hidden = current !== "transfer";
          form.querySelector("[data-ledger-category]").hidden = current === "transfer";
          const result = amountPreview(operation.value);
          const preview = form.querySelector("[data-preview]");
          preview.textContent = result !== null ? `= ${money(result,from?.currency || state.currency)}` : (operation.value ? t("请完善算式", "Complete the expression") : "");
          preview.classList.toggle("tone-red", Boolean(operation.value && result === null));
          const rate = form.querySelector("[data-rate]");
          rate.innerHTML = "";
          if (cross) {
            const recent = state.entries.find(row => row.kind === "transfer" && row.currency === from.currency && row.targetCurrency === to.currency && row.amount && row.targetAmount);
            const prior = recent ? recent.targetAmount / recent.amount : 0;
            const currentRate = fields.targetAmount.valueAsNumber > 0 && result > 0 ? fields.targetAmount.valueAsNumber / result : 0;
            if (currentRate || prior) rate.innerHTML = `<small class="muted">${currentRate ? t("隐含汇率", "Implied exchange rate") : t("上次汇率", "Previous rate")} · 1 ${h(from.currency)} ≈ ${(currentRate || prior).toFixed(4)} ${h(to.currency)}</small>${!currentRate && result > 0 ? ` <button type="button" class="ghost" data-fill-rate>${t("按此填入", "Apply")}</button>` : ""}`;
            const fill = rate.querySelector("[data-fill-rate]");
            if (fill) fill.onclick = () => {fields.targetAmount.value = (result*prior).toFixed(2); update();};
          }
        };
        const chooseCategory = () => {
          const current = fields.kind.value;
          const counts = new Map();
          for (const row of state.entries) counts.set(row.categoryID, (counts.get(row.categoryID) || 0) + 1);
          const rows = state.categories.filter(item => item.kind === current).sort((a,b) => (counts.get(b.id)||0)-(counts.get(a.id)||0));
          if (!rows.some(item => item.id === category[current])) category[current] = rows[0]?.id;
          form.querySelector("[data-choices]").innerHTML = rows.map(row => `<label class="tone-${colorKey(categoryInfo[row.id]?.[2])}"><input type="radio" name="categoryID" value="${h(row.id)}"${row.id === category[current] ? " checked" : ""}${current === "transfer" ? " disabled" : ""}>${icon(categoryInfo[row.id]?.[1] || "tag")}<span>${h(categoryName(row.id,row.name))}</span></label>`).join("");
          const noteHistory = Array.from(new Set(state.entries.filter(row => row.kind === current && row.categoryID === category[current] && row.note).map(row => row.note))).slice(0,8);
          form.querySelector("datalist").innerHTML = noteHistory.map(note => `<option value="${h(note)}"></option>`).join("");
        };
        const updateTarget = () => {
          wantedTarget = target.value || wantedTarget;
          const available = accounts.filter(account => account.id !== fields.accountID.value);
          target.innerHTML = accountOptions(available,wantedTarget);
          update();
        };
        form.querySelectorAll("[name=kind]").forEach(control => control.onchange = () => {chooseCategory(); updateTarget();});
        form.querySelector("[data-choices]").onchange = event => {
          category[fields.kind.value] = event.target.value;
          const noteHistory = Array.from(new Set(state.entries.filter(row => row.kind === fields.kind.value && row.categoryID === event.target.value && row.note).map(row => row.note))).slice(0,8);
          form.querySelector("datalist").innerHTML = noteHistory.map(note => `<option value="${h(note)}"></option>`).join("");
        };
        fields.accountID.onchange = updateTarget;
        target.onchange = update;
        fields.targetAmount.oninput = update;
        operation.oninput = () => {evaluated = false; update();};
        form.querySelectorAll("[data-day]").forEach(button => button.onclick = () => {fields.date.value = offsetDay(today(),Number(button.dataset.day));});
        form.querySelectorAll("[data-key]").forEach(button => button.onclick = () => {
          const key = button.dataset.key;
          const operator = /^[×÷−+]$/;
          if (key === "C") {operation.value = ""; evaluated = false;}
          else if (key === "⌫") {operation.value = operation.value.slice(0,-1); evaluated = false;}
          else if (key === "=" || key === "%") {
            const result = amountPreview(operation.value + (key === "%" ? "÷100" : ""));
            if (result !== null) {operation.value = String(result); evaluated = true;}
          } else {
            if (evaluated && !operator.test(key)) operation.value = "";
            if (operator.test(key) && /[×÷−+*/-]$/.test(operation.value)) operation.value = operation.value.slice(0,-1);
            operation.value += key;
            evaluated = false;
          }
          update();
          operation.focus();
        });
        chooseCategory(); updateTarget(); operation.focus();
      }});
  }

  function openRules() {
    const rows = state.recurring || [];
    openEditor({title:t("周期记账", "Recurring transactions"),subtitle:t("按所选周期生成收入或支出记录。", "Create income or expense transactions on a schedule."),width:620,
      body:`<div class="finance-line"><small class="muted">${h(t(`${rows.length} 条规则`, `${rows.length} rules`))}</small>${action("rule-new",t("新建规则", "New rule"),"plus","")}</div>${rows.length ? rows.map(row => {
        const account = accountByID(row.accountID);
        return `<div class="card finance-list-row"><span class="finance-icon tone-teal">${icon("repeat")}</span><div class="finance-row-text"><strong>${h(categoryName(row.categoryID))} · ${h(money(row.amount,account?.currency || state.currency))}</strong><small>${h(enumTitle(ruleFrequencies,row.frequency))} · ${h(dateInput(row.nextDue))}${row.note ? ` · ${h(row.note)}` : ""}</small></div>${badge(row.isEnabled ? t("已启用", "Enabled") : t("已停用", "Disabled"),row.isEnabled ? "green" : "blue")}${rowMenu(action("rule-edit",t("编辑", "Edit"),"", "ghost",row.id)+action("rule-toggle",row.isEnabled ? t("停用", "Disable") : t("启用", "Enable"),"", "ghost",row.id)+action("rule-delete",t("删除", "Delete"),"trash","ghost tone-red",row.id))}</div>`;
      }).join("") : empty(t("还没有周期规则", "No recurring rules"), "", "repeat")}`,
      onOpen: form => rootActions(form.querySelector(".editor-content"),{
        "rule-new":() => openRule(), "rule-edit":id => openRule(rows.find(row => row.id === id)),
        "rule-toggle":async id => {await api("/api/recurring/toggle",{id}); openRules();},
        "rule-delete":id => confirmAction(t("删除周期规则？", "Delete recurring rule?"),t("已生成的流水会保留。", "Transactions already created are retained."),async () => {await api("/api/recurring/delete",{id}); openRules(); return false;})
      })});
  }
  function openRule(row) {
    const accounts = activeAccounts();
    openEditor({title:row ? t("编辑周期规则", "Edit recurring rule") : t("新建周期规则", "New recurring rule"), width:520,
      body:formSection(t("规则内容", "Rule details"), `<div class="finance-form-grid">${field(t("类型", "Type"),select("kind",localizedOptions(ledgerKinds.slice(0,2),row?.kind || "expense")))}${field(t("金额（可输入算式）", "Amount or expression"),input("amountExpression",row?.amount ?? "",'inputmode="decimal" maxlength="120" required'))}${field(t("账户", "Account"),select("accountID",accountOptions(accounts,row?.accountID || state.lastLedgerAccountID || accounts[0]?.id),"required"))}${field(t("分类", "Category"),select("categoryID","","required"))}${field(t("周期", "Repeat"),select("frequency",localizedOptions(ruleFrequencies,row?.frequency || "monthly")))}${field(t("下次记账日期", "Next date"),input("nextDueDate",dateInput(row?.nextDue) || today(),'type="date" required'))}</div>${field(t("备注", "Note"),input("note",row?.note || ""))}<label class="finance-checkbox">${input("isEnabled","yes",`type="checkbox"${row?.isEnabled !== false ? " checked" : ""}`)} ${t("启用周期规则", "Enable rule")}</label><small class="muted">${t("保存后会补记已到期的周期流水。", "Saving creates any transactions already due.")}</small>`),
      onOpen:form => {
        const {kind,categoryID} = form.elements;
        const refresh = () => {categoryID.innerHTML = options(state.categories.filter(category => category.kind === kind.value).map(category => [category.id,categoryName(category.id,category.name)]),row?.categoryID);};
        kind.onchange = refresh;
        refresh();
      },
      onSubmit:async form => {const data = formPayload(form); if (row && data.nextDueDate === dateInput(row.nextDue)) data.nextDueDate = row.nextDueDate; await api("/api/recurring/save",{...data,id:row?.id,isEnabled:data.isEnabled === "yes"}); openRules(); return false;}});
  }

  function renderAccounts(root) {
    const accounts = activeAccounts();
    const groups = new Map();
    for (const account of accounts) {
      if (!groups.has(account.currency)) groups.set(account.currency, []);
      groups.get(account.currency).push(account);
    }
    const grouped = Array.from(groups, ([currency, rows]) => {
      const included = rows.filter(account => account.includeInNetWorth);
      const contribution = included.reduce((total,account) => total + account.contribution, 0);
      return `<article class="card finance-account-table"><header><h2>${h(currency)} · ${h(t(state.currencies.find(item => item.id === currency)?.name || currency,currency))}</h2>
        ${included.length ? `<div><span>${t("净资产", "Net worth")}</span><strong class="finance-number">${h(money(contribution,currency))}</strong></div>` : ""}</header>
        ${rows.map(account => {
          const note = [accountType(account.type),account.type === "credit" ? t("负债", "Debt") : "",account.includeInNetWorth ? "" : t("不计入净资产","Excluded from net worth")].filter(Boolean).join(" · ");
          return `<div class="finance-account-row"><button type="button" class="finance-account-main" data-finance="edit-account" data-value="${h(account.id)}">
            <span class="finance-icon tone-${colorKey(account.colorKey)}">${icon(account.symbol)}</span><span><strong>${h(account.name)}</strong><small>${h(note)}</small></span>
            <strong class="finance-number finance-account-number${account.type === "credit" ? " finance-movement tone-orange" : ""}">${h(money(account.balance,account.currency))}</strong></button>
            ${rowMenu(action("edit-account",t("编辑", "Edit"),"","ghost",account.id)+action("delete-account",t("归档/删除", "Archive or delete"),"trash","ghost tone-red",account.id))}</div>`;
        }).join("")}</article>`;
    });
    root.innerHTML = heading(t("资产账户", "Accounts"), "", action("new-account",t("新建账户", "New account"),"plus","")) +
      (grouped.length ? `<div class="finance-stack">${grouped.join("")}</div>` : `<article class="card">${empty(t("还没有资产账户", "No accounts yet"),
        t("新建账户，之后就可以开始记账。", "Create an account to start recording transactions."),"wallet.pass.fill")}</article>`);
    rootActions(root,{"new-account":() => openAccount(), "edit-account":id => openAccount(accountByID(id)), "delete-account":id => confirmAction(t("处理这个账户？", "Remove this account?"),t("有流水的账户会归档，没有流水的账户会删除。", "Accounts with transactions are archived. Empty accounts are deleted."),() => api("/api/accounts/delete",{id}))});
  }
  function openAccount(row) {
    openEditor({title:row ? t("编辑账户", "Edit account") : t("新建账户", "New account"),subtitle:t("账户余额与净资产分开核对，始终清楚。", "Review the account balance and its contribution to net worth."),width:520,
      body:formSection(t("账户信息", "Account details"),`${field(t("账户名称", "Name"),input("name",row?.name || "","required autofocus"))}<div class="finance-form-grid">${field(t("账户类型", "Account type"),select("type",options(state.accountTypes.map(item => [item.id,accountType(item.id)]),row?.type || "cash")))}${field(t("币种", "Currency"),select("currency",currencyOptions(row?.currency || state.currency)))}${field(t("标记色", "Color"),select("colorKey",options(colors.map(color => [color,t(({blue:"蓝色",teal:"青色",green:"绿色",orange:"橙色",purple:"紫色",red:"红色"})[color],color)]),row?.colorKey || "blue")))}</div>`) +
      formSection(t("余额与统计", "Balance and reporting"),`${field(row?.type === "credit" ? t("当前欠款", "Current debt") : t("账户余额", "Account balance"),input("balance",row?.balance ?? 0,'type="number" min="0" step="0.01" required'),"finance-account-balance")}<label class="finance-checkbox">${input("includeInNetWorth","yes",`type="checkbox"${row?.includeInNetWorth !== false ? " checked" : ""}`)} ${t("计入净资产", "Include in net worth")}</label><small class="muted">${t("修改余额会生成余额调整记录，与日常收支分别统计。", "A balance change creates an adjustment entry outside daily income and expenses.")}</small>`),
      onOpen:form => {form.elements.type.onchange = () => {form.querySelector(".finance-account-balance span").textContent = form.elements.type.value === "credit" ? t("当前欠款", "Current debt") : t("账户余额", "Account balance");};},
      onSubmit:form => {const data = formPayload(form); return api("/api/accounts/save",{...data,id:row?.id,includeInNetWorth:data.includeInNetWorth === "yes"});}});
  }

  function renderBudgets(root) {
    const currency = state.currency;
    const month = state.summary.monthKey;
    const previous = offsetMonth(month,-1);
    const rateToggle = state.settings.budgetRolloverEnabled;
    root.innerHTML = heading(t("月度预算", "Monthly budget"), monthLabel(month,true)+" · "+currency,
      `<label class="finance-checkbox" title="${h(t("可用额度 = 本月预算 + 上月结余", "Available budget = current budget plus prior balance"))}">${input("budget-rollover","yes",`type="checkbox"${rateToggle ? " checked" : ""}`)} ${t("滚存上月结余", "Carry over last month’s balance")}</label>${action("edit-budgets",t("编辑预算", "Edit budgets"),"slider.horizontal.3","")}`) +
      `<div data-finance-result class="finance-stack">${loading()}</div>`;
    const rollover = root.querySelector("[name=budget-rollover]");
    rollover.onchange = () => api("/api/settings", {budgetRolloverEnabled:rollover.checked}).catch(error => {rollover.checked = !rollover.checked; showError(error);});
    rootActions(root,{"edit-budgets":openBudget,"budget-category":openBudget});
    readView(root,"budgets",(model,error) => {
      const output = root.querySelector("[data-finance-result]");
      if (!model) {output.innerHTML = viewFailure(error); return;}
      const expenses = state.categories.filter(item => item.kind === "expense");
      const available = state.budgets.filter(row => row.currency === currency);
      const byMonth = key => new Map(available.filter(row => row.monthKey === key).map(row => [row.categoryID,row.amount]));
      const planned = byMonth(month), prior = byMonth(previous);
      const rows = expenses.map(category => ({...category,amount:planned.get(category.id)||0, spent:model.expenseCategories[category.id]||0,
        carried:rateToggle ? (prior.get(category.id)||0)-(model.previousExpenseCategories[category.id]||0) : 0}));
      const active = row => Boolean(row.amount || row.spent || row.carried);
      rows.sort((a,b) => Number(active(b))-Number(active(a)));
      const total = [...planned.values()].reduce((acc,amount) => acc+amount,0);
      const spent = model.months.at(-1).expense;
      const leftover = total-spent+rows.reduce((acc,row) => acc+row.carried,0);
      const end = new Date(`${offsetMonth(month,1)}-01T12:00:00`);
      end.setDate(end.getDate()-1);
      const days = Math.max(1,end.getDate()-Number(today().slice(8))+1);
      output.innerHTML = tiles([
        tile(rateToggle ? t("可用余额（含结转）", "Available with carryover") : t("可用余额", "Available"),moneySigned(leftover,currency),"gauge.with.dots.needle.67percent",leftover < 0 ? "red" : "teal"),
        tile(t("计划预算", "Planned budget"),money(total,currency),"target","blue"),
        tile(t("实际支出", "Actual expenses"),money(spent,currency),"cart.fill",spent > total && total > 0 ? "red" : "green"),
        tile(t("剩余日均可用", "Available per day"),moneySigned(leftover/days,currency),"calendar",leftover < 0 ? "red" : "teal")].join("")) +
        `<article class="card finance-budget-list"><header class="finance-budget-columns"><h2>${t("分类预算","Category budgets")}</h2>
        <span>${t("使用进度", "Progress")}</span><span>${t("实际支出 / 可用额度","Actual / Available")}</span></header>${rows.map(row => {
        const limit = row.amount+row.carried;
        const color = row.spent > limit && (row.spent > 0 || limit < 0) ? "red" : "teal";
        const categoryMarkup = action("budget-category",categoryName(row.id,row.name),"","ghost finance-budget-link",row.id);
        return `<div class="finance-budget-row"><span class="finance-icon tone-${colorKey(categoryInfo[row.id]?.[2])}">${icon(categoryInfo[row.id]?.[1] || "tag")}</span>
        <div>${categoryMarkup}${Math.abs(row.carried) > .004 ? `<small class="tone-${row.carried < 0 ? "red" : "teal"}">${h(t("结转", "Carryover") + " " + moneySigned(row.carried,currency))}</small>` : ""}</div>
        ${progress(limit > 0 ? row.spent/limit : (row.spent > 0 ? 1 : 0),color)}<span class="finance-number"><strong class="finance-movement tone-${color}">${h(money(row.spent,currency))}</strong> / ${h(money(limit,currency))}</span></div>`;
      }).join("")}</article>`;
    });
  }
  function openBudget(categoryID) {
    const month = state.summary.monthKey, next = offsetMonth(month,1), currency = state.currency;
    const expenses = state.categories.filter(row => row.kind === "expense");
    const valuesFor = key => new Map(state.budgets.filter(row => row.monthKey === key && row.currency === currency).map(row => [row.categoryID,row.amount]));
    openEditor({title:t("编辑月度预算", "Edit monthly budget"),subtitle:`${month} · ${currency}`,width:560,
      body:formSection(t("月份与复制", "Month and copy"),`${field(t("编辑月份", "Month"),select("monthKey",options([[month,t(`本月（${month}）`,`This month (${month})`)],[next,t(`下月（${next}）`,`Next month (${next})`)]],month)))}<button class="ghost" type="button" data-copy-budget></button><small class="muted">${t("复制时只填入尚未设置的分类。", "Copying fills categories that have no amount yet.")}</small>`) +
        formSection(t("分类预算", "Category budgets"),expenses.map(row => `<div class="finance-budget-edit"><span class="finance-icon tone-${colorKey(categoryInfo[row.id]?.[2])}">${icon(categoryInfo[row.id]?.[1] || "tag")}</span>${field(categoryName(row.id,row.name),input(`budget-${row.id}`,"",'type="number" min="0" step="0.01" placeholder="0"'))}</div>`).join("")),
      onOpen:form => {
        const control = form.elements.monthKey;
        const copy = form.querySelector("[data-copy-budget]");
        function refresh() {
          const current = valuesFor(control.value);
          const previous = offsetMonth(control.value,-1);
          for (const item of expenses) form.elements[`budget-${item.id}`].value = current.get(item.id) ?? "";
          copy.disabled = !valuesFor(previous).size;
          copy.textContent = t(`复制上月预算（${previous}）`,`Copy last month (${previous})`);
        }
        control.onchange = refresh;
        copy.onclick = () => {
          const previous = valuesFor(offsetMonth(control.value,-1));
          for (const item of expenses) {const target = form.elements[`budget-${item.id}`]; if (!Number(target.value) && previous.has(item.id)) target.value = previous.get(item.id);}
        };
        refresh(); if (categoryID) form.elements[`budget-${categoryID}`]?.focus();
      },
      onSubmit:form => api("/api/budgets/batch",{monthKey:form.elements.monthKey.value,currency,amounts:Object.fromEntries(expenses.map(row => [row.id,form.elements[`budget-${row.id}`].value || 0]))})});
  }

  const activeGoals = () => (state.goals || []).filter(goal => ["active","paused"].includes(goal.status)).sort((a,b) => (a.status === "paused")-(b.status === "paused") || a.deadline.localeCompare(b.deadline));
  function goalCard(goal) {
    const account = accountByID(goal.savingsAccountID);
    const percentage = Math.trunc(goal.progress*100);
    const color = colorKey(goal.colorKey);
    const active = ["active","paused"].includes(goal.status);
    const menu = action("edit-goal",t("编辑", "Edit"),"","ghost",goal.id) +
      (active ? action("pause-goal",goal.status === "paused" ? t("继续目标", "Resume") : t("暂停目标", "Pause"),"","ghost",goal.id) : "") +
      action("delete-goal",t("删除或归档", "Delete or archive"),"trash","ghost tone-red",goal.id);
    const deadline = dateInput(goal.deadline);
    return `<article class="card finance-goal-card tone-${color}">
      <header><span class="finance-icon">${icon(goal.symbol)}</span><div><h2>${h(goal.title)}</h2>
      ${goal.status === "active" ? "" : `<small>${h(enumTitle(goalStates,goal.status))}</small>`}</div>${rowMenu(menu)}</header>
      <div class="finance-goal-amount"><div><span>${t("已攒下","Saved")}</span><strong>${h(money(goal.balance,goal.currency))}</strong></div>
      <div><span>${t("目标", "Target")}</span><strong>${h(money(goal.targetAmount,goal.currency))}</strong></div></div>
      ${progress(goal.progress,color)}<div class="finance-goal-meta"><strong>${percentage}%</strong>
      ${deadline ? `<time datetime="${h(deadline)}">${h(deadline)}</time>` : ""}</div>
      ${goal.notes ? `<p class="finance-goal-note">${h(goal.notes)}</p>` : ""}
      <footer><small>${account ? h(`${t("存钱罐", "Savings account")} · ${account.name}`) : t("首笔积蓄时选择账户", "Choose an account on the first deposit")}</small>
      ${goal.status === "active" ? action("goal-deposit",t("存入", "Deposit"),"plus","ghost",goal.id) : ""}</footer></article>`;
  }

  function renderGoals(root) {
    const goals = state.goals || [];
    const open = activeGoals();
    const completed = goals.filter(goal => goal.status === "completed");
    const archived = goals.filter(goal => goal.status === "archived");
    const goalDeck = rows => `<div class="finance-goals-grid">${rows.map(goalCard).join("")}</div>`;
    const past = (rows, label) => rows.length ? `<details class="finance-goal-history"><summary>${h(label)} <span>${rows.length}</span></summary>${goalDeck(rows)}</details>` : "";
    root.innerHTML = heading(t("攒钱目标", "Savings goals"), "", action("new-goal",t("新建目标", "New goal"),"plus","")) +
      (goals.length ? `<div class="finance-stack">${open.length ? goalDeck(open) : ""}${past(completed,t("已完成","Completed"))}${past(archived,t("已归档","Archived"))}</div>` :
        `<article class="card">${empty(t("还没有攒钱目标", "No savings goals yet"),t("先设定目标金额和计划完成日期。", "Set an amount and a target date."),"target")}</article>`);
    const find = id => goals.find(goal => goal.id === id);
    rootActions(root,{"new-goal":() => openGoal(),"edit-goal":id => openGoal(find(id)),
      "goal-deposit":id => openRecord(undefined,{goalID:id,kind:"deposit"}),
      "pause-goal":id => api("/api/goals/status",{id,status:find(id).status === "paused" ? "active" : "paused"}),
      "delete-goal":id => confirmAction(t("处理这个目标？", "Remove this goal?"),t("已有积蓄记录的目标会归档，历史统计会保留。", "Goals with existing records are archived to keep their history."),() => api("/api/goals/delete",{id}))});
  }
  function openGoal(goal) {
    const start = new Date(`${today()}T12:00:00`);
    const end = new Date(start.getFullYear(),start.getMonth()+7,0);
    end.setDate(Math.min(end.getDate(),start.getDate()));
    openEditor({title:goal ? t("编辑攒钱目标", "Edit savings goal") : t("新建攒钱目标", "New savings goal"),subtitle:t("给一个愿望明确的金额、日期和存钱罐。", "Set an amount, deadline and savings account for your goal."),width:560,
      body:formSection(t("目标与金额", "Goal and amount"),`${field(t("目标名称", "Goal name"),input("title",goal?.title || "","required autofocus"))}<div class="finance-form-grid">${field(t("币种", "Currency"),select("currency",currencyOptions(goal?.currency || state.currency)))}${field(t("目标金额", "Target amount"),input("targetAmount",goal?.targetAmount ?? "",'type="number" min="0.01" step="0.01" required'))}${field(t("已有金额", "Starting amount"),input("startingAmount",goal?.startingAmount ?? 0,'type="number" min="0" step="0.01" required'))}</div>`) +
        formSection(t("账户与日期", "Account and date"),`<div class="finance-form-grid">${field(t("存钱罐账户", "Savings account"),select("savingsAccountID",""))}${field(t("计划完成日期", "Target date"),input("deadline",dateInput(goal?.deadline) || localDate(end),'type="date" required'))}</div><small class="muted">${t("绑定后，积蓄记录会同步生成资产转账。", "Savings records create account transfers after an account is linked.")}</small>`) +
        formSection(t("个性与备注", "Appearance and note"),`<div class="finance-form-grid">${field(t("图标", "Icon"),select("symbol",localizedOptions(goalSymbols,goal?.symbol || "flag.checkered")))}${field(t("颜色", "Color"),select("colorKey",options(colors.map(color => [color,t(({blue:"蓝色",teal:"青色",green:"绿色",orange:"橙色",purple:"紫色",red:"红色"})[color],color)]),goal?.colorKey || "blue")))}</div>${field(t("为什么想攒下这笔钱（可选）", "Why are you saving? (optional)"),`<textarea name="notes" rows="3">${h(goal?.notes || "")}</textarea>`)}`),
      onOpen:form => {const {currency,savingsAccountID} = form.elements; const sync = value => {savingsAccountID.innerHTML = accountOptions(activeAccounts().filter(account => account.currency === currency.value),value,t("记录时选择", "Choose when recording"));}; sync(goal?.savingsAccountID); currency.onchange = () => sync(savingsAccountID.value);},
      onSubmit:form => api("/api/goals/save",{...formPayload(form),id:goal?.id})});
  }

  function recordRow(row) {
    const color = row.kind === "deposit" ? "teal" : "orange";
    const from = accountByID(row.fundingAccountID), to = accountByID(row.savingsAccountID);
    const path = from && to ? (row.kind === "deposit" ? `${from.name} → ${to.name}` : `${to.name} → ${from.name}`) : "";
    const category = enumTitle(savingsCategories,row.category);
    const note = [category,row.note].filter(Boolean).join(" · ");
    const time = row.date ? row.date.slice(11,16) : "";
    const amount = (row.kind === "deposit" ? "+" : "−") + money(row.amount,row.currency);
    const cells = historyCells(row.kind === "deposit" ? "arrow.down.circle" : "arrow.up.circle",color,row.goalTitle || t("已删除的目标", "Deleted goal"),note,path,time,amount,color);
    return `<div class="finance-list-row finance-editable" data-row="${h(row.id)}"><button type="button" class="finance-row-main" data-finance="edit-record" data-value="${h(row.id)}">${cells}</button>${rowMenu(action("edit-record",t("编辑", "Edit"),"","ghost",row.id)+action("delete-record",t("删除", "Delete"),"trash","ghost tone-red",row.id))}</div>`;
  }
  function openRecord(row, defaults = {}) {
    const goals = activeGoals();
    const original = state.goals?.find(goal => goal.id === row?.goalID);
    if (original && !goals.some(goal => goal.id === original.id)) goals.push(original);
    if (!goals.length) {
      openEditor({title:t("记一笔积蓄", "New savings record"),body:empty(t("还没有攒钱目标", "No savings goals yet"),t("创建目标后就可以分配积蓄。", "Create a goal before allocating savings."),"target",action("record-new-goal",t("创建第一个目标", "Create a goal"),"plus","")),onOpen:form => rootActions(form.querySelector(".editor-content"),{"record-new-goal":() => openGoal()})});
      return;
    }
    const chosenGoal = row?.goalID || defaults.goalID || goals[0].id;
    const editDay = dateInput(row?.date) || defaults.date || today();
    openEditor({title:row ? t("编辑积蓄记录", "Edit savings record") : t("记一笔积蓄", "New savings record"),subtitle:t("把一笔钱放进真正想实现的目标。", "Allocate money to a goal you want to reach."),width:540,
      body:formSection(t("目标与金额", "Goal and amount"),`<div class="finance-form-grid">${field(t("类型", "Type"),select("kind",localizedOptions(recordKinds,row?.kind || defaults.kind || "deposit")))}${field(t("所属目标", "Goal"),select("goalID",options(goals.map(goal => [goal.id,`${goal.title} · ${goal.currency}`]),chosenGoal),"required"))}</div>${field(t("金额", "Amount"),input("amount",row?.amount ?? "",'type="number" min="0.01" step="0.01" required class="finance-amount-input"'))}`) +
        formSection(t("账户去向", "Accounts"),`<div class="finance-form-grid">${field(t("转出账户", "Source account"),select("fundingAccountID","","required"),"finance-funding")}${field(t("目标存钱罐", "Savings account"),select("savingsAccountID","","required"))}</div><small data-unavailable class="tone-orange" hidden>${t("请先在资产账户中创建至少两个与目标同币种的账户。", "Create at least two active accounts in the goal’s currency first.")}</small><small data-goal-balance class="muted"></small>`) +
        formSection(t("分类、日期与备注", "Category, date and note"),`<div class="finance-form-grid">${field(t("来源分类", "Category"),select("category",localizedOptions(savingsCategories,row?.category || "other")))}${field(t("日期", "Date"),input("date",editDay,'type="date" required'))}</div>${field(t("备注（可选）", "Note (optional)"),`<textarea name="note" rows="2">${h(row?.note || "")}</textarea>`)}`),
      onOpen:form => {
        const {kind,goalID,fundingAccountID,savingsAccountID} = form.elements;
        const find = () => goals.find(goal => goal.id === goalID.value);
        const direction = () => {
          const goal = find();
          form.querySelector(".finance-funding span").textContent = kind.value === "deposit" ? t("转出账户", "Source account") : t("转入账户", "Destination account");
          form.querySelector("[data-goal-balance]").textContent = goal && kind.value === "withdrawal" ? `${t("当前可用", "Currently available")} · ${money(goal.balance,goal.currency)}` : "";
        };
        const sync = (fundingID,savingsID,reset = false) => {
          const goal = find();
          const matching = activeAccounts().filter(account => account.currency === goal?.currency);
          if (reset && matching.some(account => account.id === goal?.savingsAccountID)) savingsID = goal.savingsAccountID;
          if (!matching.some(account => account.id === savingsID)) savingsID = matching.at(-1)?.id;
          if (fundingID === savingsID || !matching.some(account => account.id === fundingID)) fundingID = matching.find(account => account.id !== savingsID)?.id;
          fundingAccountID.innerHTML = accountOptions(matching.filter(account => account.id !== savingsID),fundingID);
          savingsAccountID.innerHTML = accountOptions(matching.filter(account => account.id !== fundingID),savingsID);
          form.querySelector("[data-unavailable]").hidden = matching.length >= 2;
          direction();
        };
        sync(row?.fundingAccountID,row?.savingsAccountID,!row);
        goalID.onchange = () => sync(fundingAccountID.value,savingsAccountID.value,true);
        fundingAccountID.onchange = () => sync(fundingAccountID.value,savingsAccountID.value);
        savingsAccountID.onchange = () => sync(fundingAccountID.value,savingsAccountID.value);
        kind.onchange = direction;
      },
      onSubmit:form => {
        const payload = formPayload(form);
        if (row && payload.date === editDay) payload.date = row.timestamp ?? row.date;
        else if (payload.date === today()) delete payload.date;
        return api("/api/records/save",{...payload,id:row?.id});
      }});
  }

  function chartColor(color) {
    return getComputedStyle(document.body).getPropertyValue(`--finance-${colorKey(color)}`).trim() || "#286b5a";
  }
  function barChart(months, series, currency, always = false) {
    const max = Math.max(1,...series.flatMap(item => item.values));
    if (!always && !series.some(item => item.values.some(value => value > 0))) return empty(t("还没有收支趋势", "No cash flow history yet"),t("记账后，这里会展示近 6 个月趋势。", "Record transactions to see the last six months."),"chart.bar.fill");
    return `<div class="finance-chart-legend">${series.map(item => `<span class="tone-${colorKey(item.color)}"><i></i>${h(item.label)}</span>`).join("")}</div><div class="finance-bars">${months.map((month,index) => `<div class="finance-bar-month"><div class="finance-bar-group">${series.map(item => {
      const value = item.values[index];
      const title = `${monthLabel(month,true)} · ${item.label} ${money(value,currency)}`;
      return `<div class="finance-bar-track tone-${colorKey(item.color)}" tabindex="0" title="${h(title)}" aria-label="${h(title)}"><span class="finance-bar" style="height:${Math.max(2,value/max*100)}%"></span></div>`;
    }).join("")}</div>${always ? `<small class="finance-bar-value muted">${h(money(series[0].values[index],currency))}</small>` : ""}<span>${h(monthLabel(month))}</span></div>`).join("")}</div>`;
  }
  function drawLine(container, months, series, currency) {
    const canvas = container.querySelector("canvas");
    const data = series.flatMap(row => row.values);
    const minimum = Math.min(0,...data), maximum = Math.max(1,...data);
    function paint() {
      const size = window.devicePixelRatio || 1;
      const width = canvas.clientWidth, height = canvas.clientHeight;
      if (width < 20 || height < 20) return;
      canvas.width = Math.round(width*size); canvas.height = Math.round(height*size);
      const ctx = canvas.getContext("2d");
      const style = getComputedStyle(container);
      ctx.scale(size,size);
      ctx.font = '11px "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", sans-serif';
      const left = Math.min(width*.27,Math.max(36,ctx.measureText(money(Math.max(Math.abs(minimum),Math.abs(maximum)),currency)).width+14));
      const right = 15, top = 13, bottom = height-26;
      const x = index => left + (width-left-right) * index / Math.max(1,months.length-1);
      const y = number => bottom - (number-minimum)/(maximum-minimum) * (bottom-top);
      ctx.strokeStyle = style.getPropertyValue("--line"); ctx.fillStyle = style.getPropertyValue("--muted");
      ctx.textBaseline = "middle";
      for (let index=0; index<=4; index++) {
        const value = minimum+(maximum-minimum)*index/4;
        ctx.beginPath(); ctx.moveTo(left,y(value)); ctx.lineTo(width-right,y(value)); ctx.stroke();
        ctx.textAlign = "right"; ctx.fillText(money(value,currency),left-5,y(value),left-8);
      }
      months.forEach((month,index) => {ctx.textAlign = index === months.length-1 ? "right" : "center"; ctx.fillText(monthLabel(month),x(index),bottom+17);});
      for (const row of series) {
        ctx.strokeStyle = chartColor(row.color); ctx.fillStyle = ctx.strokeStyle; ctx.lineWidth = 2.4;
        ctx.beginPath(); row.values.forEach((value,index) => {if (index === 0) ctx.moveTo(x(index),y(value)); else ctx.lineTo(x(index),y(value));}); ctx.stroke();
        row.values.forEach((value,index) => {ctx.beginPath(); ctx.arc(x(index),y(value),3.1,0,Math.PI*2); ctx.fill();});
      }
      const tooltip = container.querySelector(".finance-chart-tooltip");
      canvas.onpointermove = event => {
        const offset = event.clientX - canvas.getBoundingClientRect().left;
        const index = Math.max(0,Math.min(months.length-1,Math.round((offset-left)/(width-left-right)*(months.length-1))));
        tooltip.textContent = `${monthLabel(months[index],true)} · ${series.map(row => `${row.label} ${money(row.values[index],currency)}`).join(" · ")}`;
        tooltip.hidden = false;
      };
      canvas.onpointerleave = () => {tooltip.hidden = true;};
    }
    const observer = new ResizeObserver(paint);
    observer.observe(canvas);
    paint();
    return observer;
  }
  function lineChartMarkup(id, series, months, currency) {
    if (!series.length || !series.some(item => item.values.some(value => value !== 0))) return empty(t("还没有趋势数据", "No trend data yet"),t("记账后，这里会展示最近 6 个月的趋势。", "Record transactions to see six months of history."),"chart.line.uptrend.xyaxis");
    return `<div class="finance-chart-legend">${series.map(row => `<span class="tone-${colorKey(row.color)}"><i></i>${h(row.label)}</span>`).join("")}</div><div class="finance-line-chart" id="${id}"><canvas role="img" aria-label="${h(t("近六个月趋势", "Six-month trend"))}"></canvas><div class="finance-chart-tooltip" hidden></div></div><details class="finance-chart-data"><summary>${t("查看图表数据", "View chart data")}</summary><table><thead><tr><th scope="col">${t("月份", "Month")}</th>${series.map(row => `<th scope="col">${h(row.label)}</th>`).join("")}</tr></thead><tbody>${months.map((month,index) => `<tr><th scope="row">${h(monthLabel(month,true))}</th>${series.map(row => `<td>${h(money(row.values[index],currency))}</td>`).join("")}</tr>`).join("")}</tbody></table></details>`;
  }
  function categoryChart(categories, currency, fallback) {
    const entries = Object.entries(categories).sort((a,b) => b[1]-a[1]);
    const total = entries.reduce((sum,row) => sum+row[1],0);
    return entries.length ? `<div class="finance-category-mix">${entries.map(([id,amount]) => `<div class="finance-category-mix-row"><span class="tone-${colorKey(categoryInfo[id]?.[2])}">${icon(categoryInfo[id]?.[1] || "tag")}</span><strong>${h(categoryName(id))}</strong>${progress(amount/Math.max(1,total),colorKey(categoryInfo[id]?.[2]))}<span class="finance-number">${Math.trunc(amount/Math.max(1,total)*100)}% · ${h(money(amount,currency))}</span></div>`).join("")}</div>` : empty(fallback,"","chart.bar.fill");
  }
  function renderTrends(root, view) {
    root.financeObservers?.forEach(observer => observer.disconnect());
    root.financeObservers = [];
    const reports = view === "reports";
    root.innerHTML = heading(reports ? t("收支报表", "Reports") : t("积蓄趋势", "Savings trends"),
      t("金额按原币统计", "Amounts shown in the original currency"), currencyPicker(view,true)) +
      `<div data-finance-result class="finance-stack">${loading()}</div>`;
    switchCurrency(root,view);
    rootActions(root,{});
    readView(root,view,(model,error) => {
      const output = root.querySelector("[data-finance-result]");
      if (!model) {output.innerHTML = viewFailure(error); return;}
      const currency = viewOptions[view].currency || state.currency;
      const months = model.months.map(row => row.month);
      if (reports) {
        const last = model.months.at(-1), previous = model.months.at(-2);
        const net = last.income-last.expense;
        const prev = previous.income-previous.expense;
        const change = Math.abs(prev) > .004 ? (net-prev)/Math.abs(prev) : null;
        const netSeries = [{label:t("月末净资产", "Month-end net worth"),color:"blue",values:model.months.map(row => row.netWorth)}];
        const categorySeries = model.categorySeries.map((row,index) => ({label:categoryName(row.id),color:colors[index],values:row.values}));
        const incomeExpenseSeries = [
          {label:t("收入", "Income"),color:"green",values:model.months.map(row => row.income)},
          {label:t("支出", "Expense"),color:"red",values:model.months.map(row => row.expense)}
        ];
        output.innerHTML = tiles([
          tile(t("本月净现金流", "Net cash flow this month"),moneySigned(net,currency),"arrow.left.arrow.right",net < 0 ? "red" : "teal"),
          tile(change === null ? t("上月无环比基数", "No prior month baseline") : t("净现金流环比", "Cash flow vs. last month"),change === null ? "—" : `${change > 0 ? "+" : ""}${Math.round(change*100)}%`,change < 0 ? "arrow.down.left" : "arrow.up.right",change < 0 ? "red" : "green"),
          tile(t("本月流水", "Transactions this month"),model.entryCount,"list.bullet","blue")].join("")) +
          `<div class="finance-report-grid"><div class="finance-report-primary">
            ${panel(t("近六个月收支", "Income and expenses over six months"),"",barChart(months,incomeExpenseSeries,currency))}
            ${panel(t("月末净资产", "Month-end net worth"),"",lineChartMarkup("net-worth-chart",netSeries,months,currency))}
            ${panel(t("分类支出趋势", "Spending trends by category"),"",lineChartMarkup("category-trend-chart",categorySeries,months,currency))}
          </div><div class="finance-report-secondary">
            ${panel(t("本月支出结构", "Expense breakdown"),"",categoryChart(model.expenseCategories,currency,t("本月没有支出", "No expenses this month")))}
            ${panel(t("本月收入结构", "Income breakdown"),"",categoryChart(model.incomeCategories,currency,t("本月没有收入", "No income this month")))}
          </div></div>`;
        for (const [id,series] of [["net-worth-chart",netSeries],["category-trend-chart",categorySeries]]) {
          const node = root.querySelector(`#${id}`);
          if (node) root.financeObservers.push(drawLine(node,months,series,currency));
        }
        return;
      }
      const values = model.months.map(row => row.deposits);
      const average = values.reduce((sum,value) => sum+value,0)/Math.max(1,values.length);
      const dayMax = Math.max(1,...Object.values(model.days));
      const goal = activeGoals().find(item => item.currency === currency);
      const remaining = goal ? Math.max(0,goal.targetAmount-goal.balance) : 0;
      const monthsToGoal = average > 0 ? Math.ceil(remaining/average) : null;
      const outlook = goal ? `<div class="finance-brief"><strong>${h(goal.title)}</strong><strong class="finance-number">${Math.trunc(goal.progress*100)}%</strong></div>
        ${progress(goal.progress,"teal")}${remaining > 0 ?
        `<div class="finance-brief"><span class="muted">${t("距目标还差","Remaining")}</span><strong class="finance-number">${h(money(remaining,currency))}</strong></div>
        <p class="muted">${h(monthsToGoal ? t(`按近六个月平均存入速度，预计还需 ${monthsToGoal} 个月。`,`At the six-month average, about ${monthsToGoal} months remain.`) :
          t("有存入记录后即可估算完成时间。", "Record a deposit to calculate an estimate."))}</p>` : `<span class="finance-movement tone-green">${t("已达到目标","Goal reached")}</span>`}` :
        empty(t("当前币种没有进行中的目标。", "No active goals in this currency."),"","target");
      const heatmap = `<div class="finance-calendar finance-heatmap">${Object.entries(model.days).map(([date, amount]) => {
        const label = `${date} · ${money(amount,currency)}`;
        return `<div tabindex="0" title="${h(label)}" aria-label="${h(label)}"><i${amount > 0 ? ` style="opacity:${.35+amount/dayMax*.65}" class="has-data"` : ""}></i><small>${Number(date.slice(8))}</small></div>`;
      }).join("")}</div>`;
      output.innerHTML = tiles([
        tile(t("近六月月均存入", "Average monthly savings"),money(average,currency),"chart.bar.fill","teal"),
        tile(t("累计积蓄天数", "Days with savings"),`${model.savingDays} ${t("天", "days")}`,"calendar","blue"),
        tile(t("当前连续天数", "Current streak"),`${model.streak} ${t("天", "days")}`,"flame.fill","orange")].join("")) +
        `<div class="finance-report-grid"><div class="finance-report-primary">
          ${panel(t("近六个月存入趋势", "Deposits over six months"),"",barChart(months,[{label:t("存入", "Deposit"),color:"teal",values}],currency,true))}
          ${panel(t("最近 35 天积蓄日历", "Last 35 days of savings"),"",heatmap)}
        </div><div class="finance-report-secondary">${panel(t("目标进度估算", "Goal forecast"),"",outlook,link("goals",t("攒钱目标","Savings goals")))}</div></div>`;
    });
  }

  async function exportCSV() {
    const result = await fetch("/api/export/ledger.csv",{headers});
    if (!result.ok) throw new Error(t("无法导出流水。", "Could not export transactions."));
    const url = URL.createObjectURL(await result.blob());
    const link = document.createElement("a");
    link.href = url;
    link.download = `${t("搞积蓄流水", "Gao-Savings-Transactions")}-${today()}.csv`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url),1000);
  }
  function render(view) {
    const root = document.getElementById(view);
    if (!root || !state || state.status !== "ready") return;
    root.classList.add("finance-workspace");
    switch (view) {
      case "overview": renderOverview(root); break;
      case "ledger": case "records": renderHistory(root,view); break;
      case "accounts": renderAccounts(root); break;
      case "budgets": renderBudgets(root); break;
      case "reports": case "analytics": renderTrends(root,view); break;
      case "goals": renderGoals(root); break;
    }
  }
  window.GaoFinance = {render, openLedger, openRecord, exportCSV};
})();
