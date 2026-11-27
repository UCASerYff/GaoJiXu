import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";

const [base, portFile] = process.argv.slice(2);
const widgetKinds = ["calendar","net-worth","expenses","benefits","adventure"];
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
async function until(read, description) {
  let error;
  for (let attempt=0; attempt<100; attempt++) {
    try {
      if (await read()) return;
    } catch (failure) { error = failure; }
    await sleep(80);
  }
  throw new Error("Timed out: " + description,{cause:error});
}

let targets;
await until(async () => {
  const port = (await readFile(portFile,"utf8")).split("\n")[0].trim();
  targets = await (await fetch("http://127.0.0.1:" + port + "/json/list")).json();
  return widgetKinds.every(kind => targets.some(target => target.url.startsWith(base + "?widget=" + kind + "&desktop=")));
},"all five private Chromium targets");
const sockets = [];
async function page(kind) {
  const target = targets.find(target => target.url.startsWith(base + "?widget=" + kind + "&desktop="));
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  sockets.push(socket);
  await new Promise((resolve,reject) => {
    socket.addEventListener("open",resolve,{once:true});
    socket.addEventListener("error",reject,{once:true});
  });
  let id = 0;
  const pending = new Map();
  socket.addEventListener("message", ({data}) => {
    const message = JSON.parse(data);
    if (!message.id) return;
    const {resolve,reject} = pending.get(message.id);
    pending.delete(message.id);
    if (message.error || message.result.exceptionDetails) reject(new Error(JSON.stringify(message.error || message.result.exceptionDetails)));
    else resolve(message.result.result.value);
  });
  return (expression,awaitPromise=false) => new Promise((resolve,reject) => {
    const request = ++id;
    pending.set(request,{resolve,reject});
    socket.send(JSON.stringify({id:request,method:"Runtime.evaluate",params:{expression,awaitPromise,returnByValue:true}}));
  });
}

try {
  const [calendar,worth,expenses,benefits,adventure] = await Promise.all(widgetKinds.map(page));
  for (const read of [calendar,worth,expenses,benefits,adventure]) {
    await until(() => read("Boolean(document.querySelector('.widget-tile') && !document.querySelector('[data-window-pin]').hidden)"),
                "attached widget content and pin control");
    assert.equal(await read("document.title.includes('[GJX:')"),false);
    assert.ok(await read("document.documentElement.scrollWidth - innerWidth") <= 1,"widget should not require horizontal scrolling");
  }
  assert.equal(await expenses("document.querySelector('.widget-expenses').textContent.includes('Synthetic plan')"),true);
  assert.equal(await benefits("Boolean(document.querySelector('.widget-claim'))"),true);
  await calendar("document.querySelector('[data-window-pin]').click()");
  await worth("document.querySelector('[data-window-pin]').click()");
  await until(() => calendar("document.querySelector('[data-window-pin]').getAttribute('aria-pressed') === 'true'"),"calendar pinned via UI");
  await until(() => worth("document.querySelector('[data-window-pin]').getAttribute('aria-pressed') === 'true'"),"net worth pinned via UI");
  const initialAttacks = await adventure("state.adventure.attackCount");
  await benefits("document.querySelector('.widget-claim').click()");
  await until(() => benefits("!document.querySelector('.widget-claim')"),"claim commits through the authoritative loopback service");
  await calendar("api('/api/ledger/save',{kind:'income',accountID:state.accounts[0].id,categoryID:'salary-income',amount:31.45})",true);
  await until(() => calendar("[...document.querySelectorAll('.widget-day')].some(node => /31\\.45/.test(node.title))"),"calendar income updated");
  await calendar("[...document.querySelectorAll('.widget-day')].find(node=>/31\\.45/.test(node.title)).click()");
  assert.equal(await calendar("/31\\.45/.test(document.querySelector('.widget-calendar-summary').textContent)"),true);
  assert.equal(await calendar("document.querySelectorAll('.widget-day[aria-pressed=true]').length"),1);
  await until(() => worth("/31\\.45/.test(document.querySelector('.widget-value').textContent)"),"separate net worth window updated");
  await until(() => adventure("state.adventure.attackCount > " + initialAttacks),"battle progress updates in separate observation window");
  console.log("widget DOM: five connected, Win32-backed pin actions, claim, calendar/net-worth propagation, fixed expense and live adventure progress verified");
} finally {
  for (const socket of sockets) socket.close();
}
