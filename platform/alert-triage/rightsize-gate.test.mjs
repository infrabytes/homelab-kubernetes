// Run with: node --test platform/alert-triage/rightsize-gate.test.mjs (no dependencies).
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const CONFIG = join(dirname(fileURLToPath(import.meta.url)), "memory-rightsize-agent-config.yaml");
const BLOCK = "\n  gate.mjs: |\n";

const POD = {
  metadata: {
    name: "web-abc-xyz",
    annotations: { "argocd.argoproj.io/tracking-id": "web:apps/Deployment:web/web" },
    ownerReferences: [{ kind: "ReplicaSet", name: "web-abc" }],
  },
  status: {
    containerStatuses: [
      {
        name: "web",
        restartCount: 2,
        image: "nginx:1.29.0",
        lastState: { terminated: { reason: "OOMKilled", finishedAt: "2026-10-21T10:00:00Z" } },
      },
    ],
  },
};
const REPLICASET = { metadata: { name: "web-abc", ownerReferences: [{ kind: "Deployment", name: "web" }] } };
const DEPLOYMENT = {
  metadata: { name: "web" },
  spec: {
    template: {
      spec: {
        containers: [
          {
            name: "web",
            resources: { requests: { cpu: "100m", memory: "128Mi" }, limits: { memory: "256Mi" } },
          },
        ],
      },
    },
  },
};
const APPLICATION = { spec: { source: { path: "apps/web" } }, status: { sync: { revision: "deadbeef" } } };

function extractGate() {
  const text = readFileSync(CONFIG, "utf8");
  const start = text.indexOf(BLOCK);
  assert.notEqual(start, -1, "memory-rightsize-agent-config.yaml has no gate.mjs block scalar");
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

// One kubectl stub, keyed on the subcommand the gate runs.
function sandbox({ withKubectl = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "rightsize-gate."));
  writeFileSync(join(dir, "gate.mjs"), extractGate());
  const bin = join(dir, "bin");
  mkdirSync(bin);
  if (withKubectl) {
    writeFileSync(
      join(bin, "kubectl"),
      [
        "#!/bin/sh",
        'case "$*" in',
        `*"get pod"*) printf '%s\\n' '${JSON.stringify(POD)}' ;;`,
        `*"get replicaset"*) printf '%s\\n' '${JSON.stringify(REPLICASET)}' ;;`,
        `*"get deployment"*) printf '%s\\n' '${JSON.stringify(DEPLOYMENT)}' ;;`,
        `*"get application"*) printf '%s\\n' '${JSON.stringify(APPLICATION)}' ;;`,
        "*) echo '{}' ;;",
        "esac",
        "",
      ].join("\n"),
    );
    chmodSync(join(bin, "kubectl"), 0o755);
  }
  return { dir, bin, context: join(dir, "context.md"), key: join(dir, "key") };
}

function serve(payload) {
  const server = createServer((request, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(payload));
  });
  return new Promise((done) =>
    server.listen(0, "127.0.0.1", () => done({ server, url: `http://127.0.0.1:${server.address().port}` })),
  );
}

function lokiWith(lines) {
  return serve({ status: "success", data: { result: [{ values: lines.map((line) => [`${Date.now()}000000`, line]) }] } });
}

function runGate(box, { lokiUrl, apiUrl }) {
  const options = {
    encoding: "utf8",
    timeout: 30000,
    env: {
      PATH: box.bin,
      GITHUB_REPO: "acme/repo",
      GITHUB_TOKEN: "test-token",
      GITHUB_API: apiUrl,
      LOKI_URL: lokiUrl,
      ALERT_NS: "web",
      ALERT_POD: "web-abc-xyz",
      ALERT_CONTAINER: "web",
      RIGHTSIZE_COOLDOWN: "7d",
      RIGHTSIZE_CONTEXT: box.context,
      RIGHTSIZE_KEY: box.key,
    },
  };
  // Async: the stubs are HTTP servers in this process, so a sync spawn would deadlock.
  return new Promise((resolve) => {
    execFile(process.execPath, [join(box.dir, "gate.mjs")], options, (error, stdout, stderr) =>
      resolve({ status: error ? (error.code ?? -1) : 0, stdout, stderr }),
    );
  });
}

const RECORD = 'rightsize-record workload=web/Deployment/web verdict=PR branch=rightsize/web-web-20261020 pr=https://x pod=web-abc-xyz cause="x"';

test("resolves pod -> workload, names the branch and writes the context digest", async () => {
  const box = sandbox();
  const loki = await lokiWith([]);
  const api = await serve([]);
  const run = await runGate(box, { lokiUrl: loki.url, apiUrl: api.url });
  loki.server.close();
  api.server.close();

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /rightsize-event workload=web\/Deployment\/web container=web/);
  assert.match(readFileSync(box.key, "utf8"), /^WORKLOAD=web\/Deployment\/web\nBRANCH=rightsize\/web-web-\d{8}\n$/);
  const digest = readFileSync(box.context, "utf8");
  assert.match(digest, /live resources: requests cpu 100m memory 128Mi, limits cpu unset memory 256Mi/);
  assert.match(digest, /source path: apps\/web/);
  assert.match(digest, /last termination OOMKilled/);
});

test("a record inside the cooldown suppresses the run and writes no key", async () => {
  const box = sandbox();
  const loki = await lokiWith([RECORD]);
  const api = await serve([]);
  const run = await runGate(box, { lokiUrl: loki.url, apiUrl: api.url });
  loki.server.close();
  api.server.close();

  assert.equal(run.status, 10, run.stderr);
  assert.match(run.stdout, /rightsize-skip workload=web\/Deployment\/web reason=cooldown/);
  assert.equal(existsSync(box.key), false);
});

test("an open pull request for the workload suppresses the run", async () => {
  const box = sandbox();
  const loki = await lokiWith([]);
  const api = await serve([
    { head: { ref: "rightsize/web-web-20261020" }, html_url: "https://github.com/acme/repo/pull/7" },
  ]);
  const run = await runGate(box, { lokiUrl: loki.url, apiUrl: api.url });
  loki.server.close();
  api.server.close();

  assert.equal(run.status, 10, run.stderr);
  assert.match(run.stdout, /reason=open-pr pr=https:\/\/github.com\/acme\/repo\/pull\/7/);
  assert.equal(existsSync(box.key), false);
});

test("an unresolvable pod fails loudly instead of guessing a workload", async () => {
  const box = sandbox({ withKubectl: false });
  const run = await runGate(box, { lokiUrl: "http://127.0.0.1:1", apiUrl: "http://127.0.0.1:1" });

  assert.equal(run.status, 1);
  assert.match(run.stderr, /rightsize-failed: cannot read pod web\/web-abc-xyz/);
});
