// Runs the tests in the browser. window.fetch for /api/... goes to Python through the component, so
// the React build runs with no change. __startReact, defined just above this file, holds that build.
const BATCH_DELAY_MS = 15;
const NO_ANSWER_MS = 120000;
const QUIET_MS = 3000;
const PAGE_LIMIT_MS = 180000;

function makeBridge() {
  const b = {
    queue: [], pending: new Map(), inflight: null, nextId: 1, nextBatch: 1, timer: null, send: null,
    requests: 0, batches: 0, bytes: 0, serverMs: 0, slowest: null, lastActivity: Date.now(),
    errors: [], results: [], checks: "", scriptRuns: 0, fragmentRuns: 0, started: false,
  };

  b.report = () => {
    const box = document.getElementById("sis-report");
    if (!box) return;
    box.value = ["--- python ---", b.checks, "--- browser ---", ...b.results,
      `script runs ${b.scriptRuns}, fragment runs ${b.fragmentRuns}`,
      "--- errors ---", ...(b.errors.length ? b.errors.slice(0, 30) : ["none"])].join("\n");
  };
  b.say = (line) => { b.results.push(line); b.report(); };

  b.flush = () => {
    b.timer = null;
    if (b.inflight !== null || !b.queue.length || !b.send) return;
    const id = b.nextBatch++;
    const requests = b.queue.splice(0);
    b.inflight = id;
    b.batches += 1;
    b.send("batch", { id, requests });
    setTimeout(() => {
      if (b.inflight !== id) return;
      b.errors.push(`batch ${id}: no answer in ${NO_ANSWER_MS / 1000} s`);
      requests.forEach((r) => b.finish(r.id, new Error("no answer from the bridge")));
      b.inflight = null;
      b.schedule();
      b.report();
    }, NO_ANSWER_MS);
  };
  b.schedule = () => { if (!b.timer) b.timer = setTimeout(b.flush, BATCH_DELAY_MS); };

  b.finish = (id, value) => {
    const p = b.pending.get(id);
    if (!p) return;
    b.pending.delete(id);
    b.lastActivity = Date.now();
    if (value instanceof Error) p.reject(value); else p.resolve(value);
  };

  b.receive = (out) => {
    if (!out || out.batch_id !== b.inflight) return;
    b.inflight = null;
    for (const r of out.responses) {
      b.bytes += (r.body || "").length;
      b.serverMs += r.server_ms || 0;
      if (r.status >= 500) b.errors.push(`HTTP ${r.status} from the API on request ${r.id}`);
      b.finish(r.id, new Response(r.status === 204 ? null : r.body, { status: r.status, headers: r.headers }));
    }
    b.schedule();
  };

  const realFetch = window.fetch.bind(window);
  window.fetch = (input, init = {}) => {
    if (typeof input !== "string" || !input.startsWith("/api/")) return realFetch(input, init);
    const method = (init.method || "GET").toUpperCase();
    // The refresh needs a login and a local export, neither of which exists in this test.
    if (method === "POST" && input.startsWith("/api/refresh")) {
      return Promise.resolve(new Response('{"detail":"Refresh is off in this test."}', {
        status: 409, headers: { "content-type": "application/json" } }));
    }
    const id = b.nextId++;
    b.requests += 1;
    b.lastActivity = Date.now();
    return new Promise((resolve, reject) => {
      b.pending.set(id, { resolve, reject });
      b.queue.push({ id, method, path: input, body: init.body ?? null, headers: init.headers ?? null });
      b.schedule();
    });
  };

  window.addEventListener("error", (e) => { b.errors.push(`script error: ${e.message}`); b.report(); });
  window.addEventListener("unhandledrejection", (e) => { b.errors.push(`unhandled: ${e.reason}`); b.report(); });
  document.addEventListener("securitypolicyviolation", (e) => {
    b.errors.push(`blocked by CSP: ${e.violatedDirective} ${e.blockedURI}`);
    b.report();
  });
  return b;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (xs) => [...xs].sort((a, c) => a - c)[Math.floor(xs.length / 2)];

// Waits for the page to stop asking for data, and reports what it took.
async function timePage(b, label, change) {
  const start = Date.now();
  const before = { requests: b.requests, batches: b.batches, bytes: b.bytes, serverMs: b.serverMs };
  change();
  await sleep(500);
  while (Date.now() - start < PAGE_LIMIT_MS
         && (b.pending.size || b.queue.length || Date.now() - b.lastActivity < QUIET_MS)) await sleep(200);
  const secs = (Math.max(b.lastActivity, start) - start) / 1000;
  const cut = Date.now() - start >= PAGE_LIMIT_MS ? ", STOPPED AT THE TIME LIMIT" : "";
  b.say(`${label}: ${b.requests - before.requests} requests in ${b.batches - before.batches} batches, `
    + `${((b.bytes - before.bytes) / 1048576).toFixed(1)} MB, ${secs.toFixed(1)} s `
    + `(API time ${((b.serverMs - before.serverMs) / 1000).toFixed(1)} s)${cut}`);
}

async function runTests(b) {
  b.say("ok      component script ran");
  try {
    localStorage.setItem("sis-test", "1");
    b.say(`ok      localStorage read back ${localStorage.getItem("sis-test")}`);
  } catch (e) { b.say(`FAILED  localStorage: ${e.name}`); }

  try {
    const singles = [];
    for (let i = 0; i < 5; i++) {
      const t = performance.now();
      await (await fetch("/api/status")).text();
      singles.push(performance.now() - t);
    }
    b.say(`one request, 5 in a row: median ${median(singles).toFixed(0)} ms, worst ${Math.max(...singles).toFixed(0)} ms`);

    const t = performance.now();
    const batchesBefore = b.batches;
    await Promise.all(Array.from({ length: 20 }, () => fetch("/api/status").then((r) => r.text())));
    b.say(`burst of 20 at once: ${(performance.now() - t).toFixed(0)} ms in ${b.batches - batchesBefore} batches`);
  } catch (e) { b.say(`FAILED  bridge: ${e.message}`); }

  await timePage(b, "first page", () => {
    try {
      window.APP_BRAND = "Audit test";
      __startReact();
    } catch (e) { b.say(`FAILED  React start: ${e.message}`); }
  });
  const root = document.getElementById("audit-root");
  const drawn = !!root && !root.querySelector(".loading-note") && root.innerText.trim().length > 200;
  b.say(`${drawn ? "ok     " : "FAILED "} React page drew: ${root ? root.innerText.trim().length : 0} characters`);

  // A tab every role has, so the link test does not depend on the role.
  const pageBefore = root ? root.innerText : "";
  await timePage(b, "go to Warehouses", () => { location.hash = "#tab=warehouses"; });
  const linkKept = location.hash.includes("tab=warehouses");
  b.say(`${linkKept ? "ok     " : "FAILED "} page link in the address: ${location.hash}`);
  const changed = !!root && root.innerText !== pageBefore;
  b.say(`${changed ? "ok     " : "FAILED "} the page changed after the link`);
  b.say("DONE");
}

export default function (component) {
  const { data, setTriggerValue } = component;
  const b = window.__sisBridge || (window.__sisBridge = makeBridge());
  b.send = setTriggerValue;
  b.checks = data.checks || b.checks;
  b.scriptRuns = data.script_runs;
  b.fragmentRuns = data.fragment_runs;
  b.receive(data.out);
  b.schedule();
  if (!b.started) {
    b.started = true;
    runTests(b);
  }
  b.report();
}
