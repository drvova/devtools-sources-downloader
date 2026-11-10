// render-svg.mjs — the vector twin of banner.png.
//
// Reads banner.json (the Clayzo document: one source of geometry and colour)
// and writes ../banner.svg: the same plate, with
//   - the Bayer screen as <pattern> fills, so the dither is real vector cells;
//   - the type as outlined glyph paths, so the file carries no font dependency
//     and renders identically everywhere, including GitHub's SVG sanitiser.
//
// The ring densities are MEASURED from the PNG render, not guessed: sampling
// probe.png over each ring gives outer 0.99, middle 0.20, core 0.04 lit.
//
// Run from assets/banner/:  node render-svg.mjs
// Needs opentype.js:        npm i opentype.js

import { readFileSync, writeFileSync } from "node:fs";
import opentype from "opentype.js";

const doc = JSON.parse(readFileSync("banner.json", "utf8"));
const comp = doc.compositions.main;
const nodes = comp.nodes;

// --- colour -----------------------------------------------------------------
function hex(color) {
  const channel = (v) => Math.round(v * 255).toString(16).padStart(2, "0");
  return `#${channel(color.r)}${channel(color.g)}${channel(color.b)}`;
}

// An animatable's settled value: the constant, or the last keyframe (the
// document's final state, which is what the SVG shows).
function settled(animatable) {
  if (animatable.kind === "constant") return animatable.value;
  const frames = animatable.keyframes;
  return frames[frames.length - 1].value;
}

// A node's fill colour is `constant({ r, g, b, a })` in the document.
function fillOf(node) {
  const fill = node.style?.fill;
  if (!fill) throw new Error(`${node.id}: no fill`);
  const value = fill.color.value;
  if (!value || typeof value !== "object") throw new Error(`${node.id}: no colour value`);
  return hex(value);
}

// --- the Bayer screen -------------------------------------------------------
// 4x4 ordered matrix; a cell is lit when its threshold is below the density.
const BAYER = [
  [0, 8, 2, 10],
  [12, 4, 14, 6],
  [3, 11, 1, 9],
  [15, 7, 13, 5],
];

// Each tile carries an OPAQUE ground: in the render the dither replaces the
// surface, so a transparent tile would let the ring beneath show through its
// unlit cells and the rings would vanish into one texture.
function patternDef(id, color, ground, density, cell = 2) {
  const lit = Math.round(density * 16);
  const cells = [];
  for (let y = 0; y < 4; y++) {
    for (let x = 0; x < 4; x++) {
      if (BAYER[y][x] < lit) {
        cells.push(`<rect x="${x * cell}" y="${y * cell}" width="${cell}" height="${cell}" fill="${color}"/>`);
      }
    }
  }
  return `<pattern id="${id}" width="${4 * cell}" height="${4 * cell}" patternUnits="userSpaceOnUse"><rect width="${4 * cell}" height="${4 * cell}" fill="${ground}"/>${cells.join("")}</pattern>`;
}

// Densities measured from probe.png (see the header).
const DENSITY = { "plate-outer": 0.94, "plate-ring": 0.20, "plate-core": 0.04 };

// --- type as paths ----------------------------------------------------------
// opentype.parse takes the bytes; loadSync is deprecated in this version and
// returns a stub with no stringToGlyphs.
function loadFont(path) {
  const bytes = readFileSync(path);
  return opentype.parse(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
}

const FONTS = {
  display: loadFont("fonts/Michroma-Regular.ttf"),
  mono: loadFont("fonts/IBMPlexMono-Regular.ttf"),
};

// opentype has no tracking, so lay the glyphs out by hand and return the run's
// width so it can be centred.
// charToGlyph, not stringToGlyphs: Michroma carries a GSUB chaining-contextual
// substitution that opentype.js cannot parse, and these runs need no ligatures.
function textPath(font, text, size, tracking) {
  const scale = size / font.unitsPerEm;
  const parts = [];
  let x = 0;
  for (const ch of text) {
    const glyph = font.charToGlyph(ch);
    parts.push(glyph.getPath(x, 0, size).toPathData(2));
    x += glyph.advanceWidth * scale + tracking;
  }
  return { d: parts.join(" "), width: x - tracking };
}

// --- emit -------------------------------------------------------------------
const W = comp.width;
const H = comp.height;
const body = [];

const field = nodes.field;
body.push(
  `<rect x="0" y="0" width="${W}" height="${H}" fill="${fillOf(field)}"/>`,
);

const patterns = [];
const ground = fillOf(field);
for (const id of ["plate-outer", "plate-ring", "plate-core"]) {
  const node = nodes[id];
  const color = fillOf(node);
  const density = DENSITY[id];
  patterns.push(patternDef(`pat-${id}`, color, ground, density));
  const rx = settled(node.size).width / 2;
  const ry = settled(node.size).height / 2;
  const cx = settled(node.transform.position).x;
  const cy = settled(node.transform.position).y;
  body.push(`<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="url(#pat-${id})"/>`);
}

const slit = nodes["plate-slit"];
const slitFill = fillOf(slit);
const slitW = settled(slit.size).width;
const slitH = settled(slit.size).height;
const slitX = settled(slit.transform.position).x - slitW / 2;
const slitY = settled(slit.transform.position).y - slitH / 2;
body.push(
  `<rect x="${slitX}" y="${slitY}" width="${slitW}" height="${slitH}" rx="${slitH / 2}" fill="${slitFill}"/>`,
);

// The wordmark: Michroma, centred on the canvas, baseline at the node's y.
const title = nodes.title;
const titleRun = settled(title.runs)[0];
const titlePath = textPath(
  FONTS.display,
  titleRun.text,
  titleRun.fontSize,
  titleRun.letterSpacing,
);
body.push(
  `<g transform="translate(${W / 2 - titlePath.width / 2} ${settled(title.transform.position).y})"><path d="${titlePath.d}" fill="${hex(titleRun.color)}"/></g>`,
);

// The spec line: IBM Plex Mono, centred, baseline at the node's y.
const spec = nodes.spec;
const specRun = settled(spec.runs)[0];
const specPath = textPath(
  FONTS.mono,
  specRun.text,
  specRun.fontSize,
  specRun.letterSpacing,
);
body.push(
  `<g transform="translate(${W / 2 - specPath.width / 2} ${settled(spec.transform.position).y})"><path d="${specPath.d}" fill="${hex(specRun.color)}"/></g>`,
);

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="devtools-unpack — a printed plate: an elliptical aperture rendered in Bayer dither cells, bone on obsidian, with one ember optical slit.">
<title>devtools-unpack</title>
<defs>
${patterns.join("\n")}
</defs>
${body.join("\n")}
</svg>
`;

writeFileSync("../banner.svg", svg);
console.log("banner.svg written,", svg.length, "bytes");
