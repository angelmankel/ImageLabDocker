/**
 * Check a saved workflow by running it the way ComfyUI itself would.
 *
 *   node scripts/queue-workflow.mjs <ip:port> "workflows/Anima Turbo.json" [seed]
 *
 * A workflow file is an EDITOR graph; /prompt takes an API graph. Rather than convert it here and
 * hope the conversion matches, this loads the file into the pod's own ComfyUI frontend offscreen,
 * lets that convert it (app.graphToPrompt), and posts the result. So it catches exactly what a
 * person clicking Queue would hit: a missing model, a renamed widget, an off-by-one in
 * widgets_values. It prints the prompt id, then polls /history until the run ends.
 *
 * Needs `npm install` in this repo (puppeteer-core) and a local Chromium.
 */
import { createRequire } from "node:module";
import { readFileSync, existsSync } from "node:fs";

const require = createRequire(new URL("../package.json", import.meta.url));
const puppeteer = require("puppeteer-core");

const ENVFILE = process.env.IMAGELAB_ENV || new URL("../../.env", import.meta.url).pathname;
const env = Object.fromEntries(
  readFileSync(ENVFILE, "utf8").split("\n")
    .map(l => l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)).filter(Boolean)
    .map(m => [m[1], m[2].replace(/^["']|["']$/g, "")]));

const [hostport, file, seed] = process.argv.slice(2);
if (!hostport || !file) {
  console.error('usage: queue-workflow.mjs <ip:port> <workflow.json> [seed]');
  process.exit(1);
}
const base = `http://${hostport}`;
const auth = "Basic " + Buffer.from(`${env.COMFY_LOCAL_USER}:${env.COMFY_LOCAL_TOKEN}`).toString("base64");
const graph = JSON.parse(readFileSync(file, "utf8"));

const chrome = ["/usr/bin/chromium", "/usr/bin/google-chrome-stable", "/usr/bin/google-chrome", "/usr/bin/brave"].find(existsSync);
if (!chrome) { console.error("no chromium found"); process.exit(1); }

const browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox"] });
const page = await browser.newPage();
await page.authenticate({ username: env.COMFY_LOCAL_USER, password: env.COMFY_LOCAL_TOKEN });
await page.goto(`${base}/`, { waitUntil: "domcontentloaded", timeout: 90000 });
// The frontend exposes the app on window in dev builds and under comfyAPI in released ones.
await page.waitForFunction(() => window.LiteGraph && (window.app?.graph || window.comfyAPI?.app?.app?.graph), { timeout: 90000 });
await new Promise(r => setTimeout(r, 2000));

const queued = await page.evaluate(async (graph, seed) => {
  const app = window.app ?? window.comfyAPI.app.app;
  await app.loadGraphData(graph);
  const { output } = await app.graphToPrompt();
  if (seed) for (const node of Object.values(output)) if ("seed" in node.inputs) node.inputs.seed = Number(seed);
  const res = await fetch("/prompt", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ prompt: output, client_id: "queue-workflow" }),
  });
  return { status: res.status, body: await res.json() };
}, graph, seed);
await browser.close();

if (queued.status !== 200 || queued.body.error) {
  console.error("REFUSED", JSON.stringify(queued.body, null, 1));
  process.exit(1);
}
const id = queued.body.prompt_id;
console.log(`queued ${id}`);

const get = async (path) => {
  const res = await fetch(`${base}${path}`, { headers: { Authorization: auth } });
  // ComfyUI's history can carry raw control characters in a traceback, so parse loosely.
  return JSON.parse((await res.text()).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, " "));
};
for (let i = 0; i < 600; i++) {
  await new Promise(r => setTimeout(r, 2000));
  const rec = (await get(`/history/${id}`))[id];
  if (!rec?.status?.completed && !rec?.status?.status_str) continue;
  const msg = Object.fromEntries(rec.status.messages.map(m => [m[0], m[1]]));
  const secs = msg.execution_success
    ? ((msg.execution_success.timestamp - msg.execution_start.timestamp) / 1000).toFixed(1)
    : null;
  if (rec.status.status_str !== "success") {
    console.error("FAILED", msg.execution_error?.node_type, msg.execution_error?.exception_message);
    process.exit(1);
  }
  const images = Object.values(rec.outputs ?? {}).flatMap(o => o.images ?? []);
  console.log(`success in ${secs}s, ${images.length} image(s):`);
  for (const im of images) {
    console.log(`  ${base}/view?filename=${encodeURIComponent(im.filename)}&subfolder=${encodeURIComponent(im.subfolder || "")}&type=${im.type}`);
  }
  process.exit(0);
}
console.error("still running after 20 minutes");
process.exit(1);
