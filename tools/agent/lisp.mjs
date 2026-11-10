#!/usr/bin/env bun
// lisp.mjs - agent-facing evaluator for the project's persistent SBCL service.
//
//   bun tools/agent/lisp.mjs --form '(+ 1 2)'
//   bun tools/agent/lisp.mjs --file form.lisp        (one form, read from the file)
//   bun tools/agent/lisp.mjs --load tools/cl/run.lisp ((load "tools/cl/run.lisp"))
//   bun tools/agent/lisp.mjs --status
//   bun tools/agent/lisp.mjs --stop
//   printf '%s' '(+ 1 2)' | bun tools/agent/lisp.mjs
//
// Output: the Lisp's captured stdout followed by "=> printed-values".
// Exit codes: 0 ok, 1 Lisp error, 2 server/transport failure.
//
// Everything is resolved from this file, so the CLI works from any cwd:
//   ROOT   = two levels up (the checkout)
//   SERVER = tools/agent/lisp-server.lisp
//   SETUP  = %USERPROFILE%/quicklisp/setup.lisp (override: QUICKLISP_SETUP)
//   LOG    = <root>/.cache/lisp-server.log

import { spawn } from "node:child_process";
import { mkdirSync, openSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..", "..");
const SERVER = join(HERE, "lisp-server.lisp");
const SETUP =
  process.env.QUICKLISP_SETUP ||
  join(process.env.USERPROFILE || homedir(), "quicklisp", "setup.lisp");
const LOG = join(ROOT, ".cache", "lisp-server.log");
const PORT = Number(process.env.LISP_SERVER_PORT || 47311);
const SBCL = process.env.SBCL || "sbcl";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function request(line, timeout = 300000) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: "127.0.0.1", port: PORT });
    let data = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error("server timeout"));
    }, timeout);
    timer.unref?.();
    sock.setEncoding("utf8");
    sock.on("connect", () => sock.write(`${line}\n`));
    sock.on("data", (chunk) => {
      data += chunk;
      const nl = data.indexOf("\n");
      if (nl >= 0) {
        clearTimeout(timer);
        sock.destroy();
        resolve(data.slice(0, nl));
      }
    });
    sock.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    sock.on("close", () => {
      clearTimeout(timer);
      if (!data) reject(new Error("connection closed"));
    });
  });
}

async function alive() {
  try {
    return (await request("PING", 1000)) === "PONG";
  } catch {
    return false;
  }
}

async function ensureServer() {
  if (await alive()) return;
  mkdirSync(dirname(LOG), { recursive: true });
  const fd = openSync(LOG, "a");
  spawn(
    SBCL,
    ["--noinform", "--load", SETUP, "--load", SERVER, "--eval", "(agent.server:main)"],
    {
      cwd: ROOT,
      env: { ...process.env, LISP_PROJECT_ROOT: ROOT },
      detached: true,
      stdio: ["ignore", fd, fd],
    },
  ).unref();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    await sleep(250);
    if (await alive()) return;
  }
  throw new Error(`Lisp server did not start; see ${LOG}`);
}

function hexEncode(text) {
  return Buffer.from(text, "utf8").toString("hex");
}

function hexDecode(hex) {
  return Buffer.from(hex, "hex").toString("utf8");
}

async function evalForm(form) {
  const reply = await request(`EVAL ${hexEncode(form)}`);
  const space = reply.indexOf(" ");
  const status = space < 0 ? reply : reply.slice(0, space);
  const payload = space < 0 ? "" : hexDecode(reply.slice(space + 1));
  if (status === "OK") {
    process.stdout.write(payload);
    return 0;
  }
  process.stderr.write(payload || `${status}\n`);
  return 1;
}

function lispString(text) {
  return JSON.stringify(text.replaceAll("\\", "/"));
}

function usage() {
  process.stderr.write(
    "usage: bun tools/agent/lisp.mjs --form FORM | --file PATH | --load PATH | --status | --stop\n" +
      "       form on stdin when no option is given\n",
  );
  return 2;
}

async function main() {
  const args = process.argv.slice(2);
  const value = (flag) => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1] : undefined;
  };

  if (args.includes("--stop")) {
    if (!(await alive())) {
      process.stdout.write("server: not running\n");
      return 0;
    }
    await request("QUIT", 5000).catch(() => {});
    for (let i = 0; i < 40; i++) {
      await sleep(250);
      if (!(await alive())) break;
    }
    process.stdout.write("server: stopped\n");
    return 0;
  }

  if (args.includes("--status")) {
    process.stdout.write((await alive()) ? "server: up\n" : "server: down\n");
    return 0;
  }

  let form;
  if (args.includes("--form")) form = value("--form");
  else if (args.includes("--file")) form = readFileSync(value("--file"), "utf8");
  else if (args.includes("--load")) form = `(load ${lispString(value("--load"))})`;
  else if (!process.stdin.isTTY) form = readFileSync(0, "utf8");
  else return usage();

  if (form === undefined) return usage();

  await ensureServer();
  return evalForm(form);
}

try {
  process.exitCode = await main();
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 2;
}
