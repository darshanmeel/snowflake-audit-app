// Runs the React build inside a Streamlit component. Its /api/... calls go to Python through the
// component, because the browser cannot reach a port on Snowflake's side. __startReact, defined just
// above this file, holds the build.
const BATCH_DELAY_MS = 15;
const NO_ANSWER_MS = 300000;
const NO_BODY = new Set([101, 204, 205, 304]);

function makeBridge() {
  const b = {
    queue: [], pending: new Map(), inflight: null, nextId: 1, nextBatch: 1, timer: null, send: null,
    requests: 0, batches: 0, bytes: 0, serverMs: 0, roundMs: 0, sentAt: 0, problems: [], started: false,
  };

  b.show = () => {
    const box = document.getElementById("audit-browser-checks");
    if (!box) return;
    box.textContent = [
      `${b.requests} requests in ${b.batches} batches, ${(b.bytes / 1048576).toFixed(1)} MB`,
      `average batch ${b.batches ? (b.roundMs / b.batches).toFixed(0) : 0} ms, API time ${(b.serverMs / 1000).toFixed(1)} s in all`,
      ...(b.problems.length ? b.problems.slice(0, 30) : ["no problems"]),
    ].join("\n");
  };

  b.flush = () => {
    b.timer = null;
    if (b.inflight !== null || !b.queue.length || !b.send) return;
    const id = b.nextBatch++;
    const requests = b.queue.splice(0);
    b.inflight = id;
    b.batches += 1;
    b.sentAt = performance.now();
    b.send("batch", { id, requests });
    setTimeout(() => {
      if (b.inflight !== id) return;
      b.problems.push(`batch ${id}: no answer in ${NO_ANSWER_MS / 1000} s`);
      requests.forEach((r) => b.fail(r.id));
      b.inflight = null;
      b.schedule();
      b.show();
    }, NO_ANSWER_MS);
  };
  b.schedule = () => { if (!b.timer) b.timer = setTimeout(b.flush, BATCH_DELAY_MS); };

  b.fail = (id) => {
    const p = b.pending.get(id);
    b.pending.delete(id);
    if (p) p.reject(new Error("The app did not answer. Reload the page."));
  };

  b.receive = (out) => {
    if (!out || out.batch_id !== b.inflight) return;
    b.inflight = null;
    b.roundMs += performance.now() - b.sentAt;
    for (const r of out.responses) {
      b.bytes += (r.body || "").length;
      b.serverMs += r.server_ms || 0;
      if (r.status >= 500) b.problems.push(`HTTP ${r.status} on ${r.path}`);
      const p = b.pending.get(r.id);
      b.pending.delete(r.id);
      if (p) p.resolve(new Response(NO_BODY.has(r.status) ? null : r.body, { status: r.status, headers: r.headers }));
    }
    b.schedule();
    b.show();
  };

  const realFetch = window.fetch.bind(window);
  window.fetch = (input, init = {}) => {
    if (typeof input !== "string" || !input.startsWith("/api/")) return realFetch(input, init);
    const id = b.nextId++;
    b.requests += 1;
    return new Promise((resolve, reject) => {
      b.pending.set(id, { resolve, reject });
      b.queue.push({ id, method: (init.method || "GET").toUpperCase(), path: input,
                     body: init.body ?? null, headers: init.headers ?? null });
      b.schedule();
    });
  };

  document.addEventListener("securitypolicyviolation", (e) => {
    b.problems.push(`blocked by Snowflake's security policy: ${e.violatedDirective} ${e.blockedURI}`);
    b.show();
  });
  window.addEventListener("error", (e) => { b.problems.push(`script error: ${e.message}`); b.show(); });
  return b;
}

// What index.html does before first paint on the local page.
function setTheme() {
  try {
    const stored = localStorage.getItem("theme");
    const dark = stored ? stored === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
    if (dark) document.documentElement.setAttribute("data-theme", "dark");
  } catch (e) { /* storage or matchMedia unavailable: light */ }
}

export default function (component) {
  const { data, setTriggerValue } = component;
  const b = window.__auditBridge || (window.__auditBridge = makeBridge());
  b.send = setTriggerValue;
  b.receive(data.out);
  b.schedule();
  if (!b.started) {
    b.started = true;
    window.APP_BRAND = data.brand;
    window.APP_HOSTED = true;
    setTheme();
    try {
      __startReact();
    } catch (e) {
      b.problems.push(`the page did not start: ${e.message}`);
    }
  }
  b.show();
}
