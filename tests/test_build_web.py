"""The built front end in app/web/dist is committed, so it must match the source in web/.

The Vite build (web/vite.config.ts) writes dist/source-hash.txt: a sha256 over every file git tracks
under web/. This test recomputes it the same way, so a source change without `npm run build` fails.
No Node is needed to run it.
"""
from __future__ import annotations

import hashlib
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "app" / "web" / "dist"


def _source_hash() -> str:
    """The same hash as sourceHash() in web/vite.config.ts."""
    out = subprocess.run(["git", "ls-files", "web"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    files = sorted(line for line in out.split("\n") if line)
    assert files, "git tracks no files under web/"
    h = hashlib.sha256()
    for f in files:
        h.update((f + "\n").encode("utf-8"))
        h.update((ROOT / f).read_bytes().replace(b"\r\n", b"\n"))
        h.update(b"\n")
    return h.hexdigest()


@pytest.mark.skipif(not (ROOT / ".git").exists(), reason="not a git checkout (a GitHub zip): nothing to compare")
def test_the_build_matches_the_source():
    stamp = DIST / "source-hash.txt"
    assert (DIST / "index.html").exists() and stamp.exists(), "no build: cd web && npm ci && npm run build"
    assert stamp.read_text(encoding="utf-8").strip() == _source_hash(), \
        "app/web/dist is stale: commit the web/ source, then cd web && npm run build"


def test_index_html_keeps_the_first_paint_rules():
    html = (DIST / "index.html").read_text(encoding="utf-8")
    assert 'localStorage.getItem("theme")' in html and "try {" in html, "the theme script runs before first paint"
    assert '<meta name="author"' in html and '<meta name="copyright"' in html
    assert '<link rel="icon" href="data:,">' in html
    assert "no-store" not in html and "?v=" not in html
    assert "fonts.googleapis.com" not in html and "fonts.gstatic.com" not in html
    assert re.search(r'src="/assets/index-[\w-]+\.js"', html), "hashed bundle"


def test_the_old_build_is_gone():
    web = ROOT / "app" / "web"
    assert not list(web.rglob("*.jsx")), "old .jsx sources"
    assert not (web / "vendor").exists() and not (ROOT / "tools" / "build_web.js").exists()


def test_no_window_globals_in_the_source():
    hits = [str(p.relative_to(ROOT)) for p in (ROOT / "web" / "src").rglob("*.ts*")
            if re.search(r"Object\.assign\(\s*window|window\.__", p.read_text(encoding="utf-8"))]
    assert hits == []
