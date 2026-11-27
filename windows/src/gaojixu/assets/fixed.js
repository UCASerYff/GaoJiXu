(() => {
  const e = escapeHTML;
  const fixedMessages = new Map([
    ["固定支出库尚未创建。缺失时不会新建空库。", "The fixed-finance library has not been created."],
    ["固定支出库不是普通文件，未创建或替换。", "The fixed-finance path does not point to a regular file. The data was preserved."],
    ["月供业务库版本不受支持，原文件未改。", "This fixed-finance library version is unsupported. The original file was preserved."],
    ["月供业务记录格式有误，原文件未改。", "The fixed-finance records could not be validated. The original file was preserved."],
    ["月供业务库无法读取，原文件未改。", "The fixed-finance library could not be read. The original file was preserved."],
    ["固定支出可以查看。写入凭据不在这台电脑上，未改原库。", "You can view fixed expenses. Write authorization is unavailable on this PC."],
    ["固定支出库不能写入。", "The fixed-finance library cannot be updated."],
    ["固定支出刚被更新，请刷新并重新核对。", "Fixed expense data just changed. Refresh and verify it again."],
    ["固定支出资料授权已变化，停止写入。", "Fixed expense authorization changed. The update was stopped."],
    ["月供业务记录未落盘。", "The fixed expense record could not be saved."],
    ["目标已有资料，不能重新初始化。", "The destination already contains data. Initialization was blocked."],
    ["这个币种不在固定支出支持范围内。", "Fixed expenses do not support this currency."],
    ["请填写有效金额，并使用该币种支持的小数位。", "Enter a valid amount using the currency’s supported precision."],
    ["请填写订阅名称。", "Enter the subscription name."],
    ["扣费周期无法识别。", "Choose a valid billing cycle."],
    ["周期间隔无效。", "The billing interval is invalid."],
    ["权益类型无法识别。", "The benefit type is invalid."],
    ["这项订阅已变化。", "This subscription has changed. Refresh and try again."],
    ["变更生效日不能早于当前计划开始日。", "The effective date cannot precede the current plan."],
    ["取消日期不能是未来日期。", "The cancellation date cannot be in the future."],
    ["提前提醒天数无效。", "The reminder lead time is invalid."],
    ["没有这项订阅。", "This subscription could not be found."],
    ["实际日期不能是未来日期。", "The payment date cannot be in the future."],
    ["这笔支付已变化。", "This payment has changed. Refresh and try again."],
    ["本账期已变化，请重新选择。", "This billing period has changed. Select it again."],
    ["这一期已经记过，没有重复入账。", "This billing period already has a payment record."],
    ["覆盖期数应在 1 到 120 之间。", "Enter between 1 and 120 periods."],
    ["请填写权益名称，并选择每日或每周。", "Enter a benefit name and select daily or weekly."],
    ["关联的订阅不存在。", "The linked subscription could not be found."],
    ["这项权益已变化。", "This benefit has changed. Refresh and try again."],
    ["没有这项权益。", "This benefit could not be found."],
    ["不能补记未来的权益。", "Claims cannot be recorded for future dates."],
    ["对应日期的权益不可记录。", "The benefit cannot be recorded for the selected date."],
    ["领取周期已变化，请刷新后重试。", "The claim period has changed. Refresh and try again."],
    ["记录类型无法识别。", "The record type is invalid."],
    ["记录已变化。", "This record has changed. Refresh and try again."],
    ["记录操作无效。", "This operation is unavailable for the record."],
    ["请填写事项名称。", "Enter a title for the deadline."],
    ["这项到期事项已变化。", "This deadline has changed. Refresh and try again."],
    ["评价月份或使用频率无效。", "Choose a valid month and usage rating."],
    ["请输入有效的 IANA 时区，例如 Asia/Shanghai。", "Enter a valid IANA time zone, such as Asia/Shanghai."],
    ["提醒日期或时间无效。", "The reminder date or time is invalid."],
    ["月供对账设置无法读取，原文件已保留。", "The reconciliation settings could not be read. The original file was preserved."],
    ["月供对账设置格式无法读取，原文件已保留。", "The reconciliation settings format is unrecognized. The original file was preserved."],
    ["待对账任务格式无法读取，原文件已保留。", "The queued reconciliation tasks could not be read. The original file was preserved."],
    ["请选择一个仍在使用、且与订阅同币种的扣款账户。", "Choose an active payment account in the subscription’s currency."],
    ["这笔已确认的支付已变化。", "This confirmed payment has changed. Refresh and try again."],
    ["请先确认这笔款项已经实际到账。", "Confirm that you have received the funds."],
    ["请选择有效的所属月份。", "Choose a valid receipt month."],
    ["这项计划已发生变化，请关闭表单后重新选择。", "This plan has changed. Close the form and select it again."],
    ["只能确认从计划起始月到本月的收入。", "You can confirm receipts from the plan’s start month through the current month."],
    ["请选择一个仍在使用、且与计划同币种的收款账户。", "Choose an active account in the plan’s currency."],
    ["实际到账日期不能早于计划起始月，也不能是未来日期。", "The receipt date must fall between the plan’s start month and today."],
    ["计划已停用，不能确认新的到账。", "Enable the plan before confirming a new receipt."],
    ["新计划的起始月份不能早于本月。", "A new plan cannot start before this month."],
    ["没有这项固定收入。", "This fixed income plan could not be found."],
    ["该月的流水或回执存在冲突；没有创建新的收入。请先核对原记录。", "The month has a conflicting transaction or receipt. Check the existing records before confirming income."],
    ["请填写收入名称、有效的正数金额和每月 1 至 31 日的预计到账日。", "Enter an income name, a positive amount, and an expected day between 1 and 31."],
    ["原流水已删除，保留确认记录", "Original transaction deleted; receipt retained"],
    ["已入账", "Recorded"],
    ["原流水已调整", "Original transaction edited"],
    ["数据不足", "Insufficient history"],
    ["较少使用", "Rarely used"],
    ["偶尔使用", "Sometimes used"],
    ["经常使用", "Often used"],
    ["未评估", "Not reviewed"],
    ["资料写入未能完成，恢复后将重新核对。", "The update could not be saved. It will be checked again when the data is available."],
    ["时间格式无法识别。", "Enter a valid date or time."],
    ["请求无法读取。", "The request could not be read."],
  ]);
  const message = (text) => t(text, fixedMessages.get(text));
  const cycles = () => [["weekly",t("每周","Weekly")],["monthly",t("每月","Monthly")],["quarterly",t("每季","Quarterly")],["yearly",t("每年","Yearly")],["days",t("自定义天数","Custom days")]];
  const accruingCurrencies = ["CNY","USD","EUR","HKD","JPY","GBP"];
  const expenseTabs = () => [["subscription",t("订阅","Subscription")],["bills",t("待核实账期","Upcoming and unverified")],["payments",t("支付历史","Payment history")],["events",t("到期事项","Deadlines")],["review",t("统计与复盘","Spending and review")]];
  const benefitKinds = () => [["daily",t("每日","Daily")],["weekly",t("每周","Weekly")]];
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
  const accountChoices = currency => [["",t("请选择账户","Choose an account")], ...sameCurrency(currency)];
  const subsChoices = label => [["", label], ...subs().map(sub => [sub.id, sub.name])];
  const displayCurrency = (amount, code) => e(code) + " " + money(amount, code);
  const cycleName = id => cycles().find(choice => choice[0] === id)?.[1] || id;
  const englishIncome = {"salary-income":"Salary","bonus-income":"Bonus","side-income":"Side income",
    "investment-income":"Investment income","gift-income":"Gift income","other-income":"Other income"};
  const currencyNames = new Intl.DisplayNames(["en"], {type:"currency"});
  const incomeCategory = key => t(state.fixedIncome.categories[key] || "收入", englishIncome[key] || "Income");
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
    const revision = state.monthly?.revision;
    return openEditor({
      title: config.title, subtitle: config.subtitle, body: config.body, submitLabel: config.button, width: config.width || 580,
      onOpen: config.onOpen,
      onSubmit: async form => {
        const payload = val(form);
        for (const input of form.querySelectorAll('input[type="checkbox"]')) payload[input.name] = input.checked;
        if (revision && config.path.startsWith("/api/monthly/")) payload.expectedRevision = revision;
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
      const status = arrivedIDs.has(plan.id) ? t("该月已确认","Confirmed for this month") : !plan.isEnabled ? t("已停用","Disabled") : incomeMonth < plan.startMonth ? t("尚未开始","Not started") : incomeMonth > currentMonth() ? t("预计收入","Expected income") : "";
      const [year,m] = incomeMonth.split("-").map(Number);
      const date = Math.min(new Date(year,m,0).getDate(), Number(plan.dayOfMonth));
      const firstMonth = e(plan.startMonth);
      const predictedDate = e(incomeMonth + "-" + String(date).padStart(2,"0"));
      const detail = t(`每月 ${plan.dayOfMonth} 日 · ${firstMonth} 起 · `, `Monthly on day ${plan.dayOfMonth} · from ${firstMonth} · `) +
        e(incomeCategory(plan.category)) + (predicted.includes(plan) ? t(`<br>该月预计 ${predictedDate} 到账`, `<br>Expected on ${predictedDate}`) : "");
      return row(plan.name, detail, '<strong>' + displayCurrency(plan.amount, plan.currency) + "</strong>" + (status ? '<span class="pill">' + status + "</span>" :
        action("income-confirm",t("确认到账…","Confirm receipt…"),plan.id)) + action("income-edit",t("编辑计划","Edit plan"),plan.id) +
        action("income-toggle",plan.isEnabled ? t("停用","Disable") : t("启用","Enable"),plan.id));
    }).join("");
    mount(root, header(t("固定收入","Fixed income"),t("按月查看预计收入。实际收到后，请选择收款账户并确认到账。","View expected income by month. After the funds arrive, select the receiving account and confirm."),action("income-edit",icon("plus") + t("新建收入计划","New income plan"),"",true)) +
      '<div class="row fixed-month">' + action("income-prev",t("‹ 上个月","‹ Previous month")) + "<strong>" + e(incomeMonth) + "</strong>" + action("income-next",t("下个月 ›","Next month ›")) +
      action("income-current",t("本月","This month")) + '</div><div class="fixed-totals">' +
      panel(t("待确认的预计收入","Expected income awaiting confirmation"),totals(predicted,t("没有待确认收入","No income awaiting confirmation"))) + panel(t("本月归属的已确认收入","Confirmed income for this month"),totals(arrived,t("尚未确认到账","No receipts confirmed yet"))) + "</div>" +
      ((state.recurring || []).some(rule => rule.kind === "income" && rule.isEnabled) ? t('<div class="banner">账本中另有自动入账的周期收入规则。请勿为同一笔收入重复设置。</div>',"<div class=\"banner\">The ledger also has automatic recurring income. Use one schedule per payment.</div>") : "") +
      panel(t("收入计划","Income plans"), plansHTML || empty(t("还没有收入计划。可添加工资、补贴或其他按月收到的款项。","No income plans yet. Add a salary, allowance, or another monthly payment."))) +
      panel(t("该月确认记录","Receipts confirmed for this month"), arrived.map(receipt => row(receipt.name, t("到账 ","Received ") + e(receipt.received?.slice(0,10)) + " · " + e(receipt.accountName) + " · " +
        e(receipt.ledgerStatus ? message(receipt.ledgerStatus) : t("已确认","Confirmed")), '<strong>' + displayCurrency(receipt.amount, receipt.currency) + "</strong>")).join("") || empty(t("暂无记录","No records yet"))));
  }
  function editIncome(plan) {
    const codes = state.currencies.map(currency => [currency.id,t(currency.name,currencyNames.of(currency.id)) + " · " + currency.id]);
    formEditor({
      title: plan ? t("编辑固定收入计划","Edit fixed income plan") : t("新建固定收入计划","New fixed income plan"), subtitle: t("先写预计，实际到账后再确认入账。","Set the expectation now and record it once the funds arrive."), button:t("保存计划","Save plan"),
      body: group(t("收入信息","Income details"), field("name",t("收入名称","Income name"),plan?.name,'required maxlength="120"') +
        pick("category",t("分类","Category"),Object.keys(state.fixedIncome.categories).map(key => [key,incomeCategory(key)]),plan?.category || "salary-income") +
        pick("currency",t("币种","Currency"),codes,plan?.currency || state.currency) + field("amount",t("每月金额","Monthly amount"),plan?.amount,'required type="number" min="0.01" step="0.01"')) +
        group(t("到账安排","Receipt schedule"), field("dayOfMonth",t("预计每月到账日","Expected day of the month"),plan?.dayOfMonth || 1,'required type="number" min="1" max="31"') +
          field("startMonth",t("起始月份","Start month"),plan?.startMonth || currentMonth(), plan ? "readonly" : 'required type="month" min="' + currentMonth() + '"') +
          empty(t("短月按该月最后一天预计。保存计划不会增加账户余额。","Shorter months use their last day. Saving a plan leaves the account balance unchanged."))),
      path:"/api/fixed-income/save", prepare:payload => Object.assign(payload,{id:plan?.id,isEnabled:plan?.isEnabled ?? true})
    });
  }
  function confirmIncome(plan) {
    formEditor({
      title:t("确认固定收入到账","Confirm fixed income received"), subtitle:t("只有真实收到的款项才进入账本。","Only received funds enter the ledger."), button:t("确认并记入账本","Confirm and record"),
      body:group(t("到账信息","Receipt details"),'<strong>' + e(plan.name) + " · " + e(incomeMonth) + " · " + displayCurrency(plan.amount,plan.currency) + "</strong>") +
        group(t("收款账户与日期","Receiving account and date"),pick("accountID",t("实际收款账户","Receiving account"),accountChoices(plan.currency),"",true) +
          field("receivedOn",t("实际到账日期","Date received"),today(),'required type="date" max="' + today() + '"') +
          checkbox("receivedIsConfirmed",t("我已核对账户，确认这笔收入实际到账","I checked the account and confirmed receipt"),false,"required")),
      path:"/api/fixed-income/confirm", prepare:payload => Object.assign(payload,{month:incomeMonth,planID:plan.id})
    });
  }

  function unavailable(root, monthly) {
    mount(root, '<div class="card fixed-unavailable">' + icon("tray.full.fill") + '<p>' + e(message(monthly.notice)) + '</p><div class="row">' +
      action("reload",t("重新读取","Reload")) + (monthly.status === "missing" ? action("create-monthly",t("从未使用月供，建立空白业务库…","Create a new fixed-finance library…"),"",true) : "") + "</div></div>");
  }
  function renderExpenses(root, monthly) {
    const writable = monthly.status === "ready";
    const views = {
      subscription: () => t('<div class="row fixed-filter"><input type="search" id="fixed-sub-search" aria-label="搜索订阅名称" placeholder="搜索订阅名称" value="',"<div class=\"row fixed-filter\"><input type=\"search\" id=\"fixed-sub-search\" aria-label=\"Search subscriptions\" placeholder=\"Search subscriptions\" value=\"") +
        e(filter) + '">' + checkbox("archived",t("含归档","Include archived"),showArchivedSubs,'id="fixed-archive-subs"') + '</div><div id="fixed-subscriptions-list">' + subscriptionRows() + "</div>",
      bills: () => empty(t("近一年待核实及未来 90 天账期。月卡可提前续费并填写实际覆盖期数。","Unverified bills from the past year and projected bills for the next 90 days. For prepaid plans, record how many periods the payment covered.")) +
        paginated(monthly.bills || [], bill => row(bill.name, e(bill.due) + t(" · 预计 "," · Expected ") + displayCurrency(bill.price,bill.currency),
          action("pay",t("核实本期","Verify bill"),bill.id,true,!writable)), t("没有待核实账期。","No bills to verify."), t("显示更多账期","Show more bills")),
      payments: () => paginated(monthly.payments, payment => row(subById(payment.subscriptionID)?.name || t("未识别订阅","Unknown subscription"),
        e(payment.paidAt) + " · " + (payment.skipped ? t("本期未扣","No charge") : displayCurrency(payment.amount,payment.currency)) +
        t(" · 覆盖 "," · Covers ") + (payment.periods || 1) + t(" 期"," period(s)") + (payment.note ? " · " + e(payment.note) : ""), action("pay-edit",t("更正","Correct"),payment.id,false,!writable) +
        action("payment-delete",t("撤销","Undo"),payment.id,false,!writable)), t("还没有已核实的支付。","No verified payments yet."), t("显示更多支付","Show more payments")),
      events: () => '<div class="row">' + action("event-edit",t("新增到期事项","New deadline"),"",true,!writable) + "</div>" +
        ((monthly.events || []).map(event => row(event.name, e(event.deadline.replace("T"," ")) + (event.doneAt ? t(" · 已完成"," · Completed") : t(" · 待办"," · Pending")) +
          (event.note ? " · " + e(event.note) : ""), action("event-toggle",event.doneAt ? t("撤销完成","Mark incomplete") : t("标记完成","Mark complete"),event.id,false,!writable) +
          action("event-edit",t("编辑","Edit"),event.id,false,!writable) + action("event-delete",t("删除","Delete"),event.id,false,!writable))).join("") || empty(t("没有到期事项。","No deadlines."))),
      review: () => statistics(monthly, writable)
    };
    mount(root, header(t("固定支出","Fixed expenses"),t("先安排账期，再核实实际支付。预计费用不会记入个人账本。","Schedule bills and verify the actual payments. Forecasts stay outside the ledger."),
      action("monthly-settings",t("提醒设置","Reminder settings"),"",false,!writable) + action("subscription-edit",icon("plus") + t("新增订阅","New subscription"),"",true,!writable)) +
      (writable ? "" : '<div class="banner">' + e(message(monthly.notice)) + "</div>") +
      integrationWarning() +
      t('<div class="segmented fixed-expense-tab" aria-label="内容">',"<div class=\"segmented fixed-expense-tab\" aria-label=\"Fixed expense sections\">") + expenseTabs().map(([id,title]) =>
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
    return visible.map(sub => row(sub.name, (sub.archived ? t("已归档","Archived") : sub.cancelledAt ? t("已取消","Cancelled") : t("进行中","Active")) + " · " + e(cycleName(sub.cycle)) +
      " · " + displayCurrency(sub.price,sub.currency) + " · " + sub.planCount + t(" 段计划"," plan version(s)"),
      (sub.nextRenewal ? action("renew",t("续费","Renew"),sub.id,true,!writable) : "") + action("subscription-edit",t("编辑","Edit"),sub.id,false,!writable) +
      action("subscription-archive",sub.archived ? t("取消归档","Unarchive") : t("归档","Archive"),sub.id,false,!writable) +
      action("subscription-delete",t("删除","Delete"),sub.id,false,!writable))).join("") || empty(t("没有符合条件的订阅。","No matching subscriptions."));
  }
  function editSubscription(sub) {
    const now = state.monthly.today;
    formEditor({
      title: sub ? t("编辑订阅","Edit subscription") : t("新增订阅","New subscription"), path:"/api/monthly/subscription",
      body:group(t("订阅信息","Subscription details"), field("name",t("订阅名称","Subscription name"),sub?.name,"required") + field("category",t("分类","Category"),sub?.category || t("影音","Media")) +
        field("link",t("服务链接","Service link"),sub?.link) + field("note",t("备注","Note"),sub?.note) +
        checkbox("autoRenew",t("自动续费","Auto-renew"),sub?.autoRenew ?? true) + checkbox("cancelIntent",t("计划取消","Plan to cancel"),sub?.cancelIntent) +
        checkbox("stacking",t("月卡模式（按覆盖期数叠加）","Prepaid plan with multiple periods"),sub?.stacking)) +
        group(t("费用与账期","Price and billing schedule"), pick("currency",t("币种","Currency"),accruingCurrencies.map(code => [code,code]),sub?.currency || "CNY") +
          field("price",t("金额","Amount"),sub?.price,'required type="number" min="0.01" step="0.01"') +
          pick("cycle",t("周期","Cycle"),cycles(),sub?.cycle || "monthly") + field("interval",t("自定义周期天数","Custom interval in days"),sub?.interval || 30,'type="number" min="1" max="3650"') +
          field("anchor",t("账期锚点","Billing anchor date"),sub?.anchor || now,'type="date" required') + checkbox("monthEnd",t("按月末","Use month-end"),sub?.monthEnd) +
          field(sub ? "effective" : "start",sub ? t("计划变更生效日","Plan change effective date") : t("计划开始日","Plan start date"),now,'type="date" required')) +
        group(t("试用、取消和提醒","Trial, cancellation and reminders"),field("trialEnd",t("试用截止","Trial ends"),sub?.trialEnd,'type="date"') + checkbox("trialResolved",t("试用已处理","Trial resolved"),sub?.trialResolved) +
          field("cancelDeadline",t("取消截止","Cancel by"),sub?.cancelDeadline,'type="date"') + field("cancelledAt",t("取消日期","Cancellation date"),sub?.cancelledAt,'type="date" max="' + now + '"') +
          field("serviceEnd",t("权益服务截止日期","Benefits end date"),sub?.serviceEnd,'type="date"') +
          field("reminderDays",t("专属提前提醒天数","Days in advance for this subscription"),sub?.reminderDays,'type="number" min="0" max="365"')),
      prepare:payload => Object.assign(payload,{id:sub?.id,benefit:sub?.benefit || "none"})
    });
  }
  function editPayment(bill, prior) {
    if (!bill) return;
    const sub = subById(bill.subscriptionID);
    const code = prior?.currency || bill.currency;
    formEditor({
      title:prior ? t("更正支付","Correct payment") : t("核实本期支付","Verify this payment"), subtitle:(sub?.name || t("订阅","Subscription")) + t(" · 账期 "," · Bill due ") + bill.due, path:"/api/monthly/pay",
      body:group(t("实际支付","Actual payment"), checkbox("skipped",t("本期未扣款","No charge this period"),prior?.skipped) +
        field("amount",t("实际金额","Amount paid"),prior?.amount ?? bill.price,'required type="number" min="0" step="0.01"') +
        pick("currency",t("币种","Currency"),accruingCurrencies.map(c => [c,c]),code) +
        field("paidAt",t("实际日期","Date paid"),prior?.paidAt || state.monthly.today,'required type="date" max="' + state.monthly.today + '"') +
        (sub?.stacking ? field("periods",t("实际覆盖期数","Number of periods covered"),prior?.periods ?? 1,'required type="number" min="1" max="120"') : "") +
        field("note",t("备注","Note"),prior?.note)) +
        group(t("扣款账户","Payment account"), pick("accountID",t("用于记账","Ledger account"),[["",t("沿用关联账户或稍后对账","Use the linked account or reconcile later")],...sameCurrency(code)],prior?.accountID || "") +
          checkbox("rememberAccount",t("将该账户用于本订阅后续已确认支付","Use this account for future confirmed payments on this subscription")) +
          empty(t("确认的是已发生的支付。预计账期和未扣款不会进入个人账本。","Confirm a payment that has already occurred. Forecasts and skipped charges stay outside the ledger."))),
      onOpen(form) {
        const update = () => {
          const account = form.elements.accountID;
          const selected = account.value;
          account.replaceChildren(new Option(t("沿用关联账户或稍后对账","Use the linked account or reconcile later"),""));
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
      title:prior ? t("编辑到期事项","Edit deadline") : t("新增到期事项","New deadline"), path:"/api/monthly/event",
      body:group(t("事项信息","Deadline details"),field("name",t("事项名称","Title"),prior?.name,"required") +
        field("deadline",t("到期时间","Due at"),prior?.deadline || state.monthly.today + "T09:00",'required type="datetime-local"') +
        pick("subscriptionID",t("关联订阅","Linked subscription"),subsChoices(t("不关联","None")),prior?.subscriptionID || "") + field("note",t("备注","Note"),prior?.note)),
      prepare:payload => payload.id = prior?.id
    });
  }
  function settingsEditor() {
    const prefs = state.monthly.preferences || {};
    formEditor({
      title:t("固定支出提醒设置","Fixed expense reminders"), path:"/api/monthly/preferences",
      body:group(t("业务日期与隐私","Dates and privacy"),field("timezone",t("业务时区（IANA）","Business time zone (IANA)"),prefs.timezone,'placeholder="Asia/Shanghai"') +
        field("reminderDays",t("提前提醒天数","Days in advance"),prefs.reminderDays,'type="number" min="0" max="365"') +
        field("reminderHour",t("提醒小时","Reminder hour"),prefs.reminderHour,'type="number" min="0" max="23"') +
        checkbox("notifications",t("显示固定支出、试用和到期事项提醒","Show reminders for bills, trials, and deadlines"),prefs.notifications) +
        checkbox("privacy",t("隐私模式：隐藏提醒中的业务详情","Hide payment and subscription details in reminders"),prefs.privacy)) +
        group(t("Windows 桌面通知","Windows desktop notifications"),
          '<button type="button" class="ghost" id="fixed-notification-test">' + t("发送测试通知","Send a test notification") +
          '</button><p class="muted" id="fixed-notification-result" role="status"></p>') +
        group(t("月供跨应用联动","Monthly finance integration"), empty(integrationStatus()) +
          empty(t("目前没有已核实的外部月供提供方。只有通过授权验证的本地业务库可用于联动。","No external monthly finance provider has been verified. The receiver uses the authorized local database."))),
      onOpen(form) {
        form.querySelector("#fixed-notification-test").onclick = async event => {
          const button = event.currentTarget;
          const result = form.querySelector("#fixed-notification-result");
          button.disabled = true;
          try {
            await api("/api/desktop/notification-test",{language:t("zh","en")});
            result.textContent = t("已提交给 Windows。","Submitted to Windows.");
          } catch (error) {
            result.textContent = error.message;
          } finally {
            button.disabled = false;
          }
        };
      }
    });
  }
  function integrationStatus() {
    switch (state.monthlyIntegration?.source) {
      case "ready":
        return state.monthlyIntegration.transport === "windows-event" ?
          t("本会话正在监听 Windows 月供变更信号。", "Listening for Windows monthly finance changes in this session.") :
          t("本机正在定期检查已授权的月供业务库。", "Checking the authorized monthly finance database periodically.");
      case "authority-changed": return t("月供来源授权已变化，自动对账已暂停。", "Monthly finance authority has changed. Automatic reconciliation is paused.");
      case "readonly": case "protected": case "unverified":
        return t("目前无法核实月供资料授权或内容，自动对账已暂停。", "The monthly finance authorization or records could not be verified. Automatic reconciliation is paused.");
      default: return t("正在等待可核实的月供资料。", "Waiting for a verifiable monthly finance source.");
    }
  }
  function integrationWarning() {
    return ["authority-changed","unverified"].includes(state.monthlyIntegration?.source) ?
      '<div class="banner" role="status">' + e(integrationStatus()) + '</div>' : "";
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
    return t('<div class="row fixed-filter"><h2>支出统计与价值复盘</h2><label>币种<select id="fixed-statistics-currency">',"<div class=\"row fixed-filter\"><h2>Spending and subscription review</h2><label>Currency<select id=\"fixed-statistics-currency\">") +
      accruingCurrencies.map(c => "<option" + (c === code ? " selected" : "") + ">" + c + "</option>").join("") + "</select></label></div>" +
      empty(t("实际支出按业务时区和支付日汇总，仅计已确认扣款。估算按币种分别计算。","Totals use the business time zone and payment date. Confirmed charges and estimates are calculated separately for each currency.")) +
      '<div class="fixed-totals">' + panel(t("本月确认支付","Confirmed payments this month"),'<div class="metric">' + displayCurrency(points.at(-1).amount,code) + "</div>") +
      panel(t("当前订阅月化预计","Estimated monthly cost"),'<div class="metric">' + displayCurrency([...categoryTotals.values()].reduce((a,b) => a+b,0),code) + "</div>") +
      panel(t("按现价预计全年","Projected annual cost at current prices"),'<div class="metric">' + displayCurrency([...categoryTotals.values()].reduce((a,b) => a+b,0) * 12,code) + "</div>") + "</div>" +
      panel(t("近十二个月 · 实际支付","Last twelve months · Payments"),points.map(point => '<div class="fixed-stat-row"><span>' + point.month + '</span><div class="bar"><span style="width:' +
        point.amount/max*100 + '%"></span></div><small>' + point.count + t(" 笔 · "," payment(s) ·") + displayCurrency(point.amount,code) + "</small></div>").join("")) +
      panel(t("按分类月折算","Monthly estimate by category"),[...categoryTotals].map(([category,amount]) => row(category,"",displayCurrency(amount,code))).join("") || empty(t("暂无有效订阅。","No active subscriptions."))) +
      panel(t("订阅使用回顾","Subscription review"),inCurrency.map(sub => {
        const detail = sub.cancelledAt ? t("已取消 · ","Cancelled · ") + sub.cancelledAt : sub.archived ? t("已归档","Archived") :
          sub.usage?.reviewRenewal ? t("连续两个完整月使用较少，可复盘是否续费","Low usage for two full months. Review whether to renew.") : message(sub.usage?.label || "未评估");
        return row(sub.name, e(detail),
          action("review-edit",t("评价与历史","Rate and view history"),sub.id,false,!writable));
      }).join("") || empty(t("此币种尚无订阅。","No subscriptions in this currency.")));
  }
  function reviewEditor(sub) {
    const score = [["-1",t("无评价","No rating")],["0",t("较少使用","Rarely used")],["1",t("偶尔使用","Sometimes used")],["2",t("经常使用","Often used")]];
    const reviews = state.monthly.reviews.filter(review => review.subscriptionID === sub.id).sort((a,b) => b.month.localeCompare(a.month));
    formEditor({
      title:sub.name + t(" · 月度评价"," · Monthly ratings"), path:"/api/monthly/review", button:t("保存该月评价","Save monthly rating"),
      body:group(t("月度评价","Monthly rating"),field("month",t("评价月份","Month"),state.monthly.monthKey,'required type="month" max="' + state.monthly.monthKey + '"') +
        pick("rating",t("使用频率","Frequency of use"),score,String(reviews.find(review => review.month === state.monthly.monthKey)?.rating ?? -1))) +
        group(t("已保存的历史评价","Past ratings"),reviews.map(review => row(review.month,e(score.find(choice => Number(choice[0]) === review.rating)?.[1]))).join("") || empty(t("尚无记录。","No records yet."))),
      onOpen(form) {
        form.elements.month.onchange = () => form.elements.rating.value = String(reviews.find(review => review.month === form.elements.month.value)?.rating ?? -1);
      },
      prepare:payload => payload.subscriptionID = sub.id
    });
  }
  function renderBenefits(root, monthly) {
    const writable = monthly.status === "ready";
    const visible = monthly.benefits.filter(benefit => showArchivedBenefits || !benefit.archived);
    mount(root, header(t("权益打卡","Benefits"),t("记录日领或周领权益；实际领取请到服务平台完成。","Track daily or weekly benefits. Claim them on the service itself."),
      checkbox("archived",t("含归档","Include archived"),showArchivedBenefits,'id="fixed-archive-benefits"') + action("benefit-edit",icon("plus") + t("新增权益","New benefit"),"",true,!writable)) +
      (writable ? "" : '<div class="banner">' + e(message(monthly.notice)) + "</div>") +
      (visible.map(benefit => row(benefit.name, (benefit.kind === "weekly" ? t("每周权益","Weekly benefit") : t("每日权益","Daily benefit")) + " · " +
        e(subById(benefit.subscriptionID)?.name || t("独立权益","Standalone benefit")) + (benefit.archived ? t(" · 归档"," · Archived") : ""),
        action("benefit-claim",benefit.claimed ? t("本期已记","Recorded this period") : t("标记已领取","Mark claimed"),benefit.id,true,!writable || benefit.claimed || !benefit.periodKey) +
        action("benefit-history",t("历史 / 补记","History and backfill"),benefit.id) + action("benefit-edit",t("编辑","Edit"),benefit.id,false,!writable) + action("benefit-delete",t("删除","Delete"),benefit.id,false,!writable))).join("") ||
        empty(t("暂无权益，可新建独立权益或关联订阅。","No benefits yet. Create a standalone benefit or link one to a subscription."))));
  }
  function editBenefit(benefit) {
    formEditor({
      title:benefit ? t("编辑权益","Edit benefit") : t("新增权益","New benefit"), path:"/api/monthly/benefit",
      body:group(t("权益信息","Benefit details"),field("name",t("权益名称","Benefit name"),benefit?.name,"required") + pick("kind",t("领取周期","Claim interval"),benefitKinds(),benefit?.kind || "daily") +
        pick("subscriptionID",t("关联订阅","Linked subscription"),subsChoices(t("独立权益","Standalone benefit")),benefit?.subscriptionID || "") + field("note",t("备注","Note"),benefit?.note) +
        checkbox("archived",t("已归档","Archived"),benefit?.archived)),
      prepare:payload => payload.id = benefit?.id
    });
  }
  function historyEditor(benefit) {
    const monthly = state.monthly;
    const history = monthly.claims.filter(claim => claim.id.toLowerCase().startsWith(benefit.id.toLowerCase() + "|"))
      .sort((a,b) => b.date.localeCompare(a.date));
    const writable = monthly.status === "ready" && !benefit.archived;
    openEditor({
      title:benefit.name + t(" · 领取历史"," · Claim history"), submitLabel:t("补记领取","Backfill claim"),
      body:(writable ? group(t("按实际日期补记","Record a past claim"),field("date",t("实际领取日期","Actual claim date"),monthly.today,'required type="date" max="' + monthly.today + '"')) : "") +
        group(t("历史记录","History"),history.map(claim => row(claim.date,claim.backfill ? t("补记","Backfill") : t("已领取","Claimed"),
          action("claim-delete",t("撤销","Undo"),claim.id,false,!writable))).join("") || empty(t("暂无历史记录。","No claim history."))),
      onOpen: form => form.querySelectorAll("[data-fixed]").forEach(button => button.onclick = event => {
        event.stopPropagation();
        change("claims","delete",button.dataset.id,t("撤销这次领取记录？","Undo this claim record?")).then(() => historyEditor(benefit)).catch(showError);
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
    return api("/api/monthly/change",{collection,operation,id,expectedRevision:state.monthly.revision});
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
      "create-monthly":() => confirm(t("仅适用于从未使用月供的用户。建立新的固定支出业务库？","Create a new fixed-finance library? Use this only if you have never used the monthly finance module.")) && api("/api/monthly/create",{}),
      "income-prev":() => { incomeMonth = dateShift(incomeMonth,-1); render("fixed-income"); },
      "income-next":() => { incomeMonth = dateShift(incomeMonth,1); render("fixed-income"); },
      "income-current":() => { incomeMonth = currentMonth(); render("fixed-income"); },
      "income-edit":() => editIncome(plan),
      "income-confirm":() => confirmIncome(plan),
      "income-toggle":() => api("/api/fixed-income/enable",{id,enabled:!plan.isEnabled}),
      "expense-tab":() => { expenseTab = id; count = 30; render("fixed-expenses"); },
      more:() => { count += 50; render("fixed-expenses"); },
      "subscription-edit":() => editSubscription(subById(id)),
      "subscription-delete":() => change("subscriptions","delete",id,t("删除此订阅和支付历史？已关联的自动流水也将撤销。","Delete this subscription and its payment history? Linked automatic transactions will be removed.")),
      "subscription-archive":() => change("subscriptions","archive",id),
      "monthly-settings":settingsEditor,
      pay:() => editPayment(monthly.bills.find(bill => bill.id === id)),
      renew:() => editPayment(subById(id)?.nextRenewal),
      "pay-edit":() => {
        const payment = monthly.payments.find(row => row.id === id);
        if (payment) editPayment(payment,payment);
      },
      "payment-delete":() => change("payments","delete",id,t("撤销这笔支付？已关联的自动流水也将撤销。","Undo this payment? Its linked automatic transaction will be removed.")),
      "event-edit":() => eventEditor(monthly.events.find(event => event.id === id)),
      "event-toggle":() => change("events","toggle",id),
      "event-delete":() => change("events","delete",id,t("删除这个到期事项？","Delete this deadline?")),
      "benefit-edit":() => editBenefit(benefit),
      "benefit-claim":() => api("/api/monthly/claim",{id,periodKey:benefit.periodKey}),
      "benefit-history":() => historyEditor(benefit),
      "benefit-delete":() => change("benefits","delete",id,t("删除该权益及领取历史？","Delete this benefit and its claim history?")),
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
    return payments.length ? panel(t("待记入账本的已确认月供","Confirmed payments to reconcile"),payments.slice(0,10).map(payment => row(payment.name,e(payment.paidAt) + " · " +
      displayCurrency(payment.amount,payment.currency),'<button type="button" class="ghost" data-reconcile="' + e(payment.id) + t('">补记</button>',"\">Record</button>") +
      '<button type="button" class="ghost" data-reconcile-ignore="' + e(payment.id) + t('">忽略</button>',"\">Ignore</button>"))).join("")) : "";
  }
  function bindReconciliation(root) {
    for (const button of root.querySelectorAll("[data-reconcile],[data-reconcile-ignore]")) {
      button.onclick = () => {
        const missing = state.monthly.reconciliation.find(row => row.id === (button.dataset.reconcile || button.dataset.reconcileIgnore));
        if (button.dataset.reconcileIgnore) {
          if (confirm(t("忽略这笔已确认支付的记账提醒？","Ignore the ledger reminder for this payment?"))) api("/api/monthly/reconcile",{
            id:missing.id,ignore:true,expectedRevision:state.monthly.revision
          }).catch(showError);
          return;
        }
        formEditor({
          title:t("补记已确认月供","Record confirmed payment"), subtitle:missing.name + " · " + missing.paidAt, path:"/api/monthly/reconcile", button:t("确认记账","Confirm transaction"),
          body:group(t("扣款账户","Payment account"),pick("accountID",t("实际扣款账户","Payment account"),accountChoices(missing.currency),missing.accountID || "",true)),
          prepare:payload => payload.id = missing.id
        });
      };
    }
  }
  window.GaoFixed = {render,reconciliation,bindReconciliation,
    message,
    localError(path, text) {
      return /^\/api\/(monthly\/|fixed-income\/|desktop\/notification-test)/.test(path) ? message(text) : text;
    }};
})();
