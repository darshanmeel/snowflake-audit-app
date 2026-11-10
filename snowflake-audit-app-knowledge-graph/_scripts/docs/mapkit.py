"""Tiny diagram kit: absolutely positioned boxes plus one inline SVG arrow layer."""
from html import escape as esc

MARKERS = ('<defs><marker id="h" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
           'orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#17191D"/></marker>'
           '<marker id="one" viewBox="0 0 12 12" refX="1" refY="6" markerUnits="userSpaceOnUse" markerWidth="12" '
           'markerHeight="12" orient="auto"><path d="M4,1 L4,11 M8,1 L8,11" stroke="#17191D" stroke-width="1.4" fill="none"/></marker>'
           '<marker id="many" viewBox="0 0 12 12" refX="11" refY="6" markerUnits="userSpaceOnUse" markerWidth="12" '
           'markerHeight="12" orient="auto"><path d="M1,6 L11,1 M1,6 L11,11 M1,6 L11,6 M3,1 L3,11" stroke="#17191D" '
           'stroke-width="1.4" fill="none"/></marker></defs>')


class Map:
    def __init__(self, mid, w, h, hover=True):
        self.id, self.w, self.h, self.hover = mid, w, h, hover
        self.boxes, self.lines, self.over, self.under, self.ids = [], [], [], [], []
        self.related = {}  # box id -> set of line classes

    def lane(self, y, h, label):
        self.under.append(f'<div class="lane" style="top:{y}px;height:{h}px;width:{self.w}px"><span>{esc(label)}</span></div>')

    def grp(self, x, y, w, h, label):
        self.under.append(f'<div class="grp" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px"><span>{esc(label)}</span></div>')

    def box(self, bid, x, y, w, h, title='', sub='', cls='', tag='', tip='', inner=None, center=True):
        c = 'b c ' if center and inner is None else 'b '
        body = inner if inner is not None else (
            (f'<span class="tag">{esc(tag)}</span>' if tag else '') +
            f'<span class="t">{title}</span>' + (f'<span class="sub">{sub}</span>' if sub else ''))
        t = f' data-tip="{esc(tip)}"' if tip else ''
        self.boxes.append((bid, f'<div id="{self.id}-{bid}" class="{c}{cls} r-{bid}"{t} style="left:{x}px;top:{y}px;width:{w}px;height:{h}px">{body}</div>'))
        self.ids.append(bid)

    def step(self, bid, x, y, w, h, n, title, bullets, inn, out, cls=''):
        ul = '<ul>' + ''.join(f'<li>{b}</li>' for b in bullets) + '</ul>'
        io = f'<div class="io"><span class="l in">IN</span><span>{inn}</span><span class="l out">OUT</span><span>{out}</span></div>'
        inner = f'<span class="tag">STEP {n}</span><span class="t">{title}</span>{ul}{io}'
        self.box(bid, x, y, w, h, cls=cls, inner=inner)

    def arrow(self, pts, a=None, b=None, dashed=False, plain_end=False, start=None, end=None):
        cls = ('flow ' if dashed else '') + ' '.join(f'e-{k}' for k in (a, b) if k)
        da = ' stroke-dasharray="5 4"' if dashed else ''
        ms = f' marker-start="url(#{start})"' if start else ''
        me = f' marker-end="url(#{end})"' if end else ('' if plain_end else ' marker-end="url(#h)"')
        p = ' '.join(f'{x},{y}' for x, y in pts)
        self.lines.append(f'<polyline class="{cls.strip()}" points="{p}" fill="none" stroke="#17191D" stroke-width="1.5" '
                          f'stroke-linejoin="round"{da}{ms}{me}/>')

    def lbl(self, x, y, text, chip=False):
        self.over.append(f'<span class="lbl{" chip" if chip else ""}" style="left:{x}px;top:{y}px">{text}</span>')

    def num(self, x, y, n):
        self.over.append(f'<span class="num" style="left:{x}px;top:{y}px">{n}</span>')

    def css(self):
        out = []
        for bid in self.ids:
            s = f'#{self.id}'
            for st in (':hover', '.pinned'):
                out.append(f'{s}:has(#{self.id}-{bid}{st}) .b:not(.r-{bid}):not(.grp-b) {{ opacity:.3; }}')
                out.append(f'{s}:has(#{self.id}-{bid}{st}) polyline:not(.e-{bid}) {{ opacity:.15; }}')
                out.append(f'{s}:has(#{self.id}-{bid}{st}) polyline.e-{bid} {{ stroke:var(--blue); stroke-width:2.5; }}')
        return '<style>' + '\n'.join(out) + '</style>'

    def render(self):
        # a box lights its own lines; boxes at the other end of those lines also stay lit via r-<id> classes
        rel = {}
        for ln in self.lines:
            import re
            ks = re.findall(r'e-([\w]+)', ln)
            for k in ks:
                rel.setdefault(k, set()).update(ks)
        boxes = []
        for bid, html in self.boxes:
            extra = ''.join(f' r-{o}' for o in sorted(rel.get(bid, ())) if o != bid)
            boxes.append(html.replace(f' r-{bid}"', f' r-{bid}{extra}"', 1))
        hov = ' hov' if self.hover else ''
        return (f'{self.css() if self.hover else ""}<div class="map-wrap"><div class="map{hov}" id="{self.id}" style="width:{self.w}px;height:{self.h}px">'
                f'{"".join(self.under)}<svg width="{self.w}" height="{self.h}" aria-hidden="true">{MARKERS}{"".join(self.lines)}</svg>'
                f'{"".join(boxes)}{"".join(self.over)}</div></div>')
