// banner.ts — the README header for devtools-unpack, authored with Clayzo.
//
// DESIGN LANGUAGE: Sculptural Industrial Futurism (docs/design/sculptural-
// industrial-futurism.md) — the early-2000s industrial design language, not the
// eyewear. §12 is the brief:
//
//   "a past era's optimistic prediction of future hardware: silver materials,
//    elliptical geometry, flowing forms, visible mechanisms ... Retain: alien
//    but useful silhouettes; graphite/silver material contrast; aerodynamic
//    ellipses and molded structures; purposeful machinery-like identity.
//    Discard: arbitrary pixel grids, fake CRT artifacts, chrome text
//    everywhere; noisy RGB gradients, meaningless technical labels."
//
// ART DIRECTION (written before authoring, per the skill):
//   verb      assemble — the aperture's concentric rings settle into place,
//             then the type lands. Decisive travel, soft settling (§8).
//   geometry  the era's AERODYNAMIC ELLIPSE as the one memorable silhouette:
//             a machined aperture built from three concentric rings and a
//             recessed core, with one optical slit. Object left, type right,
//             one thin alignment rule between them (§7 "planes", §14 poster).
//   palette   tokens.json, at the 75/20/5 ratio: carbon ground, graphite and
//             gunmetal structure, alloy and titanium metal, mist ink, and ONE
//             accent — optic-cyan — as the slit, ~3% of the frame.
//   scale     the aperture is 300 x 280 (a third of the height's short edge);
//             the wordmark spans the right 55% of the width; one dramatic
//             scale shift between them (§14).
//   words     two: the name, and one measured spec line. The spec line is REAL
//             (26 modules, 49 dispatch arms, 48 gates, 2,729 assertions)
//             because "meaningless technical labels" are banned.
//   punch     the aperture settles inside 0.4 s; the wordmark lands at 0.5 s;
//             the spec line at 0.75 s. Settled by 1.2 s.
//
// EVERY colour, face, tracking and duration comes from ../../tokens.json. No
// hex is restated here: the token file is the single source, and the check
// greps this file for a stray hex.

import { writeFileSync } from "node:fs";
import {
  ANIMATION_DOCUMENT_VERSION, assertValidAnimationDocument, constant,
  withComputedRevision,
  type AnimationDocument, type Transform25D,
} from "@clayzo/animation/authoring";
import tokens from "../tokens.json";

const W = 1600, H = 400;
const TPS = 240;
const DURATION = TPS * 3; // 3 s; the README uses the settled frame at tick 600

// --- tokens -----------------------------------------------------------------
// DTCG entries wrap their value in `$value`; read it through a guard so a
// malformed token fails loudly here instead of rendering as `undefined`.
function tokenValue(entry: unknown): string {
  if (entry !== null && typeof entry === "object" && "$value" in entry) {
    const value = entry.$value;
    if (typeof value === "string") return value;
  }
  throw new Error("token without a string $value");
}

function tokenNumber(entry: unknown): number {
  if (entry !== null && typeof entry === "object" && "$value" in entry) {
    const value = entry.$value;
    if (typeof value === "number") return value;
  }
  throw new Error("token without a number $value");
}

function tokenEase(entry: unknown): [number, number, number, number] {
  if (entry !== null && typeof entry === "object" && "$value" in entry) {
    const value = entry.$value;
    if (Array.isArray(value) && value.length === 4 && value.every((n) => typeof n === "number")) {
      return [value[0], value[1], value[2], value[3]];
    }
  }
  throw new Error("token without a four-number $value");
}

const C = {
  carbon: tokenValue(tokens.color.carbon),
  graphite: tokenValue(tokens.color.graphite),
  gunmetal: tokenValue(tokens.color.gunmetal),
  alloy: tokenValue(tokens.color.alloy),
  titanium: tokenValue(tokens.color.titanium),
  mist: tokenValue(tokens.color.mist),
  optic: tokenValue(tokens.color.optic),
};
const F = tokens.font;
const T = tokens.tracking;
const M = tokens.motion;

const rgba = (hex: string) => ({
  r: parseInt(hex.slice(1, 3), 16) / 255,
  g: parseInt(hex.slice(3, 5), 16) / 255,
  b: parseInt(hex.slice(5, 7), 16) / 255,
  a: 1,
});

const [ex1, ey1, ex2, ey2] = tokenEase(M.ease);
const SETTLE = { x1: ex1, y1: ey1, x2: ex2, y2: ey2 };
const ms = (duration: number) => Math.round((duration / 1000) * TPS);
const heroMs = tokenNumber(M.hero);
const panelMs = tokenNumber(M.panel);

let kfCounter = 0;
const kf = (tick: number, value: unknown, interpolation: "bezier" | "hold" = "bezier") => ({
  id: `k${++kfCounter}`,
  tick, value, interpolation,
  ...(interpolation === "bezier" ? { easing: SETTLE } : {}),
});

// Every node repeats the same five-field transform; only the position varies.
const base = (id: string, position: Transform25D["position"]) => ({
  id, name: id, visible: true, inTick: 0, outTick: DURATION,
  opacity: constant(1),
  transform: {
    position,
    anchor: constant({ x: 0, y: 0, z: 0 }),
    scale: constant({ x: 1, y: 1, z: 1 }),
    rotation: constant({ x: 0, y: 0, z: 0 }),
    skew: constant({ x: 0, y: 0 }),
  },
  blendMode: "normal" as const,
});

// --- the aperture -----------------------------------------------------------
// Three concentric rings and a recessed core, centred at (360, 200). Each ring
// is a filled ellipse; the ring below shows as a rim. This is the era's
// ellipse and a believable machined part: bezel, inner bezel, well.
const AX = 360, AY = 200;

const ring = (id: string, w: number, h: number, stops: Array<[number, string]>) => ({
  ...base(id, constant({ x: AX, y: AY, z: 0 })),
  type: "ellipse" as const,
  size: constant({ width: w, height: h }),
  style: {
    gradientFill: {
      kind: "linear" as const,
      stops: constant(stops.map(([position, hex]) => ({ position, color: rgba(hex) }))),
      start: constant({ x: 0, y: -h / 2 }),
      end: constant({ x: 0, y: h / 2 }),
      opacity: constant(1),
    },
  },
});

const apertureNodes: Record<string, unknown> = {
  "ap-outer": ring("ap-outer", 366, 254, [[0, C.mist], [0.38, C.titanium], [1, C.gunmetal]]),
  "ap-ring":  ring("ap-ring", 302, 202, [[0, C.gunmetal], [1, C.graphite]]),
  "ap-core":  ring("ap-core", 238, 152, [[0, C.graphite], [1, C.carbon]]),
  // the optical slit: the one accent, ~3% of the frame
  "ap-optic": {
    ...base("ap-optic", constant({ x: AX, y: AY, z: 0 })),
    type: "rect" as const,
    size: constant({ width: 116, height: 6 }),
    cornerRadius: constant(3),
    style: { fill: { color: constant(rgba(C.optic)), opacity: constant(1) } },
  },
};

// The aperture group: settles from 0.92 scale with a fade, anchored at its own
// centre so it grows about the part, not about the canvas.
const apertureGroup = {
  ...base("aperture", constant({ x: AX, y: AY, z: 0 })),
  transform: {
    // position == anchor: the children are in canvas space, so the transform
    // must be identity at rest, and the scale then grows about the part.
    position: constant({ x: AX, y: AY, z: 0 }),
    anchor: constant({ x: AX, y: AY, z: 0 }),
    scale: {
      kind: "keyframed",
      keyframes: [
        kf(0, { x: 0.92, y: 0.92, z: 1 }),
        kf(ms(heroMs), { x: 1, y: 1, z: 1 }),
        kf(DURATION, { x: 1, y: 1, z: 1 }, "hold"),
      ],
    },
    rotation: constant({ x: 0, y: 0, z: 0 }),
    skew: constant({ x: 0, y: 0 }),
  },
  opacity: {
    kind: "keyframed",
    keyframes: [
      kf(0, 0),                    // bezier: the segment LEAVING fades
      kf(ms(heroMs), 1, "hold"),
      kf(DURATION, 1, "hold"),
    ],
  },
  type: "group" as const,
  isolation: true,
  children: Object.keys(apertureNodes),
};

// --- the alignment rule -----------------------------------------------------
// §7: "thin rules, short alignment marks ... can reinforce the engineering
// character when they communicate something." This one separates the object
// plane from the type plane.
const ruleNode = {
  ...base("rule", constant({ x: 640, y: 200, z: 0 })),
  type: "rect" as const,
  size: constant({ width: 1, height: 240 }),
  cornerRadius: constant(0),
  style: { fill: { color: constant(rgba(C.alloy)), opacity: constant(0.35) } },
};

// --- the wordmark -----------------------------------------------------------
const TITLE = "DEVTOOLS-UNPACK";
const TITLE_SIZE = 76;
const TYPE_X = 700;

const titleNode = {
  ...base("title", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: TYPE_X - 16, y: 104, z: 0 }),
      kf(ms(heroMs + panelMs), { x: TYPE_X - 16, y: 104, z: 0 }),
      kf(ms(heroMs + panelMs) + ms(heroMs), { x: TYPE_X, y: 104, z: 0 }),
      kf(DURATION, { x: TYPE_X, y: 104, z: 0 }, "hold"),
    ],
  }),
  opacity: {
    kind: "keyframed",
    keyframes: [
      kf(0, 0, "hold"),
      kf(ms(heroMs + panelMs), 0),
      kf(ms(heroMs + panelMs) + ms(heroMs), 1, "hold"),
      kf(DURATION, 1, "hold"),
    ],
  },
  type: "text" as const,
  runs: constant([{
    text: TITLE,
    fontAssetId: "display",
    fontSize: TITLE_SIZE,
    fontWeight: F.display.weight,
    letterSpacing: tokenNumber(T.display),
    lineHeight: 1.15,
    color: rgba(C.mist),
  }]),
  box: { width: 840, height: 100 },
  wrap: "none" as const,
  align: "left" as const,
  verticalAlign: "top" as const,
};

// --- the spec line ----------------------------------------------------------
const SPEC = "26 modules  ·  49 dispatch arms  ·  48 gates  ·  2,729 assertions";

const specNode = {
  ...base("spec", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: TYPE_X, y: 236, z: 0 }),
      kf(ms(heroMs + panelMs * 2), { x: TYPE_X, y: 236, z: 0 }),
      kf(ms(heroMs + panelMs * 2) + ms(heroMs), { x: TYPE_X, y: 228, z: 0 }),
      kf(DURATION, { x: TYPE_X, y: 228, z: 0 }, "hold"),
    ],
  }),
  opacity: {
    kind: "keyframed",
    keyframes: [
      kf(0, 0, "hold"),
      kf(ms(heroMs + panelMs * 2), 0),
      kf(ms(heroMs + panelMs * 2) + ms(heroMs), 1, "hold"),
      kf(DURATION, 1, "hold"),
    ],
  },
  type: "text" as const,
  runs: constant([{
    text: SPEC,
    fontAssetId: "mono",
    fontSize: 17,
    fontWeight: F.mono.weight,
    letterSpacing: tokenNumber(T.mono),
    lineHeight: 1.5,
    color: rgba(C.alloy),
  }]),
  box: { width: 840, height: 30 },
  wrap: "none" as const,
  align: "left" as const,
  verticalAlign: "top" as const,
};

// --- assemble ---------------------------------------------------------------
const nodes: Record<string, unknown> = {
  field: {
    ...base("field", constant({ x: W / 2, y: H / 2, z: 0 })),
    type: "rect" as const,
    size: constant({ width: W, height: H }),
    cornerRadius: constant(0),
    style: { fill: { color: constant(rgba(C.carbon)), opacity: constant(1) } },
  },
  aperture: apertureGroup,
  ...apertureNodes,
  rule: ruleNode,
  title: titleNode,
  spec: specNode,
};

const composition = {
  id: "main", name: "banner",
  width: W, height: H, durationTicks: DURATION,
  nodes,
  rootNodeIds: ["field", "aperture", "rule", "title", "spec"],
};

const document = withComputedRevision({
  version: ANIMATION_DOCUMENT_VERSION,
  id: "devtools-unpack-banner",
  revision: "",
  name: "devtools-unpack README banner",
  canvas: { width: W, height: H, pixelAspectRatio: 1, backgroundColor: rgba(C.carbon) },
  timing: { ticksPerSecond: TPS, frameRate: { numerator: 30, denominator: 1 },
            durationTicks: DURATION, displayStartTick: 0 },
  assets: {
    display: { id: "display", type: "font", uri: `fonts/${F.display.file}`,
               mimeType: "font/ttf" },
    mono: { id: "mono", type: "font", uri: `fonts/${F.mono.file}`,
            mimeType: "font/ttf" },
  },
  compositions: { main: composition },
  rootCompositionId: "main",
  components: {},
  markers: [],
  capabilities: { required: [], optional: [], unsupportedPolicy: "warn" },
  design: { tokens: { looping: false } },
} as unknown as AnimationDocument); // nodes are built loosely above; the validator is the real check

// The validator rejects with a diagnostics array; narrow it rather than cast.
function diagnosticsOf(e: unknown): Array<{ path: string; message: string }> {
  if (e === null || typeof e !== "object" || !("diagnostics" in e)) return [];
  const list = e.diagnostics;
  if (!Array.isArray(list)) return [];
  return list.filter((d): d is { path: string; message: string } =>
    d !== null && typeof d === "object" && "path" in d && "message" in d);
}

try { assertValidAnimationDocument(document); }
catch (e) {
  for (const d of diagnosticsOf(e)) console.log(d.path + " :: " + d.message);
  process.exit(1);
}
writeFileSync("banner.json", JSON.stringify(document));
console.log("banner.json written, revision", document.revision);
