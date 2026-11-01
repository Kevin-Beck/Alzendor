// Checks the client's copy of the balance simulation (the Balance block in
// alzendor/web/index.html) against the Python copy's results in
// tests/balance_vectors.json, to within 1e-6. Run by tests/test_balance.py
// when node is on the path, or by hand:
//
//     node tools/check_vectors.mjs [index.html] [vectors.json]
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(process.argv[2] || join(root, "alzendor/web/index.html"), "utf8");
const vectors = JSON.parse(readFileSync(process.argv[3] || join(root, "tests/balance_vectors.json"), "utf8"));

const m = html.match(/\/\* BALANCE BEGIN \*\/([\s\S]*?)\/\* BALANCE END \*\//);
if (!m) { console.error("no BALANCE block in the page"); process.exit(2); }
const Balance = new Function(`"use strict";\n${m[1]}\nreturn Balance;`)();

const TOL = 1e-6;
const problems = [];

function compare(path, want, got) {
  if (problems.length > 20) return;
  if (typeof want === "number") {
    if (typeof got !== "number" || !(Math.abs(want - got) <= TOL)) problems.push(`${path}: want ${want}, got ${got}`);
  } else if (Array.isArray(want)) {
    if (!Array.isArray(got) || got.length !== want.length) { problems.push(`${path}: want ${want.length} items, got ${got && got.length}`); return; }
    want.forEach((w, i) => compare(`${path}[${i}]`, w, got[i]));
  } else if (want && typeof want === "object") {
    if (!got || typeof got !== "object") { problems.push(`${path}: want an object, got ${got}`); return; }
    const keys = new Set([...Object.keys(want), ...Object.keys(got)]);
    for (const k of keys) compare(`${path}.${k}`, want[k], got[k]);
  } else if (want !== got) {
    problems.push(`${path}: want ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
  }
}

vectors.runs.forEach((run, i) => {
  compare(`run ${i}`, run.expect, Balance.replay(run.script));
  // The server's snapshot, restored here mid-run, carries on exactly as the run did.
  const s = run.script;
  const dot = Balance.makeDot(Balance.forPlayer(Balance.rulesFrom(s.rules || {}), s.stats || {}), s.seed, s.pid, s.slots || {}, s.shield);
  Balance.restore(dot, run.expect.snap);
  let keys = 0;
  for (const [n, k] of s.keys) if (n <= s.snap_at) keys = k;
  for (let n = s.snap_at + 1; n <= s.steps; n++) {
    for (const [m, k] of s.keys) if (m === n) keys = k;
    Balance.step(dot, keys, s.acts.filter((a) => a[0] === n).map((a) => a.slice(1)), s.blows.filter((b) => b[0] === n).map((b) => b[1]));
  }
  compare(`run ${i} restored`, run.expect.states[run.expect.states.length - 1], Balance.state(dot));
});
if (problems.length) {
  console.error(problems.join("\n"));
  process.exit(1);
}
console.log(`ok: ${vectors.runs.length} runs match`);
