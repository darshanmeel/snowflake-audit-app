from playwright.sync_api import sync_playwright
import sys,tempfile,os
from pathlib import Path
out=sys.argv[1]
with sync_playwright() as p:
    b=p.chromium.launch()
    for w in (1100,390):
        pg=b.new_page(viewport={'width':w,'height':900})
        pg.goto((Path(__file__).resolve().parents[3] / 'docs/overview.html').as_uri())
        print(w,pg.evaluate("[document.documentElement.scrollWidth,innerWidth,document.body.scrollHeight]"))
        pg.screenshot(path=os.path.join(out,f'ov{w}.png'),full_page=True)
    b.close()
