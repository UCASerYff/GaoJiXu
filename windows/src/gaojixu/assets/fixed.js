(() => {
  const e = escapeHTML;
  const cycles = [["weekly","每周"],["monthly","每月"],["quarterly","每季"],["yearly","每年"],["days","自定义天数"]];
  const accruingCurrencies = ["CNY","USD","EUR","HKD","JPY","GBP"];
  const expenseTabs = [["subscription","订阅"],["bills","待核实账期"],["payments","支付历史"],["events","到期事项"],["review","统计与复盘"]];
  const benefitKinds = [["daily","每日"],["weekly","每周"]];
  let incomeMonth = "";
  let expenseTab = "subscription";
  let filter = "";
  let showArchivedSubs = false;
  let showArchivedBenefits = false;
  let count = 30;
  let statisticsCurrency = "CNY";

  const action = (name, title, id = "", primary = false, disabled = false) => '<button type="button" class="' + (primary ? "" : "ghost") +
    '" data-fixed="' + name + '" data-id="' + e(id) + '"' + (disabled ? " disabled" : "") + ">" + title + "</button>";
  const panel = (title, body) => '<div class="card"><h2>' + title + "</h2>" + body + "</div>";
  const empty = text => '<p class="muted">' + text + "</p>";
  const row = (title, detail, controls = "") => '<div class="fixed-row"><div><strong>' + e(title) + '</strong><div class="muted">' +
    detail + '</div></div><div class="row">' + controls + "</div></div>";
  const header = (title, subtitle, interfaceActions) => '<div class="workbench-header"><div><h1>' + title + "</h1><p>" +
    subtitle + '</p></div><div class="row">' + interfaceActions + "</div></div>";
  const pick = (name, title, options, selected, required = false) => '<label>' + title + '<select name="' + name + '"' +
    (required ? " required" : "") + ">" + options.map(([key, name]) => '<option value="' + e(key) + '"' + (selected === key ? " selected" : "") + ">" + e(name) + "</option>").join("") + "</select></label>";
  const field = (name, title, val = "", attrs = "") => '<label>' + title + '<input name="' + name + '" value="' + e(val) + '" ' + attrs + "></label>";
  const checkbox = (name, title, checked = false, attrs = "") => '<label class="check-row"><input type="checkbox" name="' + name +
    '"' + (checked ? " checked" : "") + " " + attrs + ">" + title + "</label>";
  const group = (title, body) => '<div class="form-section"><h3>' + title + '</h3><div class="fixed-fields">' + body + "</div></div>";
  const val = form => Object.fromEntries(new FormData(form));
  const today = () => state.today || state.monthly?.today || new Date().toLocaleDateString("sv-SE");
  const currentMonth = () => state.summary.monthKey;
  const dateShift = (month, offset) => {
    const [year, m] = month.split("-").map(Number);
    const date = new Date(Date.UTC(year, m - 1 + offset, 1));
    return date.toISOString().slice(0, 7);
  };
  const sameCurrency = currency => (state.accounts || []).filter(a => !a.archived && a.currency === currency).map(a => [a.id, a.name]);
  const subs = () => state.monthly?.subscriptions || [];
  const subById = id => subs().find(sub => sub.id === id);
  const accountChoices = currency => [["","请选择账户"], ...sameCurrency(currency)];
  const subsChoices = label => [["", label], ...subs().map(sub => [sub.id, sub.name])];
  const displayCurrency = (amount, code) => e(code) + " " + money(amount, code);
  const cycleName = id => cycles.find(choice => choice[0] === id)?.[1] || id;
  const incomeCategory = key => state.fixedIncome.categories[key] || "收入";
  const mount = (root, html) => {
    root.classList.add("fixed-workspace");
    root.innerHTML = html;
    root.onclick = fixedClick;
    root.onchange = event => {
      if (event.target.id === "fixed-archive-subs") {
        showArchivedSubs = event.target.checked;
        render("fixed-expenses");
      } else if (event.target.id === "fixed-archive-benefits") {
        showArchivedBenefits = event.target.checked;
        render("benefits");
      } else if (event.target.id === "fixed-statistics-currency") {
        statisticsCurrency = event.target.value;
        render("fixed-expenses");
      }
    };
    const input = root.querySelector("#fixed-sub-search");
    if (input) input.oninput = () => {
      filter = input.value;
      root.querySelector("#fixed-subscriptions-list").innerHTML = subscriptionRows();
    };
  };
  function formEditor(config) {
    return openEditor({
      title: config.title, subtitle: config.subtitle, body: config.body, submitLabel: config.button, width: config.width || 580,
      onOpen: config.onOpen,
      onSubmit: async form => {
        const payload = val(form);
        for (const input of form.querySelectorAll('input[type="checkbox"]')) payload[input.name] = input.checked;
        if (config.prepare) config.prepare(payload, form);
        await api(config.path, payload);
      }
    });
  }

  function renderIncome(root) {
    incomeMonth ||= currentMonth();
    const {plans, receipts} = state.fixedIncome;
    const arrived = receipts.filter(receipt => receipt.month === incomeMonth).sort((a,b) => b.confirmedAt - a.confirmedAt);
    const arrivedIDs = new Set(arrived.map(receipt => receipt.planID));
    const predicted = plans.filter(plan => plan.startMonth <= incomeMonth && plan.isEnabled && !arrivedIDs.has(plan.id));
    const totals = (rows, message) => {
      const sums = new Map();
      rows.forEach(row => sums.set(row.currency, (sums.get(row.currency) || 0) + (Number(row.amount) || 0)));
      return sums.size ? [...sums].map(([code, amount]) => '<div class="metric">' + displayCurrency(amount, code) + "</div>").join("") : empty(message);
    };
    const plansHTML = plans.map(plan => {
      const status = arrivedIDs.has(plan.id) ? "该月已确认" : !plan.isEnabled ? "已停用" : incomeMonth < plan.startMonth ? "尚未开始" : incomeMonth > currentMonth() ? "预计收入" : "";
      const [year,m] = incomeMonth.split("-").map(Number);
      const date = Math.min(new Date(year,m,0).getDate(), Number(plan.dayOfMonth));
      const detail = "每月 " + plan.dayOfMonth + " 日 · " + e(plan.startMonth) + " 起 · " + e(incomeCategory(plan.category)) +
        (predicted.includes(plan) ? "<br>该月预计 " + e(incomeMonth + "-" + String(date).padStart(2,"0")) + " 到账" : "");
      return row(plan.name, detail, '<strong>' + displayCurrency(plan.amount, plan.currency) + "</strong>" + (status ? '<span class="pill">' + status + "</span>" :
        action("income-confirm","确认到账…",plan.id)) + action("income-edit","编辑计划",plan.id) +
        action("income-toggle",plan.isEnabled ? "停用" : "启用",plan.id));
    }).join("");
    mount(root, header("固定收入","按月查看预计收入。实际收到后，请选择收款账户并确认到账。",action("income-edit",icon("plus") + "新建收入计划","",true)) +
      '<div class="row fixed-month">' + action("income-prev","‹ 上个月") + "<strong>" + e(incomeMonth) + "</strong>" + action("income-next","下个月 ›") +
      action("income-current","本月") + '</div><div class="fixed-totals">' +
      panel("待确认的预计收入",totals(predicted,"没有待确认收入")) + panel("本月归属的已确认收入",totals(arrived,"尚未确认到账")) + "</div>" +
      ((state.recurring || []).some(rule => rule.kind === "income" && rule.isEnabled) ? '<div class="banner">账本中另有自动入账的周期收入规则。请勿为同一笔收入重复设置。</div>' : "") +
      panel("收入计划", plansHTML || empty("还没有收入计划。可添加工资、补贴或其他按月收到的款项。")) +
      panel("该月确认记录", arrived.map(receipt => row(receipt.name, "到账 " + e(receipt.received?.slice(0,10)) + " · " + e(receipt.accountName) + " · " +
        e(receipt.ledgerStatus || "已确认"), '<strong>' + displayCurrency(receipt.amount, receipt.currency) + "</strong>")).join("") || empty("暂无记录")));
  }
  function editIncome(plan) {
    const codes = state.currencies.map(currency => [currency.id,currency.name + " · " + currency.id]);
    formEditor({
      title: plan ? "编辑固定收入计划" : "新建固定收入计划", subtitle: "先写预计，实际到账后再确认入账。", button:"保存计划",
      body: group("收入信息", field("name","收入名称",plan?.name,'required maxlength="120"') +
        pick("category","分类",Object.keys(state.fixedIncome.categories).map(key => [key,incomeCategory(key)]),plan?.category || "salary-income") +
        pick("currency","币种",codes,plan?.currency || state.currency) + field("amount","每月金额",plan?.amount,'required type="number" min="0.01" step="0.01"')) +
        group("到账安排", field("dayOfMonth","预计每月到账日",plan?.dayOfMonth || 1,'required type="number" min="1" max="31"') +
          field("startMonth","起始月份",plan?.startMonth || currentMonth(), plan ? "readonly" : 'required type="month" min="' + currentMonth() + '"') +
          empty("短月按该月最后一天预计。保存计划不会增加账户余额。")),
      path:"/api/fixed-income/save", prepare:payload => Object.assign(payload,{id:plan?.id,isEnabled:plan?.isEnabled ?? true})
    });
  }
  function confirmIncome(plan) {
    formEditor({
      title:"确认固定收入到账", subtitle:"只有真实收到的款项才进入账本。", button:"确认并记入账本",
      body:group("到账信息",'<strong>' + e(plan.name) + " · " + e(incomeMonth) + " · " + displayCurrency(plan.amount,plan.currency) + "</strong>") +
        group("收款账户与日期",pick("accountID","实际收款账户",accountChoices(plan.currency),"",true) +
          field("receivedOn","实际到账日期",today(),'required type="date" max="' + today() + '"') +
          checkbox("receivedIsConfirmed","我已核对账户，确认这笔收入实际到账",false,"required")),
      path:"/api/fixed-income/confirm", prepare:payload => Object.assign(payload,{month:incomeMonth,planID:plan.id})
    });
  }

  function unavailable(root, monthly) {
    mount(root, '<div class="card fixed-unavailable">' + icon("tray.full.fill") + '<p>' + e(monthly.notice) + '</p><div class="row">' +
      action("reload","重新读取") + (monthly.status === "missing" ? action("create-monthly","从未使用月供，建立空白业务库…","",true) : "") + "</div></div>");
  }
  function renderExpenses(root, monthly) {
    const writable = monthly.status === "ready";
    const views = {
      subscription: () => '<div class="row fixed-filter"><input type="search" id="fixed-sub-search" aria-label="搜索订阅名称" placeholder="搜索订阅名称" value="' +
        e(filter) + '">' + checkbox("archived","含归档",showArchivedSubs,'id="fixed-archive-subs"') + '</div><div id="fixed-subscriptions-list">' + subscriptionRows() + "</div>",
      bills: () => empty("近一年待核实及未来 90 天账期。月卡可提前续费并填写实际覆盖期数。") +
        paginated(monthly.bills || [], bill => row(bill.name, e(bill.due) + " · 预计 " + displayCurrency(bill.price,bill.currency),
          action("pay","核实本期",bill.id,true,!writable)), "没有待核实账期。", "显示更多账期"),
      payments: () => paginated(monthly.payments, payment => row(subById(payment.subscriptionID)?.name || "未识别订阅",
        e(payment.paidAt) + " · " + (payment.skipped ? "本期未扣" : displayCurrency(payment.amount,payment.currency)) +
        " · 覆盖 " + (payment.periods || 1) + " 期" + (payment.note ? " · " + e(payment.note) : ""), action("pay-edit","更正",payment.id,false,!writable) +
        action("payment-delete","撤销",payment.id,false,!writable)), "还没有已核实的支付。", "显示更多支付"),
      events: () => '<div class="row">' + action("event-edit","新增到期事项","",true,!writable) + "</div>" +
        ((monthly.events || []).map(event => row(event.name, e(event.deadline.replace("T"," ")) + (event.doneAt ? " · 已完成" : " · 待办") +
          (event.note ? " · " + e(event.note) : ""), action("event-toggle",event.doneAt ? "撤销完成" : "标记完成",event.id,false,!writable) +
          action("event-edit","编辑",event.id,false,!writable) + action("event-delete","删除",event.id,false,!writable))).join("") || empty("没有到期事项。")),
      review: () => statistics(monthly, writable)
    };
    mount(root, header("固定支出","先安排账期，再核实实际支付。预计费用不会记入个人账本。",
      action("monthly-settings","提醒设置","",false,!writable) + action("subscription-edit",icon("plus") + "新增订阅","",true,!writable)) +
      (writable ? "" : '<div class="banner">' + e(monthly.notice) + "</div>") +
      '<div class="segmented fixed-expense-tab" aria-label="内容">' + expenseTabs.map(([id,title]) =>
        '<button type="button" class="' + (id === expenseTab ? "active" : "") + '" data-fixed="expense-tab" data-id="' + id + '">' + title + "</button>").join("") +
      '</div><div class="fixed-tab-body">' + views[expenseTab]() + "</div>");
  }
  function paginated(rows, build, emptyText, more) {
    return (rows.slice(0,count).map(build).join("") || empty(emptyText)) + (rows.length > count ? action("more",more) : "");
  }
  function subscriptionRows() {
    const writable = state.monthly.status === "ready";
    const visible = subs().filter(sub => (showArchivedSubs || !sub.archived) && sub.name.toLowerCase().includes(filter.trim().toLowerCase()))
      .sort((a,b) => a.name.localeCompare(b.name, "zh-CN"));
    return visible.map(sub => row(sub.name, (sub.archived ? "已归档" : sub.cancelledAt ? "已取消" : "进行中") + " · " + e(cycleName(sub.cycle)) +
      " · " + displayCurrency(sub.price,sub.currency) + " · " + sub.planCount + " 段计划",
      (sub.nextRenewal ? action("renew","续费",sub.id,true,!writable) : "") + action("subscription-edit","编辑",sub.id,false,!writable) +
      action("subscription-archive",sub.archived ? "取消归档" : "归档",sub.id,false,!writable) +
      action("subscription-delete","删除",sub.id,false,!writable))).join("") || empty("没有符合条件的订阅。");
  }
  function editSubscription(sub) {
    const now = state.monthly.today;
    formEditor({
      title: sub ? "编辑订阅" : "新增订阅", path:"/api/monthly/subscription",
      body:group("订阅信息", field("name","订阅名称",sub?.name,"required") + field("category","分类",sub?.category || "影音") +
        field("link","服务链接",sub?.link) + field("note","备注",sub?.note) +
        checkbox("autoRenew","自动续费",sub?.autoRenew ?? true) + checkbox("cancelIntent","计划取消",sub?.cancelIntent) +
        checkbox("stacking","月卡模式（按覆盖期数叠加）",sub?.stacking)) +
        group("费用与账期", pick("currency","币种",accruingCurrencies.map(code => [code,code]),sub?.currency || "CNY") +
          field("price","金额",sub?.price,'required type="number" min="0.01" step="0.01"') +
          pick("cycle","周期",cycles,sub?.cycle || "monthly") + field("interval","自定义周期天数",sub?.interval || 30,'type="number" min="1" max="3650"') +
          field("anchor","账期锚点",sub?.anchor || now,'type="date" required') + checkbox("monthEnd","按月末",sub?.monthEnd) +
          field(sub ? "effective" : "start",sub ? "计划变更生效日" : "计划开始日",now,'type="date" required')) +
        group("试用、取消和提醒",field("trialEnd","试用截止",sub?.trialEnd,'type="date"') + checkbox("trialResolved","试用已处理",sub?.trialResolved) +
          field("cancelDeadline","取消截止",sub?.cancelDeadline,'type="date"') + field("cancelledAt","取消日期",sub?.cancelledAt,'type="date" max="' + now + '"') +
          field("serviceEnd","权益服务截止日期",sub?.serviceEnd,'type="date"') +
          field("reminderDays","专属提前提醒天数",sub?.reminderDays,'type="number" min="0" max="365"')),
      prepare:payload => Object.assign(payload,{id:sub?.id,benefit:sub?.benefit || "none"})
    });
  }
  function editPayment(bill, prior) {
    if (!bill) return;
    const sub = subById(bill.subscriptionID);
    const code = prior?.currency || bill.currency;
    formEditor({
      title:prior ? "更正支付" : "核实本期支付", subtitle:(sub?.name || "订阅") + " · 账期 " + bill.due, path:"/api/monthly/pay",
      body:group("实际支付", checkbox("skipped","本期未扣款",prior?.skipped) +
        field("amount","实际金额",prior?.amount ?? bill.price,'required type="number" min="0" step="0.01"') +
        pick("currency","币种",accruingCurrencies.map(c => [c,c]),code) +
        field("paidAt","实际日期",prior?.paidAt || state.monthly.today,'required type="date" max="' + state.monthly.today + '"') +
        (sub?.stacking ? field("periods","实际覆盖期数",prior?.periods ?? 1,'required type="number" min="1" max="120"') : "") +
        field("note","备注",prior?.note)) +
        group("扣款账户", pick("accountID","用于记账",[["","沿用关联账户或稍后对账"],...sameCurrency(code)],prior?.accountID || "") +
          checkbox("rememberAccount","将该账户用于本订阅后续已确认支付") +
          empty("确认的是已发生的支付。预计账期和未扣款不会进入个人账本。")),
      onOpen(form) {
        const update = () => {
          const account = form.elements.accountID;
          const selected = account.value;
          account.replaceChildren(new Option("沿用关联账户或稍后对账",""));
          for (const [id,name] of sameCurrency(form.elements.currency.value)) account.add(new Option(name,id));
          if ([...account.options].some(option => option.value === selected)) account.value = selected;
          for (const name of ["accountID","rememberAccount"]) form.elements[name].disabled = form.elements.skipped.checked;
        };
        form.elements.currency.onchange = update;
        form.elements.skipped.onchange = update;
        update();
      },
      prepare:payload => Object.assign(payload,{id:prior?.id,billID:prior ? undefined : bill.id,subscriptionID:bill.subscriptionID,due:bill.due})
    });
  }
  function eventEditor(prior) {
    formEditor({
      title:prior ? "编辑到期事项" : "新增到期事项", path:"/api/monthly/event",
      body:group("事项信息",field("name","事项名称",prior?.name,"required") +
        field("deadline","到期时间",prior?.deadline || state.monthly.today + "T09:00",'required type="datetime-local"') +
        pick("subscriptionID","关联订阅",subsChoices("不关联"),prior?.subscriptionID || "") + field("note","备注",prior?.note)),
      prepare:payload => payload.id = prior?.id
    });
  }
  function settingsEditor() {
    const prefs = state.monthly.preferences || {};
    formEditor({
      title:"固定支出提醒设置", path:"/api/monthly/preferences",
      body:group("业务日期与隐私",field("timezone","业务时区（IANA）",prefs.timezone,'placeholder="Asia/Shanghai"') +
        field("reminderDays","提前提醒天数",prefs.reminderDays,'type="number" min="0" max="365"') +
        field("reminderHour","提醒小时",prefs.reminderHour,'type="number" min="0" max="23"') +
        checkbox("notifications","显示固定支出、试用和到期事项提醒",prefs.notifications) +
        checkbox("privacy","隐私模式：隐藏提醒中的业务详情",prefs.privacy))
    });
  }
  function statistics(monthly, writable) {
    const code = statisticsCurrency;
    const points = Array.from({length:12}, (_,i) => dateShift(monthly.monthKey, i - 11)).map(month => {
      const items = monthly.payments.filter(payment => !payment.skipped && payment.currency === code && payment.paidAt.startsWith(month));
      return {month,count:items.length,amount:items.reduce((total,payment) => total + Number(payment.amount || 0),0)};
    });
    const max = Math.max(1,...points.map(point => point.amount));
    const inCurrency = subs().filter(sub => sub.currency === code);
    const monthlyCost = sub => Number(sub.price || 0) * (sub.cycle === "days" ? 365 / Math.max(1,sub.interval) / 12 :
      ({weekly:52/12,monthly:1,quarterly:1/3,yearly:1/12}[sub.cycle] || 1));
    const categoryTotals = new Map();
    for (const sub of inCurrency.filter(sub => !sub.archived && !sub.cancelledAt && sub.start <= monthly.today &&
      (!sub.trialEnd || sub.trialResolved || sub.trialEnd < monthly.today))) {
      categoryTotals.set(sub.category, (categoryTotals.get(sub.category) || 0) + monthlyCost(sub));
    }
    return '<div class="row fixed-filter"><h2>支出统计与价值复盘</h2><label>币种<select id="fixed-statistics-currency">' +
      accruingCurrencies.map(c => "<option" + (c === code ? " selected" : "") + ">" + c + "</option>").join("") + "</select></label></div>" +
      empty("实际支出按业务时区和支付日汇总，仅计已确认扣款。估算按币种分别计算。") +
      '<div class="fixed-totals">' + panel("本月确认支付",'<div class="metric">' + displayCurrency(points.at(-1).amount,code) + "</div>") +
      panel("当前订阅月化预计",'<div class="metric">' + displayCurrency([...categoryTotals.values()].reduce((a,b) => a+b,0),code) + "</div>") +
      panel("按现价预计全年",'<div class="metric">' + displayCurrency([...categoryTotals.values()].reduce((a,b) => a+b,0) * 12,code) + "</div>") + "</div>" +
      panel("近十二个月 · 实际支付",points.map(point => '<div class="fixed-stat-row"><span>' + point.month + '</span><div class="bar"><span style="width:' +
        point.amount/max*100 + '%"></span></div><small>' + point.count + " 笔 · " + displayCurrency(point.amount,code) + "</small></div>").join("")) +
      panel("按分类月折算",[...categoryTotals].map(([category,amount]) => row(category,"",displayCurrency(amount,code))).join("") || empty("暂无有效订阅。")) +
      panel("订阅使用回顾",inCurrency.map(sub => {
        const detail = sub.cancelledAt ? "已取消 · " + sub.cancelledAt : sub.archived ? "已归档" :
          sub.usage?.reviewRenewal ? "连续两个完整月使用较少，可复盘是否续费" : sub.usage?.label || "未评估";
        return row(sub.name, e(detail),
          action("review-edit","评价与历史",sub.id,false,!writable));
      }).join("") || empty("此币种尚无订阅。"));
  }
  function reviewEditor(sub) {
    const score = [["-1","无评价"],["0","较少使用"],["1","偶尔使用"],["2","经常使用"]];
    const reviews = state.monthly.reviews.filter(review => review.subscriptionID === sub.id).sort((a,b) => b.month.localeCompare(a.month));
    formEditor({
      title:sub.name + " · 月度评价", path:"/api/monthly/review", button:"保存该月评价",
      body:group("月度评价",field("month","评价月份",state.monthly.monthKey,'required type="month" max="' + state.monthly.monthKey + '"') +
        pick("rating","使用频率",score,String(reviews.find(review => review.month === state.monthly.monthKey)?.rating ?? -1))) +
        group("已保存的历史评价",reviews.map(review => row(review.month,e(score.find(choice => Number(choice[0]) === review.rating)?.[1]))).join("") || empty("尚无记录。")),
      onOpen(form) {
        form.elements.month.onchange = () => form.elements.rating.value = String(reviews.find(review => review.month === form.elements.month.value)?.rating ?? -1);
      },
      prepare:payload => payload.subscriptionID = sub.id
    });
  }
  function renderBenefits(root, monthly) {
    const writable = monthly.status === "ready";
    const visible = monthly.benefits.filter(benefit => showArchivedBenefits || !benefit.archived);
    mount(root, header("权益打卡","记录日领或周领权益；实际领取请到服务平台完成。",
      checkbox("archived","含归档",showArchivedBenefits,'id="fixed-archive-benefits"') + action("benefit-edit",icon("plus") + "新增权益","",true,!writable)) +
      (writable ? "" : '<div class="banner">' + e(monthly.notice) + "</div>") +
      (visible.map(benefit => row(benefit.name, (benefit.kind === "weekly" ? "每周权益" : "每日权益") + " · " +
        e(subById(benefit.subscriptionID)?.name || "独立权益") + (benefit.archived ? " · 归档" : ""),
        action("benefit-claim",benefit.claimed ? "本期已记" : "标记已领取",benefit.id,true,!writable || benefit.claimed || !benefit.periodKey) +
        action("benefit-history","历史 / 补记",benefit.id) + action("benefit-edit","编辑",benefit.id,false,!writable) + action("benefit-delete","删除",benefit.id,false,!writable))).join("") ||
        empty("暂无权益，可新建独立权益或关联订阅。")));
  }
  function editBenefit(benefit) {
    formEditor({
      title:benefit ? "编辑权益" : "新增权益", path:"/api/monthly/benefit",
      body:group("权益信息",field("name","权益名称",benefit?.name,"required") + pick("kind","领取周期",benefitKinds,benefit?.kind || "daily") +
        pick("subscriptionID","关联订阅",subsChoices("独立权益"),benefit?.subscriptionID || "") + field("note","备注",benefit?.note) +
        checkbox("archived","已归档",benefit?.archived)),
      prepare:payload => payload.id = benefit?.id
    });
  }
  function historyEditor(benefit) {
    const monthly = state.monthly;
    const history = monthly.claims.filter(claim => claim.id.toLowerCase().startsWith(benefit.id.toLowerCase() + "|"))
      .sort((a,b) => b.date.localeCompare(a.date));
    const writable = monthly.status === "ready" && !benefit.archived;
    openEditor({
      title:benefit.name + " · 领取历史", submitLabel:"补记领取",
      body:(writable ? group("按实际日期补记",field("date","实际领取日期",monthly.today,'required type="date" max="' + monthly.today + '"')) : "") +
        group("历史记录",history.map(claim => row(claim.date,claim.backfill ? "补记" : "已领取",
          action("claim-delete","撤销",claim.id,false,!writable))).join("") || empty("暂无历史记录。")),
      onOpen: form => form.querySelectorAll("[data-fixed]").forEach(button => button.onclick = event => {
        event.stopPropagation();
        change("claims","delete",button.dataset.id,"撤销这次领取记录？").then(() => historyEditor(benefit)).catch(showError);
      }),
      onSubmit:writable ? async form => {
        await api("/api/monthly/claim",{id:benefit.id,date:form.elements.date.value});
        historyEditor(benefit);
        return false;
      } : null
    });
  }
  function change(collection, operation, id, confirmation) {
    if (confirmation && !confirm(confirmation)) return Promise.resolve();
    return api("/api/monthly/change",{collection,operation,id});
  }
  function fixedClick(event) {
    const button = event.target.closest("[data-fixed]");
    if (!button || button.disabled) return;
    const id = button.dataset.id;
    const monthly = state.monthly;
    const plan = state.fixedIncome.plans.find(plan => plan.id === id);
    const benefit = monthly.benefits.find(item => item.id === id);
    const actions = {
      reload:() => refresh(),
      "create-monthly":() => confirm("仅适用于从未使用月供的用户。建立新的固定支出业务库？") && api("/api/monthly/create",{}),
      "income-prev":() => { incomeMonth = dateShift(incomeMonth,-1); render("fixed-income"); },
      "income-next":() => { incomeMonth = dateShift(incomeMonth,1); render("fixed-income"); },
      "income-current":() => { incomeMonth = currentMonth(); render("fixed-income"); },
      "income-edit":() => editIncome(plan),
      "income-confirm":() => confirmIncome(plan),
      "income-toggle":() => api("/api/fixed-income/enable",{id,enabled:!plan.isEnabled}),
      "expense-tab":() => { expenseTab = id; count = 30; render("fixed-expenses"); },
      more:() => { count += 50; render("fixed-expenses"); },
      "subscription-edit":() => editSubscription(subById(id)),
      "subscription-delete":() => change("subscriptions","delete",id,"删除此订阅和支付历史？已关联的自动流水也将撤销。"),
      "subscription-archive":() => change("subscriptions","archive",id),
      "monthly-settings":settingsEditor,
      pay:() => editPayment(monthly.bills.find(bill => bill.id === id)),
      renew:() => editPayment(subById(id)?.nextRenewal),
      "pay-edit":() => {
        const payment = monthly.payments.find(row => row.id === id);
        if (payment) editPayment(payment,payment);
      },
      "payment-delete":() => change("payments","delete",id,"撤销这笔支付？已关联的自动流水也将撤销。"),
      "event-edit":() => eventEditor(monthly.events.find(event => event.id === id)),
      "event-toggle":() => change("events","toggle",id),
      "event-delete":() => change("events","delete",id,"删除这个到期事项？"),
      "benefit-edit":() => editBenefit(benefit),
      "benefit-claim":() => api("/api/monthly/claim",{id,periodKey:benefit.periodKey}),
      "benefit-history":() => historyEditor(benefit),
      "benefit-delete":() => change("benefits","delete",id,"删除该权益及领取历史？"),
      "review-edit":() => reviewEditor(subById(id))
    };
    Promise.resolve().then(actions[button.dataset.fixed]).catch(showError);
  }
  function render(section) {
    const root = document.getElementById(section);
    const monthly = state.monthly;
    if (section === "fixed-income") return renderIncome(root);
    if (!["ready","readonly"].includes(monthly.status)) return unavailable(root,monthly);
    if (section === "benefits") return renderBenefits(root,monthly);
    return renderExpenses(root,monthly);
  }
  function reconciliation() {
    const payments = state.monthly?.reconciliation || [];
    return payments.length ? panel("待记入账本的已确认月供",payments.slice(0,10).map(payment => row(payment.name,e(payment.paidAt) + " · " +
      displayCurrency(payment.amount,payment.currency),'<button type="button" class="ghost" data-reconcile="' + e(payment.id) + '">补记</button>' +
      '<button type="button" class="ghost" data-reconcile-ignore="' + e(payment.id) + '">忽略</button>')).join("")) : "";
  }
  function bindReconciliation(root) {
    for (const button of root.querySelectorAll("[data-reconcile],[data-reconcile-ignore]")) {
      button.onclick = () => {
        const missing = state.monthly.reconciliation.find(row => row.id === (button.dataset.reconcile || button.dataset.reconcileIgnore));
        if (button.dataset.reconcileIgnore) {
          if (confirm("忽略这笔已确认支付的记账提醒？")) api("/api/monthly/reconcile",{id:missing.id,ignore:true}).catch(showError);
          return;
        }
        formEditor({
          title:"补记已确认月供", subtitle:missing.name + " · " + missing.paidAt, path:"/api/monthly/reconcile", button:"确认记账",
          body:group("扣款账户",pick("accountID","实际扣款账户",accountChoices(missing.currency),missing.accountID || "",true)),
          prepare:payload => payload.id = missing.id
        });
      };
    }
  }
  window.GaoFixed = {render,reconciliation,bindReconciliation};
})();
