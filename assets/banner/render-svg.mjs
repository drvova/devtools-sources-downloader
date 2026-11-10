// render-svg.mjs — the vector twin of banner.png.
//
// Reads banner.json (the Clayzo document: one source of geometry and colour)
// and writes ../banner.svg. The plate is a CELL FIELD, so the SVG is one shape
// per cell — rects, diamonds (a rect turned 45 degrees) and circles — and the
// type is outlined glyph paths, so the file carries no font dependency and
// renders identically everywhere, GitHub's sanitiser included.
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

body.push(`<rect x="0" y="0" width="${W}" height="${H}" fill="${fillOf(nodes.field)}"/>`);

// Every cell in the plate, in document order (the group's children array).
const plate = nodes.plate;
if (!plate || plate.type !== "group") throw new Error("no plate group in the document");
const cells = plate.children.map((id) => nodes[id]);

for (const cell of cells) {
  const fill = fillOf(cell);
  const { x, y } = settled(cell.transform.position);
  const rotation = settled(cell.transform.rotation).z;

  if (cell.type === "ellipse") {
    const { width, height } = settled(cell.size);
    body.push(`<circle cx="${x}" cy="${y}" r="${width / 2}" fill="${fill}"/>`);
    continue;
  }
  if (cell.type !== "rect") throw new Error(`${cell.id}: unexpected type ${cell.type}`);

  const { width, height } = settled(cell.size);
  const radius = settled(cell.cornerRadius);
  const rx = radius > 0 ? ` rx="${radius}"` : "";
  const transform = rotation !== 0 ? ` transform="rotate(${rotation} ${x} ${y})"` : "";
  body.push(
    `<rect x="${x - width / 2}" y="${y - height / 2}" width="${width}" height="${height}"${rx}${transform} fill="${fill}"/>`,
  );
}

// The wordmark: Michroma, centred on the canvas, baseline at the node's y.
const title = nodes.title;
const titleRun = settled(title.runs)[0];
const titlePath = textPath(FONTS.display, titleRun.text, titleRun.fontSize, titleRun.letterSpacing);
body.push(
  `<g transform="translate(${W / 2 - titlePath.width / 2} ${settled(title.transform.position).y})"><path d="${titlePath.d}" fill="${hex(titleRun.color)}"/></g>`,
);

// The spec line: IBM Plex Mono, centred, baseline at the node's y.
const spec = nodes.spec;
const specRun = settled(spec.runs)[0];
const specPath = textPath(FONTS.mono, specRun.text, specRun.fontSize, specRun.letterSpacing);
body.push(
  `<g transform="translate(${W / 2 - specPath.width / 2} ${settled(spec.transform.position).y})"><path d="${specPath.d}" fill="${hex(specRun.color)}"/></g>`,
);

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="devtools-unpack — a printed plate: an elliptical aperture built from cells, bone squares outside, gunmetal diamonds, graphite circles and one ember slit, on obsidian.">
<title>devtools-unpack</title>
${body.join("\n")}
</svg>
`;

writeFileSync("../banner.svg", svg);
console.log("banner.svg written,", cells.length, "cells,", svg.length, "bytes");
