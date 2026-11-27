import assert from "node:assert/strict";
import {readFile, mkdir, writeFile} from "node:fs/promises";
import {join} from "node:path";

const [base, chromePortFile, output] = process.argv.slice(2);
if (!base || !chromePortFile || !output) throw new Error("Expected app URL, Chrome DevToolsActivePort path, and screenshot directory");
await mkdir(output,{recursive:true});
const delay = milliseconds => new Promise(resolve => setTimeout(resolve,milliseconds));
async function until(fn, description) {
  let last;
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      if (await fn()) return;
    } catch (error) { last = error; }
    await delay(80);
  }
  throw new Error("Timed out waiting for " + description + (last ? ": " + last.message : ""));
}
let port;
await until(async () => {
  port = Number((await readFile(chromePortFile,"utf8")).split("\n")[0]);
  return port > 0;
},"headless Chrome");
const targets = await (await fetch("http://127.0.0.1:" + port + "/json/list")).json();
const page = targets.find(target => target.type === "page");
const websocket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve,reject) => {
  websocket.addEventListener("open",resolve,{once:true});
  websocket.addEventListener("error",reject,{once:true});
});
const pending = new Map();
const failures = [];
let sequence = 0;
function cdp(method,params = {}) {
  const id = ++sequence;
  return new Promise((resolve,reject) => {
    pending.set(id,{resolve,reject});
    websocket.send(JSON.stringify({id,method,params}));
  });
}
websocket.addEventListener("message", ({data}) => {
  const message = JSON.parse(data);
  if (message.method === "Runtime.exceptionThrown") failures.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
  if (message.method === "Page.javascriptDialogOpening") void cdp("Page.handleJavaScriptDialog",{accept:true});
  if (!message.id || !pending.has(message.id)) return;
  const {resolve,reject} = pending.get(message.id);
  pending.delete(message.id);
  if (message.error) reject(new Error(JSON.stringify(message.error)));
  else resolve(message.result);
});
const js = async expression => {
  const result = await cdp("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true});
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result.value;
};
const click = selectors => js(`document.querySelector(${JSON.stringify(selectors)}).click()`);
const waitFor = selectors => until(() => js(`Boolean(document.querySelector(${JSON.stringify(selectors)}))`),selectors);
const dialog = () => waitFor("dialog[open]");
const close = () => until(() => js("!document.querySelector('dialog[open]')"),"editor closing");
const section = id => waitFor("#" + id + ":not([hidden]) h1");
const fixed = (name,id = "") => '[data-fixed="' + name + '"]' + (id ? '[data-id="' + id + '"]' : "");
const selectRoute = id => click('nav [data-route="' + id + '"]');
const textHas = (selector,needle) => until(() => js(`document.querySelector(${JSON.stringify(selector)})?.textContent.includes(${JSON.stringify(needle)})`),needle);
async function edit(values) {
  await dialog();
  await js(`(values => {
    const form = document.querySelector('#editor-form');
    for (const [key,value] of Object.entries(values)) {
      const input = form.elements[key];
      if (!input) throw new Error('Missing editor field: ' + key);
      if (input.type === 'checkbox') input.checked = value;
      else input.value = value;
      input.dispatchEvent(new Event('change', {bubbles:true}));
    }
    form.requestSubmit();
  })(${JSON.stringify(values)})`);
  await close();
}
async function snapshot(name,width,height,dpi) {
  await cdp("Emulation.setDeviceMetricsOverride",{width,height,deviceScaleFactor:dpi,mobile:false});
  await delay(230);
  const overflow = await js("document.documentElement.scrollWidth - innerWidth");
  assert.ok(overflow <= 2, name + " overflows horizontally by " + overflow);
  const image = await cdp("Page.captureScreenshot",{format:"png"});
  await writeFile(join(output,name + ".png"),Buffer.from(image.data,"base64"));
}

try {
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Page.navigate",{url:base});
  await waitFor('[data-workbench="create"]');
  await click('[data-workbench="create"]');
  await section("overview");
  await snapshot("overview-light-1360",1360,900,1);

  await selectRoute("ledger");
  await waitFor('#ledger:not([hidden]) [name="ledger-query"]');
  await selectRoute("fixed-income");
  await section("fixed-income");
  await click(fixed("income-edit"));
  await edit({name:"QA 收入计划",amount:1200,dayOfMonth:27});
  await textHas("#fixed-income","QA 收入计划");
  assert.equal(await js("state.summary.monthIncome"),0);
  await click(fixed("income-confirm"));
  const accountID = await js("state.accounts.find(account => account.currency === 'CNY').id");
  await edit({accountID,receivedIsConfirmed:true});
  await textHas("#fixed-income","已入账");
  assert.equal(await js("state.summary.monthIncome"),1200);

  await selectRoute("fixed-expenses");
  await waitFor(fixed("create-monthly"));
  await click(fixed("create-monthly"));
  await section("fixed-expenses");
  await click(fixed("subscription-edit"));
  await edit({name:"QA 月卡",price:25,stacking:true});
  await textHas("#fixed-expenses","QA 月卡");
  const sub = await js("state.monthly.subscriptions.find(row => row.name === 'QA 月卡').id");
  await click(fixed("expense-tab","bills"));
  await textHas("#fixed-expenses","QA 月卡");
  assert.equal(await js("state.summary.monthExpense"),0);
  await click(fixed("pay"));
  await edit({accountID,periods:2,rememberAccount:true});
  assert.equal(await js("state.summary.monthExpense"),25);
  await click(fixed("expense-tab","payments"));
  await textHas("#fixed-expenses","覆盖 2 期");
  await click(fixed("pay-edit"));
  await edit({amount:30,periods:1});
  await textHas("#fixed-expenses","覆盖 1 期");
  assert.equal(await js("state.summary.monthExpense"),30);
  await click(fixed("expense-tab","events"));
  await click(fixed("event-edit"));
  await edit({name:"QA 到期事项",subscriptionID:sub});
  await click(fixed("event-toggle"));
  await textHas("#fixed-expenses","已完成");
  await click(fixed("expense-tab","review"));
  await click(fixed("review-edit"));
  await edit({rating:"2"});
  await textHas("#fixed-expenses","经常使用");

  await selectRoute("benefits");
  await click(fixed("benefit-edit"));
  await edit({name:"QA 权益",kind:"weekly",subscriptionID:sub});
  await textHas("#benefits","QA 权益");
  await click(fixed("benefit-claim"));
  await textHas("#benefits","本期已记");
  await click(fixed("benefit-history"));
  await textHas("#editor","历史记录");
  await click("#editor-cancel");
  await close();
  await click(".toolbar-menu summary");
  await click('[data-workbench="settings"]');
  await dialog();
  await click('[data-settings="data"]');
  await waitFor('[data-settings-panel="data"]:not([hidden]) [data-folder="widgets"]');
  await click('[data-settings="appearance"]');
  await edit({appearance:"dark"});
  await snapshot("benefits-dark-1060-150dpi",1060,730,1.5);

  await click(".toolbar-menu summary");
  await click('[data-workbench="widgets"]');
  await section("widgets");
  await waitFor(".widget-grid .widget-adventure");
  assert.equal(await js("document.querySelectorAll('.widget-tile').length"),5);
  await snapshot("widgets-dark-1040-125dpi",1040,800,1.25);
  await cdp("Page.navigate",{url:base + "?widget=calendar"});
  await waitFor(".widget-single .widget-calendar");
  await snapshot("calendar-widget-dark-420",420,580,1);
  await cdp("Page.navigate",{url:base + "#fixed-expenses"});
  await section("fixed-expenses");
  await click(fixed("expense-tab","payments"));
  await click(fixed("payment-delete"));
  await textHas("#fixed-expenses","还没有已核实的支付");
  assert.equal(await js("state.summary.monthExpense"),0);
  assert.deepEqual(failures,[]);
  console.log("Workbench smoke passed for fixed income, expenses, benefits, widgets, dark mode and relaunch routes");
} finally {
  websocket.close();
}
