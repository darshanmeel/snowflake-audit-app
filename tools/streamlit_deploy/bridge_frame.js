// Warehouse runtime: a v1 component in its own frame, speaking Streamlit's message protocol.
const toStreamlit = (type, fields) => window.parent.postMessage({ isStreamlitMessage: true, type, ...fields }, "*");

function fitFrame() {
  let height = 900;
  try { height = window.parent.innerHeight || height; } catch (e) { /* another origin: keep the default */ }
  toStreamlit("streamlit:setFrameHeight", { height });
}

const bridge = window.__auditBridge = makeBridge();
bridge.send = (_name, value) => toStreamlit("streamlit:setComponentValue", { value, dataType: "json" });

window.addEventListener("message", (event) => {
  if (!event.data || event.data.type !== "streamlit:render") return;
  const args = event.data.args || {};
  bridge.receive(args.out);
  bridge.schedule();
  if (!bridge.started) {
    bridge.started = true;
    window.APP_BRAND = args.brand;
    window.APP_HOSTED = true;
    setTheme();
    const script = document.createElement("script");
    script.type = "module";
    script.src = document.body.dataset.bundle;
    script.onerror = () => { bridge.problems.push("the page script did not load"); bridge.show(); };
    document.body.appendChild(script);
    fitFrame();
  }
  bridge.show();
});
window.addEventListener("resize", fitFrame);
toStreamlit("streamlit:componentReady", { apiVersion: 1 });
