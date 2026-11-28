import assert from "node:assert/strict";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";

const [base, portFile, output] = process.argv.slice(2);
if (!base || !portFile || !output) throw new Error("Pass an isolated app URL, a DevToolsActivePort file and an evidence directory");
await mkdir(output,{recursive:true});
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
async function until(test,label) {
  let last;
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      const result = await test();
      if (result) return result;
    } catch (error) { last = error; }
    await delay(80);
  }
  throw new Error(`Timed out waiting for ${label}${last ? " (" + last.message + ")" : ""}`);
}

const port = await until(async () => Number((await readFile(portFile,"utf8")).split("\n")[0]),"isolated Chrome");
const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const socket = new WebSocket(pages.find(target => target.type === "page").webSocketDebuggerUrl);
await new Promise((resolve,reject) => {
  socket.addEventListener("open",resolve,{once:true});
  socket.addEventListener("error",reject,{once:true});
});
const pending = new Map();
const failures = [];
let nextID = 0;
function cdp(method, params = {}) {
  const id = ++nextID;
  return new Promise((resolve,reject) => {
    pending.set(id,{resolve,reject});
    socket.send(JSON.stringify({id,method,params}));
  });
}
socket.addEventListener("message", ({data}) => {
  const message = JSON.parse(data);
  if (message.method === "Runtime.exceptionThrown") failures.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
  const call = pending.get(message.id);
  if (!call) return;
  pending.delete(message.id);
  if (message.error) call.reject(new Error(message.error.message));
  else call.resolve(message.result);
});
async function script(expression) {
  const reply = await cdp("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true});
  if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description || reply.exceptionDetails.text);
  return reply.result.value;
}
const q = selector => `document.querySelector(${JSON.stringify(selector)})`;
const waitFor = selector => until(() => script(`Boolean(${q(selector)})`),selector);
const click = async selector => {await waitFor(selector); await script(`${q(selector)}.click()`);};
const textHas = (selector,text) => until(() => script(`${q(selector)}?.textContent.includes(${JSON.stringify(text)})`),`${selector} has ${text}`);
async function open(route, after) {
  const selector = `nav [data-route="${route}"]`;
  await waitFor(selector);
  await script(`[...document.querySelectorAll(${JSON.stringify(selector)})]
    .filter(button => button.getClientRects().length).at(-1).click()`);
  await waitFor(`#${route}:not([hidden]) ${after}`);
}
async function screenshot(name,width,height,pixelRatio,selector,focus = false) {
  await cdp("Emulation.setDeviceMetricsOverride",{width,height,deviceScaleFactor:pixelRatio,mobile:false});
  await script(focus ? `${q(selector)}.scrollIntoView({block:"start",inline:"nearest"})` : "window.scrollTo(0,0)");
  await delay(175);
  assert.ok(await script("document.documentElement.scrollWidth <= innerWidth + 2"),name+" page overflow");
  if (selector) assert.ok(await script(`((node) => node.scrollWidth <= node.clientWidth + 2)(${q(selector)})`),name+" content overflow");
  const result = await cdp("Page.captureScreenshot",{format:"png"});
  await writeFile(join(output,name+".png"),Buffer.from(result.data,"base64"));
}
async function setValue(selector,value) {
  await waitFor(selector);
  await script(`((input,value) => {
    input.value = value;
    input.dispatchEvent(new Event("input",{bubbles:true}));
    input.dispatchEvent(new Event("change",{bubbles:true}));
  })(${q(selector)},${JSON.stringify(value)})`);
}
const sub = selector => `#editor [name="${selector}"]`;

async function verifyCategoryCharts(appearance, expected) {
  await script(`api("/api/settings",{appearance:${JSON.stringify(appearance)}})`);
  await waitFor("#reports .finance-category-mix");
  for (const width of [360,600,900,1080,1400]) {
    await screenshot(`category-mix-${appearance}-${width}`,width,820,1,".finance-report-secondary",true);
    const measured = await script(`(() => {
      return {appearance:document.body.dataset.theme, charts:[...document.querySelectorAll("#reports .finance-category-mix")].map(chart => ({
        width:chart.getBoundingClientRect().width,
        rows:[...chart.children].map(row => {
          const label = row.querySelector("strong"), value = row.querySelector(".finance-number"), bar = row.querySelector("progress");
          const rect = bar.getBoundingClientRect();
          const [share,amount] = value.textContent.split(" · ");
          return {left:rect.left,width:rect.width,share:parseInt(share),position:bar.position,label:label.textContent,
            amount:Number(amount.replace(/[^0-9.]/g,"")),overflow:row.scrollWidth-row.clientWidth,
            below:rect.top >= Math.max(label.getBoundingClientRect().bottom,value.getBoundingClientRect().bottom)};
        })
      }))};
    })()`);
    assert.equal(measured.appearance,appearance);
    assert.equal(measured.charts.length,2);
    assert.ok(measured.charts.every(({rows}) => rows.every(row =>
      Math.abs(row.width-rows[0].width) < 0.1 && Math.abs(row.left-rows[0].left) < 0.1)),
      `${appearance} ${width}px uneven expense/income tracks: ${JSON.stringify(measured.charts.map(({rows}) => rows.map(row => row.width)))}`);
    measured.charts.forEach(({width:chartWidth,rows},index) => {
      const amounts = expected[index];
      const total = amounts.reduce((sum,value) => sum+value,0);
      assert.deepEqual(rows.map(row => row.amount),amounts);
      for (const row of rows) {
        assert.equal(row.share,Math.trunc(row.amount/total*100));
        assert.ok(Math.abs(row.position-row.amount/total) < 1e-9);
        assert.ok(row.width > 30 && row.overflow <= 1 && row.label.length > 0);
        assert.equal(row.below,chartWidth <= 320);
      }
    });
  }
}

try {
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Emulation.setDeviceMetricsOverride",{width:1400,height:940,deviceScaleFactor:1,mobile:false});
  await cdp("Page.navigate",{url:base});
  await click('[data-workbench="create"]');
  await waitFor(".finance-summary");
  const fixture = await script(`(async () => {
    const now = state.today;
    const [year,month] = now.split("-").map(Number);
    const previous = new Date(year,month-2,8);
    const previousMonth = [previous.getFullYear(),String(previous.getMonth()+1).padStart(2,"0")].join("-");
    const source = state.accounts[0].id;
    const target = state.accounts[1].id;
    await api("/api/settings",{language:"zh",appearance:"light"});
    const data = [
      ["income",source,8800,"salary-income","样本工资",now],
      ["expense",source,42.75,"food","工作日午餐样本",now],
      ["expense",target,380,"transport","月度交通记录",now],
      ["expense",source,23.50,"groceries","历史月份采购",previousMonth + "-08"],
      ["income",target,360,"side-income","历史兼职记录",previousMonth + "-08"],
      ["expense",source,128,"utilities","季度水电样本",previousMonth + "-09"]
    ];
    for (const [kind,accountID,amount,categoryID,note,date] of data) await api("/api/ledger/save",{kind,accountID,amount,categoryID,note,date});
    await api("/api/budgets/batch", {monthKey:now.slice(0,7),currency:"CNY",amounts:{food:650,transport:400,utilities:230}});
    const goal = await api("/api/goals/save",{title:"春节旅行储备",targetAmount:6500,
      startingAmount:1100,deadline:year + "-12-29",currency:"CNY",colorKey:"teal",savingsAccountID:target});
    await api("/api/records/save",{kind:"deposit",goalID:goal.id,fundingAccountID:source,savingsAccountID:target,
      amount:500,category:"scheduled",note:"周储蓄样本",date:now});
    return {now,previousMonth};
  })()`);
  await textHas(".finance-calendar-month",fixture.now.slice(0,4));
  await textHas(".finance-summary-primary","净资产");
  await waitFor('.finance-calendar-day[aria-current="date"]');
  assert.equal(await script(`${q('.finance-calendar-day[aria-pressed="true"]')}.dataset.value`),fixture.now);
  assert.ok(await script(`${q(".finance-calendar-selection")}.textContent.includes("42.75") || ${q(".finance-calendar-selection")}.textContent.includes("422.75")`));
  await screenshot("finance-overview-light-1400",1400,940,1,".finance-overview-grid");

  await click('[data-finance="calendar-prev"]');
  await waitFor(`[data-finance="calendar-day"][data-value="${fixture.previousMonth}-08"]`);
  await click(`[data-finance="calendar-day"][data-value="${fixture.previousMonth}-08"]`);
  await script(`${q('[data-finance="calendar-day"][aria-pressed="true"]')}.focus()`);
  await cdp("Input.dispatchKeyEvent",{type:"rawKeyDown",key:"ArrowRight",code:"ArrowRight",windowsVirtualKeyCode:39});
  await cdp("Input.dispatchKeyEvent",{type:"keyUp",key:"ArrowRight",code:"ArrowRight",windowsVirtualKeyCode:39});
  assert.equal(await script("document.activeElement.dataset.value"),fixture.previousMonth+"-09");
  await click('[data-finance="calendar-ledger"]');
  await waitFor("#ledger:not([hidden]) .finance-history-table");
  await textHas("#ledger","季度水电样本");
  assert.equal(await script(`${q('#ledger [name="history-day"]')}.value`),fixture.previousMonth+"-09");
  assert.equal(await script("document.querySelectorAll('#ledger [data-row]').length"),1);
  await click('#ledger [data-finance="new-ledger"]');
  await waitFor('dialog[open] .finance-ledger-editor');
  assert.equal(await script(`${q(sub("date"))}.value`),fixture.previousMonth+"-09");
  await setValue(sub("amountExpression"),"45.25+4");
  await setValue(sub("note"),"日期筛选下记账");
  await textHas("[data-preview]","49.25");
  await click(".finance-calculator > summary");
  await waitFor(".finance-calculator[open]");
  await screenshot("finance-entry-light-1020-dpi150",1020,740,1.5,".finance-ledger-editor");
  await click("#editor-submit");
  await until(() => script("!document.querySelector('dialog[open]')"),"saved editor");
  await textHas("#ledger","日期筛选下记账");
  await click('[data-finance="clear-day"]');
  await textHas("#ledger","工作日午餐样本");
  assert.equal(await script(`${q('#ledger [name="history-day"]')}.value`),"");
  await click("#ledger .finance-day-group > summary");
  assert.equal(await script(`${q("#ledger .finance-day-group")}.open`),false);
  await click("#ledger .finance-day-group > summary");
  await screenshot("finance-ledger-light-1280",1280,820,1,".finance-history-table");

  await open("accounts",".finance-account-table");
  await textHas("#accounts","净资产");
  await open("budgets",".finance-budget-columns");
  await click('#budgets [data-finance="budget-category"][data-value="food"]');
  await waitFor("dialog[open]");
  assert.equal(await script("document.activeElement.name"),"budget-food");
  await click("#editor-cancel");
  await open("reports",".finance-report-grid");
  await waitFor("#net-worth-chart canvas");
  await screenshot("finance-reports-light-1280",1280,820,1,".finance-report-grid");

  await open("goals",".finance-goal-card");
  const goal = await script(`[...document.querySelectorAll(".finance-goal-card")].find(card => card.textContent.includes("春节旅行储备")).querySelector('[data-finance="goal-deposit"]').dataset.value`);
  await click(`[data-finance="goal-deposit"][data-value="${goal}"]`);
  await waitFor("dialog[open]");
  assert.equal(await script(`${q(sub("goalID"))}.value`),goal);
  await click("#editor-cancel");
  await open("records",".finance-history-table");
  await textHas("#records","周储蓄样本");
  await open("analytics",".finance-report-grid");
  await textHas("#analytics","最近 35 天积蓄日历");
  await open("goals",".finance-goal-card");
  await script('api("/api/settings",{appearance:"dark"})');
  await screenshot("finance-goals-dark-980-dpi150",980,760,1.5,".finance-goals-grid");
  await open("ledger",".finance-history-table");
  await screenshot("finance-ledger-dark-530-dpi150",530,740,1.5,".finance-history-table");
  await open("overview",".finance-calendar-calendar");
  await screenshot("finance-overview-dark-530-dpi150",530,780,1.5,".finance-calendar-card");
  await click('.record-button[data-workbench="record"]');
  await waitFor("dialog[open] .finance-ledger-editor");
  await click("#editor-cancel");
  await cdp("Input.dispatchKeyEvent",{type:"rawKeyDown",key:"n",code:"KeyN",windowsVirtualKeyCode:78,modifiers:2});
  await cdp("Input.dispatchKeyEvent",{type:"keyUp",key:"n",code:"KeyN",windowsVirtualKeyCode:78,modifiers:2});
  await waitFor("dialog[open] .finance-ledger-editor");
  await click("#editor-cancel");
  await script('api("/api/settings",{language:"en"})');
  await textHas("#overview","Financial overview");
  await textHas("#overview","Cash flow calendar");
  await script(`(async () => {
    const accountID = state.accounts.find(account => account.currency === "CNY").id;
    for (const [kind,categoryID,amount] of [["expense","utilities",2380.41],["income","investment-income",2083.13],["income","gift-income",17.65]]) {
      await api("/api/ledger/save",{kind,accountID,amount,categoryID,date:state.today,note:"QA category chart"});
    }
  })()`);
  await cdp("Page.navigate",{url:base + "#reports"});
  await waitFor("#reports:not([hidden]) .finance-category-mix");
  const expected = [[2380.41,380,42.75],[8800,2083.13,17.65]];
  await verifyCategoryCharts("light",expected);
  await verifyCategoryCharts("dark",expected);
  await setValue('#reports [name="finance-currency"]',"USD");
  await textHas("#reports","No expenses this month");
  await textHas("#reports","No income this month");
  assert.deepEqual(failures,[]);
  console.log("Finance redesign smoke passed: calendar keyboard/month/date flow, ledger editor, category proportions, reports, goals, English, light/dark and 150% scaling");
} finally {
  socket.close();
}
