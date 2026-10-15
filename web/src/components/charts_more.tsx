// web/src/components/charts_more.tsx -- P4 (design/DESIGN-DIRECTION.md sections 5 & 7): the
// chart primitives charts.tsx's original set did not need -- RankedBars, Columns, Meter, Heatmap,
// Icicle, DivergingBars, Dumbbell and Scatter. Everything here is presentation-only, exactly like
// charts.tsx: it takes already-aggregated {name/id/value/...} data and draws it; group-by/top-N/sum
// aggregation stays in hooks.tsx. Built on charts.tsx's shared ChartFrame/RoundRect/foldTopNOther/
// paletteColor/tipText/chartLabel/niceTicks/inkForFill/useHatchId/HatchDef -- all globals, loaded
// one script tag earlier (index.html), no import needed (same pattern pressure.tsx already uses
// for paletteColor).
//
// P3 (running in parallel in this worktree) owns the real StateNote in primitives.tsx; every
// "no rows" case below renders the small local EmptyChart instead of importing that in-progress
// component, matching this pass's own instruction.

// ─────────── EmptyChart -- StateNote-like, never a blank chart (mirrors charts.tsx's own
// Treemap/HBarList "nothing to rank" fallback, same .chart-note classes, so it already matches the
// theme without any new CSS). ───────────
import React from "react";
import { fmtCredits, fmtDayShort } from "../format";
import { CHART_OTHER_COLOR, CHART_UNTAGGED_BG, CHART_UNTAGGED_LINE, ChartFrame, HatchDef, RoundRect, chartLabel, foldTopNOther, inkForFill, measureTextPx, niceTicks, paletteColor, tipText, truncateLeft, useChartWidth, useHatchId, useThemeVersion } from "./charts";
import type { ChartItem } from "./charts";
import type { Row } from "../types";

type ValueFmt = (v: number) => string;

export function EmptyChart({ text }: { text?: string | null }) {
  return (
    <div className="chart-note ok">
      <div className="chart-note-text">{text || "Nothing to show -- every value is zero or absent at this window/filters."}</div>
    </div>
  );
}

// ─────────── a small numeric-axis tick formatter (1.2k / 3.4m), local to this file -- charts.tsx's
// niceTicks gives the tick VALUES, this just makes them short labels. ───────────
export function compactNum(v: unknown): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  if (abs >= 1e9) return sign + (abs / 1e9).toFixed(abs >= 1e10 ? 0 : 1) + "b";
  if (abs >= 1e6) return sign + (abs / 1e6).toFixed(abs >= 1e7 ? 0 : 1) + "m";
  if (abs >= 1e3) return sign + (abs / 1e3).toFixed(abs >= 1e4 ? 0 : 1) + "k";
  return sign + (Number.isInteger(abs) ? String(abs) : abs.toFixed(1));
}

// ─────────── compactTick -- a y-axis tick's own decimal precision follows niceTicks' STEP, not a
// fixed 1 decimal. compactNum's fixed rule read a 0.18 max / 0.05 step axis as "0, 0.1, 0.1, 0.2,
// 0.2" (0.05 and 0.10 both round to 1 decimal). `step` is the gap between two adjacent ticks;
// log10 of it gives how many decimals a step that small actually needs. Values at compactNum's own
// magnitude range (>= 1000) still get its k/m/b abbreviation -- only the small, sub-1000 case
// (where a coarse or fine step matters) is handled here. ───────────
export function compactTick(v: unknown, step?: unknown): string {
  const n = Number(v);
  if (!Number.isFinite(n)) return String(v);
  if (Math.abs(n) >= 1e3) return compactNum(n);
  const s = Number(step);
  const decimals = Number.isFinite(s) && s > 0 ? Math.max(0, -Math.floor(Math.log10(s))) : (Number.isInteger(n) ? 0 : 1);
  return n.toFixed(decimals);
}

// ─────────── maxOrOne -- a plain `Math.max(...vals, 1)` floor doesn't just guard the empty-array/
// all-zero case (its intent), it also FLOORS every real positive max under 1: a $0.40 top bar or a
// 0.3 share divides by 1 instead of 0.4/0.3 and draws at 40%/30% width instead of the correct,
// larger fraction its own scale implies. Only fall back to 1 when there is truly nothing positive
// to scale against. ───────────
export function maxOrOne(vals: number[] | null | undefined): number {
  const m = (vals && vals.length) ? Math.max(...vals) : 0;
  return m > 0 ? m : 1;
}

// The label column of a row chart: about a third of the card, never under 96px or over 240px.
export function rowLabelWidth(W: number, labels?: string[] | null, reserve = 0): number {
  if (!labels || !labels.length) return Math.max(96, Math.min(240, Math.round(W * 0.34)));
  // Wide enough for the longest label when the card has room, so names are cut only on narrow cards.
  const need = Math.ceil(Math.max(...labels.map((l) => measureTextPx(String(l || ""))))) + 10;
  const cap = Math.max(96, Math.min(320, Math.round(W * 0.45), W - reserve - 80));
  return Math.max(96, Math.min(need, cap));
}

// ─────────── RankedBars -- top N + Other, value labels at tips, an optional part-of-whole inner
// bar (strong colour inside a light --seq-1 track, e.g. possible waste inside spend). `categorical`
// gives each of the top N its own --c1..--c5 slot (a real breakdown, e.g. a donut replacement);
// the default is one uniform series colour for a plain ranked measure (e.g. "jobs by failure
// streak") -- ranking many individual entities by a rainbow is not a category. ───────────
export function RankedBars({
  items, n = 8, categorical = false, color = "var(--c1)", wholeColor = "var(--seq-1)",
  valueFmt, unitLabel, width = 760, note, ariaLabel, emptyText, ratio = false, onItemClick,
}: {
  items: ChartItem[] | null | undefined; n?: number; categorical?: boolean; color?: string; wholeColor?: string;
  valueFmt?: ValueFmt; unitLabel?: string; width?: number; note?: React.ReactNode; ariaLabel?: string; emptyText?: string;
  ratio?: boolean;
  /** Click a bar or its label (not the Other bucket): e.g. open the task panel or the filtered rows. */
  onItemClick?: ((item: ChartItem) => void) | null;
}) {
  const folded = foldTopNOther(items, { n, categorical, color, noOther: ratio });
  const hatchId = useHatchId();
  const [measureRef, W] = useChartWidth(width);
  if (!folded.length) return <div ref={measureRef}><EmptyChart text={emptyText} /></div>;
  const fmt = valueFmt || ((v: number) => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 }));
  // Fewer than 2 non-zero categories isn't a ranking -- one plain line instead of a bar chart
  // with a single bar (and every other row reading a silent "0").
  const nonZero = folded.filter((it) => (it.whole != null ? it.whole : it.value) > 0);
  if (nonZero.length < 2) {
    if (!nonZero.length) return <div ref={measureRef}><EmptyChart text={emptyText} /></div>;
    const only = nonZero[0];
    const onlyVal = only.whole != null ? only.whole : only.value;
    return <div ref={measureRef}><div className="chart-note-oneline">{`All ${fmt(onlyVal)} in ${chartLabel(only.name, only.id)}`}</div></div>;
  }
  const labelW = rowLabelWidth(W, folded.map((it) => chartLabel(it.name, it.id)), 90), rowH = 26, barH = 18, padTop = 4, padBottom = 4;
  const height = padTop + folded.length * rowH + padBottom;
  const trackX = labelW + 10;
  const valueText = (it: ChartItem) => (it.whole != null ? `${fmt(it.value)} of ${fmt(it.whole)}` : fmt(it.value));
  // The value column is as wide as its longest label, so "41,458 min of 43,200" is never clipped.
  const valueW = Math.min(Math.round(W * 0.4), Math.ceil(Math.max(0, ...folded.map((it) => measureTextPx(valueText(it)))) + 14));
  const trackW = Math.max(20, W - trackX - valueW);
  const max = maxOrOne(folded.map((it) => (it.whole != null ? it.whole : it.value)));
  const pxPerUnit = trackW / max;
  const catLegend = categorical
    ? folded.filter((it) => !it.hatch).map((it) => ({ label: it.name, color: it.color }))
    : null;
  const hasHatch = folded.some((it) => it.hatch);
  const legend = catLegend && hasHatch
    ? [...catLegend, { label: "Untagged", color: CHART_UNTAGGED_LINE, bg: CHART_UNTAGGED_BG, hatch: true }]
    : catLegend;
  const table = {
    columns: [{ key: "name", label: "Name" }, { key: "value", label: unitLabel || "Value", align: "right" }],
    rows: folded.map((it) => ({ name: chartLabel(it.name, it.id), value: fmt(it.value) })),
  };
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={{ l: 0, r: 0, t: 0, b: 0 }}
      legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="rb"
      renderPlot={() => (
        <>
          <defs><HatchDef id={hatchId} /></defs>
          {folded.map((it, i) => {
            const y = padTop + i * rowH;
            const barY = y + (rowH - barH) / 2;
            const wholeVal = it.whole != null ? it.whole : it.value;
            const wholeW = Math.max(0, wholeVal * pxPerUnit);
            const partW = Math.max(0, it.value * pxPerUnit);
            const fill = it.hatch ? `url(#${hatchId})` : it.color;
            const tip = tipText({ name: it.name, id: it.id, value: fmt(it.value), basis: unitLabel });
            const tipLabel = chartLabel(it.name, it.id);
            const clickable = !!onItemClick && !it.isOther && !it.pooled;
            const click = clickable ? () => onItemClick!(it) : undefined;
            return (
              <g key={i} className={clickable ? "rb-clickable" : undefined} onClick={click}>
                <foreignObject x={0} y={y} width={labelW} height={rowH}>
                  <div className="rb-label" title={tipLabel} style={{ lineHeight: `${rowH}px` }}>{it.dot && <span className="rb-dot" style={{ background: it.dot }} aria-hidden="true" />}{truncateLeft(tipLabel, labelW - (it.dot ? 22 : 8))}</div>
                </foreignObject>
                {it.whole != null && (
                  <RoundRect x={trackX} y={barY} w={wholeW} h={barH} r={4} fill={wholeColor} squareEdge="left" />
                )}
                <RoundRect x={trackX} y={barY} w={it.whole != null ? partW : wholeW} h={barH} r={4} fill={fill} squareEdge="left" title={tip} />
                <text x={trackX + Math.max(wholeW, partW) + 8} y={barY + barH / 2} dominantBaseline="middle" className="rb-value">
                  {valueText(it)}
                </text>
              </g>
            );
          })}
        </>
      )}
    />
    </div>
  );
}

// ─────────── Columns -- daily columns stacked by series (fold at 5 + Other, colours never cycle),
// with optional marker days (e.g. a cost spike). ───────────
// `partialDays`: day (or month) keys whose bar is still filling (today, the month in progress); each
// is drawn faded and its tooltip says partial, so an unfinished bar is never read as a real drop.
interface ColumnSeries { name?: any; id?: any; values?: any[] | null; untagged?: boolean; [key: string]: any }
interface PlotSeries { name: any; id?: any; color?: string; hatch?: boolean; values: any[]; isOther?: boolean }
export function Columns({ days, series, markers, valueFmt, unitLabel, width = 760, height = 220, n = 5, note, ariaLabel, dollarAxis, partialDays }: {
  days: string[] | null | undefined; series: ColumnSeries[] | null | undefined; markers?: { day: string; label?: string }[] | null;
  valueFmt?: ValueFmt; unitLabel?: string; width?: number; height?: number; n?: number; note?: React.ReactNode; ariaLabel?: string;
  dollarAxis?: boolean; partialDays?: string[] | null;
}) {
  const hatchId = useHatchId();
  const [measureRef, W] = useChartWidth(width);
  const hasDays = days && days.length > 0;
  const hasSeries = series && series.some((s) => s && s.values && s.values.some((v) => Number(v) > 0));
  if (!hasDays || !hasSeries) {
    return <div ref={measureRef}><EmptyChart text={"Nothing to show -- every value is zero or absent at this window/filters."} /></div>;
  }
  // Review round 1: keyed by `name` alone, two series sharing a display name but different ids
  // collapsed into one (the head plotted whichever the Map's last write won, the other's own
  // values vanished from both the head AND the Other tail). `id` is the real identity when a
  // caller has one; `name` is only the fallback for series that never carry one.
  const keyOf = (s: ColumnSeries) => (s && s.id !== undefined && s.id !== null ? s.id : (s && s.name));
  const totals = series!.map((s) => ({
    name: s.name, id: s.id, key: keyOf(s), untagged: !!s.untagged,
    value: (s.values || []).reduce((a, b) => a + (Number(b) || 0), 0),
  }));
  const folded = foldTopNOther(totals, { n, categorical: true });
  const byKey = new Map<any, ColumnSeries>(series!.map((s): [any, ColumnSeries] => [keyOf(s), s]));
  const headKeys = new Set(folded.filter((f) => !f.isOther).map((f) => f.key));
  const otherKeys = series!.map((s) => keyOf(s)).filter((k) => !headKeys.has(k));
  const plotSeries = folded.map((f): PlotSeries => {
    if (f.isOther) {
      const vals = days!.map((_, di) => otherKeys.reduce((sum, k) => sum + (Number((byKey.get(k)!.values || [])[di]) || 0), 0));
      return { name: "Other", color: f.color, values: vals, isOther: true };
    }
    const src = byKey.get(f.key);
    // Review round 1: an untagged series (foldTopNOther always marks it `hatch: true`, never
    // folds it into Other) was drawn as a solid fill, same as any real category -- the hatch is
    // this measure's own "untagged" evidence, so it must survive onto the actual bar and legend.
    return { name: f.name, id: f.id, color: f.color, hatch: !!f.hatch, values: (src && src.values) || days!.map(() => 0) };
  });
  const stackTotals = days!.map((_, di) => plotSeries.reduce((s, ser) => s + (Number(ser.values[di]) || 0), 0));
  const maxTotal = maxOrOne(stackTotals);
  const ticks = niceTicks(0, maxTotal, 4);
  const tickStep = ticks.length > 1 ? ticks[1] - ticks[0] : undefined;
  const P = { l: 48, r: 8, t: 10, b: 26 };
  const innerW = W - P.l - P.r, innerH = height - P.t - P.b;
  const topTick = ticks[ticks.length - 1] || 1;
  const yOf = (v: number) => P.t + innerH - (v / topTick) * innerH;
  const colW = innerW / days!.length;
  const barW = Math.max(2, Math.min(20, colW - 2));
  const fmt = valueFmt || ((v: number) => compactNum(v));
  const legend = plotSeries.length >= 2
    ? plotSeries.map((s) => ({ label: s.name, color: s.hatch ? CHART_UNTAGGED_LINE : s.color, hatch: !!s.hatch, bg: CHART_UNTAGGED_BG }))
    : null;
  const table = {
    columns: [{ key: "day", label: "Day" }, ...plotSeries.map((s, i) => ({ key: `s${i}`, label: s.name, align: "right" }))],
    rows: days!.map((d, di) => {
      const row: Record<string, any> = { day: d };
      plotSeries.forEach((s, i) => { row[`s${i}`] = fmt(s.values[di] || 0); });
      return row;
    }),
  };
  const markerDays = new Set((markers || []).map((m) => m.day));
  const partialSet = new Set(partialDays || []);
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={P}
      yTicks={ticks.map((t) => ({ y: yOf(t), value: t, label: `${dollarAxis ? "$" : ""}${compactTick(t, tickStep)}` }))}
      zeroY={yOf(0)}
      xLabels={[days![0], days![Math.floor((days!.length - 1) / 2)], days![days!.length - 1]].map(fmtDayShort)}
      legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="cols"
      renderPlot={() => (
        <>
          <defs><HatchDef id={hatchId} /></defs>
          {days!.map((d, di) => {
            const x = P.l + di * colW + (colW - barW) / 2;
            let acc = 0;
            return (
              <g key={di} opacity={partialSet.has(d) ? 0.5 : undefined}>
                {plotSeries.map((s, si) => {
                  const v = Number(s.values[di]) || 0;
                  if (v <= 0) return null;
                  const y0 = yOf(acc), y1 = yOf(acc + v);
                  acc += v;
                  const isTop = si === plotSeries.length - 1 || plotSeries.slice(si + 1).every((later) => !(Number(later.values[di]) > 0));
                  const fill = s.hatch ? `url(#${hatchId})` : s.color;
                  return (
                    <RoundRect
                      key={si} x={x} y={y1} w={barW} h={Math.max(0, y0 - y1)} r={isTop ? 4 : 0}
                      fill={fill} squareEdge="bottom"
                      title={tipText({ name: s.name, id: s.id, date: partialSet.has(d) ? `${d} (partial)` : d, value: fmt(v), basis: unitLabel })}
                    />
                  );
                })}
                {markerDays.has(d) && (
                  <text x={x + barW / 2} y={Math.max(P.t, yOf(acc) - 6)} textAnchor="middle" className="cols-marker">
                    {"▲"}
                    <title>{(markers!.find((m) => m.day === d) || {} as { label?: string }).label || "Spike"}</title>
                  </text>
                )}
              </g>
            );
          })}
        </>
      )}
    />
    </div>
  );
}

// ─────────── Meter -- a 100% stacked bar for <= 4 parts, instead of a donut (section 5: "never a
// donut above 4 slices"). ───────────
export function Meter({ segments, valueFmt, width = 760, height = 26, note, ariaLabel }: {
  segments: { label?: any; value: number; color?: string; untagged?: boolean; [key: string]: any }[] | null | undefined;
  valueFmt?: ValueFmt; width?: number; height?: number; note?: React.ReactNode; ariaLabel?: string;
}) {
  const list = (segments || []).filter((s) => s && Number.isFinite(s.value) && s.value > 0);
  const hatchId = useHatchId();
  const [measureRef, W] = useChartWidth(width);
  if (!list.length) return <div ref={measureRef}><EmptyChart text={"Nothing to show -- every part is zero or absent at this window/filters."} /></div>;
  const withColor = list.map((s, i) => ({ ...s, color: s.color || (s.untagged ? CHART_UNTAGGED_LINE : paletteColor(i)) }));
  const total = withColor.reduce((s, x) => s + x.value, 0) || 1;
  const fmt = valueFmt || ((v: number) => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 }));
  const legend = withColor.map((s) => ({
    label: `${s.label} · ${((s.value / total) * 100).toFixed(0)}% · ${fmt(s.value)}`,
    color: s.color, hatch: !!s.untagged, bg: CHART_UNTAGGED_BG,
  }));
  const table = {
    columns: [{ key: "label", label: "Part" }, { key: "value", label: "Value", align: "right" }, { key: "pct", label: "Share", align: "right" }],
    rows: withColor.map((s) => ({ label: s.label, value: fmt(s.value), pct: `${((s.value / total) * 100).toFixed(0)}%` })),
  };
  let acc = 0;
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={{ l: 0, r: 0, t: 0, b: 0 }}
      legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="meter" forceLegend
      renderPlot={() => (
        <>
          <defs>
            <HatchDef id={hatchId} />
            <clipPath id={`${hatchId}-clip`}><rect x="0" y="0" width={W} height={height} rx="6" ry="6" /></clipPath>
          </defs>
          <g clipPath={`url(#${hatchId}-clip)`}>
            {withColor.map((s, i) => {
              const w = (s.value / total) * W;
              const x = acc;
              acc += w;
              const fill = s.untagged ? `url(#${hatchId})` : s.color;
              return (
                <g key={i}>
                  <rect x={x} y={0} width={w} height={height} fill={fill} />
                  <title>{tipText({ name: s.label, value: fmt(s.value), basis: `${((s.value / total) * 100).toFixed(0)}%` })}</title>
                </g>
              );
            })}
          </g>
        </>
      )}
    />
    </div>
  );
}

// ─────────── Heatmap({rows, cols, value, bins}) -- section 5's own prop names. `value` is a 2-D
// array value[rowIndex][colIndex]; a cell that is undefined/null (not 0) is "no data" and hatched,
// never coloured --seq-0 (that is reserved for a real, verified zero). Rows show "name
// (abcd…wxyz)" in a left column; a right total column sums each row; the legend lists the bin
// edges plus 0 and "No data". ───────────
export function Heatmap({ rows, cols, value, bins, valueFmt, width, note }: {
  rows: any[] | null | undefined; cols: any[] | null | undefined; value: any[][] | null | undefined; bins?: number;
  valueFmt?: (v: any) => string; width?: number; note?: React.ReactNode;
}) {
  const R = rows || [], C = cols || [];
  const hatchId = useHatchId();
  const [measureRef, W] = useChartWidth(width || 760);
  if (!R.length || !C.length) return <div ref={measureRef}><EmptyChart text={"Nothing to show -- no rows or columns in this window."} /></div>;
  const colLabel = (c: any) => (c && typeof c === "object" ? c.label : c);
  // Review round 1: `r.name || r` reads the whole ROW OBJECT as the name whenever it has none
  // (renders as "[object Object]") -- a row is either a plain id/name string, or an object that
  // may or may not carry `.name`.
  const rowName = (r: any) => (r && typeof r === "object" ? r.name : r);
  const get = (ri: number, ci: number) => { const row = value && value[ri]; return row ? row[ci] : undefined; };
  const nBins = bins || 5;
  const fmt = valueFmt || ((v: any) => (v == null ? "" : Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 })));
  const allVals: number[] = [];
  R.forEach((_, ri) => C.forEach((_, ci) => { const v = get(ri, ci); if (v > 0) allVals.push(v); }));
  const max = allVals.length ? Math.max(...allVals) : 1;
  const min = allVals.length ? Math.min(...allVals) : 0;
  const edges: number[] = [];
  for (let i = 0; i <= nBins; i++) edges.push(min + ((max - min) * i) / nBins);
  const seqVar = (i: number) => `var(--seq-${Math.max(0, Math.min(5, i))})`;
  function binColor(v: any) {
    if (v === undefined || v === null) return null;
    if (!(v > 0)) return seqVar(0);
    for (let i = 1; i <= nBins; i++) { if (v <= edges[i] || i === nBins) return seqVar(i); }
    return seqVar(nBins);
  }
  const labelW = 180, totalW = 64, padT = 4, padR = 8, gap = 2, rowH = 22;
  const availPlot = Math.max(100, W - labelW - totalW - padR);
  let cellW = availPlot / C.length;
  cellW = Math.max(10, Math.min(26, cellW));
  const plotW = cellW * C.length;
  // Review round 1: `w = width || (...)` kept the CALLER's requested width even when the 10px
  // cellW floor needed more room than that -- 90 columns need >=900px of plot alone, so cells and
  // the total column painted past the edge of a narrower requested viewBox. The svg's own width
  // must always be what its content actually needs; `W` (measured, or the width prop before the
  // first measurement) only decides how roomy each cell CAN be, never how wide the chart ends up.
  const w = labelW + plotW + totalW + padR;
  const height = padT + R.length * (rowH + gap) + 26;
  const rowTotal = (ri: number) => C.reduce((s, _, ci) => { const v = get(ri, ci); return s + (v > 0 ? v : 0); }, 0);
  // section 5: "at 90 days cells shrink to ~10px and x labels go weekly" -- approximated here as an
  // even stride (rather than detecting real calendar weeks) so labels never overlap however many
  // columns are passed in.
  const stride = Math.max(1, Math.ceil(C.length / 10));
  const legend = [
    { label: "0", color: seqVar(0) },
    ...Array.from({ length: nBins }, (_, i) => ({ label: `${fmt(edges[i])}–${fmt(edges[i + 1])}`, color: seqVar(i + 1) })),
    { label: "No data", color: CHART_UNTAGGED_LINE, bg: CHART_UNTAGGED_BG, hatch: true },
  ];
  const table = {
    columns: [{ key: "row", label: "Name" }, ...C.map((c, ci) => ({ key: `c${ci}`, label: String(colLabel(c)), align: "right" })), { key: "total", label: "Total", align: "right" }],
    rows: R.map((r, ri) => {
      const row: Record<string, any> = { row: chartLabel(rowName(r), r.id) };
      C.forEach((c, ci) => { row[`c${ci}`] = fmt(get(ri, ci)); });
      row.total = fmt(rowTotal(ri));
      return row;
    }),
  };
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={w} height={height} pad={{ l: 0, r: 0, t: 0, b: 0 }}
      legend={legend} table={table} note={note} ariaLabel="Heatmap" className="heat"
      renderPlot={() => (
        <>
          <defs><HatchDef id={hatchId} /></defs>
          {R.map((r, ri) => {
            const y = padT + ri * (rowH + gap);
            const label = chartLabel(rowName(r), r.id);
            return (
              <g key={ri}>
                <foreignObject x={0} y={y} width={labelW - 8} height={rowH}>
                  <div className="heat-row-label" style={{ lineHeight: `${rowH}px` }} title={label}>{truncateLeft(label, labelW - 12)}</div>
                </foreignObject>
                {C.map((c, ci) => {
                  const v = get(ri, ci);
                  const col = binColor(v);
                  const x = labelW + ci * cellW;
                  const fill = col === null ? `url(#${hatchId})` : col;
                  return (
                    <rect key={ci} x={x} y={y} width={Math.max(0, cellW - gap)} height={rowH} fill={fill} rx="2" ry="2">
                      <title>{tipText({ name: rowName(r), id: r.id, date: colLabel(c), value: fmt(v) })}</title>
                    </rect>
                  );
                })}
                <text x={labelW + C.length * cellW + 10} y={y + rowH / 2 + 4} textAnchor="start" className="heat-total">
                  {fmt(rowTotal(ri))}
                </text>
              </g>
            );
          })}
          {C.map((c, ci) => (
            (ci % stride === 0 || ci === C.length - 1) && (
              <text key={ci} x={labelW + ci * cellW + cellW / 2} y={height - 6} textAnchor="middle" className="cf-xtick">
                {String(colLabel(c))}
              </text>
            )
          ))}
        </>
      )}
    />
    </div>
  );
}

// ─────────── Icicle -- the tag rollup (section 5): a left-to-right partition, 4 levels, each
// parent folded to its top 5 children + Other + hatched Untagged (never folded into Other). Colour
// comes from the level-1 ancestor and is assigned once from the true root (`assignIcicleColors`),
// cached on each node as `_color`/`_folded`, so zooming in/out never re-ranks or re-colours a
// bucket already on screen. Click a block with children to zoom; the breadcrumb zooms back out.
// The Table view is the same tree as an indented bar list. ───────────
export const ICICLE_COLS = 4;
export interface IcicleNode {
  name?: any;
  value: number;
  children?: IcicleNode[];
  untagged?: boolean;
  isOther?: boolean;
  isUntagged?: boolean;
  _color?: string;
  _folded?: IcicleNode[];
  [key: string]: any;
}
export function foldChildren(children: IcicleNode[] | null | undefined, n?: number): IcicleNode[] {
  const list = (children || []).filter((c) => c && Number.isFinite(c.value) && c.value > 0);
  const untagged = list.filter((c) => c.untagged);
  const rest = list.filter((c) => !c.untagged).sort((a, b) => b.value - a.value);
  const head = rest.slice(0, n || 5);
  const tail = rest.slice(n || 5);
  const tailTotal = tail.reduce((s, c) => s + c.value, 0);
  const out = head.slice();
  if (tailTotal > 0) out.push({ name: "Other", value: tailTotal, isOther: true, children: [] });
  untagged.forEach((c) => out.push({ ...c, isUntagged: true }));
  return out;
}
// Builds a fresh, coloured COPY of the tree -- never mutates the caller's `root` (review round 1:
// the old assignIcicleColors wrote `_color`/`_folded` onto the caller's own node objects on every
// render, rebuilding new Other/Untagged objects each time; a zoomChain entry captured from an
// earlier render could end up pointing at a node no other render still uses). Two more fixes live
// here: (a) a level-1 Untagged node's OWN colour, and every one of its descendants regardless of
// their own tag, is the untagged hatch line -- not paletteColor(i)/CHART_OTHER_COLOR, which used to
// paint an untagged account's warehouse-tag children in the top bucket's ordinary blue; (b) a
// parent whose value exceeds its children's sum (spend that never broke down any further at the
// next level) gets an extra synthetic "Untagged" leaf for the remainder, so that gap stays visible
// instead of the layout silently stretching the real children to fill 100% of the parent.
export function buildIcicleTree(node: IcicleNode, depth: number, color: string | null, parentUntagged?: boolean): IcicleNode {
  const untagged = !!node.isUntagged || !!parentUntagged;
  const nodeColor = depth === 0 ? "var(--surface-3)" : (untagged ? CHART_UNTAGGED_LINE : color!);
  const kids = foldChildren(node.children, 5);
  const sum = kids.reduce((s, k) => s + k.value, 0);
  // Only a genuinely MODELED level (the data actually named a `children` array for this node, even
  // an empty one) can have an "implicit untagged" gap -- a synthetic Other/Untagged bucket this
  // function itself just built has no real children data at all (Array.isArray is false, since the
  // remainder leaf below carries no `children` key), so it never recurses into inventing its own
  // 100%-remainder child underneath itself.
  const modeled = Array.isArray(node.children) && !node.isOther && !node.isUntagged;
  const remainder = modeled ? Math.max(0, (node.value || 0) - sum) : 0;
  const built = kids.map((k, i) => {
    const kColor = depth === 0 ? (k.isOther ? CHART_OTHER_COLOR : paletteColor(i)) : nodeColor;
    return buildIcicleTree(k, depth + 1, kColor, untagged);
  });
  if (remainder > 0 && depth < ICICLE_COLS - 1) {
    built.push(buildIcicleTree({ name: "Untagged", value: remainder, isUntagged: true }, depth + 1, CHART_UNTAGGED_LINE, true));
  }
  return { ...node, _color: nodeColor, _folded: built, isUntagged: untagged };
}
export function Icicle({ root, width = 760, height = 280, valueFmt, note, ariaLabel }: {
  root?: IcicleNode | null; width?: number; height?: number; valueFmt?: ValueFmt; note?: React.ReactNode; ariaLabel?: string;
}) {
  const fmt = valueFmt || ((v: number) => "$" + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 }));
  const empty = !root || !Number.isFinite(root.value) || root.value <= 0;
  // A stable placeholder (memoized once) when there is nothing to show, so the hooks below never
  // see a fresh object identity every render while `empty` stays true (that would re-fire the
  // reset effect forever). Real data flows straight through as `root` itself.
  const emptyPlaceholder = React.useMemo((): IcicleNode => ({ name: "Account", value: 0, children: [] }), []);
  const safeRoot = empty ? emptyPlaceholder : root!;
  const coloredRoot = React.useMemo(() => buildIcicleTree(safeRoot, 0, null, false), [safeRoot]);
  const [zoomChain, setZoomChain] = React.useState(() => [coloredRoot]);
  const hatchId = useHatchId();
  const [measureRef, W] = useChartWidth(width);
  useThemeVersion(); // ink (inkForFill) is read at render time; re-render once after a toggle.
  // A new `root` (a filter/window change upstream) resets the zoom -- otherwise a stale zoomChain
  // could point at nodes that no longer exist in the new tree.
  React.useEffect(() => { setZoomChain([coloredRoot]); }, [coloredRoot]);

  if (empty) return <div ref={measureRef}><EmptyChart text={"Nothing to show -- every value is zero or absent at this window/filters."} /></div>;

  const base = zoomChain[zoomChain.length - 1] || coloredRoot;
  const cols = ICICLE_COLS;
  const colW = W / cols;
  const gap = 2;
  const crumbH = 22;
  const plotH = height - crumbH;

  interface IcicleBlock { node: IcicleNode; depth: number; x: number; y: number; w: number; h: number; chain: IcicleNode[] }
  function layout(node: IcicleNode, depth: number, y: number, h: number, chain: IcicleNode[]): IcicleBlock[] {
    const out: IcicleBlock[] = [{ node, depth, x: depth * colW, y, w: colW - gap, h, chain }];
    if (depth >= cols - 1 || !node._folded || !node._folded.length) return out;
    const total = node._folded.reduce((s, k) => s + k.value, 0) || 1;
    let acc = y;
    node._folded.forEach((k) => {
      const kh = (k.value / total) * h;
      out.push(...layout(k, depth + 1, acc, kh, [...chain, k]));
      acc += kh;
    });
    return out;
  }
  const blocks = layout(base, 0, 0, plotH, [base]);

  interface IcicleFlatRow { depth: number; name: any; value: number; isUntagged: boolean }
  function flatten(node: IcicleNode, depth: number, out: IcicleFlatRow[]) {
    out.push({ depth, name: node.name || (depth === 0 ? "Account" : ""), value: node.value, isUntagged: !!node.isUntagged });
    (node._folded || []).forEach((k) => flatten(k, depth + 1, out));
  }
  const flat: IcicleFlatRow[] = [];
  flatten(base, 0, flat);
  const table = {
    columns: [{ key: "name", label: "Name" }, { key: "value", label: "Value", align: "right" }],
    rows: flat.map((r) => ({
      name: `${" ".repeat(r.depth)}${r.depth > 0 ? "— " : ""}${r.name}${r.isUntagged ? " (untagged)" : ""}`,
      value: fmt(r.value),
    })),
  };
  const legend = base._folded && base._folded.length >= 2
    ? base._folded.map((k) => ({ label: k.name, color: k.isUntagged ? CHART_UNTAGGED_LINE : k._color, hatch: !!k.isUntagged, bg: CHART_UNTAGGED_BG }))
    : null;

  return (
    <div className="icicle-wrap" ref={measureRef}>
      <div className="icicle-crumb">
        {zoomChain.map((n, i) => (
          <React.Fragment key={i}>
            {i > 0 && <span className="icicle-sep">/</span>}
            <button
              type="button" className="icicle-crumb-btn"
              disabled={i === zoomChain.length - 1}
              onClick={() => setZoomChain(zoomChain.slice(0, i + 1))}
            >
              {i === 0 ? (n.name || "Account") : n.name}
            </button>
          </React.Fragment>
        ))}
      </div>
      <ChartFrame
        width={W} height={plotH} pad={{ l: 0, r: 0, t: 0, b: 0 }}
        legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="icicle"
        renderPlot={() => (
          <>
            <defs><HatchDef id={hatchId} /></defs>
            {blocks.map((b, i) => {
              const canZoom = b.depth < cols - 1 && b.node._folded && b.node._folded.length > 0 && b.node !== base;
              const isHatch = !!b.node.isUntagged;
              const fill = isHatch ? `url(#${hatchId})` : b.node._color;
              const bh = Math.max(0, b.h - gap);
              const showLabel = bh >= 18;
              const pct = base.value ? `${((b.node.value / base.value) * 100).toFixed(0)}%` : "";
              const label = b.depth === 0 ? (b.node.name || "Account") : `${b.node.name} · ${fmt(b.node.value)} · ${pct}`;
              const ink = inkForFill(isHatch ? CHART_UNTAGGED_BG : fill!);
              const tip = tipText({ name: b.node.name || "Account", value: fmt(b.node.value), basis: pct });
              return (
                <g key={i} onClick={canZoom ? () => setZoomChain([...zoomChain, ...b.chain.slice(1)]) : undefined} className={canZoom ? "icicle-zoomable" : ""}>
                  <rect x={b.x} y={b.y} width={Math.max(0, b.w)} height={bh} fill={fill} />
                  {showLabel && (
                    <foreignObject x={b.x + 4} y={b.y} width={Math.max(0, b.w - 8)} height={bh}>
                      <div className="icicle-label" style={{ color: ink, lineHeight: `${bh}px` }}>{label}</div>
                    </foreignObject>
                  )}
                  <title>{tip}</title>
                </g>
              );
            })}
          </>
        )}
      />
    </div>
  );
}

// ─────────── DivergingBars -- top movers vs the previous window, --div-up (more) / --div-down
// (less) around a zero axis. ───────────
export function DivergingBars({ items, n = 8, valueFmt, unitLabel, width = 760, note, ariaLabel }: {
  items: ChartItem[] | null | undefined; n?: number; valueFmt?: ValueFmt; unitLabel?: string; width?: number; note?: React.ReactNode; ariaLabel?: string;
}) {
  const list = (items || []).filter((it) => it && Number.isFinite(it.value) && it.value !== 0);
  const [measureRef, W] = useChartWidth(width);
  if (!list.length) return <div ref={measureRef}><EmptyChart text={"Nothing to show -- no change to rank in this window."} /></div>;
  const sorted = [...list].sort((a, b) => Math.abs(b.value) - Math.abs(a.value)).slice(0, n);
  const fmt = valueFmt || ((v: number) => (v > 0 ? "+" : "") + Number(v).toLocaleString(undefined, { maximumFractionDigits: 0 }));
  const labelW = rowLabelWidth(W, sorted.map((it) => chartLabel(it.name, it.id)), 90), rowH = 26, barH = 18, padTop = 4, padBottom = 4;
  const height = padTop + sorted.length * rowH + padBottom;
  // Review round 1: at plotX = labelW+10, the biggest negative bar's leftmost edge sits exactly at
  // plotX (right against the name column) and its value label, end-anchored 6px further left, sat
  // ON the name column's own text. 70px on each side leaves enough room for a value label on
  // either the most-positive or the most-negative bar.
  const plotX = labelW + 70, plotW = Math.max(40, W - plotX - 70);
  const axisX = plotX + plotW / 2;
  const maxAbs = maxOrOne(sorted.map((it) => Math.abs(it.value)));
  const pxPerUnit = (plotW / 2) / maxAbs;
  const legend = [
    { label: "More than the previous window", color: "var(--div-up)" },
    { label: "Less than the previous window", color: "var(--div-down)" },
  ];
  const table = {
    columns: [{ key: "name", label: "Name" }, { key: "value", label: unitLabel || "Change", align: "right" }],
    rows: sorted.map((it) => ({ name: chartLabel(it.name, it.id), value: fmt(it.value) })),
  };
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={{ l: 0, r: 0, t: 0, b: 0 }}
      legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="dbar"
      renderPlot={() => (
        <>
          <line x1={axisX} y1={0} x2={axisX} y2={height} stroke="var(--axis)" strokeWidth="1" />
          {sorted.map((it, i) => {
            const y = padTop + i * rowH;
            const barY = y + (rowH - barH) / 2;
            const w = Math.abs(it.value) * pxPerUnit;
            const up = it.value > 0;
            const x = up ? axisX : axisX - w;
            const color = up ? "var(--div-up)" : "var(--div-down)";
            const tip = tipText({ name: it.name, id: it.id, value: fmt(it.value), basis: unitLabel });
            const tipLabel = chartLabel(it.name, it.id);
            return (
              <g key={i}>
                <foreignObject x={0} y={y} width={labelW} height={rowH}>
                  <div className="rb-label" title={tipLabel} style={{ lineHeight: `${rowH}px` }}>{truncateLeft(tipLabel, labelW - 8)}</div>
                </foreignObject>
                <RoundRect x={x} y={barY} w={w} h={barH} r={4} fill={color} squareEdge={up ? "left" : "right"} title={tip} />
                <text x={up ? x + w + 6 : x - 6} y={barY + barH / 2} dominantBaseline="middle" textAnchor={up ? "start" : "end"} className="rb-value">
                  {fmt(it.value)}
                </text>
              </g>
            );
          })}
        </>
      )}
    />
    </div>
  );
}

// ─────────── Dumbbell -- earlier median (hollow) -> now (filled), per job duration regression. ──
// `only` keeps one direction: a "running slower" chart draws only slower rows (the default), never
// faster ones that happen to rank on the size of their change.
export function Dumbbell({ items, n = 8, valueFmt, unitLabel, width = 760, note, ariaLabel, only = "slower", emptyText }: {
  items: { name?: any; id?: any; before: number; after: number; [key: string]: any }[] | null | undefined;
  n?: number; valueFmt?: ValueFmt; unitLabel?: string; width?: number; note?: React.ReactNode; ariaLabel?: string;
  only?: "slower" | "faster" | "all"; emptyText?: string;
}) {
  const list = (items || []).filter((it) => it && Number.isFinite(it.before) && Number.isFinite(it.after))
    .filter((it) => (only === "slower" ? it.after > it.before : only === "faster" ? it.after < it.before : true));
  const [measureRef, W] = useChartWidth(width);
  if (!list.length) {
    const dflt = only === "slower" ? "Nothing ran slower than before in this window." : only === "faster" ? "Nothing ran faster than before in this window." : "Nothing to show -- no earlier/now pair in this window.";
    return <div ref={measureRef}><EmptyChart text={emptyText || dflt} /></div>;
  }
  const sorted = [...list].sort((a, b) => Math.abs(b.after - b.before) - Math.abs(a.after - a.before)).slice(0, n);
  const fmt = valueFmt || ((v) => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 }));
  const labelW = rowLabelWidth(W), rowH = 30, padTop = 4, padBottom = 4;
  // Review round 1: ChartFrame was given pad={l:0,r:0,t:0,b:0} while xLabels ("0"/mid/max) render
  // at ChartFrame's OWN P.l/(width-P.r) -- with a zero pad that's x=0 (on the name column) and
  // x=width (past the real plot's own right edge at plotX+plotW), and the +26px row ChartFrame
  // reserves for them had no matching gap in this height, so they sat on the last dumbbell's row.
  // Passing the SAME plotX/70 as this chart's own pad -- and 26 extra px of height for that row --
  // makes ChartFrame draw "0"/mid/max exactly where the geometry below actually starts/ends.
  const height = padTop + sorted.length * rowH + padBottom + 26;
  const plotX = labelW + 10, plotW = Math.max(40, W - plotX - 70);
  const max = maxOrOne(sorted.flatMap((it) => [it.before, it.after]));
  const pxPerUnit = plotW / max;
  const legend = [
    only !== "faster" ? { label: "Slower than before", color: "var(--div-up)" } : null,
    only !== "slower" ? { label: "Faster than before", color: "var(--div-down)" } : null,
  ].filter((l): l is { label: string; color: string } => !!l);
  // A narrow card keeps only the two end ticks, so they never run into each other.
  const xTicks = plotW < 260 ? ["0", fmt(max)] : ["0", fmt(max / 2), fmt(max)];
  const table = {
    columns: [{ key: "name", label: "Name" }, { key: "before", label: "Earlier median", align: "right" }, { key: "after", label: "Now", align: "right" }],
    rows: sorted.map((it) => ({ name: chartLabel(it.name, it.id), before: fmt(it.before), after: fmt(it.after) })),
  };
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={{ l: plotX, r: 70, t: 0, b: 26 }}
      xLabels={xTicks} legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="dumb" forceLegend
      renderPlot={() => (
        <>
          {sorted.map((it, i) => {
            const y = padTop + i * rowH + rowH / 2;
            const x0 = plotX + it.before * pxPerUnit;
            const x1 = plotX + it.after * pxPerUnit;
            const up = it.after > it.before;
            const color = up ? "var(--div-up)" : "var(--div-down)";
            const tip = tipText({ name: it.name, id: it.id, value: `${fmt(it.before)} → ${fmt(it.after)}`, basis: unitLabel });
            const tipLabel = chartLabel(it.name, it.id);
            return (
              <g key={i}>
                <foreignObject x={0} y={y - rowH / 2} width={labelW} height={rowH}>
                  <div className="rb-label" title={tipLabel} style={{ lineHeight: `${rowH}px` }}>{truncateLeft(tipLabel, labelW - 8)}</div>
                </foreignObject>
                <line x1={x0} y1={y} x2={x1} y2={y} stroke={color} strokeWidth="2" />
                <circle cx={x0} cy={y} r="4" fill="var(--surface)" stroke={color} strokeWidth="2" />
                <circle cx={x1} cy={y} r="4" fill={color} />
                <title>{tip}</title>
              </g>
            );
          })}
        </>
      )}
    />
    </div>
  );
}

// ─────────── Scatter -- size by value, colour by up to 3 categories (a 4th+ falls back to
// --c-other rather than inventing a 4th hue), top 5 by size labelled directly on the plot. ───────
export function Scatter({ items, xLabel, yLabel, valueFmt, width = 760, height = 280, note, ariaLabel }: {
  items: { name?: any; id?: any; x: number; y: number; size?: any; category?: string | null; [key: string]: any }[] | null | undefined;
  xLabel?: string; yLabel?: string; valueFmt?: (v: any) => string; width?: number; height?: number; note?: React.ReactNode; ariaLabel?: string;
}) {
  const list = (items || []).filter((it) => it && Number.isFinite(it.x) && Number.isFinite(it.y));
  const [measureRef, W] = useChartWidth(width);
  if (!list.length) return <div ref={measureRef}><EmptyChart text={"Nothing to show -- no rows in this window."} /></div>;
  const fmt = valueFmt || ((v) => Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 }));
  const cats: string[] = [];
  const catColor: Record<string, string> = {};
  list.forEach((it) => {
    const key = it.category || "";
    if (!(key in catColor)) { catColor[key] = cats.length < 3 ? paletteColor(cats.length) : CHART_OTHER_COLOR; cats.push(key); }
  });
  // Review round 1: t/b grew (10->22, 26->40) to make room for the axis titles below -- xLabel/
  // yLabel used to reach the reader only through the table and tooltips; the plot itself had no
  // titles at all.
  const P = { l: 48, r: 16, t: 22, b: 40 };
  const innerW = W - P.l - P.r, innerH = height - P.t - P.b;
  const xs = list.map((it) => it.x), ys = list.map((it) => it.y);
  const xMin = Math.min(...xs, 0), xMax = Math.max(...xs, 1);
  const yTv = niceTicks(Math.min(...ys, 0), Math.max(...ys, 1), 4);
  const yStep = yTv.length > 1 ? yTv[1] - yTv[0] : undefined;
  const yLo = yTv[0], yHi = yTv[yTv.length - 1];
  const yOf = (v: number) => P.t + innerH - ((v - yLo) / ((yHi - yLo) || 1)) * innerH;
  const xOf = (v: number) => P.l + ((v - xMin) / ((xMax - xMin) || 1)) * innerW;
  const sizes = list.map((it) => Number(it.size) || 0);
  const maxSize = maxOrOne(sizes);
  const rOf = (v: number) => 4 + Math.sqrt(Math.max(0, v) / maxSize) * 12;
  const top5 = new Set([...list].sort((a, b) => (Number(b.size) || 0) - (Number(a.size) || 0)).slice(0, 5));
  const legend = cats.filter((c) => c).length >= 2 ? cats.filter((c) => c).map((c) => ({ label: c, color: catColor[c] })) : null;
  const table = {
    columns: [
      { key: "name", label: "Name" }, { key: "x", label: xLabel || "X", align: "right" },
      { key: "y", label: yLabel || "Y", align: "right" }, { key: "size", label: "Size", align: "right" }, { key: "cat", label: "Category" },
    ],
    rows: list.map((it) => ({ name: chartLabel(it.name, it.id), x: fmt(it.x), y: fmt(it.y), size: fmt(it.size), cat: it.category || "" })),
  };
  return (
    <div ref={measureRef}>
    <ChartFrame
      width={W} height={height} pad={P}
      yTicks={yTv.map((t) => ({ y: yOf(t), value: t, label: compactTick(t, yStep) }))}
      xLabels={[fmt(xMin), fmt((xMin + xMax) / 2), fmt(xMax)]}
      legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="scatter"
      renderPlot={() => (
        <>
          {yLabel && <text x={P.l} y={12} textAnchor="start" className="cf-xtick">{yLabel}</text>}
          {xLabel && <text x={(P.l + W - P.r) / 2} y={height - 20} textAnchor="middle" className="cf-xtick">{xLabel}</text>}
          {list.map((it, i) => {
            const cx = xOf(it.x), cy = yOf(it.y), r = rOf(it.size);
            const fill = catColor[it.category || ""];
            const tip = tipText({ name: it.name, id: it.id, value: `${xLabel || "x"} ${fmt(it.x)}, ${yLabel || "y"} ${fmt(it.y)}`, basis: it.category });
            return (
              <g key={i}>
                <circle cx={cx} cy={cy} r={r} fill={fill} opacity="0.82" stroke="var(--surface)" strokeWidth="1">
                  <title>{tip}</title>
                </circle>
                {top5.has(it) && <text x={cx + r + 4} y={cy + 4} className="scatter-label">{chartLabel(it.name, it.id)}</text>}
              </g>
            );
          })}
        </>
      )}
    />
    </div>
  );
}

// ─────────── AnomalyChart -- daily credits against Snowflake's expected upper bound. Markers: a triangle
// where Snowflake flags the day, a dot where this audit's own spike test does. A day with no Snowflake row
// yet (its view lags up to 8 hours) draws no bound. Reads sf_cost_anomalies_vs_spikes rows as they are. ───────────
export function AnomalyChart({ rows, width = 760, height = 220, partialDay, note, ariaLabel }: {
  rows: Row[] | null | undefined; width?: number; height?: number; partialDay?: string | null; note?: React.ReactNode; ariaLabel?: string;
}) {
  const [measureRef, W] = useChartWidth(width);
  const list = (rows || []).filter((r) => r && r.usage_date);
  if (!list.length) return <div ref={measureRef}><EmptyChart text="Nothing to show for this window." /></div>;
  const byDay = new Map<string, { our: number; bound: number | null; sfAnom: boolean; ourSpike: boolean }>();
  list.forEach((r) => {
    const d = String(r.usage_date).slice(0, 10);
    const cur = byDay.get(d) || { our: 0, bound: null, sfAnom: false, ourSpike: false };
    cur.our += Number(r.our_credits) || 0;
    if (r.snowflake_row !== false && r.sf_upper_bound !== null && r.sf_upper_bound !== undefined) cur.bound = (cur.bound || 0) + (Number(r.sf_upper_bound) || 0);
    cur.sfAnom = cur.sfAnom || r.snowflake_anomaly === true;
    cur.ourSpike = cur.ourSpike || r.our_spike === true;
    byDay.set(d, cur);
  });
  const days = [...byDay.keys()].sort();
  const P = { l: 48, r: 8, t: 12, b: 26 };
  const innerW = W - P.l - P.r, innerH = height - P.t - P.b;
  const maxV = maxOrOne(days.flatMap((d) => [byDay.get(d)!.our, byDay.get(d)!.bound || 0]));
  const ticks = niceTicks(0, maxV, 4);
  const top = ticks[ticks.length - 1] || 1;
  const step = ticks.length > 1 ? ticks[1] - ticks[0] : undefined;
  const yOf = (v: number) => P.t + innerH - (v / top) * innerH;
  const xOf = (i: number) => P.l + (days.length > 1 ? (i * innerW) / (days.length - 1) : innerW / 2);
  const ourPath = days.map((d, i) => `${i ? "L" : "M"}${xOf(i).toFixed(1)} ${yOf(byDay.get(d)!.our).toFixed(1)}`).join(" ");
  // The bound line breaks where a day has no Snowflake row.
  let boundPath = "", pen = false;
  days.forEach((d, i) => {
    const b = byDay.get(d)!.bound;
    if (b === null) { pen = false; return; }
    boundPath += `${pen ? "L" : "M"}${xOf(i).toFixed(1)} ${yOf(b).toFixed(1)} `;
    pen = true;
  });
  const legend = [
    { label: "Credits per day", color: "var(--c1)" },
    { label: "Snowflake upper bound", color: "var(--c-other)" },
    { label: "Snowflake flags the day", color: "var(--st-warn)" },
    { label: "Audit spike", color: "var(--c2)" },
  ];
  const table = {
    columns: [{ key: "day", label: "Day" }, { key: "our", label: "Credits", align: "right" }, { key: "bound", label: "Upper bound", align: "right" }, { key: "flag", label: "Flagged by" }],
    rows: days.map((d) => {
      const v = byDay.get(d)!;
      return { day: d, our: fmtCredits(v.our), bound: v.bound === null ? "-" : fmtCredits(v.bound), flag: [v.sfAnom ? "Snowflake" : null, v.ourSpike ? "audit" : null].filter(Boolean).join(" and ") || "-" };
    }),
  };
  return (
    <div ref={measureRef}>
      <ChartFrame
        width={W} height={height} pad={P}
        yTicks={ticks.map((t) => ({ y: yOf(t), value: t, label: compactTick(t, step) }))}
        zeroY={yOf(0)} xLabels={[days[0], days[Math.floor((days.length - 1) / 2)], days[days.length - 1]].map(fmtDayShort)}
        legend={legend} table={table} note={note} ariaLabel={ariaLabel} className="cols"
        renderPlot={() => (
          <>
            {boundPath && <path d={boundPath} fill="none" stroke="var(--c-other)" strokeWidth="1.6" strokeDasharray="5 4" />}
            <path d={ourPath} fill="none" stroke="var(--c1)" strokeWidth="1.8" />
            {days.map((d, i) => {
              const v = byDay.get(d)!;
              const partial = partialDay === d;
              return (
                <g key={d}>
                  <circle cx={xOf(i)} cy={yOf(v.our)} r={partial ? 3 : 2} fill={partial ? "var(--bg, #fff)" : "var(--c1)"} stroke="var(--c1)">
                    <title>{`${d}${partial ? " (partial)" : ""}: ${fmtCredits(v.our)}${v.bound === null ? ", no Snowflake bound yet" : `, Snowflake upper bound ${fmtCredits(v.bound)}`}`}</title>
                  </circle>
                  {v.sfAnom && <text x={xOf(i)} y={Math.max(P.t, yOf(v.our) - 8)} textAnchor="middle" className="cols-marker">{"▲"}<title>{`${d}: Snowflake flags this day`}</title></text>}
                  {v.ourSpike && <circle cx={xOf(i)} cy={yOf(v.our)} r="5" fill="none" stroke="var(--c2)" strokeWidth="1.6"><title>{`${d}: audit spike`}</title></circle>}
                </g>
              );
            })}
          </>
        )}
      />
    </div>
  );
}
