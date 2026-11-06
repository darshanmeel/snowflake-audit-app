// Container runtime: a v2 component. __startReact, defined above this file, holds the build.
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
