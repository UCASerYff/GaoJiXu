import assert from "node:assert/strict";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {join, resolve} from "node:path";

const [base, portFile, evidence, fixtureDirectory] = process.argv.slice(2);
if (!base || !portFile || !evidence || !fixtureDirectory) {
  throw new Error("Pass the isolated app URL, DevToolsActivePort, evidence directory and temporary fixture directory.");
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(action, description) {
  let failure;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const result = await action();
      if (result) return result;
    } catch (error) {
      failure = error;
    }
    await delay(85);
  }
  throw new Error("Timed out waiting for " + description, {cause:failure});
}

await mkdir(evidence, {recursive:true});
const fixture = resolve(fixtureDirectory, "synthetic-ledger.csv");
const timestamp = "2026-09-08T08:21:00+08:00";
await writeFile(fixture, [
  "\uFEFF日期,类型,账户,目标账户,分类,备注,金额,币种,转入金额,转入币种",
  `${timestamp},支出,现金,,餐饮,合成重复,28.45,CNY,,`,
  `${timestamp},支出,现金,,转账,转账 银行卡,56.78,CNY,,`,
  `${timestamp},收入,银行卡,,转账,转账 现金,56.78,CNY,,`,
  `${timestamp},转账,现金,美元测试,,合成换汇,41.23,CNY,,USD`,
  `${timestamp},支出,现金,,餐饮,缺少金额,,CNY,,`
].join("\r\n"),"utf8");

const port = await until(async () => Number((await readFile(portFile,"utf8")).split("\n")[0]), "isolated Chrome");
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const socket = new WebSocket(targets.find(target => target.type === "page").webSocketDebuggerUrl);
await new Promise((resolve,reject) => {
  socket.addEventListener("open",resolve,{once:true});
  socket.addEventListener("error",reject,{once:true});
});
const pending = new Map();
const errors = [];
let next = 0;
socket.addEventListener("message", ({data}) => {
  const message = JSON.parse(data);
  if (message.method === "Runtime.exceptionThrown") errors.push(message.params.exceptionDetails.text);
  const waiting = pending.get(message.id);
  if (!waiting) return;
  pending.delete(message.id);
  if (message.error) waiting.reject(new Error(message.error.message));
  else waiting.resolve(message.result);
});
function cdp(method, params = {}) {
  const id = ++next;
  return new Promise((resolve,reject) => {
    pending.set(id,{resolve,reject});
    socket.send(JSON.stringify({id,method,params}));
  });
}
async function js(expression) {
  const answer = await cdp("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true});
  if (answer.exceptionDetails) throw new Error(answer.exceptionDetails.exception?.description || answer.exceptionDetails.text);
  return answer.result.value;
}
const q = selector => `document.querySelector(${JSON.stringify(selector)})`;
const find = selector => until(() => js(`Boolean(${q(selector)})`),selector);
const click = async selector => { await find(selector); await js(`${q(selector)}.click()`); };
const alter = async (selector,value) => {
  await find(selector);
  await js(`((control,value) => {
    control.value = value;
    control.dispatchEvent(new Event("change",{bubbles:true}));
  })(${q(selector)},${JSON.stringify(value)})`);
};
const inbox = "#csv-review[open]";
const rows = "[data-csv-row]";
const getRows = () => js(`Array.from(document.querySelectorAll(${JSON.stringify(rows)}),
  row => ({id:row.dataset.csvRow,text:row.textContent,decision:row.querySelector("[data-csv-decision]")?.value ?? null}))`);
async function getRow(text) {
  const {id} = await until(async () => (await getRows()).find(row => row.text.includes(text)),text);
  return `[data-csv-row="${id}"]`;
}
async function upload() {
  await find("[data-csv-file]");
  const {root} = await cdp("DOM.getDocument");
  const {nodeId} = await cdp("DOM.querySelector",{nodeId:root.nodeId,selector:"[data-csv-file]"});
  await cdp("DOM.setFileInputFiles",{nodeId,files:[fixture]});
  if (await js(`Boolean(${q("[data-csv-stage]")})`)) await click("[data-csv-stage]");
}
async function screenshot(name,width,height,deviceScaleFactor=1) {
  await cdp("Emulation.setDeviceMetricsOverride",{width,height,deviceScaleFactor,mobile:false});
  await js(`${q(inbox)}.scrollTop = 0`);
  await delay(180);
  assert.ok(await js(`(() => {
    const dialog = ${q(inbox)};
    return dialog.getBoundingClientRect().width <= innerWidth && dialog.scrollWidth <= dialog.clientWidth + 2;
  })()`), name + " dialog overflows");
  const shot = await cdp("Page.captureScreenshot",{format:"png"});
  await writeFile(join(evidence,name + ".png"),Buffer.from(shot.data,"base64"));
}
async function approve() {
  await click("#decision[open] #decision-confirm");
}

async function batches() {
  return (await js('get("/api/csv/review")')).batches;
}
async function currentBatch() {
  const [batch] = await batches();
  return js(`get("/api/csv/review/detail?batchID=" + ${JSON.stringify(batch.id)})`);
}
const ledger = () => js('get("/api/state").then(state => state.entries)');
const waitText = (selector,text) => until(() => js(`${q(selector)}?.textContent.includes(${JSON.stringify(text)})`),text);

try {
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Emulation.setDeviceMetricsOverride",{width:1200,height:860,deviceScaleFactor:1,mobile:false});
  await cdp("Page.navigate",{url:base});
  await click('[data-workbench="create"]');
  await until(() => js('state?.status === "ready"'),"new synthetic library");
  assert.equal(await js('fetch("/api/csv/review").then(response => response.status)'),403);
  await js(`(async () => {
    await api("/api/settings",{language:"zh",appearance:"light"});
    await api("/api/accounts/save",{name:"美元测试",type:"bank",currency:"USD",balance:0});
    const cash = state.accounts.find(account => account.name === "现金");
    await api("/api/ledger/save",{kind:"expense",accountID:cash.id,amount:"28.45",
      categoryID:"food",date:${JSON.stringify(timestamp)},note:"合成重复"});
  })()`);
  const original = await ledger();
  assert.equal(original.length,1);
  await click(".toolbar-menu summary");
  await click('[data-workbench="import"]');
  await find(inbox);
  await upload();
  const duplicateRow = await getRow("合成重复");
  const crossRow = await getRow("合成换汇");
  await getRow("缺少金额");
  await waitText(duplicateRow,"重复");
  await find("[data-csv-pair]");
  const initial = await currentBatch();
  assert.equal(initial.batch.counts.total,5);
  assert.equal(initial.pairs.length,1);
  assert.equal(new Date(initial.rows[0].date).toISOString(), new Date(timestamp).toISOString());
  assert.deepEqual(await ledger(),original,"upload must not affect the ledger");
  await screenshot("csv-review-light",1200,870);

  await cdp("Page.reload");
  await find('[data-route="ledger"]');
  await click('[data-route="ledger"]');
  await click('[data-finance="csv-review"]');
  await click(`[data-csv-batch="${initial.batch.id}"]`);
  await getRow("合成重复");
  await js('api("/api/settings",{appearance:"dark"})');
  await screenshot("csv-review-dark-narrow-150",470,790,1.5);
  assert.equal(await js('document.body.dataset.theme'),"dark");

  await alter(duplicateRow + " [data-csv-decision]","apply");
  assert.equal(await js(`${q("[data-csv-apply]")}.disabled`),true,"duplicate override must be explicit");
  await js("requestQuit()");
  await waitText("#app-exit[open]","尚未保存");
  await click("#app-exit [data-exit-cancel]");
  assert.equal(await js(`${q(duplicateRow + " [data-csv-decision]")}.value`),"apply","cancelling quit keeps review choices");
  await click(duplicateRow + " [data-csv-override]");
  await click("[data-csv-pair]");
  await click("[data-csv-apply]");
  await click("#decision[open] #decision-cancel");
  assert.deepEqual(await ledger(),original,"cancelling confirmation leaves the ledger intact");
  await click("[data-csv-apply]");
  await approve();
  await until(async () => (await currentBatch()).batch.counts.applied === 3,"selected duplicate and both paired rows");
  const imported = await ledger();
  assert.equal(imported.length,3);
  assert.equal(imported.filter(row => row.note === "合成重复").length,2);
  const transfers = imported.filter(row => row.kind === "transfer");
  assert.equal(transfers.length,1);
  assert.equal(transfers[0].amount,56.78);
  assert.equal(transfers[0].targetAmount,56.78);
  assert.notEqual(transfers[0].accountID,transfers[0].targetAccountID);
  assert.ok((await currentBatch()).rows.some(row => row.note === "合成换汇" && row.status === "pending"));

  await click(crossRow + " [data-csv-edit]");
  await alter('input[name="targetAmount"]',"6.07");
  await click("#editor-submit");
  await click("[data-csv-apply]");
  await approve();
  await until(async () => (await currentBatch()).rows.some(row => row.note === "合成换汇" && row.canApply),
    "corrected cross-currency row");
  await alter(crossRow + " [data-csv-decision]","apply");
  await click("[data-csv-apply]");
  await approve();
  await until(async () => (await ledger()).some(row => row.note === "合成换汇" && row.targetAmount === 6.07),
    "explicit target amount enters the ledger");

  const beforeRetry = await ledger();
  await upload();
  await waitText("[data-csv-status]","已加入审核箱");
  await click('[data-csv-filter="all"]');
  await getRow("合成换汇");
  assert.equal((await batches()).length,1);
  assert.equal((await currentBatch()).batch.id,initial.batch.id);
  assert.deepEqual(await ledger(),beforeRetry,"restaging does not create another ledger entry");
  await click("[data-csv-undo]");
  await approve();
  await until(async () => (await currentBatch()).batch.counts.undone === 4,"import undo");
  assert.deepEqual(await ledger(),original,"undo leaves the pre-existing ledger entry intact");
  const blocked = await getRow("缺少金额");
  await alter(blocked + " [data-csv-decision]","skip");
  await click("[data-csv-apply]");
  await approve();
  await until(async () => (await currentBatch()).batch.counts.skipped === 1,"a missing-amount row can be explicitly skipped");
  assert.deepEqual(await ledger(),original);
  assert.deepEqual(errors,[]);
  console.log("CSV review smoke passed: normal entry, persisted inbox, reasons, override, pair, FX repair, retry, undo, light/dark/narrow.");
} finally {
  await Promise.race([cdp("Browser.close").catch(() => {}),delay(400)]);
  socket.close();
}
