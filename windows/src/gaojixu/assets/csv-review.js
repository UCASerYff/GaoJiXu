(() => {
  "use strict";

  const dialog = document.getElementById("csv-review");
  const $ = selector => dialog.querySelector(selector);
  const h = escapeHTML;
  const endpoint = "/api/csv/review";
  const rowLimit = 20;
  const kinds = {income:["收入","Income"], expense:["支出","Expense"], transfer:["转账","Transfer"]};
  const states = {
    pending:["待确认","Pending"], partial:["部分处理","Partially reviewed"], applied:["已入账","Recorded"],
    undone:["已撤销","Undone"], resolved:["已处理","Reviewed"], skipped:["已忽略","Skipped"]
  };
  const reasons = {
    "ledger-exact":["账本中已有日期时间、账户、币种、金额和备注相符的流水","The ledger already has a row with matching time, account, currency, amount and note"],
    "ledger-same-day":["账本中已有当天同账户、同币种、同金额的流水","The ledger already has a row on this date with the same account, currency and amount"],
    "batch-exact":["本批有另一条日期时间、账户、币种、金额和备注相符的流水","This batch contains another row with matching time, account, currency, amount and note"],
    "batch-same-day":["本批有另一条当天同账户、同币种、同金额的流水","This batch contains another row on this date with the same account, currency and amount"],
    "missing-date":["缺少日期","Date is missing"], "invalid-date":["日期格式无法识别","Unrecognized date format"],
    "ambiguous-local-time":["本地时间重复或不存在，请填带时区偏移的日期时间","This local time is ambiguous or does not exist. Enter a date and time with a UTC offset"],
    "missing-kind":["缺少收支类型","Transaction type is missing"], "invalid-kind":["无法识别收支类型","Unrecognized transaction type"],
    "direction-conflict":["收支类型和金额方向相冲突","Transaction type conflicts with the amount direction"],
    "missing-account":["缺少账户","Account is missing"], "ambiguous-account":["存在多个同名账户","More than one account has this name"],
    "archived-account":["账户已归档","The account is archived"], "missing-currency":["缺少币种","Currency is missing"],
    "invalid-currency":["无法识别币种","Unrecognized currency"], "currency-mismatch":["币种与账户不匹配","Currency does not match the account"],
    "missing-amount":["缺少金额","Amount is missing"], "invalid-amount":["金额格式或范围无效","The amount has an invalid format or is out of range"],
    "amount-precision":["金额超出该币种的小数精度","The amount has too many decimal places for the currency"],
    "invalid-category":["分类与收支类型不匹配","The category does not match the transaction type"],
    "missing-target-account":["缺少转入账户","Destination account is missing"], "same-account":["转出和转入不能是同一账户","The source and destination must be different accounts"],
    "missing-target-currency":["缺少转入币种","Destination currency is missing"],
    "target-currency-mismatch":["转入币种与账户不匹配","Destination currency does not match the account"],
    "missing-target-amount":["请填写实际转入金额","Enter the actual amount received"],
    "invalid-target-amount":["转入金额格式或范围无效","The amount received has an invalid format or is out of range"],
    "target-amount-precision":["转入金额超出币种的小数精度","The amount received has too many decimal places for its currency"],
    "same-currency-amount-mismatch":["同币种转出和转入金额不一致","Amounts sent and received do not match for the same currency"],
    "transfer-leg":["这是单边转账记录，请核对匹配建议或补齐转账信息","This row is one side of a transfer. Check for a match or complete the transfer details"],
    "extra-columns":["本行字段数量超出表头，请核对原文件","This row has more columns than the header. Check the original file"],
    "new-account":["入账时会新建账户","A new account will be created when recorded"],
    "new-target-account":["入账时会新建转入账户","A new destination account will be created when recorded"],
    "default-category":["使用默认分类","The default category will be used"],
    "local-time":["源文件未给偏移，日期按账本时区解释","No UTC offset was provided. The date uses the ledger time zone"]
  };
  const errors = {
    "csv-review-protected":"The import inbox could not be read. The original data was preserved.",
    "csv-review-not-found":"This import batch could not be found.",
    "csv-review-empty":"Choose a CSV containing transaction rows.",
    "csv-review-limit":"This CSV exceeds the batch limit. Split it into smaller files.",
    "csv-review-format":"Check the CSV quotes, columns and header names.",
    "csv-review-header":"Use at least two recognizable transaction column names.",
    "csv-review-confirmation":"Confirm this review action first.",
    "csv-review-stale":"The ledger or batch has changed. Refresh the batch and review your choices again.",
    "csv-review-decision":"Some changes do not match the current inbox rows. Review them or refresh the batch.",
    "csv-review-account":"New accounts with different currencies need different names.",
    "csv-review-blocked":"Some rows still need required information. Edit them or leave them pending.",
    "csv-review-duplicate":"Confirm each suspected duplicate you want to keep.",
    "csv-review-undo-conflict":"Undo stopped because this batch contains entries that were changed, removed, or linked to savings records."
  };
  let model;
  let picker;

  const say = (entries, key, fallback = "—") => entries[key] ? t(...entries[key]) : fallback;
  const fmt = value => String(value || "").replace(/^(\d{4}-\d\d-\d\d)T/,"$1 ");
  const draftFor = id => model.drafts.get(id) || {};
  const hasDraft = () => Boolean(dialog.open && model && (model.drafts.size || model.pairs.size || picker?.files.length));
  const newDraft = () => {model.drafts.clear(); model.pairs.clear();};
  const moneyText = (amount, currency) => amount == null || amount === "" ? "—" : [currency, amount].filter(Boolean).join(" ");
  const statusLabel = batch => say(states, batch.status);
  const reasonLabel = key => say(reasons, key, t("该行需要核对","Review this row"));
  const localError = (message, code) => t(message, errors[code] || message);

  function replaceDetail(detail) {
    model.detail = detail;
    newDraft();
    model.filter = detail.batch.counts.pending ? "pending" : "all";
    model.page = 0;
    const index = model.batches.findIndex(item => item.id === detail.batch.id);
    if (index >= 0) model.batches[index] = detail.batch;
    else model.batches.unshift(detail.batch);
  }

  function actions() {
    const detail = model.detail;
    const batch = detail?.batch;
    const selections = Array.from(model.drafts.values());
    const activePairs = detail?.pairs.filter(pair => model.pairs.has(pair.id)) || [];
    const paired = new Set(activePairs.flatMap(pair => [pair.expenseID, pair.incomeID]));
    const transfers = activePairs.length;
    const records = Array.from(model.drafts).filter(([id, draft]) => !paired.has(id) && draft.decision === "apply").length;
    const skips = Array.from(model.drafts).filter(([id, draft]) => !paired.has(id) && draft.decision === "skip").length;
    const unconfirmedDuplicate = (detail?.rows || []).some(row => {
      if (draftFor(row.id).override) return false;
      if (paired.has(row.id)) return row.duplicates.length || activePairs.some(pair => (pair.expenseID === row.id || pair.incomeID === row.id) && pair.duplicates?.length);
      return draftFor(row.id).decision === "apply" && row.duplicates.length;
    });
    const edited = selections.some(draft => draft.edits);
    const apply = $("[data-csv-apply]"), undo = $("[data-csv-undo]");
    apply.hidden = !batch?.counts.pending;
    apply.disabled = model.busy || Boolean(unconfirmedDuplicate) || !(records || skips || edited || transfers);
    apply.textContent = records || transfers ? t("确认入账", "Confirm entries") : t("保存审核", "Save review");
    undo.hidden = !batch?.canUndo;
    undo.disabled = model.busy || hasDraft();
    $("[data-csv-stage]").disabled = model.busy;
    $("[data-csv-close]").disabled = model.busy;
    $("[data-csv-batches]").inert = $("[data-csv-result]").inert = model.busy;
    $("[data-csv-status]").textContent = model.busy ? t("正在处理…","Working…") : unconfirmedDuplicate ?
      t("请逐条确认保留疑似重复项。","Confirm each suspected duplicate you want to keep.") :
      records || transfers || skips ? t(`已选 ${records} 笔流水、${transfers} 笔合并转账、忽略 ${skips} 行`, `${records} entries, ${transfers} matched transfers, ${skips} rows to skip`) : model.notice;
    dialog.setAttribute("aria-busy", String(model.busy));
  }

  function drawBatches() {
    const list = $("[data-csv-batches]");
    list.setAttribute("aria-label", t("导入批次","Import batches"));
    list.innerHTML = `<div class="csv-batches-heading"><h3>${t("批次","Batches")}</h3><button type="button" class="ghost" data-csv-refresh>${t("刷新","Refresh")}</button></div>
      <div class="csv-batch-list">${model.batches.map(batch => `<button type="button" class="ghost csv-batch" data-csv-batch="${h(batch.id)}"
        ${batch.id === model.detail?.batch.id ? 'aria-current="true"' : ""}><strong>${h(batch.name)}</strong>
        <small>${h(statusLabel(batch))} · ${h(t(`${batch.counts.pending} 待确认`, `${batch.counts.pending} pending`))}</small></button>`).join("")}</div>`;
  }

  function duplicateTips(items) {
    return items.map(item => `<li>${h(reasonLabel(item.code))}${item.line ? ` · ${h(t(`第 ${item.line} 行`, `row ${item.line}`))}` : ""}</li>`).join("");
  }

  function drawPair(pair, rows) {
    const source = rows.get(pair.expenseID), target = rows.get(pair.incomeID);
    if (!source || !target) return "";
    return `<label class="csv-pair">
      <input type="checkbox" data-csv-pair="${h(pair.id)}" ${model.pairs.has(pair.id) ? "checked" : ""}>
      <span><strong>${h(source.accountName)} → ${h(target.accountName)}</strong> <b>${h(moneyText(pair.amount,pair.currency))}</b>
      <small>${h(t(`第 ${source.line}、${target.line} 行。日期、币种、金额相同，方向相反，并有明确的转账线索。`, `Rows ${source.line} and ${target.line}. Date, currency and amount match, directions are opposite, and the rows have transfer evidence.`))}</small>
      ${pair.duplicates?.length ? `<small class="csv-warning">${t("也有疑似重复，请分别核对两条来源。","There may also be a duplicate. Review both source rows.")}</small>` : ""}</span></label>`;
  }

  function drawRow(item, matched, pairedDuplicate) {
    const draft = draftFor(item.id);
    const row = {...item,...draft.edits};
    const pending = item.status === "pending";
    const rowNumber = t(`第 ${row.line} 行`, `Row ${row.line}`);
    const option = (value,label,disabled = false) => `<option value="${value}" ${(draft.decision || "pending") === value ? "selected" : ""} ${disabled ? "disabled" : ""}>${label}</option>`;
    const issues = [...item.problems.map(key => `<li>${h(reasonLabel(key))}</li>`), duplicateTips(item.duplicates)].join("");
    const note = draft.edits ? t("保存审核后可重新核对这条流水。","Save the review to check this row again.") :
      (item.notices || []).map(reasonLabel).join(" · ");
    return `<article class="csv-row" data-csv-row="${h(row.id)}">
      <div class="csv-row-top">
        <span class="csv-row-line">${h(rowNumber)}</span><span class="csv-pill" data-status="${h(item.status)}">${h(say(states,item.status))}</span>
        <strong class="csv-row-amount">${h(moneyText(row.amount,row.currency))}${row.targetAmount ? ` → ${h(moneyText(row.targetAmount,row.targetCurrency || row.currency))}` : ""}</strong>
      </div>
      <div><strong>${h(row.accountName || "—")}${row.targetAccountName ? ` → ${h(row.targetAccountName)}` : ""}</strong>
        <small class="csv-row-meta">${h([fmt(row.date),row.dateTimezone,say(kinds,row.kind,row.kind),row.categoryName].filter(Boolean).join(" · "))}</small></div>
      ${row.note ? `<p class="csv-row-note">${h(row.note)}</p>` : ""}
      ${issues ? `<ul class="csv-warning">${issues}</ul>` : ""}
      ${note ? `<small class="csv-row-meta">${h(note)}</small>` : ""}
      ${pending ? `<div class="csv-row-controls">
        ${matched ? `<span class="csv-pill">${t("合并为转账","Match as a transfer")}</span>` : `<select data-csv-decision aria-label="${h(t(`审核 ${rowNumber}`, `Review ${rowNumber}`))}">
          ${option("pending", t("保留待确认","Keep pending"))}
          ${option("apply", t("选中入账","Select to record"), !item.canApply || Boolean(draft.edits))}
          ${option("skip", t("忽略此行","Skip this row"))}</select>`}
        <button type="button" class="ghost" data-csv-edit ${matched ? "disabled" : ""}>${t("修改","Edit")}</button>
        ${item.duplicates.length || pairedDuplicate ? `<label class="csv-check"><input type="checkbox" data-csv-override ${draft.override ? "checked" : ""}>
          ${t("已核对，仍保留","Reviewed, keep anyway")}</label>` : ""}
      </div>` : ""}
    </article>`;
  }

  function draw() {
    const result = $("[data-csv-result]");
    const detail = model.detail;
    if (!detail) {
      result.innerHTML = `<div class="csv-blank" role="status">${h(model.busy ? t("正在读取审核箱…","Reading the inbox…") :
        t("审核箱为空。选择一份搞积蓄格式的 CSV 开始审核。","The inbox is empty. Choose a Gao Savings CSV to begin."))}</div>`;
      drawBatches();
      actions();
      return;
    }
    const focus = document.activeElement;
    const rowIndex = new Map(detail.rows.map(row => [row.id,row]));
    const compatiblePairs = detail.pairs.filter(pair => !draftFor(pair.expenseID).edits && !draftFor(pair.incomeID).edits && !draftFor(pair.expenseID).decision && !draftFor(pair.incomeID).decision);
    const selectedPairs = compatiblePairs.filter(pair => model.pairs.has(pair.id));
    const paired = new Map(selectedPairs.flatMap(pair => [[pair.expenseID,pair],[pair.incomeID,pair]]));
    const {batch} = detail, {counts} = batch;
    const matches = detail.rows.filter(row => model.filter === "all" || row.status === model.filter);
    const pages = Math.max(1,Math.ceil(matches.length / rowLimit));
    model.page = Math.min(model.page,pages-1);
    const rows = matches.slice(model.page*rowLimit,(model.page+1)*rowLimit);
    const focusPair = focus?.dataset?.csvPair;
    result.innerHTML = `<div class="csv-batch-title"><h3>${h(batch.name)}</h3><span class="csv-pill" data-status="${h(batch.status)}">${h(statusLabel(batch))}</span></div>
      ${batch.timezone ? `<p class="csv-row-meta">${t("账本时区","Ledger time zone")} · ${h(batch.timezone)}</p>` : ""}
      ${batch.createdTimezone && batch.createdTimezone !== batch.timezone ?
        `<p class="csv-row-meta">${t("导入时的账本时区","Ledger time zone when staged")} · ${h(batch.createdTimezone)}</p>` : ""}
      <dl class="csv-counts">${[
        [t("待确认","Pending"), counts.pending], [t("疑似重复","Possible duplicates"), counts.duplicates],
        [t("待补足","Needs details"), counts.blocked], [t("本批入账","Entries recorded"), counts.entries]
      ].map(([label,value]) => `<div><dt>${h(label)}</dt><dd>${h(value)}</dd></div>`).join("")}</dl>
      ${compatiblePairs.length ? `<details open class="csv-pairs"><summary>${t("同币种转账建议","Same-currency transfer matches")} · ${compatiblePairs.length}</summary>
        <p class="csv-row-meta">${t("勾选后会把双方记为一笔转账。","Select a match to record both sides as one transfer.")}</p>
        <div class="csv-pair-list">${compatiblePairs.map(pair => drawPair(pair,rowIndex)).join("")}</div></details>` : ""}
      <div class="csv-filter" role="group" aria-label="${t("筛选审核行","Filter review rows")}">
        ${[["pending", t("待确认","Pending")],["all",t("全部行","All rows")]].map(([key,label]) => `<button type="button" class="ghost" data-csv-filter="${key}" aria-pressed="${model.filter === key}">${label}</button>`).join("")}
      </div>
      <div class="csv-rows">${rows.length ? rows.map(row => drawRow(row,paired.has(row.id),paired.get(row.id)?.duplicates?.length)).join("") :
        `<div class="csv-blank">${t("没有符合筛选的流水。","No rows match this filter.")}</div>`}</div>
      ${pages > 1 ? `<div class="csv-pages"><button type="button" class="ghost" data-csv-page="-1" ${model.page === 0 ? "disabled" : ""}>${t("上一页","Previous")}</button>
        <span>${h(t(`第 ${model.page+1} / ${pages} 页`, `Page ${model.page+1} of ${pages}`))}</span>
        <button type="button" class="ghost" data-csv-page="1" ${model.page+1 === pages ? "disabled" : ""}>${t("下一页","Next")}</button></div>` : ""}`;
    drawBatches();
    actions();
    if (focusPair) result.querySelector(`[data-csv-pair="${CSS.escape(focusPair)}"]`)?.focus({preventScroll:true});
  }

  function setDraft(id, changes) {
    const draft = {...draftFor(id),...changes};
    if (draft.decision || draft.override || draft.edits) model.drafts.set(id,draft);
    else model.drafts.delete(id);
  }

  function editRow(id) {
    const original = model.detail.rows.find(item => item.id === id);
    const row = {...original,...original.values,...draftFor(id).edits};
    const fields = [
      ["date",t("日期时间","Date and time")], ["kind",t("类型","Type")],
      ["accountName",t("账户","Account")], ["targetAccountName",t("转入账户","Destination account")],
      ["amount",t("金额","Amount")], ["currency",t("币种","Currency")],
      ["targetAmount",t("实际转入金额","Actual amount received")], ["targetCurrency",t("转入币种","Destination currency")],
      ["categoryName",t("分类","Category")], ["note",t("备注","Note")]
    ];
    const options = (items,value) => items.map(([id,label]) => `<option value="${h(id)}" ${id === value ? "selected" : ""}>${h(label)}</option>`).join("");
    const accountList = `<datalist id="csv-accounts">${(state.accounts || []).filter(item => !item.archived).map(item => `<option value="${h(item.name)}">${h(item.currency)}</option>`).join("")}</datalist>`;
    const control = key => {
      const value = String(row[key] ?? "");
      if (key === "note") return `<textarea name="note" rows="2">${h(value)}</textarea>`;
      if (key === "kind" || key.toLowerCase().includes("currency")) {
        const choices = key === "kind" ? Object.keys(kinds).map(code => [code,say(kinds,code)]) : (state.currencies || []).map(item => [item.id,item.id]);
        if (value && !choices.some(option => option[0] === value)) choices.unshift([value,value]);
        return `<select name="${key}">${options([["",t("未填写","Unspecified")],...choices],value)}</select>`;
      }
      return `<input name="${key}" value="${h(value)}" ${key.endsWith("AccountName") || key === "accountName" ? 'list="csv-accounts"' : ""}
        ${/amount/i.test(key) ? 'inputmode="decimal"' : ""}>`;
    };
    openEditor({
      title:t("修改待确认流水","Edit a pending row"), subtitle:t(`CSV 第 ${row.line} 行`, `CSV row ${row.line}`),
      body:`<p class="csv-edit-help">${t("日期可填 YYYY-MM-DD 或带偏移的 ISO 时间。跨币种转账请填写实际转入金额与币种。","Use YYYY-MM-DD or an ISO time with an offset. For a cross-currency transfer, enter the actual amount received and its currency.")}</p>
        <div class="csv-edit-fields">${fields.map(([key,label]) => `<label><span>${h(label)}</span>${control(key)}</label>`).join("")}</div>${accountList}`,
      submitLabel:t("保留修改","Keep changes"),
      onSubmit: form => {
        setDraft(id,{edits:Object.fromEntries(new FormData(form)),decision:"",override:false});
        draw();
      }
    });
  }

  function displayError(error) {
    const node = $("[data-csv-error]");
    node.hidden = !error;
    node.textContent = error?.message || "";
  }

  async function run(action) {
    if (model.busy) return;
    model.busy = true;
    model.notice = "";
    displayError(null);
    actions();
    try {
      await action();
    } catch (error) {
      displayError(error);
    } finally {
      model.busy = false;
      draw();
    }
  }

  const readBatch = async id => replaceDetail(await get(endpoint + "/detail?" + new URLSearchParams({batchID:id})));

  async function load() {
    const preferred = model.detail?.batch.id;
    const {batches} = await get(endpoint);
    model.batches = batches;
    const next = batches.find(batch => batch.id === preferred) || batches.find(batch => batch.counts.pending) || batches[0];
    if (next) await readBatch(next.id);
    else model.detail = null;
  }

  async function stage(file) {
    if (file.size > 7*1024*1024) throw new Error(t("请选择 7 MiB 以内的 CSV。","Choose a CSV no larger than 7 MiB."));
    let text;
    try {
      text = new TextDecoder("utf-8",{fatal:true}).decode(await file.arrayBuffer());
    } catch {
      throw new Error(t("请将文件另存为 UTF-8 CSV 后重试。","Save the file as UTF-8 CSV and try again."));
    }
    const payload = {text,name:file.name};
    if (new Blob([JSON.stringify(payload)]).size > 8*1024*1024) {
      throw new Error(t("请将这份 CSV 分成多个较小的文件。","Split this CSV into smaller files."));
    }
    replaceDetail(await api(endpoint + "/stage",payload));
    model.notice = t("已加入审核箱，账本没有变化。","Added to the inbox. The ledger is unchanged.");
    picker.value = "";
  }

  async function apply() {
    const {batch,pairs} = model.detail;
    const chosen = pairs.filter(pair => model.pairs.has(pair.id));
    const paired = new Set(chosen.flatMap(pair => [pair.expenseID,pair.incomeID]));
    const drafts = Array.from(model.drafts);
    const decisions = Object.fromEntries(drafts.filter(([id,row]) => row.decision && !paired.has(id)).map(([id,row]) => [id,row.decision]));
    const edits = Object.fromEntries(drafts.filter(([,row]) => row.edits).map(([id,row]) => [id,row.edits]));
    const count = Object.values(decisions).filter(value => value === "apply").length;
    if (!await confirmAction(
      count || chosen.length ? t(`将记入 ${count} 笔流水和 ${chosen.length} 笔匹配转账。未选择的流水仍待确认。`,
        `Record ${count} entries and ${chosen.length} matched transfers. Unselected rows stay pending.`) :
        t("保存已选修改和忽略决定。其他流水仍待确认。","Save the selected edits and skips. Other rows stay pending."),
      {title:t("确认审核结果","Confirm review"), label:count || chosen.length ? t("确认入账","Record entries") : t("保存审核","Save review"),destructive:false}
    )) return;
    await run(async () => {
      replaceDetail(await api(endpoint + "/apply",{
        batchID:batch.id, revision:batch.revision, decisions, edits, pairs:chosen.map(pair => pair.id),
        overrideDuplicates:drafts.filter(([,row]) => row.override).map(([id]) => id), confirmed:true
      }));
      model.notice = t("审核结果已保存。","Review saved.");
    });
  }

  async function undo() {
    const {batch} = model.detail;
    if (!await confirmAction(
      t("撤销会移除本批入账的流水，已创建的账户会保留。如果有流水已更改，撤销会停止。","This removes transactions recorded by this batch. Created accounts are kept. If any imported transaction has changed, the undo stops."),
      {title:t("撤销本批入账？","Undo this batch?"), label:t("撤销入账","Undo entries")}
    )) return;
    await run(async () => {
      replaceDetail(await api(endpoint + "/undo",{batchID:batch.id,revision:batch.revision,confirmed:true}));
      model.notice = t("本批入账已撤销。","Entries from this batch were undone.");
    });
  }

  function discardChanges(includeFile = true) {
    if (!(model.drafts.size || model.pairs.size || (includeFile && picker?.files.length))) return Promise.resolve(true);
    return confirmAction(t("本次选择和修改尚未提交。已加入审核箱的流水仍会保存。","Your unsubmitted choices and edits will be discarded. Rows already in the inbox will be kept."),
      {title:t("放弃未提交的审核？","Discard unsubmitted review?"),label:t("放弃修改","Discard changes")});
  }

  function open() {
    if (dialog.open) return;
    const labels = [
      ["#csv-review-title",t("导入审核箱","Import inbox")],
      ["[data-csv-intro]",t("核对 CSV 流水后，再选择哪些要记入账本。","Review CSV rows and choose which ones to record.")],
      ["[data-csv-file-label]",t("UTF-8 CSV 流水文件","UTF-8 CSV transaction file")],
      ["[data-csv-stage]",t("加入审核箱","Add to inbox")], ["[data-csv-undo]",t("撤销本批入账","Undo batch entries")]
    ];
    for (const [selector,label] of labels) $(selector).textContent = label;
    $("[data-csv-close]").setAttribute("aria-label",t("关闭审核箱","Close import inbox"));
    picker = $("[data-csv-file]");
    picker.value = "";
    model = {detail:null, batches:[], drafts:new Map(), pairs:new Set(), busy:false, page:0, filter:"pending", notice:""};
    dialog.showModal();
    window.addEventListener("beforeunload", guardExit);
    draw();
    run(load);
  }

  function guardExit(event) {
    if (hasDraft()) {
      event.preventDefault();
      event.returnValue = "";
    }
  }

  async function close() {
    if (!model.busy && await discardChanges()) dialog.close();
  }

  dialog.addEventListener("close", () => window.removeEventListener("beforeunload", guardExit));
  dialog.addEventListener("cancel", event => {event.preventDefault(); close();});
  $("[data-csv-close]").onclick = close;
  $("[data-csv-apply]").onclick = apply;
  $("[data-csv-undo]").onclick = undo;
  $(".csv-upload").onsubmit = async event => {
    event.preventDefault();
    if (!model.busy && picker.files[0] && await discardChanges(false)) run(() => stage(picker.files[0]));
  };
  dialog.addEventListener("click", async event => {
    const target = event.target.closest("button");
    if (model.busy || !target) return;
    if (target.matches("[data-csv-refresh]")) {
      if (await discardChanges(false)) run(load);
    } else if (target.dataset.csvBatch) {
      if (target.dataset.csvBatch !== model.detail?.batch.id && await discardChanges(false)) run(() => readBatch(target.dataset.csvBatch));
    } else if (target.dataset.csvFilter) {
      model.filter = target.dataset.csvFilter;
      model.page = 0;
      draw();
      $(`[data-csv-filter="${model.filter}"]`)?.focus();
    } else if (target.dataset.csvPage) {
      model.page += Number(target.dataset.csvPage);
      draw();
      $("[data-csv-result] [data-csv-row]")?.scrollIntoView({block:"nearest"});
      $("[data-csv-page]:enabled")?.focus();
    } else if (target.matches("[data-csv-edit]")) {
      editRow(target.closest("[data-csv-row]").dataset.csvRow);
    }
  });
  dialog.addEventListener("change", event => {
    const {target} = event;
    if (target.dataset.csvPair && !model.busy) {
      if (target.checked) model.pairs.add(target.dataset.csvPair);
      else model.pairs.delete(target.dataset.csvPair);
      draw();
    } else {
      const row = target.closest("[data-csv-row]");
      if (row && !model.busy) {
        if (target.matches("[data-csv-decision]")) {
          setDraft(row.dataset.csvRow,{decision:target.value === "pending" ? "" : target.value});
          draw();
          $(`[data-csv-row="${CSS.escape(row.dataset.csvRow)}"] [data-csv-decision]`)?.focus({preventScroll:true});
        }
        if (target.matches("[data-csv-override]")) setDraft(row.dataset.csvRow,{override:target.checked});
      }
      actions();
    }
  });

  window.GaoCSVReview = {open,hasDraft,localError};
})();
