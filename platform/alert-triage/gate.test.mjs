// Run with: node --test platform/alert-triage/gate.test.mjs (no dependencies).
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const CONFIG = join(dirname(fileURLToPath(import.meta.url)), "agent-config.yaml");
const BLOCK = "\n  gate.mjs: |\n";
const RECORD =
  'triage-record fingerprint=fp-test alertname="TestAlert" verdict=NOISE confidence=high pod=triage-abc cause="scrape gap"';

function extractGate() {
  const text = readFileSync(CONFIG, "utf8");
  const start = text.indexOf(BLOCK);
  assert.notEqual(start, -1, "agent-config.yaml has no gate.mjs block scalar");
  const body = [];
  for (const line of text.slice(start + BLOCK.length).split("\n")) {
    if (line.trim() === "") {
      body.push("");
    } else if (line.startsWith("    ")) {
      body.push(line.slice(4));
    } else {
      break;
    }
  }
  return body.join("\n").trimEnd() + "\n";
}

function sandbox({ withKubectl }) {
  const dir = mkdtempSync(join(tmpdir(), "triage-gate."));
  writeFileSync(join(dir, "gate.mjs"), extractGate());
  const bin = join(dir, "bin");
  mkdirSync(bin);
  if (withKubectl) {
    writeFileSync(join(bin, "kubectl"), '#!/bin/sh\nprintf %s \'{"items": []}\'\n');
    chmodSync(join(bin, "kubectl"), 0o755);
  }
  return { dir, bin, digest: join(dir, "digest.md") };
}

async function lokiWith(lines) {
  const server = createServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        status: "success",
        data: { result: [{ values: lines.map((line) => [`${Date.now()}000000`, line]) }] },
      }),
    );
  });
  await new Promise((done) => server.listen(0, "127.0.0.1", done));
  return { server, url: `http://127.0.0.1:${server.address().port}` };
}

function runGate({ dir, bin, digest }, lokiUrl) {
  const options = {
    encoding: "utf8",
    timeout: 30000,
    env: {
      PATH: bin,
      HOSTNAME: "triage-test",
      LOKI_URL: lokiUrl,
      ALERT_FP: "fp-test",
      ALERT_NAME: "TestAlert",
      ALERT_JSON: JSON.stringify({ alerts: [{ fingerprint: "fp-test", labels: { alertname: "TestAlert" } }] }),
      TRIAGE_COOLDOWN: "2h",
      TRIAGE_MEMORY_WINDOW: "6h",
      TRIAGE_DIGEST: digest,
      TRIAGE_RECURRENCE: join(dir, "recurrence"),
    },
  };
  // Async: the Loki stub is an HTTP server in this process, so a sync spawn would deadlock.
  return new Promise((resolve) => {
    execFile(process.execPath, [join(dir, "gate.mjs")], options, (error, stdout, stderr) =>
      resolve({ status: error ? (error.code ?? -1) : 0, stdout, stderr }),
    );
  });
}

test("a prior NOISE verdict suppresses the run without writing a digest", async () => {
  const box = sandbox({ withKubectl: true });
  const loki = await lokiWith([RECORD]);
  const run = await runGate(box, loki.url);
  loki.server.close();

  assert.equal(run.status, 10, run.stderr);
  assert.match(run.stdout, /triage-skip fingerprint=fp-test .*prior_verdict=NOISE/);
  assert.equal(existsSync(box.digest), false);
});

test("a prior ACTIONABLE verdict re-runs with the earlier report attached", async () => {
  const box = sandbox({ withKubectl: true });
  const loki = await lokiWith([RECORD.replace("verdict=NOISE", "verdict=ACTIONABLE")]);
  const run = await runGate(box, loki.url);
  loki.server.close();

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /recurrence=1/);
  assert.match(readFileSync(box.digest, "utf8"), /## Previous analysis of this alert/);
});

test("a dead gate fails open: Loki and kubectl down still analyses", async () => {
  const box = sandbox({ withKubectl: false });
  const run = await runGate(box, "http://127.0.0.1:1");

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /gate=degraded/);
  assert.match(readFileSync(box.digest, "utf8"), /Cluster events[\s\S]*unavailable/);
});
