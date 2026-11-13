# Streamlit bridge flow

How the React build's `fetch("/api/...")` calls reach FastAPI inside Streamlit in Snowflake, where the browser cannot reach a server port.

## Why

- The browser cannot reach a port on Snowflake's side, so `/api/...` calls go through a Streamlit component and the API answers in the Streamlit process (tools/streamlit_deploy/streamlit_app.py:1-5).
- The FastAPI app is called in-process through `fastapi.testclient.TestClient`, no port, no network (tools/streamlit_deploy/streamlit_app.py:95-103).

## Sequence (warehouse runtime, v1 frame)

```mermaid
sequenceDiagram
  participant U as Browser (Snowsight)
  participant ST as Streamlit page<br/>streamlit_app.py
  participant FR as Component frame<br/>frame/index.html
  participant BC as bridge_core.js + bridge_frame.js
  participant R as React build<br/>assets/index-*.js
  participant API as FastAPI app<br/>(TestClient, in-process)

  ST->>FR: declare_component("audit_app", path=frame/)
  BC->>ST: postMessage streamlit:componentReady (apiVersion 1)
  ST->>BC: streamlit:render args {out, brand}
  BC->>BC: first render: APP_BRAND, APP_HOSTED=true, setTheme()
  BC->>R: inject <script type=module src=assets/index-*.js>
  R->>BC: fetch("/api/meta") (window.fetch patched)
  BC->>BC: queue; flush after 15 ms, max 8 per batch
  BC->>ST: streamlit:setComponentValue {id, requests[]}
  ST->>ST: on_change=_on_batch (fragment rerun)
  ST->>API: _answer(req) x4 threads
  API-->>ST: status, body, headers
  ST->>ST: pack <= 24 MB, 413 if one is too big, rest -> retry
  ST->>BC: streamlit:render args.out {batch_id, responses, retry}
  BC->>R: resolve each Promise with new Response(body)
  BC->>BC: re-queue retry ids, schedule next batch
```

## Steps with code

1. **Page start**: `server_checks()` once per server; `PAGE_CSS` hides Streamlit chrome; if `frame/` exists → v1 `declare_component(path=frame)`, else v2 `components.v2.component(html, css, js)` (tools/streamlit_deploy/streamlit_app.py:106-120, 204-218).
2. **Frame page** is written by `deploy.py`: stylesheet with `url(/assets/` rewritten to relative, `data-bundle` naming the JS, then `bridge_core.js` and `bridge_frame.js` (tools/streamlit_deploy/deploy.py:23-33, 60-72).
3. **Handshake**: `bridge_frame.js` posts `streamlit:componentReady`; on each `streamlit:render` it hands `args.out` to `bridge.receive`, and on the first one sets `APP_BRAND`, `APP_HOSTED`, theme, loads the bundle and sets frame height (tools/streamlit_deploy/bridge_frame.js:1-33).
4. **Intercept**: `window.fetch` is replaced; only string URLs starting `/api/` are queued as `{id, method, path, body, headers}`; everything else uses the real fetch (tools/streamlit_deploy/bridge_core.js:70-81).
5. **Batch**: one batch in flight; `flush` sends up to `MAX_BATCH = 8` after `BATCH_DELAY_MS = 15`; no answer in 300 s → all its requests reject "The app did not answer. Reload the page." (tools/streamlit_deploy/bridge_core.js:3-7, 25-50).
6. **Answer**: `_on_batch` runs the batch on a 4-thread pool through `_answer` (tools/streamlit_deploy/streamlit_app.py:30-31, 145-152).
   - `POST /api/refresh` → 409 "Refresh is off in Streamlit in Snowflake."; any `PUT` → 409 "Settings are read-only here." (tools/streamlit_deploy/streamlit_app.py:126-133).
   - Exception → 500 with only the exception type name (tools/streamlit_deploy/streamlit_app.py:139-142).
   - `content-length`, `content-encoding`, `transfer-encoding` dropped (tools/streamlit_deploy/streamlit_app.py:33, 137).
7. **Size rule**: each response JSON size counted; one over 24 MB → 413 "This result is too large to send here."; once the batch would pass 24 MB, later responses go to `retry` (tools/streamlit_deploy/streamlit_app.py:153-165).
   - Example: 3 responses of 10 MB each → first two kept (20 MB), third id in `retry`, the page re-sends it in the next batch (bridge_core.js:64-66).
8. **Return**: result stored in `st.session_state["bridge_out"]`; the fragment `app_view` reruns and passes `out` back to the component (tools/streamlit_deploy/streamlit_app.py:165, 194-201).
9. **Resolve**: `receive` ignores stale batch ids, resolves each pending Promise with a `Response` (null body for 101/204/205/304), records 5xx/413 under Browser checks (tools/streamlit_deploy/bridge_core.js:52-68).

## Container runtime differences (v2)

- The React bundle is wrapped as `function __startReact(){...}` and concatenated with `bridge_core.js` + `bridge_container.js` into one inline script; fonts are inlined as base64 data URLs (tools/streamlit_deploy/streamlit_app.py:168-183).
- `bridge_container.js` default export uses `setTriggerValue` to send, `data.out` to receive, and calls `__startReact()` once (tools/streamlit_deploy/bridge_container.js:1-20).
- Python side reads `st.session_state["bridge"].batch` instead of the raw value; `on_batch_change=_on_batch` (tools/streamlit_deploy/streamlit_app.py:148, 201).
- Styles are not isolated, because the build looks up its root in the document (tools/streamlit_deploy/streamlit_app.py:215-216).

## UI side

- `HOSTED = !!window.APP_HOSTED` hides the Refresh button and the settings gear (web/src/api.ts:7-10; web/src/App.tsx:277, 490, 646).
- `tests/test_build_web.py:57-60` forbids `window.__` in `web/src`; the bridge's `window.__auditBridge` lives in `tools/streamlit_deploy`, outside that rule.

## Status

- Checked only with Streamlit run locally; not run in Snowflake (STATUS.md:45). Whether v1 components are allowed on warehouse runtime is unclear (tools/streamlit_deploy/README.md:7).
