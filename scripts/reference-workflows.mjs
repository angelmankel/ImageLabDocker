/**
 * Write the reference workflows for model families whose models are not on the pod yet:
 * Wan 2.2 T2V / I2V (A14B), Flux dev, Z-Image Turbo and Qwen-Image.
 *
 *   node scripts/reference-workflows.mjs <ip:port>
 *
 * Each graph is written here in API format and turned into an editor workflow in workflows/ by
 * ImageLab's own converter (../ImageLab/src/lib/workflowGraph.ts), against the pod's /object_info,
 * so widget order is exactly what ComfyUI and Studio read. Every file is then checked twice:
 * converted back (editorToApi) it must give the same graph, and /prompt must reject it only for
 * model files that are not downloaded yet. Settings follow ComfyUI's own templates.
 */
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const HOSTPORT = process.argv[2];
if (!HOSTPORT) { console.error("usage: reference-workflows.mjs <ip:port>"); process.exit(1); }
const ROOT = new URL("..", import.meta.url).pathname;
const env = Object.fromEntries(readFileSync(process.env.IMAGELAB_ENV || `${ROOT}../.env`, "utf8").split("\n")
  .map((l) => l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)).filter(Boolean).map((m) => [m[1], m[2].replace(/^["']|["']$/g, "")]));
const AUTH = "Basic " + Buffer.from(`${env.COMFY_LOCAL_USER}:${env.COMFY_LOCAL_TOKEN}`).toString("base64");
const api = (path, body) => fetch(`http://${HOSTPORT}${path}`, {
  method: body ? "POST" : "GET", headers: { Authorization: AUTH, "Content-Type": "application/json" }, body: body && JSON.stringify(body),
}).then((r) => r.json());

// ImageLab's converter, loaded straight from its TypeScript source (it imports nothing).
const ts = createRequire(`${ROOT}../ImageLab/package.json`)("typescript");
const src = readFileSync(`${ROOT}../ImageLab/src/lib/workflowGraph.ts`, "utf8");
const conv = {};
new Function("exports", ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText)(conv);

const n = (class_type, inputs, title) => ({ class_type, inputs, ...(title ? { _meta: { title } } : {}) });
const WAN_NEGATIVE = "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走";
const HF = "https://huggingface.co";

/** Wan 2.2 A14B: a high-noise expert for the first half of the steps, a low-noise one for the rest. */
function wan(kind) {
  const i2v = kind === "i2v";
  const g = {
    1: n("UNETLoader", { unet_name: `wan2.2_${kind}_high_noise_14B_fp8_scaled.safetensors`, weight_dtype: "default" }, "High-noise model"),
    2: n("UNETLoader", { unet_name: `wan2.2_${kind}_low_noise_14B_fp8_scaled.safetensors`, weight_dtype: "default" }, "Low-noise model"),
    3: n("CLIPLoader", { clip_name: "umt5_xxl_fp8_e4m3fn_scaled.safetensors", type: "wan", device: "default" }),
    4: n("VAELoader", { vae_name: "wan_2.1_vae.safetensors" }),
    5: n("ModelSamplingSD3", { model: ["1", 0], shift: 8 }),
    6: n("ModelSamplingSD3", { model: ["2", 0], shift: 8 }),
    7: n("CLIPTextEncode", { text: i2v ? "the girl turns her head and smiles, petals drift past, gentle camera push in" : "a red fox trotting through fresh snow in a pine forest, morning light, slow tracking shot", clip: ["3", 0] }, "Positive"),
    8: n("CLIPTextEncode", { text: WAN_NEGATIVE, clip: ["3", 0] }, "Negative"),
  };
  let pos = ["7", 0], neg = ["8", 0], latent;
  if (i2v) {
    g[9] = n("LoadImage", { image: "example.png" }, "Start image");
    g[10] = n("WanImageToVideo", { positive: pos, negative: neg, vae: ["4", 0], width: 832, height: 480, length: 81, batch_size: 1, start_image: ["9", 0] });
    pos = ["10", 0]; neg = ["10", 1]; latent = ["10", 2];
  } else {
    g[10] = n("EmptyHunyuanLatentVideo", { width: 832, height: 480, length: 81, batch_size: 1 });
    latent = ["10", 0];
  }
  const ks = (model, first, latentIn, title) => n("KSamplerAdvanced", {
    model, add_noise: first ? "enable" : "disable", noise_seed: 0, steps: 20, cfg: 3.5, sampler_name: "euler", scheduler: "simple",
    positive: pos, negative: neg, latent_image: latentIn, start_at_step: first ? 0 : 10, end_at_step: first ? 10 : 10000,
    return_with_leftover_noise: first ? "enable" : "disable",
  }, title);
  g[11] = ks(["5", 0], true, latent, "High noise (steps 0-10)");
  g[12] = ks(["6", 0], false, ["11", 0], "Low noise (steps 10-20)");
  g[13] = n("VAEDecode", { samples: ["12", 0], vae: ["4", 0] });
  // Animated WebP, not CreateVideo + SaveVideo: SaveVideo's format/codec are a dynamic combo
  // (COMFY_DYNAMICCOMBO_V3) that ImageLab's workflow converter cannot read yet, and Studio shows
  // an animated WebP like any image.
  g[14] = n("SaveAnimatedWEBP", { images: ["13", 0], filename_prefix: `video/Wan2.2_${kind.toUpperCase()}`, fps: 16, lossless: false, quality: 90, method: "default" });
  return g;
}

/** Flux-style flow models: diffusion model + own text encoder + VAE, CFG 1 unless noted. */
function flow({ unet, clip, vae, shift, guidance, negative, size, steps, cfg, sampler, prefix }) {
  const g = {
    1: n("UNETLoader", { unet_name: unet, weight_dtype: "default" }),
    2: clip,
    3: n("VAELoader", { vae_name: vae }),
  };
  let model = ["1", 0];
  if (shift !== undefined) { g[4] = n("ModelSamplingAuraFlow", { model, shift }); model = ["4", 0]; }
  g[5] = n("CLIPTextEncode", { text: "a red fox sitting in fresh snow in a pine forest, morning light, detailed fur, photograph", clip: ["2", 0] }, "Positive");
  let pos = ["5", 0];
  if (guidance !== undefined) { g[6] = n("FluxGuidance", { conditioning: pos, guidance }); pos = ["6", 0]; }
  // CFG 1 ignores the negative; a zeroed positive keeps the sampler's input filled.
  g[7] = negative === undefined
    ? n("ConditioningZeroOut", { conditioning: ["5", 0] }, "Negative (unused at CFG 1)")
    : n("CLIPTextEncode", { text: negative, clip: ["2", 0] }, "Negative");
  g[8] = n("EmptySD3LatentImage", { width: size, height: size, batch_size: 1 });
  g[9] = n("KSampler", { seed: 0, steps, cfg, sampler_name: sampler, scheduler: "simple", denoise: 1, model, positive: pos, negative: ["7", 0], latent_image: ["8", 0] });
  g[10] = n("VAEDecode", { samples: ["9", 0], vae: ["3", 0] });
  g[11] = n("SaveImage", { images: ["10", 0], filename_prefix: prefix });
  return g;
}

const WORKFLOWS = [
  {
    file: "Wan 2.2 T2V A14B.json", graph: wan("t2v"),
    note: `## Wan 2.2 T2V (A14B)\n\nText to video, 832×480, 81 frames (5 s at 16 fps). Two 14B experts: high noise for steps 0–10, low noise for 10–20, CFG 3.5, euler / simple, shift 8.\n\n**Models** (not in models.txt yet):\n- diffusion_models: wan2.2_t2v_high_noise_14B_fp8_scaled, wan2.2_t2v_low_noise_14B_fp8_scaled — ${HF}/Comfy-Org/Wan_2.2_ComfyUI_Repackaged\n- text_encoders: umt5_xxl_fp8_e4m3fn_scaled — ${HF}/Comfy-Org/Wan_2.1_ComfyUI_repackaged\n- vae: wan_2.1_vae — Wan_2.2_ComfyUI_Repackaged\n\n720p: 1280×704. Keep \`length\` at 4n+1. Saves an animated WebP; for MP4 put CreateVideo + SaveVideo after VAE Decode.`,
  },
  {
    file: "Wan 2.2 I2V A14B.json", graph: wan("i2v"),
    note: `## Wan 2.2 I2V (A14B)\n\nImage to video from the start image, 832×480, 81 frames (5 s at 16 fps). High-noise expert for steps 0–10, low-noise for 10–20, CFG 3.5, euler / simple, shift 8.\n\n**Models** (not in models.txt yet):\n- diffusion_models: wan2.2_i2v_high_noise_14B_fp8_scaled, wan2.2_i2v_low_noise_14B_fp8_scaled — ${HF}/Comfy-Org/Wan_2.2_ComfyUI_Repackaged\n- text_encoders: umt5_xxl_fp8_e4m3fn_scaled — ${HF}/Comfy-Org/Wan_2.1_ComfyUI_repackaged\n- vae: wan_2.1_vae — Wan_2.2_ComfyUI_Repackaged\n\nMatch width/height to the start image's shape. Saves an animated WebP; for MP4 put CreateVideo + SaveVideo after VAE Decode.`,
  },
  {
    file: "Flux Dev.json",
    graph: flow({
      unet: "flux1-dev.safetensors", vae: "ae.safetensors", guidance: 3.5, size: 1024, steps: 20, cfg: 1, sampler: "euler", prefix: "Flux_Dev",
      clip: n("DualCLIPLoader", { clip_name1: "clip_l.safetensors", clip_name2: "t5xxl_fp8_e4m3fn.safetensors", type: "flux", device: "default" }),
    }),
    note: `## Flux.1 dev\n\n1024², 20 steps, CFG 1 (the negative is unused), guidance 3.5 in FluxGuidance, euler / simple. Schnell: flux1-schnell, 4 steps.\n\n**Models** (not in models.txt yet):\n- diffusion_models: flux1-dev — ${HF}/black-forest-labs/FLUX.1-dev (gated: accept the licence)\n- text_encoders: clip_l, t5xxl_fp8_e4m3fn — ${HF}/comfyanonymous/flux_text_encoders\n- vae: ae — FLUX.1-dev (or FLUX.1-schnell)`,
  },
  {
    file: "Z-Image Turbo.json",
    graph: flow({
      unet: "z_image_turbo_bf16.safetensors", vae: "ae.safetensors", shift: 3, size: 1024, steps: 9, cfg: 1, sampler: "res_multistep", prefix: "Z-Image_Turbo",
      clip: n("CLIPLoader", { clip_name: "qwen_3_4b.safetensors", type: "lumina2", device: "default" }),
    }),
    note: `## Z-Image Turbo\n\n6B distilled model (Tongyi). 1024², 9 steps, CFG 1 (the negative is unused), res_multistep / simple, AuraFlow shift 3. Natural-language prompts work well.\n\n**Models** (not in models.txt yet) — ${HF}/Comfy-Org/z_image_turbo:\n- diffusion_models: z_image_turbo_bf16\n- text_encoders: qwen_3_4b (CLIPLoader type lumina2)\n- vae: ae (the Flux VAE)`,
  },
  {
    file: "Qwen Image.json",
    graph: flow({
      unet: "qwen_image_fp8_e4m3fn.safetensors", vae: "qwen_image_vae.safetensors", shift: 3.1, negative: " ", size: 1328, steps: 20, cfg: 2.5, sampler: "euler", prefix: "Qwen_Image",
      clip: n("CLIPLoader", { clip_name: "qwen_2.5_vl_7b_fp8_scaled.safetensors", type: "qwen_image", device: "default" }),
    }),
    note: `## Qwen-Image\n\n20B model, strong at text in images. 1328² native, 20 steps, CFG 2.5, euler / simple, AuraFlow shift 3.1.\n\n**Models** (not in models.txt yet) — ${HF}/Comfy-Org/Qwen-Image_ComfyUI:\n- diffusion_models: qwen_image_fp8_e4m3fn\n- text_encoders: qwen_2.5_vl_7b_fp8_scaled (CLIPLoader type qwen_image)\n- vae: qwen_image_vae (already on the pod, shared with Anima)`,
  },
];

const info = await api("/object_info");
const MODEL_INPUTS = new Set(["unet_name", "clip_name", "clip_name1", "clip_name2", "vae_name"]);
let bad = 0;
for (const { file, graph, note } of WORKFLOWS) {
  const wf = conv.apiToEditor(graph, info);
  const bottom = Math.max(...wf.nodes.map((nd) => nd.pos[1] + (nd.size?.[1] ?? 100)));
  const noteId = Math.max(...wf.nodes.map((nd) => nd.id)) + 1;
  wf.nodes.push({ id: noteId, type: "MarkdownNote", pos: [40, bottom + 40], size: [420, 320], flags: {}, order: wf.nodes.length, mode: 0,
    inputs: [], outputs: [], properties: {}, widgets_values: [note] });
  wf.last_node_id = Math.max(wf.last_node_id ?? 0, noteId);
  wf.id = wf.id ?? randomUUID();
  writeFileSync(`${ROOT}workflows/${file}`, JSON.stringify(wf, null, 2) + "\n");

  // 1. Round trip: the editor file must give back the same graph.
  const back = conv.editorToApi(wf, info).graph ?? conv.editorToApi(wf, info);
  const strip = (g) => Object.fromEntries(Object.entries(g).map(([k, v]) => [k, { class_type: v.class_type, inputs: v.inputs }]));
  const sorted = (o) => JSON.stringify(o, (_, v) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort()) : v));
  const same = sorted(strip(back)) === sorted(strip(graph));
  // 2. /prompt: only not-yet-downloaded model files may fail.
  const res = await api("/prompt", { prompt: graph, client_id: "reference-check" });
  const errs = Object.values(res.node_errors ?? {}).flatMap((ne) => ne.errors.map((e) => ({ cls: ne.class_type, input: e.extra_info?.input_name, msg: e.message })));
  const other = errs.filter((e) => !(MODEL_INPUTS.has(e.input) && e.msg === "Value not in list"));
  if (res.prompt_id) other.push({ msg: "queued (all models present?)" });
  console.log(`${file}: round trip ${same ? "same" : "DIFFERENT"}; missing models: ${errs.length - other.length}; other problems: ${other.length ? JSON.stringify(other) : "none"}`);
  if (!same || other.length) bad++;
}
process.exit(bad ? 1 : 0);
