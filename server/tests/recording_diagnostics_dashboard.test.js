const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {test} = require("node:test");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "../templates/dashboard.html"), "utf8");
const source = html.slice(html.indexOf("  function isCurrentUser("), html.indexOf("  // ── Self check-ins"));
const now = Date.parse("2026-11-17T21:00:00Z");

function harness() {
  let clock = 0;
  let nextTimer = 0;
  const timers = new Map();
  const requests = [];
  const panel = {
    innerHTML: "",
    set textContent(text) { this.innerHTML = text; },
    querySelector() { return null; },
  };
  const context = vm.createContext({
    $: () => panel,
    location: {hash: "#/user/a"},
    state: {userId: "a"},
    esc: String,
    when: String,
    F: {full: {}},
    performance: {now: () => clock},
    Date: class extends Date { static now() { return now + clock; } },
    AbortController,
    setTimeout: (callback, delay) => {
      const id = ++nextTimer;
      timers.set(id, {callback, at: clock + delay});
      return id;
    },
    clearTimeout: id => timers.delete(id),
    api: (url, {signal}) => new Promise((resolve, reject) => requests.push({url, signal, resolve, reject})),
  });
  vm.runInContext(source, context);
  return {
    context, panel, requests,
    advance(ms) {
      const target = clock + ms;
      while (true) {
        const next = [...timers].filter(([, timer]) => timer.at <= target)
          .sort(([, a], [, b]) => a.at - b.at)[0];
        if (!next) break;
        const [id, {callback, at}] = next;
        timers.delete(id);
        clock = at;
        callback();
      }
      clock = target;
    },
  };
}

function report(build, ageMs = 0) {
  return {
    as_of: new Date(now).toISOString(),
    installations: [{
      installation_id: "installation",
      latest: {
        app_build: build,
        observed_at: new Date(now - ageMs).toISOString(),
        received_at: new Date(now).toISOString(),
      },
      stages: {sensor: "receiving", local: "recording", delivery: "up_to_date"},
      freshness: "fresh",
    }],
    recent_events: [],
  };
}

test("active dashboard expires stages before a pending refresh and clears them on failure", async () => {
  const {context, requests, panel, advance} = harness();
  const started = context.loadRecordingDiagnostics("a");
  requests[0].resolve(report("build-a", 179_000));
  await started;
  assert.match(panel.innerHTML, /Current/);
  assert.match(panel.innerHTML, /receiving/);

  advance(1_000);
  assert.match(panel.innerHTML, /Historical/);
  assert.doesNotMatch(panel.innerHTML, /receiving/);
  advance(30_000);
  assert.equal(requests.length, 2);
  requests[1].reject(new Error("refresh failed"));
  await new Promise(setImmediate);
  assert.match(panel.innerHTML, /could not be loaded/);
  assert.doesNotMatch(panel.innerHTML, /recording<\/td>/);

  advance(30_000);
  assert.equal(requests.length, 3);
  requests[2].resolve(report("recovered"));
  await new Promise(setImmediate);
  assert.match(panel.innerHTML, /recovered/);
});

test("only the latest same-user request can render or clear the active panel", async () => {
  const {context, requests, panel, advance} = harness();
  const first = context.loadRecordingDiagnostics("a");
  const second = context.loadRecordingDiagnostics("a");
  assert.ok(requests[0].signal.aborted);
  requests[1].resolve(report("newer-build"));
  await second;
  requests[0].resolve(report("old-build"));
  await first;
  assert.match(panel.innerHTML, /newer-build/);
  assert.doesNotMatch(panel.innerHTML, /old-build/);

  const obsolete = context.loadRecordingDiagnostics("a");
  context.resetRecordingDiagnostics("");
  assert.ok(requests[2].signal.aborted);
  context.location.hash = "#/user/b";
  context.state.userId = "b";
  requests[2].reject(new Error("obsolete error"));
  await obsolete;
  advance(120_000);
  assert.equal(panel.innerHTML, "");
  assert.equal(requests.length, 3);
});
