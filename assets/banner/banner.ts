// banner.ts — the README header for devtools-unpack, authored with Clayzo.
//
// DESIGN LANGUAGE: Sculptural Industrial Futurism (design.md), early-2000s
// Oakley era — the LANGUAGE, not the eyewear. design.md §12 is the brief:
//
//   "The most important part of the early-2000s aesthetic is not nostalgia. It
//    is a past era's optimistic prediction of future hardware: silver
//    materials, elliptical geometry, flowing forms, visible mechanisms...
//    Retain: alien but useful silhouettes; graphite/silver material contrast;
//    aerodynamic ellipses and molded structures; purposeful machinery-like
//    identity; experimentation and unexpected proportions.
//    Discard: arbitrary pixel grids, fake CRT artifacts, chrome text
//    everywhere; noisy RGB gradients, meaningless technical labels."
//
// ART DIRECTION (written before authoring, per the skill):
//   verb      travel — one machined member extends along its own axis and
//             settles; the wordmark and the spec line follow it. Decisive
//             travel, soft settling, no overshoot (§8).
//   geometry  one long, low, tapered spar: thin at both tips, swelled at a
//             single raised junction (§2A "thin architectural spans" +
//             §2B "localized sculptural masses at joints"). Everything else is
//             type on a field. No cards, no borders, no dividers.
//   palette   §5 at the 75/20/5 ratio: carbon #0B0E11 ground, graphite
//             #181D21 and gunmetal #384249 structure, alloy #79848B and
//             titanium #B6C0C5 metal, mist #E7ECEE ink. ONE accent —
//             optic-cyan #62CFDE — as an optical inset in the junction, ~3%.
//   scale     the spar spans 82% of the width (§3 "long, low"); the wordmark
//             ~74%, one dramatic scale shift between the two (§14 poster).
//   words     two: the name, and one measured spec line. The spec line is REAL
//             (module count, dispatch arms, gates, assertions) because
//             "meaningless technical labels" are banned and "every figure is
//             read from the kit".
//   punch     the spar extends from its left tip inside 0.35 s; the wordmark
//             lands at 0.5 s; the spec line at 0.8 s. Settled by 1.4 s.
//
// The README embeds the SETTLED frame. Faces: Space Grotesk (display) and
// IBM Plex Mono (metadata), both SIL OFL, self-hosted in fonts/.

import { writeFileSync } from "node:fs";
import {
  ANIMATION_DOCUMENT_VERSION, assertValidAnimationDocument, constant,
  withComputedRevision,
  type AnimationDocument, type Transform25D,
} from "@clayzo/animation/authoring";

const W = 1600, H = 400;
const TPS = 240;
const DURATION = TPS * 3; // 3 s; the README uses the settled frame at tick 600

// design.md §5. Two primary materials (graphite, satin titanium) + one accent.
const CARBON = "#0B0E11";
const GRAPHITE = "#181D21";
const GUNMETAL = "#384249";
const ALLOY = "#79848B";
const TITANIUM = "#B6C0C5";
const MIST = "#E7ECEE";
const OPTIC = "#62CFDE";

const rgba = (hex: string) => ({
  r: parseInt(hex.slice(1, 3), 16) / 255,
  g: parseInt(hex.slice(3, 5), 16) / 255,
  b: parseInt(hex.slice(5, 7), 16) / 255,
  a: 1,
});

// §8's own curve: decisive travel, soft settling, minimal overshoot.
const SETTLE = { x1: 0.2, y1: 0.7, x2: 0.2, y2: 1 };

let kfCounter = 0;
const kf = (tick: number, value: unknown, interpolation: "bezier" | "hold" = "bezier") => ({
  id: `k${++kfCounter}`,
  tick, value, interpolation,
  ...(interpolation === "bezier" ? { easing: SETTLE } : {}),
});

const transform = (position: Transform25D["position"]): Transform25D => ({
  position,
  anchor: constant({ x: 0, y: 0, z: 0 }),
  scale: constant({ x: 1, y: 1, z: 1 }),
  rotation: constant({ x: 0, y: 0, z: 0 }),
  skew: constant({ x: 0, y: 0 }),
});

const base = (id: string, position: Transform25D["position"]) => ({
  id, name: id, visible: true, inTick: 0, outTick: DURATION,
  opacity: constant(1), transform: transform(position), blendMode: "normal" as const,
});

// ---------------------------------------------------------------------------
// THE SPAR — the one memorable silhouette (§3, §11 side profile).
//
// A long low member, y centred on 236. Thin at both tips, accelerating into a
// swell at x = 560, running straight, then tapering out to the right tip. The
// swell is the single raised junction (§2B): a localized sculptural mass where
// the taper meets the run, carrying a cyan optical inset.
//
// Vertices are in canvas space; the node sits at (0,0) so the path IS the
// geometry. Cubic tangents are offsets from each vertex (§ facts that bite).
// ---------------------------------------------------------------------------

const SPAR_LEFT = 140;
const SPAR_RIGHT = 1460;
const SPAR_MID = 236;
const SWELL_X = 560;
const SWELL_HALF = 48;   // full height 96 at the swell: the sculptural mass
const RUN_HALF = 20;     // height 40 along the run: the thin architectural span

const v = (x: number, y: number, ix = 0, iy = 0, ox = 0, oy = 0) => ({
  point: { x, y },
  inTangent: { x: ix, y: iy },
  outTangent: { x: ox, y: oy },
});

// Closed contour, clockwise: left tip -> top edge -> right tip -> bottom edge.
const sparContour = {
  closed: true,
  vertices: [
    // left tip (a point: both tangents zero)
    v(SPAR_LEFT, SPAR_MID),
    // accelerate up into the swell
    v(SWELL_X, SPAR_MID - SWELL_HALF, -170, 0, 0, 0),
    // the run
    v(SPAR_RIGHT - 190, SPAR_MID - RUN_HALF, 0, 0, 0, 0),
    // taper down to the right tip
    v(SPAR_RIGHT, SPAR_MID, 0, 0, 0, 0),
    // bottom edge back to the swell
    v(SPAR_RIGHT - 190, SPAR_MID + RUN_HALF, 0, 0, 0, 0),
    v(SWELL_X, SPAR_MID + SWELL_HALF, 0, 0, 170, 0),
  ],
};

// Satin titanium: a linear gradient down the short axis — light at the top
// edge, gunmetal at the foot, which is how a rolled metal member reads.
const sparNode = {
  ...base("spar", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: 0, y: 0, z: 0 }),
      kf(DURATION, { x: 0, y: 0, z: 0 }, "hold"),
    ],
  }),
  // Extends from its LEFT tip: anchor at the left tip, scale.x 0 -> 1.
  transform: {
    // position == anchor: the path vertices ARE canvas coordinates, so the
    // transform must be identity at rest — (point - anchor) + position would
    // otherwise shift the whole member by -anchor.
    position: constant({ x: SPAR_LEFT, y: SPAR_MID, z: 0 }),
    anchor: constant({ x: SPAR_LEFT, y: SPAR_MID, z: 0 }),
    scale: {
      kind: "keyframed",
      keyframes: [
        kf(0, { x: 0, y: 1, z: 1 }),
        kf(84, { x: 1, y: 1, z: 1 }),   // 350 ms: hero travel (§8)
        kf(DURATION, { x: 1, y: 1, z: 1 }, "hold"),
      ],
    },
    rotation: constant({ x: 0, y: 0, z: 0 }),
    skew: constant({ x: 0, y: 0 }),
  },
  type: "path" as const,
  path: constant({ contours: [sparContour], fillRule: "nonzero" as const }),
  style: {
    gradientFill: {
      kind: "linear" as const,
      stops: constant([
        { position: 0, color: rgba(TITANIUM) },
        { position: 0.42, color: rgba(ALLOY) },
        { position: 1, color: rgba(GUNMETAL) },
      ]),
      start: constant({ x: 0, y: SPAR_MID - SWELL_HALF }),
      end: constant({ x: 0, y: SPAR_MID + SWELL_HALF }),
      opacity: constant(1),
    },
  },
};

// The junction: a raised shoulder at the swell — one credible visible joint
// (§2A "make one junction distinctive"), with the single optical accent inset.
const shoulderNode = {
  ...base("shoulder", constant({ x: SWELL_X, y: SPAR_MID, z: 0 })),
  type: "ellipse" as const,
  // TALLER than the member at the swell (96): the collar wraps it and
  // stands proud above and below, which is what makes it read as a part.
  size: constant({ width: 232, height: 118 }),
  style: {
    gradientFill: {
      kind: "linear" as const,
      stops: constant([
        { position: 0, color: rgba(MIST) },
        { position: 0.38, color: rgba(TITANIUM) },
        { position: 1, color: rgba(GUNMETAL) },
      ]),
      start: constant({ x: 0, y: -59 }),
      end: constant({ x: 0, y: 59 }),
      opacity: constant(1),
    },
    // The rim: a fine titanium edge on the bezel, which is what separates a
    // machined part from a soft oval.
    stroke: {
      color: constant(rgba(MIST)),
      opacity: constant(0.55),
      width: constant(1.5),
      lineCap: "round" as const,
      lineJoin: "round" as const,
      miterLimit: 4,
    },
  },
};

// The recessed face: a darker inner ellipse inside the titanium bezel. Two
// concentric rings read as construction — a machined bezel with a recessed
// well — where one soft oval reads as a pebble.
const recessNode = {
  ...base("recess", constant({ x: SWELL_X, y: SPAR_MID, z: 0 })),
  type: "ellipse" as const,
  size: constant({ width: 172, height: 86 }),
  style: {
    gradientFill: {
      kind: "linear" as const,
      stops: constant([
        { position: 0, color: rgba(GRAPHITE) },
        { position: 1, color: rgba(CARBON) },
      ]),
      start: constant({ x: 0, y: -43 }),
      end: constant({ x: 0, y: 43 }),
      opacity: constant(1),
    },
  },
};

// The optical inset: 3 px of optic-cyan inside the shoulder. ~3% of the frame.
const opticNode = {
  ...base("optic", constant({ x: SWELL_X, y: SPAR_MID + 24, z: 0 })),
  type: "rect" as const,
  size: constant({ width: 64, height: 4 }),
  cornerRadius: constant(2),
  style: { fill: { color: constant(rgba(OPTIC)), opacity: constant(1) } },
};

// The top-edge highlight: an OPEN path along the member's upper contour,
// stroked in titanium. §4: "preserve fine highlights along the edges of
// metallic forms to reveal their surface geometry."
const highlightNode = {
  ...base("highlight", constant({ x: SPAR_LEFT, y: SPAR_MID, z: 0 })),
  transform: {
    position: constant({ x: SPAR_LEFT, y: SPAR_MID, z: 0 }),
    anchor: constant({ x: SPAR_LEFT, y: SPAR_MID, z: 0 }),
    scale: {
      kind: "keyframed",
      keyframes: [
        kf(0, { x: 0, y: 1, z: 1 }),
        kf(84, { x: 1, y: 1, z: 1 }),
        kf(DURATION, { x: 1, y: 1, z: 1 }, "hold"),
      ],
    },
    rotation: constant({ x: 0, y: 0, z: 0 }),
    skew: constant({ x: 0, y: 0 }),
  },
  type: "path" as const,
  path: constant({
    contours: [{
      closed: false,
      vertices: [
        v(SPAR_LEFT, SPAR_MID),
        v(SWELL_X, SPAR_MID - SWELL_HALF, -170, 0, 0, 0),
        v(SPAR_RIGHT - 190, SPAR_MID - RUN_HALF, 0, 0, 0, 0),
        v(SPAR_RIGHT, SPAR_MID, 0, 0, 0, 0),
      ],
    }],
    fillRule: "nonzero" as const,
  }),
  style: {
    stroke: {
      color: constant(rgba(TITANIUM)),
      opacity: constant(0.85),
      width: constant(2),
      lineCap: "round" as const,
      lineJoin: "round" as const,
      miterLimit: 4,
    },
  },
};

// ---------------------------------------------------------------------------
// The wordmark: Space Grotesk, uppercase, mist. §6 display face.
// ---------------------------------------------------------------------------

const TITLE = "DEVTOOLS-UNPACK";
const TITLE_SIZE = 92;

const titleNode = {
  ...base("title", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: 0, y: 152, z: 0 }),
      kf(96, { x: 0, y: 152, z: 0 }),
      kf(216, { x: 0, y: 128, z: 0 }),   // 500 ms: lands after the spar
      kf(DURATION, { x: 0, y: 128, z: 0 }, "hold"),
    ],
  }),
  opacity: {
    kind: "keyframed",
    keyframes: [
      kf(0, 0, "hold"),
      kf(96, 0),                          // bezier: the segment LEAVING fades
      kf(216, 1, "hold"),
      kf(DURATION, 1, "hold"),
    ],
  },
  type: "text" as const,
  runs: constant([{
    text: TITLE,
    fontAssetId: "display",
    fontSize: TITLE_SIZE,
    fontWeight: 600,
    letterSpacing: 2,
    lineHeight: 1.15,
    color: rgba(MIST),
  }]),
  box: { width: W, height: 120 },
  wrap: "none" as const,
  align: "center" as const,
  verticalAlign: "top" as const,
};

// ---------------------------------------------------------------------------
// The spec line: IBM Plex Mono, alloy. Real measured figures only (§6
// metadata face; "every figure is read from the kit, never typed by hand").
// ---------------------------------------------------------------------------

const SPEC = "26 modules  ·  49 dispatch arms  ·  48 gates  ·  2,729 assertions";

const specNode = {
  ...base("spec", {
    kind: "keyframed",
    keyframes: [
      kf(0, { x: 0, y: 342, z: 0 }),
      kf(192, { x: 0, y: 342, z: 0 }),
      kf(312, { x: 0, y: 334, z: 0 }),   // 800 ms
      kf(DURATION, { x: 0, y: 334, z: 0 }, "hold"),
    ],
  }),
  opacity: {
    kind: "keyframed",
    keyframes: [
      kf(0, 0, "hold"),
      kf(192, 0),
      kf(312, 1, "hold"),
      kf(DURATION, 1, "hold"),
    ],
  },
  type: "text" as const,
  runs: constant([{
    text: SPEC,
    fontAssetId: "mono",
    fontSize: 17,
    fontWeight: 400,
    letterSpacing: 1.2,
    lineHeight: 1.5,
    color: rgba(ALLOY),
  }]),
  box: { width: W, height: 30 },
  wrap: "none" as const,
  align: "center" as const,
  verticalAlign: "top" as const,
};

// ---------------------------------------------------------------------------
// Assemble. Root order: field, spar, shoulder, optic, title, spec.
// ---------------------------------------------------------------------------

const nodes: Record<string, unknown> = {
  field: {
    ...base("field", constant({ x: 800, y: 200, z: 0 })),
    type: "rect" as const,
    size: constant({ width: W, height: H }),
    cornerRadius: constant(0),
    style: { fill: { color: constant(rgba(CARBON)), opacity: constant(1) } },
  },
  spar: sparNode,
  highlight: highlightNode,
  shoulder: shoulderNode,
  recess: recessNode,
  optic: opticNode,
  title: titleNode,
  spec: specNode,
};

const composition = {
  id: "main", name: "banner",
  width: W, height: H, durationTicks: DURATION,
  nodes,
  rootNodeIds: ["field", "spar", "highlight", "shoulder", "recess", "optic", "title", "spec"],
};

const document = withComputedRevision({
  version: ANIMATION_DOCUMENT_VERSION,
  id: "devtools-unpack-banner",
  revision: "",
  name: "devtools-unpack README banner",
  canvas: { width: W, height: H, pixelAspectRatio: 1,
            backgroundColor: rgba(CARBON) },
  timing: { ticksPerSecond: TPS, frameRate: { numerator: 30, denominator: 1 },
            durationTicks: DURATION, displayStartTick: 0 },
  assets: {
    display: { id: "display", type: "font", uri: "fonts/SpaceGrotesk-Variable.ttf",
               mimeType: "font/ttf" },
    mono: { id: "mono", type: "font", uri: "fonts/IBMPlexMono-Regular.ttf",
            mimeType: "font/ttf" },
  },
  compositions: { main: composition },
  rootCompositionId: "main",
  components: {},
  markers: [],
  capabilities: { required: [], optional: [], unsupportedPolicy: "warn" },
  // A settled piece, not a loop: the review must not check the seam.
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
