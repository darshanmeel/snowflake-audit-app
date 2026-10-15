// web/src/format.tsx -- scalar formatters. Every formatter returns "-" for null/undefined/NaN/
// anything that is not really a number, never a fabricated "$0"/"0%"/"0 credits" that would read as
// a verified zero, and never a bare "NaN" printed because a non-numeric value was handed to a
// magnitude formatter. fmtCell's "money" branch is the one exception: a missing money cell gets its
// own, more specific words.

// Numbers are formatted in a FIXED locale, never the viewer's. toLocaleString(undefined, ...)
// takes the browser's locale, so on a European machine 33096 ms rendered as "33.096" -- which
// reads as 33 milliseconds for 61 queries (observed 2026-09-22). In an audit tool the same
// figure must not change meaning between two people's screens, and the "." / "," ambiguity is a
// real misreading risk on money. Consistency beats localisation here.
import { fmtChangePct } from "./components/hooks";
import { Tip } from "./components/primitives";
import { columnEnumLabel } from "./components/labels";
import type { Money, Row } from "./types";

export const LOCALE = "en-US";

export function isMissing(v: any) {
  return v === null || v === undefined || (typeof v === "number" && Number.isNaN(v));
}

// The one gate every magnitude formatter shares: true for a real finite number, or a string that
// parses cleanly to one. A raw server value can be a non-numeric string (a text or timestamp column
// whose NAME happens to look like a magnitude), and Number("2026-09-24T00:00:00") is NaN, which
// would print the literal text "NaN". A value that fails this gate is treated like a missing one
// (still just "-"); fmtCell knows what to show instead (its text/date fallback, below).
export function isNumericValue(v: any) {
  if (typeof v === "number") return Number.isFinite(v);
  if (typeof v === "string") {
    const s = v.trim();
    if (s === "") return false;
    return Number.isFinite(Number(s));
  }
  return false;
}

// Plain money formatting -- missing -> "-", a real zero -> "$0", same as every other magnitude
// formatter below. Used throughout the tiles/charts for a SUM/aggregate figure, where a zero
// already has an established meaning from the outcome branch that gated the call (e.g. "no rows
// matched this window") rather than "this one row's price was $0" -- fmtCell's own "money" branch
// is where that per-row free-vs-unpriced distinction actually belongs (see its comment).
export function fmtMoney(value: any, decimals = 0) {
  if (!isNumericValue(value)) return "-";
  const n = Number(value);
  const sign = n < 0 ? "-" : "";
  // A real but tiny amount must not read as a clean $0.
  if (decimals === 0 && n !== 0 && Math.abs(n) < 0.5) return `${sign}<$1`;
  return `${sign}$${Math.abs(n).toLocaleString(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}`;
}

// "effective $/credit" at the 0% default (dollars are credits times the account's effective price,
// read from the organization billing view where the role can see it, else the price given to the
// export), or "what-if: effective $/credit, -X%" once the Settings discount is set away from 0.
// X is the percentage to one decimal, trailing zeros dropped (12.5% stays "-12.5%").
export function estLabel(discountPct: any) {
  const d = Number(discountPct);
  if (!d) return "effective $/credit";
  const pctOff = Math.round(d * 1000) / 10;
  return `what-if: effective $/credit, -${pctOff}%`;
}

// A money figure in its own currency: "$" for list-price dollars, the currency code for an invoice
// amount. An invoice amount with no currency code and no value reads "-", never the bare words
// "invoice currency 0" as a headline.
export function fmtMoneyOf(m: Money | null | undefined, value: any, decimals?: number) {
  if (!m || m.unit !== "currency") return fmtMoney(value, decimals);
  if (!isNumericValue(value)) return "-";
  const n = fmtMoney(value, decimals).replace("$", "");
  if (m.currency) return `${m.currency} ${n}`;
  return Number(value) === 0 ? "-" : `${n} (invoice currency)`;
}

// Credits, the unit Snowflake bills in.
export function fmtCredits(value: any, decimals = 1) {
  if (!isNumericValue(value)) return "-";
  return `${Number(value).toLocaleString(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })} credits`;
}

export function fmtPct(value: any, decimals = 1) {
  if (!isNumericValue(value)) return "-";
  return `${Number(value).toLocaleString(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })}%`;
}

// A change the way people read it: "6.2×" once it has doubled, "new" or "from $5" when there was
// almost nothing before, otherwise a signed percent -- never "+85,205%".
export function fmtChange(current: any, previous: any, money = true) {
  if (!isNumericValue(current) || !isNumericValue(previous)) return "-";
  const cur = Number(current), prev = Number(previous);
  const tiny = money ? 50 : 1;
  if (prev < tiny) {
    if (cur <= 0) return "-";
    return prev > 0 && money ? `from ${fmtMoney(prev, 0)}` : "new";
  }
  return fmtChangePct(((cur - prev) / prev) * 100);
}

// The same change as a phrase against `what` ("the previous period"): "6.2× vs ...", "up from $30
// in ...", "none in ..."; null when there is nothing to compare.
export function fmtChangeVs(current: any, previous: any, what: string) {
  const t = fmtChange(current, previous);
  if (t === "-") return null;
  if (t === "new") return `none in ${what}`;
  if (t.indexOf("from ") === 0) return `${Number(current) >= Number(previous) ? "up" : "down"} ${t} in ${what}`;
  return `${t} vs ${what}`;
}


export function fmtHours(value: any, decimals = 1) {
  if (!isNumericValue(value)) return "-";
  return `${Number(value).toLocaleString(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })} h`;
}

export function fmtGb(value: any, decimals = 2, fromBytes = false) {
  if (!isNumericValue(value)) return "-";
  const v = fromBytes ? Number(value) / 1e9 : Number(value);
  return `${v.toLocaleString(LOCALE, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })} GB`;
}

export function fmtInt(value: any) {
  if (!isNumericValue(value)) return "-";
  return Number(value).toLocaleString(LOCALE);
}

// "$19k" for a badge/pill where a full "$18,955" would not fit -- one decimal only when it changes
// which thousand a reader would round to (e.g. "$1.2k", never "$1.0k").
export function fmtMoneyShort(value: any) {
  if (!isNumericValue(value)) return "-";
  const n = Number(value);
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  if (abs < 1000) return `${sign}$${Math.round(abs)}`;
  const thousands = abs / 1000;
  const decimals = thousands < 10 && Math.round(thousands * 10) % 10 !== 0 ? 1 : 0;
  return `${sign}$${thousands.toFixed(decimals)}k`;
}

// "45 s" / "1 m 08 s" / "2 h 14 m" from a duration in seconds -- ms callers pass seconds = ms/1000.
// Never a bare "134 min" once past an hour, and the seconds component is zero-padded so "1 m 8 s"
// never misreads as eighteen seconds.
export function fmtDuration(seconds: any) {
  if (!isNumericValue(seconds)) return "-";
  const total = Math.round(Number(seconds));
  if (total < 60) return `${total} s`;
  if (total < 3600) {
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m} m ${String(s).padStart(2, "0")} s`;
  }
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  return `${h} h ${m} m`;
}

// "15 Sep" -- a bare YYYY-MM-DD calendar day, no year (a chart axis tick or a short table cell).
// UTC-parsed: a calendar day is never reinterpreted through the viewer's time zone.
export function fmtDayShort(dateStr: any) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(dateStr || ""));
  if (!m) return String(dateStr || "");
  const d = new Date(`${m[1]}-${m[2]}-${m[3]}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return String(dateStr || "");
  return d.toLocaleDateString(LOCALE, { month: "short", day: "numeric", timeZone: "UTC" });
}

// "21 Sep" -- day before month, no year, for a card with no room for fmtDate's year. UTC-parsed;
// the input may carry a trailing time, only the leading YYYY-MM-DD is read.
export function fmtDayMonth(dateStr: any) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(dateStr || ""));
  if (!m) return String(dateStr || "");
  const names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${Number(m[3])} ${names[Number(m[2]) - 1] || m[2]}`;
}

// Adaptive byte size (B/KB/MB/GB/TB): picks the smallest unit that keeps the number readable, so a
// 1,000-byte figure reads "1,000 B", not "0.0 GB". Always takes a raw byte count.
export function fmtBytes(value: any, decimals = 1) {
  if (!isNumericValue(value)) return "-";
  const v = Number(value);
  const abs = Math.abs(v);
  const units: [string, number][] = [["TB", 1e12], ["GB", 1e9], ["MB", 1e6], ["KB", 1e3]];
  for (const [unit, size] of units) {
    if (abs >= size) {
      return `${(v / size).toLocaleString(LOCALE, { minimumFractionDigits: decimals, maximumFractionDigits: decimals })} ${unit}`;
    }
  }
  return `${Math.round(v).toLocaleString(LOCALE)} B`;
}

// `kind` is app/api/service.py's classify_columns: a NAME-only guess (a regex over the column name,
// no look at any value). A text or timestamp column whose name happens to match has no numbers in
// it, so it needs its own fallback, not a magnitude formatter's "-". A bare ISO date or timestamp
// gets a short, fixed-locale reading; anything else prints as plain text. Returns null for anything
// that is not one of those two shapes, so callers can fall back without parsing twice.
export const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const ISO_DATETIME_RE = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$/;
export function fmtDate(value: any) {
  if (typeof value !== "string") return null;
  const s = value.trim();
  if (ISO_DATE_RE.test(s)) {
    const d = new Date(`${s}T00:00:00Z`);
    if (Number.isNaN(d.getTime())) return null;
    return d.toLocaleDateString(LOCALE, { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
  }
  if (ISO_DATETIME_RE.test(s)) {
    // A timestamp with no offset reads as the exact wall time the server wrote, never the viewer's
    // own time zone: parse and render in UTC, and label one that carries an explicit offset "UTC".
    const iso = s.replace(" ", "T");
    const hasOffset = /(Z|[+-]\d{2}:?\d{2})$/.test(iso);
    // A bare timestamp at exactly midnight is a calendar-DAY column (usage_date and friends) that
    // was re-serialised with a spurious "T00:00:00": read it as a bare date, not "12:00 AM".
    if (!hasOffset && /T00:00:00(\.0+)?$/.test(iso)) {
      const dayOnly = new Date(`${iso.slice(0, 10)}T00:00:00Z`);
      if (Number.isNaN(dayOnly.getTime())) return null;
      return dayOnly.toLocaleDateString(LOCALE, { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
    }
    const d = new Date(hasOffset ? iso : `${iso}Z`);
    if (Number.isNaN(d.getTime())) return null;
    const text = d.toLocaleString(LOCALE, { year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "UTC" });
    return hasOffset ? `${text} UTC` : text;
  }
  return null;
}

// A cell whose kind expected a number but whose value is not one: shown as-is, as a formatted date
// when it parses as one, otherwise as plain text, never handed to a magnitude formatter.
export function textOrDateCell(value: any) {
  const asDate = fmtDate(value);
  if (asDate) return asDate;
  if (typeof value === "boolean") return value ? "true" : "false";
  return String(value);
}

// A missing (null/undefined/NaN) cell: an em dash with a hover tip, never a raw "undefined" or
// "null". The magnitude formatters above stay plain strings on purpose (callers interpolate them
// into template literals), so only this cell returns an element.
export function missingCell() {
  return <Tip text="no value"><span className="muted">{"—"}</span></Tip>;
}

// The kinds whose formatter treats its input as a magnitude: each is gated on isNumericValue before
// it reaches its formatter, so a text column that shares a name pattern falls through to
// textOrDateCell instead of printing "NaN <unit>".
export const NUMERIC_CELL_KINDS = new Set<string>(["credits", "pct", "hours", "gb", "gb_bytes"]);

// A money cell is row-aware. An unpriced or not-yet-computed cost is NULL, never a zero, so a NULL
// reads "unpriced" only when the row itself says so (price_basis "unpriced") and otherwise an em
// dash; a real zero stays "$0". Only a row's own price_basis ever produces "(free)" or "unpriced".
export function fmtCell(value: any, kind?: string | null, row?: Row | null) {
  // An empty or whitespace-only string is "no value", like null/undefined/NaN.
  const blank = isMissing(value) || (typeof value === "string" && value.trim() === "");
  if (kind === "money") {
    const priceBasis = row && row.price_basis;
    if (!!row && priceBasis === "free") return "$0 (free)";
    if (blank) {
      if (row && priceBasis === "unpriced") return "unpriced";
      return missingCell();
    }
    if (!isNumericValue(value)) return textOrDateCell(value);
    return fmtMoney(value, 2);
  }
  if (blank) return missingCell();
  // A currency amount is in the row's own currency, never a "$" figure and never added to one.
  if (kind === "currency") {
    if (!isNumericValue(value)) return textOrDateCell(value);
    const n = Number(value).toLocaleString(LOCALE, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return row && row.currency ? `${row.currency} ${n}` : `${n} (invoice currency)`;
  }
  // A root task reads name (id), never the bare id.
  if (kind === "root_task") return row && !isMissing(row.root_task_id) && row.root_task_id !== "" ? `${value} (${row.root_task_id})` : String(value);
  // A warehouse in no SHOW and not dropped is "not visible to this role", never "deleted".
  if (kind === "flag:not_visible") return value === true || value === "true" ? "Not visible to this role" : "Visible";
  if (kind === "flag:dropped") return value === true || value === "true" ? "Dropped" : "No drop event";
  // A known code column (pressure, lever, row kind ...) reads in words; the raw code stays on hover.
  if (typeof kind === "string" && kind.indexOf("enum:") === 0) {
    const word = typeof columnEnumLabel === "function" ? columnEnumLabel(kind.slice(5), value) : null;
    return word ? <Tip text={String(value)}><span>{word}</span></Tip> : String(value);
  }
  if (NUMERIC_CELL_KINDS.has(kind as string) &&
 !isNumericValue(value)) return textOrDateCell(value);
  switch (kind) {
    case "credits": return fmtCredits(value);
    case "pct": return fmtPct(value);
    case "hours": return fmtHours(value);
    case "gb": return fmtGb(value, 2, false);
    case "gb_bytes": return fmtGb(value, 2, true);
    case "id": return String(value);
    default:
      if (typeof value === "number") {
        return Number.isInteger(value) ? fmtInt(value) : value.toLocaleString(LOCALE, { maximumFractionDigits: 3 });
      }
      if (typeof value === "boolean") return value ? "true" : "false";
      // A column with no kind (usage_date and friends): try a date reading first, so it shows
      // "Sep 18, 2026" like every other date in this app.
      return fmtDate(value) || String(value);
  }
}
