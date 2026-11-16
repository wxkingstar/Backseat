// 用法：node render.mjs <fps> [只渲染这些秒数，逗号分隔]
// 起一个无头 Chrome，逐帧调用页面里的 frame(t) 并截图到 frames/
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.dirname(fileURLToPath(import.meta.url));
const fps = Number(process.argv[2] || 30);
const only = process.argv[3] ? process.argv[3].split(",").map(Number) : null;
const out = path.join(dir, only ? "stills" : "frames");
mkdirSync(out, { recursive: true });
const port = 9377;

const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${path.join(dir, "profile")}`,
  "--window-size=1920,1080", "--hide-scrollbars", "--force-device-scale-factor=1", "--no-first-run",
  "file://" + path.join(dir, "index.html"),
], { stdio: "ignore" });

const sleep = ms => new Promise(r => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    target = list.find(x => x.type === "page" && x.url.includes("index.html"));
  } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r));
let seq = 0;
const pending = new Map();
ws.addEventListener("message", e => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise(r => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });

await send("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await sleep(500);
const dur = (await send("Runtime.evaluate", { expression: "window.DURATION" })).result.value;
const times = only ?? Array.from({ length: Math.round(dur * fps) }, (_, i) => i / fps);
for (let i = 0; i < times.length; i++) {
  await send("Runtime.evaluate", { expression: `window.frame(${times[i]})` });
  const shot = await send("Page.captureScreenshot", { format: "png" });
  const name = only ? `t${String(times[i]).replace(".", "_")}.png` : `f${String(i).padStart(5, "0")}.png`;
  writeFileSync(path.join(out, name), Buffer.from(shot.data, "base64"));
}
console.log(`rendered ${times.length} frames, duration ${dur}s`);
ws.close();
chrome.kill();
