/**
 * Open ImageLab on a pod in a headless browser and say whether it actually works.
 *
 *   node scripts/lab-check.mjs http://<ip:port>/imagelab/ [shot.png]
 *
 * A white screen and a page that loads but reaches no ComfyUI look identical from curl: both are
 * HTTP 200. This loads the page for real, reports how many children #root grew, and prints the
 * console, the page errors and every response over 400 — which is how the two were told apart.
 *
 * puppeteer-core comes from this repo's package.json: run `npm install` once.
 */
import { createRequire } from "node:module";
import { readFileSync, existsSync } from "node:fs";

const puppeteer = createRequire(new URL("../package.json", import.meta.url))("puppeteer-core");

// Credentials from the one project .env beside the three repos, same as the shell scripts.
const ENVFILE = process.env.IMAGELAB_ENV || new URL("../../.env", import.meta.url).pathname;
const env = Object.fromEntries(
  readFileSync(ENVFILE, "utf8").split("\n")
    .map(l => l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)).filter(Boolean)
    .map(m => [m[1], m[2].replace(/^["']|["']$/g, "")]));

const url = process.argv[2];
const shot = process.argv[3];
if (!url) { console.error("usage: lab-check.mjs <url> [shot.png]"); process.exit(1); }

const chrome = ["/usr/bin/chromium", "/usr/bin/google-chrome-stable", "/usr/bin/google-chrome", "/usr/bin/brave"].find(existsSync);
if (!chrome) { console.error("no chromium found"); process.exit(1); }

const browser = await puppeteer.launch({ executablePath: chrome, headless: "new", args: ["--no-sandbox"] });
const page = await browser.newPage();
await page.authenticate({ username: env.COMFY_LOCAL_USER, password: env.COMFY_LOCAL_TOKEN });

const msgs = [];
page.on("console", m => msgs.push(`[${m.type()}] ${m.text()}`));
page.on("pageerror", e => msgs.push(`[pageerror] ${e.message}`));
page.on("requestfailed", r => msgs.push(`[reqfail] ${r.url()} ${r.failure()?.errorText}`));
page.on("response", r => { if (r.status() >= 400) msgs.push(`[http ${r.status()}] ${r.url()}`); });

await page.goto(url, { waitUntil: "networkidle2", timeout: 60000 }).catch(e => msgs.push(`[goto] ${e.message}`));
await new Promise(s => setTimeout(s, 3000));

const seen = await page.evaluate(() => ({
  children: document.getElementById("root")?.children.length ?? -1,
  text: (document.body.innerText || "").slice(0, 400),
}));
console.log("URL:", url);
console.log("#root children:", seen.children, seen.children > 0 ? "(rendered)" : "(WHITE SCREEN)");
console.log("connected:", /\bConnected\b/.test(seen.text) ? "yes" : `no — ${JSON.stringify(seen.text.slice(0, 120))}`);
console.log("--- console ---");
console.log(msgs.slice(0, 40).join("\n") || "(silent)");
if (shot) await page.screenshot({ path: shot });
await browser.close();
