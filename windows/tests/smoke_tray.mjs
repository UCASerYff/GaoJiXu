import assert from "node:assert/strict";
import {readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";

const [base, portFile, phase, evidence] = process.argv.slice(2);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(test, name) {
  let failure;
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      const value = await test();
      if (value) return value;
    } catch (error) {
      failure = error;
    }
    await pause(90);
  }
  throw new Error(`Timed out waiting for ${name}${failure ? ": " + failure.message : ""}`);
}

const page = await until(async () => {
  const port = Number((await readFile(portFile, "utf8")).split("\n")[0]);
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  return targets.find(target => target.type === "page" && target.url.startsWith(base) && !target.url.includes("?widget="));
}, "private main window DevTools target");
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, {once: true});
  socket.addEventListener("error", reject, {once: true});
});

let nextId = 0;
const pending = new Map();
socket.addEventListener("message", ({data}) => {
  const message = JSON.parse(data);
  const request = pending.get(message.id);
  if (!request) return;
  pending.delete(message.id);
  if (message.error) request.reject(new Error(message.error.message));
  else request.resolve(message.result);
});
socket.addEventListener("close", () => {
  for (const {reject} of pending.values()) reject(new Error("The isolated Chromium window closed."));
  pending.clear();
});
function call(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    socket.send(JSON.stringify({id, method, params}));
  });
}
async function evaluate(expression) {
  const result = await call("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true});
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
  return result.result.value;
}
const q = selector => `document.querySelector(${JSON.stringify(selector)})`;
const waitFor = selector => until(() => evaluate(`Boolean(${q(selector)})`), selector);
async function click(selector) {
  await waitFor(selector);
  await evaluate(`${q(selector)}.click()`);
}
async function input(selector, value) {
  await waitFor(selector);
  await evaluate(`((element, value) => {
    element.value = value;
    element.dispatchEvent(new Event("input", {bubbles: true}));
    element.dispatchEvent(new Event("change", {bubbles: true}));
  })(${q(selector)}, ${JSON.stringify(value)})`);
}

try {
  const exit = "#app-exit[open]";
  switch (phase) {
    case "ready":
      await waitFor(".finance-summary");
      break;
    case "background":
      await waitFor('nav [data-route="ledger"]');
      await evaluate(`[...document.querySelectorAll('nav [data-route="ledger"]')].filter(node => node.getClientRects().length).at(-1).click()`);
      await until(() => evaluate(`${q("#ledger:not([hidden])")}?.textContent.includes("后台合成记账")`), "background record");
      break;
    case "deep-link":
      await until(() => evaluate('location.hash === "#adventure"'), "forwarded adventure link");
      await waitFor('#adventure:not([hidden]) .adv-battle-scene[data-renderer="webgl"] canvas');
      break;
    case "prepare":
      await click('.record-button[data-workbench="record"]');
      await input('#editor [name="amountExpression"]', "19.50");
      await input('#editor [name="note"]', "退出前保存");
      break;
    case "cancel":
      await waitFor(exit);
      assert.match(await evaluate(`${q("#app-exit-text")}.textContent`), /尚未保存/);
      if (evidence) {
        const shot = await call("Page.captureScreenshot", {format: "png"});
        await writeFile(join(evidence, "tray-confirm-private-desktop.png"), Buffer.from(shot.data, "base64"));
      }
      await click("[data-exit-cancel]");
      await until(() => evaluate(`!${q(exit)}`), "dismissed exit confirmation");
      assert.equal(await evaluate(`${q('#editor[open] [name="note"]')}.value`), "退出前保存");
      break;
    case "save":
      await click("#editor-submit");
      await until(() => evaluate(`!${q("#editor[open]")}`), "ledger write before exit");
      break;
    case "in-app-quit-cancel":
      await click(".toolbar-menu summary");
      await click('[data-workbench="quit"]');
      await waitFor(exit);
      await click("[data-exit-cancel]");
      await until(() => evaluate(`!${q(exit)}`), "dismissed workbench quit confirmation");
      break;
    case "confirm":
      await waitFor(exit);
      await waitFor("[data-exit-confirm]");
      await evaluate(`setTimeout(() => ${q("[data-exit-confirm]")}.click(), 120)`);
      break;
    default:
      assert.fail("Unknown tray smoke phase " + phase);
  }
} finally {
  socket.close();
}
