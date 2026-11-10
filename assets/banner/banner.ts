// banner.ts — the README header for devtools-unpack, authored with Clayzo.
//
// DESIGN LANGUAGE: dither-ui (docs/design/dither-ui.md), fused with the
// Sculptural Industrial Futurism form language. dither-ui's identity line is
// the brief:
//
//   "A printed thing in the dark: one bone ink on obsidian, a fine grain, the
//    kit's Bayer dither as the only art, a monospace voice, and an extended
//    display face for the few words that lead. Engineered, never decorated."
//
// So the plate is PRINTED, not lit:
//   - obsidian #101214 ground, bone #E4E1D8 ink, muted #9C998F second ink;
//   - the aperture is drawn as flat rings and then run through the kit's
//     ordered dither — the dither IS the art, so there are no gradients on it;
//   - one signal, the ember #FF9632, as the optical slit (the one live thing);
//   - Michroma, the extended display face, for the wordmark only;
//   - IBM Plex Mono for the spec line, the print's voice;
//   - the grain covers the page, because the dither samples the drawn surface.
//
// Bans held (dither-ui, Bans): no neon, no cyberpunk HUD, no arbitrary pixel
// grids, no fake CRT artifacts, no chrome text everywhere, no noisy RGB
// gradients, no red, no meaningless technical labels.
//
// ART DIRECTION (written before authoring, per the skill):
//   verb      print — the plate is struck: the aperture's dither resolves, then
//             the type sets. One moving layer at a time.
//   geometry  the era's ellipse, printed: three concentric rings and a recessed
//             core, one ember slit. Mark above, name below, spec at the foot.
//   palette   two inks on one ground plus the one signal, per dither-ui.
//   scale     the aperture is 300 x 210; the wordmark spans ~57% of the width;
//             the spec line sits at the foot. One scale shift.
//   words     two: the name, and one measured spec line.
//   punch     the plate settles inside 0.4 s, the name at 0.55 s, the spec at
//             0.8 s. Settled by 1.2 s.
//
// EVERY colour, face, tracking and duration comes from ../tokens.json. No hex
// is restated here.

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
  obsidian: tokenValue(tokens.color.obsidian),
  bone: tokenValue(tokens.color.bone),
  muted: tokenValue(tokens.color.muted),
  ember: tokenValue(tokens.color.ember),
  graphite2: tokenValue(tokens.color.graphite2),
  gunmetal: tokenValue(tokens.color.gunmetal),
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

// --- the plate: a CELL FIELD ------------------------------------------------
// The aperture is not a filled ellipse: it is BUILT from discrete cells on an
// indexed grid (pattern-systems.md: "index cells, not pixels"). Each ring is a
// different cell SHAPE, so the layer reads by geometry as well as colour:
//   outer ring   rounded squares, bone
//   middle ring  diamonds (a square turned 45 degrees), gunmetal
//   core         circles, graphite
//   the slit     ember squares, the one signal
// Cells gather in a measured order rather than a sweep: delay grows with the
// distance from the centre plus a fixed per-cell offset.
const PX = 800, PY = 100;
const PITCH = 17;
const UNIT = 14;
const COLS = 16;
const ROWS = 10;
const R_OUTER = [136, 90];
const R_MID = [111, 70];
const R_CORE = [86, 50];

const OX = PX - ((COLS - 1) * PITCH) / 2;
const OY = PY - ((ROWS - 1) * PITCH) / 2;

// A deterministic per-cell offset, so the gather never looks like a sweep.
const jitter = (i: number, j: number) => ((i * 7 + j * 13) % 11) * 6;

const cellNodes: Record<string, unknown> = {};
let cellIndex = 0;

for (let j = 0; j < ROWS; j++) {
  for (let i = 0; i < COLS; i++) {
    const cx = OX + i * PITCH;
    const cy = OY + j * PITCH;
    const dx = cx - PX;
    const dy = cy - PY;
    const inEllipse = ([rx, ry]: number[]) => (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry) <= 1;

    const inCore = inEllipse(R_CORE);
    const inMid = inEllipse(R_MID);
    const inOuter = inEllipse(R_OUTER);
    if (!inOuter) continue;

    const inSlit = Math.abs(dy) <= UNIT / 2 && Math.abs(dx) <= 46;
    const id = `cell-${cellIndex++}`;
    const delay = Math.round(Math.hypot(dx, dy) * 0.9 + jitter(i, j));

    const common = {
      ...base(id, {
        kind: "keyframed",
        keyframes: [
          kf(0, { x: cx, y: cy, z: 0 }),
          kf(DURATION, { x: cx, y: cy, z: 0 }, "hold"),
        ],
      }),
      opacity: {
        kind: "keyframed",
        keyframes: [
          kf(0, 0, "hold"),
          kf(delay, 0),
          kf(delay + ms(120), 1, "hold"),
          kf(DURATION, 1, "hold"),
        ],
      },
    };

    if (inSlit) {
      cellNodes[id] = {
        ...common,
        type: "rect" as const,
        size: constant({ width: UNIT, height: UNIT }),
        cornerRadius: constant(2),
        style: { fill: { color: constant(rgba(C.ember)), opacity: constant(1) } },
      };
    } else if (inCore) {
      cellNodes[id] = {
        ...common,
        type: "ellipse" as const,
        size: constant({ width: UNIT, height: UNIT }),
        style: { fill: { color: constant(rgba(C.graphite2)), opacity: constant(1) } },
      };
    } else if (inMid) {
      // a diamond: the square turned 45 degrees, in the transform
      cellNodes[id] = {
        ...common,
        transform: {
          position: constant({ x: cx, y: cy, z: 0 }),
          anchor: constant({ x: 0, y: 0, z: 0 }),
          scale: constant({ x: 1, y: 1, z: 1 }),
          rotation: constant({ x: 0, y: 0, z: 45 }),
          skew: constant({ x: 0, y: 0 }),
        },
        type: "rect" as const,
        size: constant({ width: UNIT * 0.78, height: UNIT * 0.78 }),
        cornerRadius: constant(1),
        style: { fill: { color: constant(rgba(C.gunmetal)), opacity: constant(1) } },
      };
    } else {
      cellNodes[id] = {
        ...common,
        type: "rect" as const,
        size: constant({ width: UNIT, height: UNIT }),
        cornerRadius: constant(2),
        style: { fill: { color: constant(rgba(C.bone)), opacity: constant(1) } },
      };
    }
  }
}

// The plate group carries the cells; it is a root node (no effect node now:
// the cells ARE the dither).
const plateGroup = {
  ...base("plate", constant({ x: PX, y: PY, z: 0 })),
  transform: {
    position: constant({ x: PX, y: PY, z: 0 }),
    anchor: constant({ x: PX, y: PY, z: 0 }),
    scale: constant({ x: 1, y: 1, z: 1 }),
    rotation: constant({ x: 0, y: 0, z: 0 }),
    skew: constant({ x: 0, y: 0 }),
  },
  type: "group" as const,
  isolation: true,
  children: Object.keys(cellNodes),
};

// --- the wordmark -----------------------------------------------------------
// Michroma, the extended display face, bone. 15 glyphs at 64 px span ~910 px,
// centred, which is ~57% of the width.
const TITLE = "DEVTOOLS-UNPACK";
const TITLE_SIZE = 60;

const titleNode = {
  ...base("title", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: 0, y: 294, z: 0 }),
      kf(ms(heroMs + panelMs), { x: 0, y: 294, z: 0 }),
      kf(ms(heroMs + panelMs) + ms(heroMs), { x: 0, y: 286, z: 0 }),
      kf(DURATION, { x: 0, y: 286, z: 0 }, "hold"),
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
    fontWeight: F.extended.weight,
    letterSpacing: tokenNumber(T.display),
    lineHeight: 1.15,
    color: rgba(C.bone),
  }]),
  box: { width: W, height: 90 },
  wrap: "none" as const,
  align: "center" as const,
  verticalAlign: "top" as const,
};

// --- the spec line ----------------------------------------------------------
const SPEC = "26 modules  ·  49 dispatch arms  ·  48 gates  ·  2,729 assertions";

const specNode = {
  ...base("spec", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: 0, y: 356, z: 0 }),
      kf(ms(heroMs + panelMs * 2), { x: 0, y: 356, z: 0 }),
      kf(ms(heroMs + panelMs * 2) + ms(heroMs), { x: 0, y: 350, z: 0 }),
      kf(DURATION, { x: 0, y: 350, z: 0 }, "hold"),
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
    color: rgba(C.muted),
  }]),
  box: { width: W, height: 30 },
  wrap: "none" as const,
  align: "center" as const,
  verticalAlign: "top" as const,
};

// --- assemble ---------------------------------------------------------------
const nodes: Record<string, unknown> = {
  field: {
    ...base("field", constant({ x: W / 2, y: H / 2, z: 0 })),
    type: "rect" as const,
    size: constant({ width: W, height: H }),
    cornerRadius: constant(0),
    style: { fill: { color: constant(rgba(C.obsidian)), opacity: constant(1) } },
  },
  plate: plateGroup,
  ...cellNodes,
  title: titleNode,
  spec: specNode,
};

const composition = {
  id: "main", name: "banner",
  width: W, height: H, durationTicks: DURATION,
  nodes,
  rootNodeIds: ["field", "plate", "title", "spec"],
};

const document = withComputedRevision({
  version: ANIMATION_DOCUMENT_VERSION,
  id: "devtools-unpack-banner",
  revision: "",
  name: "devtools-unpack README banner",
  canvas: { width: W, height: H, pixelAspectRatio: 1, backgroundColor: rgba(C.obsidian) },
  timing: { ticksPerSecond: TPS, frameRate: { numerator: 30, denominator: 1 },
            durationTicks: DURATION, displayStartTick: 0 },
  assets: {
    display: { id: "display", type: "font", uri: `fonts/${F.extended.file}`,
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
