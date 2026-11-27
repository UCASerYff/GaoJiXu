import assert from "node:assert/strict";
import {mkdir, readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";

const [base, chromeEndpoint, output] = process.argv.slice(2);
if (!base || !chromeEndpoint || !output) throw new Error("Expected app URL, Chrome DevToolsActivePort path, and screenshot directory");
await mkdir(output,{recursive:true});
const pause = milliseconds => new Promise(resolve=>setTimeout(resolve,milliseconds));
async function until(check, description) {
  for (let attempt=0;attempt<100;attempt++) {
    try { const result = await check(); if(result) return result; } catch (_) {}
    await pause(80);
  }
  throw new Error("Timed out waiting for " + description);
}
const port = await until(async()=>Number((await readFile(chromeEndpoint,"utf8")).split("\n")[0]),"DevTools");
const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = pages.find(item=>item.type==="page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve,reject)=>{
  ws.addEventListener("open",resolve,{once:true});
  ws.addEventListener("error",reject,{once:true});
});
const pending = new Map();
const failures = [];
let count=0;
function cdp(method,params={}) {
  const id=++count;
  return new Promise((resolve,reject)=>{
    pending.set(id,{resolve,reject});
    ws.send(JSON.stringify({id,method,params}));
  });
}
ws.addEventListener("message",({data})=>{
  const value=JSON.parse(data);
  if(value.method==="Runtime.exceptionThrown") failures.push(value.params.exceptionDetails.exception?.description || value.params.exceptionDetails.text);
  if(!pending.has(value.id)) return;
  const {resolve,reject}=pending.get(value.id);
  pending.delete(value.id);
  if(value.error) reject(new Error(JSON.stringify(value.error)));
  else resolve(value.result);
});
async function js(expression) {
  const {result,exceptionDetails}=await cdp("Runtime.evaluate",{expression,awaitPromise:true,returnByValue:true});
  if(exceptionDetails) throw new Error(exceptionDetails.exception?.description || exceptionDetails.text);
  return result.value;
}
async function shot(name) {
  const {data}=await cdp("Page.captureScreenshot",{format:"png"});
  await writeFile(join(output,name+".png"),Buffer.from(data,"base64"));
}
const battle = "#adventure .adv-battle-scene";
const camp = "#adventure .adv-camp-scene";
const renderer = `${battle}[data-renderer=webgl]`;
const prepared = `document.querySelector(${JSON.stringify(renderer)})`;
const ready = selector => until(()=>js(`Boolean(document.querySelector(${JSON.stringify(selector)}))`),selector);
const click = selector => js(`document.querySelector(${JSON.stringify(selector)}).click()`);
const text = selector => js(`document.querySelector(${JSON.stringify(selector)}).textContent`);
const scroll = selector => js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:"center"})`);
const getHeroX = () => js(`Number.parseFloat(${prepared}.querySelector(".adv-hero").style.getPropertyValue("--actor-x"))`);
const pixels = () => js(`(() => {
  const canvas=${prepared}.querySelector("canvas");
  const gl=canvas.getContext("webgl");
  const pixel=new Uint8Array(4);
  let painted=0;
  const stride=Math.max(4,Math.floor(Math.min(canvas.width,canvas.height)/45));
  for(let x=0;x<canvas.width;x+=stride) for(let y=0;y<canvas.height;y+=stride) {
    gl.readPixels(x,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    if(pixel[3]>100) painted++;
  }
  return painted;
})()`);

try {
  await cdp("Page.enable");
  await cdp("Runtime.enable");
  await cdp("Emulation.setDeviceMetricsOverride",{width:1280,height:900,deviceScaleFactor:1,mobile:false});
  const probe=await cdp("Page.addScriptToEvaluateOnNewDocument",{source:`(() => {
    const native = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (type, options) {
      return native.call(this,type,type==="webgl"?{...options,preserveDrawingBuffer:true}:options);
    };
  })()`});
  await cdp("Page.navigate",{url:base});
  await ready('[data-workbench="create"]');
  await click('[data-workbench="create"]');
  await ready('#overview:not([hidden]) h1');
  await js(`api("/api/settings",{language:"en"})`);
  const overview = "#overview .adv-observation .adv-battle-scene";
  await ready(overview);
  await scroll(overview);
  await ready(overview+"[data-renderer=webgl]");
  assert.equal(await js(`Boolean(document.querySelector(${JSON.stringify(overview)}).querySelector("button"))`),false);
  await click('[data-route="adventure"]');
  await ready(renderer);
  assert.equal(await js(`document.querySelector(${JSON.stringify(renderer)}).querySelector("canvas").getContext("webgl").getParameter(WebGLRenderingContext.DEPTH_BITS)>=16`),true);
  assert.ok(await pixels()>8,"WebGL backbuffer must contain the illustrated actors");
  assert.match(await text(battle),/Hero Lv\./);
  assert.match(await text(battle),/Coin Slime/);
  assert.ok(await js(`document.querySelector(".adv-operations").getBoundingClientRect().left > ${prepared}.getBoundingClientRect().left`),
    "combat telemetry appears beside the map at desktop width");
  await js(`api("/api/settings",{language:"zh",appearance:"light"})`);
  await ready(renderer);
  await shot("adventure-map-light");
  await js(`api("/api/settings",{language:"en"})`);
  await ready(renderer);
  const heroBefore=await getHeroX();
  await js(`api("/api/adventure/tick",{})`);
  await until(async()=>Math.abs(await getHeroX()-heroBefore)>3,"hero position changes with real battle token");
  await click(battle+' [data-adv-action="actor"]');
  assert.ok((await text("#adventure .adv-battle-info")).includes(await js("state.adventure.english.monsterTrait")));
  await click(battle+" .adv-scene-view");
  await ready(battle+".adv-orbit");
  await pause(150);
  const heroOrbit=await getHeroX();
  assert.ok(Math.abs(heroOrbit-heroBefore)>5,"perspective shifts actor projection");
  await until(async()=>await pixels()>20,"modeled view contains colored geometry");
  await js(`document.querySelector(${JSON.stringify(battle+" .adv-scene-view")}).dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowLeft",bubbles:true}))`);
  await until(async()=>Math.abs(await getHeroX()-heroOrbit)>2,"keyboard orbits the rendered camera");
  const xBeforeWheel = await getHeroX();
  await js(`${prepared}.dispatchEvent(new WheelEvent("wheel",{deltaY:-100,bubbles:true,cancelable:true}))`);
  await until(async()=>Math.abs(await getHeroX()-xBeforeWheel)>2,"wheel changes perspective distance");
  const xBeforeDrag = await getHeroX();
  const point = await js(`(() => {
    const bounds = ${prepared}.getBoundingClientRect();
    return {x:Math.round(bounds.left + bounds.width * .19), y:Math.round(bounds.top + bounds.height*.32)};
  })()`);
  await cdp("Input.dispatchMouseEvent",{type:"mousePressed",...point,button:"left",buttons:1,clickCount:1});
  await cdp("Input.dispatchMouseEvent",{type:"mouseMoved",x:point.x+40,y:point.y,button:"left",buttons:1});
  await cdp("Input.dispatchMouseEvent",{type:"mouseReleased",x:point.x+40,y:point.y,button:"left",buttons:0,clickCount:1});
  await until(async()=>Math.abs(await getHeroX()-xBeforeDrag)>2,"drag changes perspective angle");
  await shot("adventure-perspective");
  assert.equal(await js(`(async () => {
    const scene=${prepared};
    const gl=scene.querySelector("canvas").getContext("webgl");
    const buffer=new Uint8Array(4);
    const hashes=new Set();
    for(let sprite=0;sprite<10;sprite++) {
      window.GaoAdventureScene.update(scene,"battle",{...state.adventure,monsterSprite:sprite},true,t,true);
      await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
      let hash=0;
      for(let x=gl.drawingBufferWidth/2;x<gl.drawingBufferWidth*.8;x+=13) for(let y=40;y<gl.drawingBufferHeight*.7;y+=12) {
        gl.readPixels(x,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,buffer);
        hash=(hash*31+buffer[3]+buffer[0]*41+buffer[1]*152)|0;
      }
      hashes.add(hash);
    }
    return hashes.size;
  })()`),10,"all catalogued enemies produce different rendered silhouettes");
  await click('[data-adv-action="jump-camp"]');
  assert.equal(await js("document.activeElement.closest('.adv-camp-links') !== null"),true);
  await ready(camp+'[data-renderer="webgl"]');
  assert.match(await text(camp),/Forge|Foundry/);
  await click(camp+" .adv-scene-view");
  await ready(camp+".adv-orbit");
  await shot("adventure-camp-perspective");
  await click(camp+' [data-id="technique"]');
  await ready('#adventure[data-adv-tab="technique"]');
  assert.match(await text("#adventure .adv-page"),/Insight/);
  assert.match(await text("#adventure .adv-page"),/Steady Heart/);
  await click('#adventure nav [data-id="equipment"]');
  assert.match(await text("#adventure .adv-page"),/AttackPower|Attack Power|Attack/);
  assert.equal(await js("Boolean(document.querySelector('.adv-catalog-workspace .adv-search') && document.querySelector('.adv-loadout-side .adv-slots'))"),true);
  await js(`api("/api/settings",{language:"zh",appearance:"dark"})`);
  await cdp("Emulation.setDeviceMetricsOverride",{width:730,height:850,deviceScaleFactor:1.5,mobile:false});
  assert.ok(await js("document.documentElement.scrollWidth-innerWidth")<=1);
  await shot("adventure-gear-dark-150dpi");
  await js(`api("/api/settings",{language:"en",appearance:"light"})`);
  await cdp("Emulation.setDeviceMetricsOverride",{width:1280,height:900,deviceScaleFactor:1,mobile:false});
  await click('#adventure nav [data-id="pets"]');
  assert.match(await text("#adventure .adv-page"),/Fortune Cat/);
  await click('#adventure nav [data-id="lottery"]');
  assert.match(await text("#adventure .adv-page"),/Wishes|Wish/);
  await click('#adventure nav [data-id="achievements"]');
  assert.match(await text("#adventure .adv-page"),/Achievements/);
  await click('#adventure nav [data-id="map"]');
  await ready(renderer);
  await cdp("Emulation.setDeviceMetricsOverride",{width:450,height:820,deviceScaleFactor:2,mobile:false});
  await ready(renderer);
  assert.ok(await js("document.documentElement.scrollWidth-innerWidth")<=1);
  await shot("adventure-450-dpi2");
  await cdp("Page.removeScriptToEvaluateOnNewDocument",{identifier:probe.identifier});
  await cdp("Page.addScriptToEvaluateOnNewDocument",{source:`(() => {
    const native=HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext=function(type,options) {
      return type==="webgl" ? null : native.call(this,type,options);
    };
  })()`});
  await cdp("Page.reload",{ignoreCache:true});
  await ready(battle+" .adv-hero img");
  assert.equal(await js(`Boolean(document.querySelector(${JSON.stringify(renderer)}))`),false);
  await click(battle+' [data-adv-action="actor"]');
  assert.ok((await text("#adventure .adv-battle-info")).includes(await js("state.adventure.english.monsterTrait")));
  await shot("adventure-webgl-fallback");
  await js(`api("/api/settings",{language:"zh",appearance:"dark"})`);
  await cdp("Emulation.setDeviceMetricsOverride",{width:325,height:455,deviceScaleFactor:1.5,mobile:false});
  await cdp("Page.navigate",{url:base+"?widget=calendar"});
  await ready(".widget-calendar .widget-day");
  await js(`api("/api/ledger/save",{kind:"income",accountID:state.accounts[0].id,categoryID:"salary-income",amount:1234.56})`);
  await click('.widget-day[aria-current="date"]');
  assert.match(await text(".widget-calendar-summary"),/1,234\.56/);
  assert.ok(await js("document.documentElement.scrollWidth-innerWidth")<=1);
  await shot("calendar-widget-dark-150dpi");
  assert.deepEqual(failures,[]);
  console.log("Adventure normal route, WebGL depth, original art, real attack animation, orbit and camp, English, observation, DPR 2 and fallback passed.");
} finally {
  ws.close();
}
