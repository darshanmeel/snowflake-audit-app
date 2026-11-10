import sys
from pathlib import Path
from playwright.sync_api import sync_playwright
REPO = Path(__file__).resolve().parents[3]
SHOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
JS = """
() => {
  const out = {docW: document.documentElement.scrollWidth, winW: window.innerWidth, over: [], overlap: [], tbl: []};
  document.querySelectorAll('.map .b').forEach(b => {
    if (b.scrollHeight > b.clientHeight + 1 || b.scrollWidth > b.clientWidth + 1)
      out.over.push([b.closest('.map').id, b.id, b.scrollWidth + 'x' + b.scrollHeight, b.clientWidth + 'x' + b.clientHeight, (b.innerText||'').slice(0,40)]);
  });
  document.querySelectorAll('.map').forEach(m => {
    const bs = [...m.querySelectorAll('.b')].filter(x => !x.classList.contains('decision'));
    for (let i = 0; i < bs.length; i++) for (let j = i + 1; j < bs.length; j++) {
      const a = bs[i].getBoundingClientRect(), c = bs[j].getBoundingClientRect();
      if (a.left < c.right - 1 && c.left < a.right - 1 && a.top < c.bottom - 1 && c.top < a.bottom - 1) out.overlap.push([m.id, bs[i].id, bs[j].id]);
    }
    // labels overlapping boxes
    m.querySelectorAll('.lbl').forEach(l => {
      const a = l.getBoundingClientRect();
      bs.forEach(b => { const c = b.getBoundingClientRect();
        if (a.left < c.right - 1 && c.left < a.right - 1 && a.top < c.bottom - 1 && c.top < a.bottom - 1) out.overlap.push([m.id, 'label:' + l.innerText, b.id]); });
    });
    const w = m.parentElement; if (w.scrollWidth > w.clientWidth + 1) out.over.push([m.id, 'MAP-SCROLL', w.scrollWidth, w.clientWidth]);
  });
  document.querySelectorAll('table').forEach(t => { if (t.scrollWidth > t.parentElement.clientWidth + 1) out.tbl.push([t.innerText.slice(0,40), t.scrollWidth, t.parentElement.clientWidth]); });
  document.querySelectorAll('pre').forEach(t => { if (t.scrollWidth > t.clientWidth + 1) out.tbl.push(['PRE', t.innerText.slice(0,40), t.scrollWidth, t.clientWidth]); });
  return out;
}
"""
with sync_playwright() as p:
    b = p.chromium.launch()
    for w in (1100, 390):
        pg = b.new_page(viewport={'width': w, 'height': 900})
        pg.goto((REPO / 'docs' / 'technical.html').as_uri())
        r = pg.evaluate(JS)
        print(w, 'doc/win', r['docW'], r['winW'])
        for k in ('over', 'overlap', 'tbl'):
            for x in r[k][:40]: print(' ', k, x)
        if w == 1100:
            for m in pg.query_selector_all('.map'):
                mid = m.get_attribute('id')
                m.screenshot(path=str(SHOT / f'map_{mid}.png'))
    b.close()
