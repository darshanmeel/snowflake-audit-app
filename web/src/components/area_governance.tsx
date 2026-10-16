// web/src/components/area_governance.tsx -- the governance sub-tab pages (Access, Audit, PII & policies,
// Lineage & usage, Sharing & org): four issue tiles (the check's own "N of M", one cause line), two
// cause cards, then one drill-down list whose rows open the drawer. Every figure is read off the
// checks' rows; "…" while loading, "–" and why when a check did not run.
// Registered into AREA_CHART_PAGES by area_pages.tsx. Never import this file from a module that
// area_pages.tsx does not already load first: the two import each other.
import React from "react";
import "../styles/css/p_area_governance.css";
import { fmtDayShort, fmtInt, fmtMoney, fmtMoneyOf } from "../format";
import { numOrZero, useFindingAgg, useFindingData } from "./hooks";
import { DrawerBus } from "./drawer";
import { withoutTotalRows } from "../tabs/tab_area";
import { ApPanel, ApRow } from "./area_pages";
import type { ApPageProps } from "./area_pages";
import { Columns, Dumbbell, RankedBars } from "./charts_more";
import {
  IssueTile, ShareBarList, StackedShareBar, StatusBars, fmtShare, pctOf,
} from "./blocks";
import type { ShareItem, ShareSegment, StatusBarItem } from "./blocks";
import { ChartCard, KindChip, bandOf } from "./primitives";
import { DrillTable } from "./drill_table";
import { notAssessedText } from "./scope";
import { SummaryTileRow, scrollToAnchor, windowShortLabel, windowSpan } from "./overview_tile";
import {
  CheckTile, MoneyTile, Row2, Slot, dtChip, fmtSize, isFlagged, nameId, useCheck, useLede,
} from "./area_ai_storage";
import type { Chk } from "./area_ai_storage";
import { CxBarRows, CxChip, CxDot, CxDotLegend, CxEyebrow, CxMiniCols, CxMissing, CxObjName, CxRanked, CxStat, CxSwatches, CxTable, CxTwoBar, rankTally } from "./cx_e";
import type { CxBarRow, CxRankItem } from "./cx_e";
import type { FetchState, Finding, Row } from "../types";

// ═══════════════════════ shared helpers ═══════════════════════

const STATUS_RANK: Record<string, number> = { CRITICAL: 3, WARN: 2, OK: 1, NOT_ASSESSED: 0 };
/** The worst of two row statuses. */
function worse(a: string | null | undefined, b: string | null | undefined): string {
  return (STATUS_RANK[String(b)] ?? 0) > (STATUS_RANK[String(a)] ?? 0) ? String(b) : String(a || b || "OK");
}
const plural = (n: number, one: string, many?: string) => `${fmtInt(n)} ${n === 1 ? one : (many || `${one}s`)}`;
const words = (v: any) => String(v ?? "").replace(/_/g, " ").toLowerCase();
/** Words with a capital first letter, acronyms kept upper case: "MFA bypass", "IP address". */
const capWords = (v: any) => words(v).replace(/\b(mfa|ip|sso|ddl|pii|dmf|url)\b/g, (x) => x.toUpperCase()).replace(/^./, (x) => x.toUpperCase());
const isTrue = (v: any) => v === true || v === "true" || v === 1;
const day = (v: any) => (v ? String(v).slice(0, 10) : null);
const ADMIN_RE = /ACCOUNTADMIN|SECURITYADMIN|ORGADMIN/i;

function findingOf(p: ApPageProps, id: string): Finding | null {
  return (p.findings || []).find((f) => f.query_id === id) || (p.allFindingsIndex ? p.allFindingsIndex[id] || null : null);
}
function openCheck(p: ApPageProps, id: string) {
  return () => p.goTo({ tab: p.area, subtab: p.subtab, focusQueryId: id });
}
/** The same page, reading every check in the export: for a tile on a check homed on another tab. */
function everyCheck(p: ApPageProps): ApPageProps {
  return p.allFindingsIndex ? { ...p, findings: Object.values(p.allFindingsIndex) } : p;
}

/** An org row's account as "name (locator)", never a bare locator. */
function acct(r: Row): string {
  const name = r.account_name || null;
  const loc = r.account_locator || null;
  if (name && loc && name !== loc) return `${name} (${loc})`;
  return String(name || loc || "(no account)");
}

/** One currency for a set of invoice rows, or null when they mix currencies (never added). */
function oneCurrency(rows: Row[]): { ok: boolean; fmt: (v: number) => string } {
  const cur = [...new Set(rows.map((r) => r.currency).filter((c) => c !== null && c !== undefined && c !== ""))];
  if (cur.length > 1) return { ok: false, fmt: (v) => fmtInt(v) };
  const m = { unit: "currency", currency: cur[0] || null };
  return { ok: true, fmt: (v) => fmtMoneyOf(m, v, 0) };
}
const MIXED_CURRENCY = "These amounts are in more than one currency, so they are not added; the rows are below.";

/** A short headline line above a chart: the issue in one figure. */
function Headline({ children }: { children?: React.ReactNode }) {
  return <div className="gov-headline">{children}</div>;
}

/** A check's "N of M noun": its own affected count (the figure the checks list shows), else its rows. */
function affOf(f: Finding | null, rows: Row[], noun = "rows") {
  const a = f && f.affected;
  if (a && Number(a.total) > 0) return { flagged: Number(a.flagged) || 0, total: Number(a.total), noun: String(a.noun || noun) };
  return { flagged: rows.filter(isFlagged).length, total: rows.length, noun };
}
const ofText = (a: { flagged: number; total: number; noun: string }) => `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}`;

/** A tile on a check's own "N of M": a % of the base or the count, a mono base line and one cause line. */
function AffTile({ c, label, as = "pct", noun, extra, cause, openLabel, onOpen, pill }: {
  c: Chk; label: string; as?: "pct" | "count"; noun?: string;
  extra?: (rows: Row[]) => string | null; cause?: (rows: Row[]) => React.ReactNode;
  openLabel?: string; onOpen?: () => void; pill?: React.ReactNode;
}) {
  return (
    <CheckTile c={onOpen ? { ...c, open: onOpen } : c} label={label} badge build={(rows) => {
      const a = affOf(c.f, rows, noun);
      const pct = pctOf(a.flagged, a.total);
      return {
        headline: as === "pct" ? fmtShare(pct) : fmtInt(a.flagged),
        unit: as === "pct" ? ` of ${a.noun}` : ` of ${fmtInt(a.total)} ${a.noun}`,
        base: [as === "pct" ? ofText(a) : (pct != null ? fmtShare(pct) : null), extra ? extra(rows) : null].filter(Boolean).join(" · ") || null,
        cause: cause ? cause(rows) : undefined,
        ...(openLabel ? { openLabel } : {}),
        ...(pill !== undefined ? { pill } : {}),
      };
    }} />
  );
}

/** A tile on a check homed on another tab: its own "N of M" from the findings list, or "–" and why. */
function FindingTile({ p, id, label, cause, tab, subtab, openLabel }: {
  p: ApPageProps; id: string; label: string; cause?: string; tab: string; subtab?: string | null; openLabel: string;
}) {
  const f = findingOf(p, id);
  const b = f ? bandOf(f) : "NOT_ASSESSED";
  const ran = !!f && b !== "NOT_ASSESSED" && b !== "ERROR";
  const a = f && f.affected;
  const go = () => p.goTo({ tab, subtab: subtab || null, focusQueryId: id });
  if (!ran || !a) {
    return <IssueTile label={label} headline={null} status="not_assessed" missingReason={!f ? "not in this export" : !ran ? notAssessedText(f) : "no count for this check"}
      onOpen={go} openLabel={openLabel} />;
  }
  return (
    <IssueTile label={label} headline={fmtInt(a.flagged)} unit={` of ${fmtInt(a.total)} ${a.noun}`} status={tileStatus(f)}
      base={fmtShare(pctOf(a.flagged, a.total))} cause={cause} onOpen={go} openLabel={openLabel} />
  );
}

function tileStatus(f: Finding | null): "critical" | "warn" | "ok" | "not_assessed" | "neutral" {
  if (!f) return "not_assessed";
  const b = bandOf(f);
  if (b === "CRITICAL") return "critical";
  if (b === "WARN") return "warn";
  if (b === "OK") return "ok";
  if (b === "NOT_ASSESSED" || b === "ERROR") return "not_assessed";
  return "neutral";
}

/** Rows grouped by a key: count, a summed value and the worst status. */
function tally(rows: Row[], key: (r: Row) => string, val: (r: Row) => number = () => 1) {
  const m = new Map<string, { name: string; n: number; value: number; status: string; rows: Row[] }>();
  rows.forEach((r) => {
    const k = key(r);
    const cur = m.get(k) || { name: k, n: 0, value: 0, status: "OK", rows: [] };
    cur.n += 1;
    cur.value += val(r);
    cur.status = worse(cur.status, r.status);
    cur.rows.push(r);
    m.set(k, cur);
  });
  return [...m.values()];
}
const distinct = (rows: Row[], col: string) => new Set(rows.map((r) => r[col]).filter((v) => v !== null && v !== undefined && v !== "")).size;
const drawerBy = (id: string, col: string, val: any, label: string) => () => DrawerBus.open({ id, col, val: String(val), label });
const lastDay = (v: any) => (v ? fmtDayShort(day(v)) : "–");

// ═══════════════════════ Access › Roles & grants ═══════════════════════

// A privilege that lets the grantee change or own the object, not only read or use it.
const WRITE_PRIV = /OWNERSHIP|INSERT|UPDATE|DELETE|TRUNCATE|CREATE|MODIFY|^ALL|WRITE|APPLY|OPERATE|MANAGE|REBUILD/i;

/** One check's rows for a tile and a card: rows, "…" while loading, or "–" and why. */
function useCheckRows(p: ApPageProps, id: string) {
  const f = findingOf(p, id);
  const st = useFindingData(f ? id : null, p.filters.window, p.filters.accountIds, 5000) as FetchState;
  let note: string | null = null;
  if (!f) note = "not in this export";
  else if (st.phase === "loading") note = "…";
  else if (st.phase === "error") note = st.error || "could not load";
  else if (st.outcome === "not_assessed") note = notAssessedText(st.data);
  else if (st.outcome === "error") note = (st.data && st.data.error) || "the check failed";
  else if (st.outcome === "ok_empty_filters") note = "the current filters exclude every row";
  const rows = st.phase === "ready" && st.outcome === "ok_rows" ? withoutTotalRows(st.data!.rows).filter((r) => r.status !== "NOT_ASSESSED")
    : st.phase === "ready" && st.outcome === "ok_empty_window" ? [] : null;
  return { id, f, rows, note, loading: !!f && st.phase === "loading" };
}

export function ApAccessRoles(p: ApPageProps) {
  const pub = useCheckRows(p, "sf_gov_public_role_grants");
  const broad = useCheckRows(p, "access_broad_grants");
  const direct = findingOf(p, "sf_secx_direct_user_grants");
  const schemas = useCheckRows(p, "sf_govx_schema_grant_control");
  const open = (id: string) => () => DrawerBus.open({ id });
  const aff = (f: Finding | null) => (f && f.affected && f.affected.total ? f.affected : null);
  const why = (c: { note: string | null }) => (c.note && c.note !== "…" ? c.note : undefined);

  const pubRows = pub.rows || [];
  const pubWrite = pubRows.filter((r) => WRITE_PRIV.test(String(r.privilege || ""))).length;
  const pubAff = aff(pub.f);
  const broadAff = aff(broad.f);
  const broadRows = broad.rows || [];
  const broadRoles = new Set(broadRows.map((r) => String(r.grantee || ""))).size;
  // Distinct people reached, the same on every row of the check; an older export has no such column.
  const reach = broadRows.find((r) => r.users_holding_broad != null && r.active_users != null) || null;
  const broadWrite = broadRows.filter((r) => isTrue(r.is_write)).length;
  const broadManage = broadRows.filter((r) => isTrue(r.is_manage)).length;
  const directAff = aff(direct);
  const sRows = schemas.rows || [];
  const managed = sRows.filter((r) => isTrue(r.is_managed_access)).length;
  const managedPct = sRows.length ? pctOf(managed, sRows.length) : null;

  const lede = pub.loading || schemas.loading ? "…" : [
    pubAff ? `PUBLIC can reach ${fmtInt(pubAff.flagged)} of ${fmtInt(pubAff.total)} ${pubAff.noun}${pub.rows ? `, and ${plural(pubWrite, "grant")} to PUBLIC can write or own` : ""}.` : null,
    managedPct != null ? `${fmtShare(managedPct)} of schemas route grants through their owner.` : null,
  ].filter(Boolean).join(" ") || null;
  React.useEffect(() => { if (p.setLede) p.setLede(lede); }, [lede]); // eslint-disable-line react-hooks/exhaustive-deps

  // Broad grants by role: the bar is how many users hold the role.
  const byRole = new Map<string, { holders: number; n: number; status: string }>();
  broadRows.forEach((r) => {
    const k = String(r.grantee || "(no role)");
    const cur = byRole.get(k) || { holders: 0, n: 0, status: "OK" };
    cur.holders = Math.max(cur.holders, numOrZero(r.holders));
    cur.n += 1;
    cur.status = worse(cur.status, r.status);
    byRole.set(k, cur);
  });
  const roleItems: StatusBarItem[] = [...byRole.entries()].map(([name, v]) => ({
    key: name, name, value: v.holders, status: v.status, valueText: `${fmtInt(v.holders)} users · ${plural(v.n, "grant")}`,
  }));

  return (
    <div className="cx-e">
      <div className="summary-tile-row compact gov-role-tiles">
        <IssueTile label="PUBLIC can reach" loading={pub.loading} status={tileStatus(pub.f)}
          headline={pubAff ? fmtInt(pubAff.flagged) : null} unit={pubAff ? `of ${fmtInt(pubAff.total)} ${pubAff.noun}` : undefined}
          missingReason={why(pub) || "no count for this check"}
          base={pub.rows ? `${plural(pubRows.length, "grant")} to PUBLIC; ${fmtInt(pubWrite)} of them can write or own.` : null}
          onOpen={open("sf_gov_public_role_grants")} openLabel="By object type ↓" />
        <IssueTile label="Broad grants" loading={broad.loading} status={tileStatus(broad.f)}
          headline={broadAff ? fmtInt(broadAff.flagged) : null} unit={broadAff ? `of ${fmtInt(broadAff.total)} ${broadAff.noun}` : undefined}
          missingReason={why(broad) || "no count for this check"}
          base={broad.rows ? `On ${broadRoles === 1 ? "one role" : plural(broadRoles, "role")} that many users hold${reach ? `, ${fmtInt(reach.users_holding_broad)} of ${fmtInt(reach.active_users)} users` : ""}. ${fmtInt(broadWrite)} write or own; ${fmtInt(broadManage)} manage grants.` : null}
          onOpen={open("access_broad_grants")} openLabel="By role ↓" />
        <IssueTile label="Direct grants" loading={false} status={tileStatus(direct)}
          headline={directAff ? fmtInt(directAff.flagged) : null} unit={directAff ? `of ${fmtInt(directAff.total)} ${directAff.noun}` : undefined}
          missingReason={!direct ? "not in this export" : notAssessedText(direct)}
          base={directAff ? "Privileges held by people, not roles: direct role grants or a personal role." : null}
          onOpen={open("sf_secx_direct_user_grants")} openLabel="Open →" />
        <IssueTile label="Managed access" loading={schemas.loading} status={tileStatus(findingOf(p, "sf_govx_schema_grant_control"))}
          headline={managedPct != null ? fmtShare(managedPct) : null} unit="of schemas"
          missingReason={why(schemas) || "no schemas the role can see"}
          base={sRows.length ? `${fmtInt(managed)} of ${plural(sRows.length, "schema")} use managed access.` : null}
          cause={sRows.length ? "Elsewhere, object owners hand out access instead of the schema owner." : null}
          onOpen={open("sf_govx_schema_grant_control")} openLabel="By database ↓" />
      </div>
      <ApRow>
        <ApPanel {...p} id="sf_gov_public_role_grants" title="What PUBLIC can reach, by object type" subtitle="Grants to PUBLIC · dark part = can write or own"
          build={(rows) => {
            const by = new Map<string, { value: number; whole: number }>();
            rows.forEach((r) => {
              const k = words(r.object_type) || "(unknown type)";
              const cur = by.get(k) || { value: 0, whole: 0 };
              cur.whole += 1;
              if (WRITE_PRIV.test(String(r.privilege || ""))) cur.value += 1;
              by.set(k, cur);
            });
            const items = [...by.entries()].map(([name, v]) => ({ name, value: v.value, whole: v.whole })).sort((x, y) => y.whole - x.whole || y.value - x.value);
            if (!items.length) return null;
            const max = Math.max(...items.map((x) => x.whole));
            const writeOn = items.filter((x) => x.value > 0).map((x) => `${fmtInt(x.value)} ${x.name}`);
            return (
              <CxTable ariaLabel="Grants to PUBLIC by object type"
                cols={[{ label: "Object type" }, { label: "", width: "45%" }, { label: "Grants", num: true }, { label: "Write or own", num: true }]}
                foot={`${plural(items.length, "object type")}${writeOn.length ? ` · the ${plural(pubWrite, "grant")} that can write or own ${pubWrite === 1 ? "is" : "are"} on ${writeOn.join(" and ")}` : ""}.`}
                rows={items.map((x) => ({ key: x.name, cells: [x.name, <CxTwoBar part={x.value} whole={x.whole} max={max} />, fmtInt(x.whole), x.value ? <b>{fmtInt(x.value)}</b> : "–"] }))} />
            );
          }} />
        <div>
          <ApPanel {...p} id="sf_govx_schema_grant_control" title="Managed-access schemas" subtitle="Only the schema owner can grant on its objects"
            build={(rows) => {
              if (!rows.length) return null;
              const by = new Map<string, { value: number; total: number }>();
              rows.forEach((r) => {
                const k = String(r.database_name || "(no database)");
                const cur = by.get(k) || { value: 0, total: 0 };
                cur.total += 1;
                if (isTrue(r.is_managed_access)) cur.value += 1;
                by.set(k, cur);
              });
              // Databases with no managed schema read as one sentence; the rest as shares.
              const none = [...by.entries()].filter(([, v]) => v.value === 0).map(([k]) => k).sort();
              const some: CxRankItem[] = [...by.entries()].filter(([, v]) => v.value > 0)
                .map(([k, v]) => ({ key: k, label: k, value: pctOf(v.value, v.total) ?? 0, strong: fmtShare(pctOf(v.value, v.total)), rest: `${fmtInt(v.value)} of ${plural(v.total, "schema")}` }))
                .sort((x, y) => x.value - y.value);
              const named = none.slice(0, 6);
              return (
                <div>
                  <CxStat>{<span><b>{`${fmtInt(managed)} of ${plural(rows.length, "schema")}`}</b>{" use managed access."}</span>}</CxStat>
                  {none.length > 0 && <CxStat>{`None of the schemas in ${named.join(", ")}${none.length > named.length ? ` or ${plural(none.length - named.length, "more database")}` : ""} use${none.length === 1 ? "s" : ""} managed access.`}</CxStat>}
                  {some.length > 0 && <div className="cx-block"><CxRanked items={some} max={100} layout="above" ariaLabel="Managed-access share by database" /></div>}
                </div>
              );
            }} />
          <ApPanel {...p} id="access_broad_grants" title="Broad grants, by role" subtitle="Write, ownership, an admin role or MANAGE GRANTS on a role many users hold"
            build={() => {
              if (!roleItems.length) return null;
              if (roleItems.length === 1) {
                const r = roleItems[0], v = byRole.get(String(r.key))!;
                return <CxStat>{<span>{`One role holds all ${plural(v.n, "broad grant")}: `}<b>{String(r.name)}</b>{`, held by ${plural(v.holders, "user")}.`}</span>}</CxStat>;
              }
              return <StatusBars items={roleItems} n={8} unitLabel="users hold it" ariaLabel="Broad grants by role"
                onBarClick={(it) => DrawerBus.open({ id: "access_broad_grants", col: "grantee", val: String(it.key), label: String(it.name) })} />;
            }} />
        </div>
      </ApRow>
      <GovGrantsByPrivilege p={p} />
      <GovUnusedGrantsFit p={p} />
    </div>
  );
}
(ApAccessRoles as any).ownsTiles = true;
(ApAccessRoles as any).ownsLede = true;

// ═══════════════════════ Access › Users & sign-ins ═══════════════════════

// Every user the role can see: the user-state check lists them all, so it is the one base for the
// sign-in credential bar.
const ALL_USERS_ID = "sf_secx_user_auth_state";

// Password age bands, oldest last: a histogram of how long passwords have gone unchanged.
const AGE_BANDS: [string, number, number][] = [
  ["under 90 days", 0, 90], ["90-180 days", 90, 180], ["180 days-1 year", 180, 365], ["1-2 years", 365, 730], ["over 2 years", 730, Infinity],
];

/** Credentials held, ranked, label above each bar: from the key-and-password check. */
function SignInMix({ rows, population }: { rows: Row[]; population: number | null }) {
  const n = (pred: (r: Row) => boolean) => rows.filter(pred).length;
  const pw = (r: Row) => isTrue(r.has_password), key = (r: Row) => isTrue(r.has_rsa_key), mfa = (r: Row) => isTrue(r.has_mfa);
  const parts: [string, number][] = [
    ["Password only, no MFA", n((r) => pw(r) && !mfa(r) && !key(r))],
    ["Password and MFA", n((r) => pw(r) && mfa(r) && !key(r))],
    ["Password and key pair", n((r) => pw(r) && key(r))],
    ["Key pair only", n((r) => !pw(r) && key(r))],
  ];
  // Users with neither (SSO, OAuth or nothing) are the rest of the base.
  const rest = population ? Math.max(0, population - rows.length) : 0;
  const base = population || rows.length;
  const items: CxRankItem[] = parts.map(([label, v]) => ({ key: label, label, value: v, strong: plural(v, "user"), rest: fmtShare(pctOf(v, base)) }));
  if (rest > 0) items.push({ key: "rest", label: "No password or key (SSO, OAuth or none)", value: rest, other: true, strong: plural(rest, "user"), rest: fmtShare(pctOf(rest, base)) });
  if (items.filter((x) => x.value > 0).length < 2) return null;
  return (
    <div>
      <CxStat>{<span><b>{`${fmtInt(parts[0][1])} of ${plural(base, "user")}`}</b>{" have a password and no MFA."}</span>}</CxStat>
      <div className="cx-block"><CxRanked items={items.filter((x) => x.value > 0).sort((x, y) => y.value - x.value)} layout="above" max={base} ariaLabel="Users by sign-in credential" /></div>
    </div>
  );
}

// Password age, oldest last; a darker shade is an older band.
const AGE_SHADES = ["var(--seq-1)", "var(--seq-2)", "var(--seq-3)", "var(--seq-4)", "var(--seq-5)"];

/** Password age bands in time order, each its own row, labelled directly. */
function PasswordAge({ rows }: { rows: Row[] }) {
  const ages = rows.filter((r) => isTrue(r.has_password) && r.password_age_days != null).map((r) => numOrZero(r.password_age_days));
  if (ages.length < 2) return null;
  const items: CxRankItem[] = AGE_BANDS.map(([label, lo, hi], i) => {
    const v = ages.filter((x) => x >= lo && x < hi).length;
    return { key: label, label: label.charAt(0).toUpperCase() + label.slice(1), value: v, color: AGE_SHADES[i], strong: fmtInt(v), rest: fmtShare(pctOf(v, ages.length)) };
  });
  const old = ages.filter((x) => x >= 365).length;
  return (
    <div>
      <CxStat>{<span><b>{`${fmtInt(old)} of ${plural(ages.length, "password")}`}</b>{" are over a year old."}</span>}</CxStat>
      <div className="cx-block"><CxRanked items={items} ariaLabel="Password age" /></div>
      <div className="cx-foot">{"Darker = older. The last two rows are the passwords over a year old."}</div>
    </div>
  );
}

export function ApAccessUsers(p: ApPageProps) {
  const mfa = useCheck(p, "sf_sec_users_without_mfa");
  const stale = useCheck(p, "sf_sec_stale_users");
  const svc = useCheck(p, "sf_sec_password_service_users");
  const cred = useCheck(p, "sf_secx_key_and_password_age");
  const allUsers = findingOf(p, ALL_USERS_ID);
  const population = allUsers && allUsers.affected && bandOf(allUsers) !== "NOT_ASSESSED" ? Number(allUsers.affected.total) || null : null;
  const noMfa = (mfa.rows || []).filter(isFlagged);
  const admins = noMfa.filter((r) => ADMIN_RE.test(String(r.admin_roles || ""))).length;
  const aM = mfa.rows ? affOf(mfa.f, mfa.rows, "users") : null;
  const aS = stale.rows ? affOf(stale.f, stale.rows, "users") : null;
  const aV = svc.rows ? affOf(svc.f, svc.rows, "service users") : null;
  useLede(p, mfa.loading || stale.loading || svc.loading, [
    aM ? `${ofText(aM)} sign in with a password and no MFA, ${fmtInt(admins)} of them admins.` : null,
    aS ? `${ofText(aS)} no longer sign in but stay enabled.` : null,
    aV ? `${ofText(aV)} use a password instead of a key pair.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <AffTile c={mfa} label="People without MFA" noun="users" openLabel="The fix →" onOpen={() => DrawerBus.open({ id: "sf_sec_users_without_mfa" })}
          cause={(rows) => `${fmtInt(admins)} of the ${fmtInt(rows.filter(isFlagged).length)} hold ACCOUNTADMIN, SECURITYADMIN or ORGADMIN.`} />
        <AffTile c={stale} label="Users who never sign in" noun="users"
          cause={(rows) => {
            const fl = rows.filter(isFlagged);
            return `Still enabled. ${fmtInt(fl.filter((r) => isTrue(r.never_logged_in)).length)} never signed in; ${fmtInt(fl.filter((r) => r.admin_roles).length)} can use an admin role.`;
          }} />
        <AffTile c={svc} label="Service users with a password" as="count" noun="service users"
          cause={(rows) => `${fmtInt(rows.filter((r) => isFlagged(r) && numOrZero(r.password_logins) > 0).length)} signed in with a password, not a key pair, in the window.`} />
        <FindingTile p={p} id="sf_secx_direct_user_grants" label="Direct grants" tab="access" subtab="roles" openLabel="Roles & grants →"
          cause="Direct grants or a personal role with privileges: access that leaves with the person." />
      </SummaryTileRow>
      <Row2>
        <Slot c={cred} title="How users can sign in" subtitle={population ? `Credentials held, of all ${fmtInt(population)} users` : "Credentials held, users with a password or key"}>
          {(rows) => <SignInMix rows={rows} population={population} />}
        </Slot>
        <Slot c={cred} title="Password age" subtitle="Passwords, by time since the last change">
          {(rows) => <PasswordAge rows={rows} />}
        </Slot>
      </Row2>
      <Slot c={mfa} title="Who signs in without MFA, by role" subtitle="People with a password and no MFA, by default role · bar = users · dot = status">
        {(rows) => {
          const groups = tally(rows.filter(isFlagged), (r) => String(r.default_role || "(no default role)"), (r) => numOrZero(r.password_only_logins))
            .sort((x, y) => y.n - x.n || y.value - x.value);
          if (!groups.length) return null;
          const max = Math.max(...groups.map((g) => g.n));
          return <CxTable ariaLabel="People without MFA by default role" n={8}
            cols={[{ label: "Role" }, { label: "", width: "45%" }, { label: "Users", num: true }, { label: "Password sign-ins", num: true }]}
            rows={groups.map((g) => ({ key: g.name, status: g.status,
              onClick: () => DrawerBus.open({ id: "sf_sec_users_without_mfa", col: "default_role", val: g.name, label: g.name }),
              cells: [g.name, <CxTwoBar part={g.n} whole={g.n} max={max} />, <b>{fmtInt(g.n)}</b>, fmtInt(g.value)] }))} />;
        }}
      </Slot>
      <GovFailedByCause p={p} />
      <Slot c={mfa} title="People signing in with a password and no MFA" subtitle="Admins first · select a row for its sign-ins and the fix">
        {(rows) => (
          <CxTable ariaLabel="People without MFA" n={10}
            cols={[{ label: "User" }, { label: "Admin role" }, { label: "Password sign-ins", num: true }, { label: "Last sign-in", num: true }]}
            rows={rows.filter(isFlagged)
              .sort((a, b) => Number(ADMIN_RE.test(String(b.admin_roles || ""))) - Number(ADMIN_RE.test(String(a.admin_roles || ""))) || numOrZero(b.password_only_logins) - numOrZero(a.password_only_logins))
              .map((r) => ({
                key: `${r.account_id}|${r.user_id ?? r.user_name}`, status: r.status,
                onClick: drawerBy("sf_sec_users_without_mfa", "user_name", r.user_name, nameId(r.user_name, r.user_id)),
                cells: [nameId(r.user_name, r.user_id, "(no user)"), r.admin_roles ? <CxChip status={ADMIN_RE.test(String(r.admin_roles)) ? "CRITICAL" : "WARN"}>{String(r.admin_roles).split(",")[0].trim()}</CxChip> : <span className="cx-muted">None</span>,
                  fmtInt(numOrZero(r.password_only_logins)), lastDay(r.last_success_login)],
              }))} />
        )}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Access › Account perimeter ═══════════════════════

// The perimeter controls: one check each, read off the check's own "N of M".
const PERIMETER_CONTROLS: [string, string][] = [
  ["sf_sec_network_policy_coverage", "Network policy"],
  ["sf_sec_account_security_settings", "Security parameters"],
  ["sf_secx_authentication_policy_posture", "Authentication policy"],
  ["sf_secx_password_policy_posture", "Password policy"],
  ["sf_secx_session_policy_coverage", "Session policy"],
  ["sf_gov_integrations_exposure", "Integrations"],
  ["sf_govx_external_stage_credentials", "External stages"],
  ["sf_secx_secrets_hygiene", "Secrets"],
];

/** One row per control: the flagged share of what it judged; a control that did not run says why. */
function ControlRows({ p }: { p: ApPageProps }) {
  const rows = PERIMETER_CONTROLS.map(([id, label]) => {
    const f = findingOf(p, id);
    const b = f ? bandOf(f) : "NOT_ASSESSED";
    const ran = !!f && b !== "NOT_ASSESSED" && b !== "ERROR";
    const a = f && f.affected;
    const why = !f ? "not in this export" : notAssessedText(f).replace(/^Not assessed: /, "");
    const share = ran && a && Number(a.total) > 0 ? pctOf(Number(a.flagged), Number(a.total)) : null;
    return {
      key: id, status: ran ? (b === "CRITICAL" || b === "WARN" ? b : "OK") : "NOT_ASSESSED",
      onClick: f ? () => DrawerBus.open({ id }) : null,
      cells: [label,
        share != null ? <span className="cx-bars-track" aria-hidden="true"><span className="cx-bars-fill" style={{ width: `${share}%` }} /></span> : <span className="cx-muted">{`– ${why}`}</span>,
        share != null ? <b>{fmtShare(share)}</b> : "–",
        ran && a ? ofText({ flagged: Number(a.flagged), total: Number(a.total), noun: String(a.noun) }) : ran ? "nothing to judge" : "–"],
    };
  });
  const judged = rows.filter((r) => r.status !== "NOT_ASSESSED");
  const flagged = judged.filter((r) => r.status !== "OK").length;
  return (
    <ChartCard title="Account perimeter, control by control" subtitle={`Share of each control's objects that are flagged · ${fmtInt(flagged)} of ${plural(judged.length, "control")} flagged${rows.length > judged.length ? ` · ${fmtInt(rows.length - judged.length)} not judged` : ""}`} takeaway={null}>
      <CxTable ariaLabel="Perimeter controls" cols={[{ label: "Control" }, { label: "Flagged share", width: "45%" }, { label: "Share", num: true }, { label: "Flagged", num: true }]} rows={rows} />
    </ChartCard>
  );
}

const TC_SEVERITIES: [string, string][] = [["CRITICAL", "var(--c1)"], ["HIGH", "var(--c2)"], ["MEDIUM", "var(--c3)"], ["LOW", "var(--c-other)"]];

export function ApAccessPerimeter(p: ApPageProps) {
  const np = useCheck(p, "sf_sec_network_policy_coverage");
  const set = useCheck(p, "sf_sec_account_security_settings");
  const sess = useCheck(p, "sf_secx_session_policy_coverage");
  const integ = useCheck(p, "sf_gov_integrations_exposure");
  const tc = useCheck(p, "sf_sec_trust_center_findings");
  const flaggedControls = PERIMETER_CONTROLS.filter(([id]) => { const f = findingOf(p, id); const b = f ? bandOf(f) : ""; return b === "CRITICAL" || b === "WARN"; }).length;
  const notJudged = PERIMETER_CONTROLS.filter(([id]) => { const f = findingOf(p, id); const b = f ? bandOf(f) : "NOT_ASSESSED"; return b === "NOT_ASSESSED" || b === "ERROR"; }).length;
  const aN = np.rows ? affOf(np.f, np.rows, "users") : null;
  useLede(p, np.loading, [
    `${fmtInt(flaggedControls)} of ${fmtInt(PERIMETER_CONTROLS.length)} perimeter controls are flagged${notJudged ? ` and ${fmtInt(notJudged)} could not be judged` : ""}.`,
    aN ? `${ofText(aN)} have no network policy that limits where they sign in from.` : null,
  ].filter(Boolean).join(" "));
  const other = (id: string) => { const f = findingOf(p, id); const a = f && f.affected; return a && bandOf(f!) !== "NOT_ASSESSED" ? `${fmtInt(a.flagged)} of ${fmtInt(a.total)} ${a.noun}` : null; };
  const userRows = (rows: Row[]) => rows.filter((r) => String(r.scope || "").toUpperCase() !== "ACCOUNT");
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <AffTile c={np} label="Network policy" as="count" noun="users" openLabel="The fix →" onOpen={() => DrawerBus.open({ id: "sf_sec_network_policy_coverage" })}
          extra={(rows) => (rows.some((r) => String(r.scope || "").toUpperCase() === "ACCOUNT" && r.effective_policy) ? "account has a policy" : "none on the account")}
          cause={(rows) => `No policy of their own limits where they sign in from. ${fmtInt(userRows(rows).filter((r) => isFlagged(r) && r.admin_roles).length)} of them are admins; ${fmtInt(rows.filter((r) => isTrue(r.allows_any_ip)).length)} policies allow any IP.`} />
        <AffTile c={set} label="Account parameters" as="count" noun="settings" openLabel="Settings ↓"
          cause={(rows) => { const n = rows.filter(isFlagged).length; return n ? `${plural(n, "setting")} not as recommended; the list is below.` : "Every setting as recommended."; }} />
        <AffTile c={sess} label="Session policy coverage" noun="users" />
        <AffTile c={integ} label="Paths in and out" as="count" noun="integrations" openLabel="Checks ↓"
          extra={() => [other("sf_govx_external_stage_credentials"), other("sf_secx_secrets_hygiene")].filter(Boolean).join(" · ") || null}
          cause={(rows) => `${fmtInt(rows.filter((r) => isFlagged(r) && isTrue(r.public_usage)).length)} open to PUBLIC; ${fmtInt(rows.filter((r) => isFlagged(r) && isTrue(r.egress_path)).length)} a path out.`} />
      </SummaryTileRow>
      <ControlRows p={p} />
      <Slot c={set} title="Account-level settings" subtitle="What the account itself enforces, for every user and session · snapshot at export">
        {(rows) => (
          <CxTable ariaLabel="Account security settings"
            cols={[{ label: "Setting" }, { label: "Why it matters" }, { label: "State" }]}
            rows={[...rows].sort((a, b) => (STATUS_RANK[String(b.status)] ?? 0) - (STATUS_RANK[String(a.status)] ?? 0)).map((r) => ({
              key: String(r.setting), status: r.status, onClick: drawerBy("sf_sec_account_security_settings", "setting", r.setting, String(r.setting)),
              cells: [<code className="cx-code">{String(r.setting || "(unnamed setting)")}</code>, <span className="cx-why">{String(r.why || "–")}</span>,
                <span className="cx-nowrap">{isFlagged(r) ? "Not as recommended" : "As recommended"}</span>],
            }))} />
        )}
      </Slot>
      <Row2>
        <Slot c={np} title="Who has a network policy" subtitle="Users by the policy that applies to them · dot = status">
          {(rows) => {
            const groups = tally(userRows(rows), (r) => (r.effective_policy ? String(r.effective_policy) : "No policy")).sort((x, y) => y.n - x.n);
            if (!groups.length) return null;
            const max = Math.max(...groups.map((g) => g.n));
            return <CxTable ariaLabel="Users by network policy" n={8} cols={[{ label: "Policy" }, { label: "", width: "45%" }, { label: "Users", num: true }]}
              rows={groups.map((g) => ({ key: g.name, status: g.status, onClick: () => np.open(), cells: [<code className="cx-code">{g.name}</code>, <CxTwoBar part={g.n} whole={g.n} max={max} />, plural(g.n, "user")] }))} />;
          }}
        </Slot>
        <Slot c={tc} title="Trust Center findings by severity" subtitle="open findings with at least one entity at risk">
          {(rows) => {
            const open = rows.filter((r) => String(r.state || "OPEN").toUpperCase() === "OPEN" && numOrZero(r.at_risk_count) > 0);
            if (!open.length) return <div className="chart-note-oneline">No open Trust Center finding has an entity at risk.</div>;
            const known = new Set(TC_SEVERITIES.map(([s]) => s));
            const segs = TC_SEVERITIES.map(([sev, color]) => ({ label: words(sev), value: open.filter((r) => String(r.severity).toUpperCase() === sev).length, color }));
            const rest = open.filter((r) => !known.has(String(r.severity).toUpperCase())).length;
            if (rest) segs.push({ label: "no severity", value: rest, color: "var(--c-other)" });
            const entities = open.reduce((s, r) => s + numOrZero(r.at_risk_count), 0);
            return (
              <StackedShareBar segments={segs} valueFmt={(v) => plural(v, "finding")} ariaLabel="Open Trust Center findings by severity"
                totalLabel={<span><b>{plural(open.length, "open finding")}</b>{` · ${plural(entities, "entity", "entities")} at risk`}</span>} />
            );
          }}
        </Slot>
      </Row2>
    </div>
  );
}

// ═══════════════════════ Audit › Admins & sign-ins ═══════════════════════

const ADMIN_ORDER = ["ORGADMIN", "ACCOUNTADMIN", "SECURITYADMIN", "USERADMIN", "SYSADMIN"];
const rankAdmin = (r: string) => { const i = ADMIN_ORDER.indexOf(String(r).toUpperCase()); return i < 0 ? 99 : i; };

/** One line per enabled user: their highest admin role and whether they have MFA. */
function adminUsers(rows: Row[]) {
  const users = new Map<string, { name: string; role: string; mfa: boolean; defaultAdmin: boolean }>();
  rows.filter((r) => !isTrue(r.is_disabled)).forEach((r) => {
    const k = String(r.user_id ?? r.user_name);
    const role = String(r.admin_role || r.granted_role || "admin role");
    const cur = users.get(k);
    if (!cur || rankAdmin(role) < rankAdmin(cur.role)) users.set(k, { name: nameId(r.user_name, r.user_id, "(no user)"), role, mfa: isTrue(r.has_mfa), defaultAdmin: isTrue(r.default_role_is_admin) });
  });
  return [...users.values()];
}

export function ApAuditAdmins(p: ApPageProps) {
  const ah = useCheck(p, "sf_sec_admin_role_holders");
  const si = useCheck(p, "sf_audit_admin_signins");
  const du = useCheck(p, "sf_govx_admin_role_daily_use");
  const users = adminUsers(ah.rows || []);
  const noMfa = users.filter((u) => !u.mfa);
  const top = users.filter((u) => ["ORGADMIN", "ACCOUNTADMIN", "SECURITYADMIN"].includes(u.role.toUpperCase()));
  // The check's own "N of M" (the figure the checks list shows), else the users counted here.
  const topAff = ah.f && ah.f.affected && Number(ah.f.affected.total) > 0 ? { flagged: Number(ah.f.affected.flagged) || 0, total: Number(ah.f.affected.total), noun: String(ah.f.affected.noun || "users") } : null;
  const pwOnly = (si.rows || []).reduce((s, r) => s + numOrZero(r.password_only_logins), 0);
  const logins = (si.rows || []).reduce((s, r) => s + numOrZero(r.logins), 0);
  useLede(p, ah.loading || si.loading, [
    ah.rows && users.length ? `${fmtInt(noMfa.length)} of ${plural(users.length, "admin")} have no MFA.` : null,
    si.rows && logins ? `${fmtShare(pctOf(pwOnly, logins))} of admin sign-ins used a password only.` : null,
    ah.rows && users.length ? `${topAff ? ofText(topAff) : fmtInt(top.length)} hold ACCOUNTADMIN, SECURITYADMIN or ORGADMIN.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={ah} label="Admins without MFA" badge build={() => {
          const aa = users.filter((u) => u.role.toUpperCase() === "ACCOUNTADMIN");
          return {
            headline: fmtShare(pctOf(noMfa.length, users.length)), unit: " of admins",
            base: `${fmtInt(noMfa.length)} of ${plural(users.length, "admin")}, including ${fmtInt(aa.filter((u) => !u.mfa).length)} of the ${fmtInt(aa.length)} ACCOUNTADMIN holders.`,
            cause: "Each one is a phished password away from the account.", openLabel: "By role ↓",
          };
        }} />
        <CheckTile c={si} label="Password-only admin sign-ins" badge build={(rows) => {
          const who = rows.filter((r) => numOrZero(r.password_only_logins) > 0);
          return {
            headline: fmtShare(pctOf(pwOnly, logins)), unit: " of admin sign-ins",
            base: `${fmtInt(pwOnly)} of ${fmtInt(logins)} sign-ins, by ${fmtInt(who.length)} of ${plural(rows.length, "admin")}.`,
            cause: who.length ? `${who.slice(0, 2).map((r) => String(r.user_name)).join(" and ")}: no SSO, key pair or MFA.` : "Every admin sign-in used SSO, a key pair or MFA.",
            openLabel: "By user ↓",
          };
        }} />
        <CheckTile c={ah} label="Top admin role holders" badge build={() => ({
          headline: fmtInt(topAff ? topAff.flagged : top.length), unit: ` of ${topAff ? `${fmtInt(topAff.total)} ${topAff.noun}` : plural(users.length, "admin user")}`,
          base: `Hold ACCOUNTADMIN, SECURITYADMIN or ORGADMIN; ${fmtInt(users.filter((u) => u.defaultAdmin).length)} use it as their default role. Snapshot at export.`,
          cause: "Two or three per role is enough.",
        })} />
        <CheckTile c={du} label="Data work under admin roles" badge build={(rows) => {
          const fl = rows.filter(isFlagged);
          const roles = [...new Set(fl.map((r) => String(r.role_name || "")))].filter(Boolean);
          return {
            headline: fmtInt(roles.length), unit: ` of ${plural(distinct(rows, "role_name"), "admin role")}`,
            base: `${fmtInt(fl.reduce((s, r) => s + numOrZero(r.queries), 0))} statements ran as ${roles.join(" or ")}.`,
            cause: "Pipelines and dashboards that belong under a working role.",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={ah} title="Admins by highest role and MFA" subtitle={`Enabled users who can use an admin role · ${fmtInt(users.length)} in all`}>
          {() => {
            const by = new Map<string, { value: number; whole: number }>();
            users.forEach((u) => {
              const cur = by.get(u.role) || { value: 0, whole: 0 };
              cur.whole += 1;
              if (!u.mfa) cur.value += 1;
              by.set(u.role, cur);
            });
            const items = [...by.entries()].sort((a, b) => rankAdmin(a[0]) - rankAdmin(b[0]));
            if (!items.length) return null;
            const max = Math.max(...items.map(([, v]) => v.whole));
            return (
              <div>
                <CxSwatches items={[["var(--c1)", "No MFA"], ["color-mix(in srgb, var(--c1) 35%, var(--surface))", "All users whose highest admin role it is"]]} />
                <CxTable ariaLabel="Admins by highest role, without MFA" cols={[{ label: "Role" }, { label: "", width: "45%" }, { label: "No MFA", num: true }]}
                  rows={items.map(([name, v]) => ({ key: name, cells: [name, <CxTwoBar part={v.value} whole={v.whole} max={max} />, <span><b>{fmtInt(v.value)}</b>{` of ${fmtInt(v.whole)}`}</span>] }))} />
              </div>
            );
          }}
        </Slot>
        <Slot c={si} title="Password-only admin sign-ins, by user" subtitle="Bar = password-only sign-ins · after it, of all that user's sign-ins">
          {(rows) => {
            const items: CxBarRow[] = rows.filter((r) => numOrZero(r.logins) > 0).map((r) => ({
              key: String(r.user_name), name: nameId(r.user_name, r.user_id, "(no user)"), value: numOrZero(r.password_only_logins), status: r.status,
              strong: fmtInt(numOrZero(r.password_only_logins)), rest: `of ${fmtInt(numOrZero(r.logins))}`,
              onClick: () => DrawerBus.open({ id: "sf_audit_admin_signins", col: "user_name", val: String(r.user_name), label: String(r.user_name) }),
            })).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Password-only sign-ins by admin user" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={du} title="Everyday data work under admin roles" subtitle="Statements run as an admin role in the window · select a row">
        {(rows) => rows.some(isFlagged) ? (
          <CxTable ariaLabel="Data work under admin roles" n={10}
            cols={[{ label: "User" }, { label: "Role" }, { label: "Kind" }, { label: "Statements", num: true }, { label: "Last", num: true }]}
            rows={rows.filter(isFlagged).sort((a, b) => numOrZero(b.queries) - numOrZero(a.queries)).map((r, i) => ({
              key: `${r.user_id ?? r.user_name}|${r.role_name}|${r.work_kind}|${i}`, status: r.status,
              onClick: drawerBy("sf_govx_admin_role_daily_use", "user_name", r.user_name, nameId(r.user_name, r.user_id)),
              cells: [nameId(r.user_name, r.user_id, "(no user)"), String(r.role_name || "–"), words(r.work_kind) || "–", fmtInt(numOrZero(r.queries)), lastDay(r.last_query)],
            }))} />
        ) : okNote("No data work ran under an admin role.")}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Audit › Changes ═══════════════════════

// DROP in a muted rose, so it does not read as Critical; colours are categories, not status.
const DDL_COLORS: Record<string, string> = {
  DROP: "color-mix(in srgb, var(--st-crit) 55%, var(--c4))", ALTER: "var(--c2)", CREATE: "var(--c1)", UNDROP: "var(--c4)", REPLACE: "var(--c3)",
};
const DDL_ORDER = ["DROP", "ALTER", "CREATE", "UNDROP", "REPLACE"];

/** DDL per day as small multiples, each kind on its own scale; a kind that dwarfs the rest reads as a sentence. */
function DdlTimeline({ rows, p }: { rows: Row[]; p: ApPageProps }) {
  const [sel, setSel] = React.useState<string | null>(null);
  const span = windowSpan(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
  const days: string[] = [];
  if (span) for (let t = span.first; t <= span.last; t += 86400000) days.push(new Date(t).toISOString().slice(0, 10));
  else [...new Set(rows.map((r) => String(r.usage_date || "").slice(0, 10)).filter(Boolean))].sort().forEach((d) => days.push(d));
  const byKind = new Map<string, Map<string, number>>();
  rows.forEach((r) => {
    const k = String(r.operation || "OTHER").toUpperCase(), d = String(r.usage_date || "").slice(0, 10);
    const m = byKind.get(k) || new Map<string, number>();
    m.set(d, (m.get(d) || 0) + (numOrZero(r.statements) || 1));
    byKind.set(k, m);
  });
  const totalOf = (k: string) => [...(byKind.get(k) || new Map()).values()].reduce((s, v) => s + v, 0);
  const total = [...byKind.keys()].reduce((s, k) => s + totalOf(k), 0);
  const kinds = [...byKind.keys()].sort((a, b) => (DDL_ORDER.indexOf(a) < 0 ? 99 : DDL_ORDER.indexOf(a)) - (DDL_ORDER.indexOf(b) < 0 ? 99 : DDL_ORDER.indexOf(b)));
  // A kind with most of the statements flattens every other panel: say it in a line instead.
  const big = kinds.find((k) => totalOf(k) > total / 2) || null;
  const panels = kinds.filter((k) => k !== big);
  const partial = !!(p.meta && p.meta.cost_cutoff && p.meta.cost_cutoff.partial_day && days[days.length - 1] === String(p.meta.cost_cutoff.partial_day).slice(0, 10));
  const onDay = rows.filter((r) => sel && String(r.usage_date || "").slice(0, 10) === sel);
  const byUser = new Map<string, StatusBarItem>();
  onDay.forEach((r) => {
    const k = `${r.user_name || "(no user)"} · ${words(r.operation)} ${words(r.object_domain)}`;
    const cur = byUser.get(k) || { key: k, name: k, value: 0, status: "OK" };
    cur.value += numOrZero(r.statements) || 1;
    cur.status = worse(cur.status, r.status);
    byUser.set(k, cur);
  });
  const peakOf = (k: string) => { const m = byKind.get(k)!; let best = ""; m.forEach((v, d) => { if (!best || v > (m.get(best) || 0)) best = d; }); return best; };
  return (
    <div>
      {big && (
        <div className="cx-callout"><span><span className="cx-legend-sq" style={{ background: DDL_COLORS[big] || "var(--c-other)", marginRight: 6 }} /><b>{big}</b></span>
          <span>{`About ${fmtInt(Math.round(totalOf(big) / Math.max(1, days.length)))} a day: ${fmtInt(totalOf(big))} of the ${fmtInt(total)} statements (${fmtShare(pctOf(totalOf(big), total))}). A line here, so the kinds below can be seen.`}</span></div>
      )}
      <div className="cx-minis">
        {panels.map((k) => (
          <CxMiniCols key={k} title={k} color={DDL_COLORS[k] || "var(--c-other)"} days={days} values={days.map((d) => (byKind.get(k)!.get(d) || 0))}
            sub={`${fmtInt(totalOf(k))} in all · most on ${fmtDayShort(peakOf(k))}`} partialLast={partial} selected={sel}
            onDay={(d) => setSel(sel === d ? null : d)} dayLabel={(d) => fmtDayShort(d)} />
        ))}
      </div>
      <div className="cx-foot"><span>{"Y axis: statements / day, each panel on its own scale."}</span><span>{sel ? "" : "Select a day for who made its changes."}</span></div>
      {sel && (
        <div className="gov-sub">
          <div className="gov-sub-title">{`${fmtDayShort(sel)}: who changed what`}</div>
          <StatusBars items={[...byUser.values()]} n={8} unitLabel="statements" ariaLabel={`Changes on ${sel}`} onBarClick={openCheck(p, "sf_audit_object_ddl_timeline")} />
        </div>
      )}
    </div>
  );
}

export function ApAuditChanges(p: ApPageProps) {
  const pg = useCheck(p, "sf_sec_privileged_grant_changes");
  const sc = useCheck(p, "sf_sec_security_config_changes");
  const ga = useCheck(p, "sf_audit_grant_activity");
  const dd = useCheck(p, "sf_audit_object_ddl_timeline");
  const aP = pg.rows ? affOf(pg.f, pg.rows, "grantees") : null;
  const ddl = (dd.rows || []).reduce((s, r) => s + (numOrZero(r.statements) || 1), 0);
  const drops = (dd.rows || []).filter((r) => String(r.operation).toUpperCase() === "DROP").reduce((s, r) => s + (numOrZero(r.statements) || 1), 0);
  useLede(p, pg.loading || dd.loading, [
    aP ? `${ofText(aP)} received an admin role, ownership or an account privilege.` : null,
    dd.rows && ddl ? `${plural(ddl, "DDL statement")} in all; ${fmtInt(drops)} were DROPs.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <AffTile c={pg} label="Privileged grants" noun="grantees" openLabel="By grantee ↓"
          cause={(rows) => `${plural(rows.length, "grant")}. ${fmtInt(rows.filter((r) => isFlagged(r) && String(r.grantee_type).toUpperCase() === "USER").length)} went to people, not roles.`} />
        <CheckTile c={sc} label="Who changes security" badge build={(rows) => {
          const roles = distinct(rows, "role_name"), fl = distinct(rows.filter(isFlagged), "role_name");
          const kinds = tally(rows, (r) => words(r.change_kind), (r) => numOrZero(r.statements)).sort((a, b) => b.value - a.value);
          return {
            headline: fmtInt(fl), unit: ` of ${plural(roles, "role")}`,
            base: `${fmtShare(pctOf(fl, roles))}. ${plural(rows.reduce((s, r) => s + numOrZero(r.statements), 0), "statement")}${kinds.length ? `, mostly ${kinds.slice(0, 2).map((k) => k.name).join(" and ")}` : ""}.`,
            openLabel: "By kind ↓",
          };
        }} />
        <AffTile c={ga} label="Grants and revokes by role" as="count" noun="sets of changes"
          cause={(rows) => `${plural(rows.filter((r) => isFlagged(r) && String(r.grantee_name).toUpperCase() === "PUBLIC").length, "grant")} went to PUBLIC, which every user has.`} />
        <AffTile c={dd} label="Objects created, changed or dropped" as="count" noun="sets of changes"
          cause={() => `${plural(ddl, "DDL statement")}; ${fmtInt(drops)} were DROPs (${fmtShare(pctOf(drops, ddl))}).`} />
      </SummaryTileRow>
      <Slot c={dd} title="Changes per day, by kind" subtitle="DDL statements per day · each panel on its own scale · last day partial">
        {(rows) => (rows.length ? <DdlTimeline rows={rows} p={p} /> : null)}
      </Slot>
      <Row2>
        <Slot c={sc} title="Security changes, by kind" subtitle={`Statements that change users, roles, grants or security policies`}>
          {(rows) => {
            const total = rows.reduce((s, r) => s + numOrZero(r.statements), 0);
            const kinds = rankTally(tally(rows, (r) => words(r.change_kind) || "(no kind)", (r) => numOrZero(r.statements)).map((g) => [g.name, g.value] as [string, number]),
              total, (v) => plural(v, "statement"), 7, capWords).map((x) => ({ ...x, strong: x.rest, rest: x.strong }));
            const who: CxBarRow[] = tally(rows, (r) => String(r.role_name || "(no role)"), (r) => numOrZero(r.statements))
              .map((g) => ({ key: g.name, name: g.name, value: g.value, status: g.status, strong: plural(g.value, "statement"),
                onClick: () => DrawerBus.open({ id: "sf_sec_security_config_changes", col: "role_name", val: g.name, label: g.name }) })).sort((x, y) => y.value - x.value);
            return (
              <div>
                <CxRanked items={kinds} ariaLabel="Security changes by kind" />
                <div className="cx-block"><CxEyebrow>Who made them</CxEyebrow><CxBarRows rows={who} n={6} ariaLabel="Security changes by role" /></div>
              </div>
            );
          }}
        </Slot>
        <Slot c={pg} title="Privileged grants, by grantee" subtitle="Admin roles, ownership and account privileges granted in the window">
          {(rows) => {
            const items: CxRankItem[] = tally(rows, (r) => String(r.grantee || r.user_name || r.grantee_role || "(no grantee)")).map((g) => {
              const type = g.rows[0] && g.rows[0].grantee_type ? words(g.rows[0].grantee_type) : "";
              return {
                key: g.name, label: <span className="cx-dotlabel"><CxDot status={g.status} /><span>{g.name}{type ? <span className="cx-muted">{` · ${type}`}</span> : null}</span></span>, value: g.n,
                strong: plural(g.n, "grant"), rest: [...new Set(g.rows.map((r) => String(r.privilege || "")))].filter(Boolean).slice(0, 2).join(", "),
                onClick: () => DrawerBus.open({ id: "sf_sec_privileged_grant_changes", col: "grantee", val: g.name, label: g.name }),
              };
            }).sort((x, y) => y.value - x.value);
            return items.length ? <div><CxDotLegend statuses={rows.map((r) => r.status)} /><RankedAbove items={items} noun="grantees" ariaLabel="Privileged grants by grantee" /></div> : null;
          }}
        </Slot>
      </Row2>
    </div>
  );
}

// ═══════════════════════ PII › Sensitive data ═══════════════════════

const category = (r: Row) => words(r.semantic_category || r.privacy_category || "unclassified");

/** Sensitive columns grouped by a key as ranked "N of M · share" rows, the highest unmasked share first. */
function unmaskedRanked(rows: Row[], key: (r: Row) => string, col: string | null, cap = false): CxRankItem[] {
  return tally(rows, key).map((g) => {
    const v = g.rows.filter((r) => !isTrue(r.is_masked)).length;
    return {
      key: g.name, label: cap ? capWords(g.name) : g.name, value: pctOf(v, g.n) ?? 0, strong: `${fmtInt(v)} of ${fmtInt(g.n)}`, rest: fmtShare(pctOf(v, g.n)),
      onClick: col ? drawerBy("sf_gov_sensitive_columns_unprotected", col, g.name, g.name) : null,
    };
  }).sort((a, b) => b.value - a.value || String(a.label).localeCompare(String(b.label)));
}

/** Ranked rows, the first `n`, then "Show N more <noun>". */
function RankedMore({ items, n = 8, noun, ariaLabel, labelWidth }: { items: CxRankItem[]; n?: number; noun: string; ariaLabel: string; labelWidth?: number }) {
  const [all, setAll] = React.useState(false);
  const shown = all ? items : items.slice(0, n);
  return (
    <div>
      <CxRanked items={shown} max={100} labelWidth={labelWidth} ariaLabel={ariaLabel} />
      {items.length > n && <div className="cx-foot"><button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(items.length - n)} more ${noun}`}</button></div>}
    </div>
  );
}

export function ApPiiSensitive(p: ApPageProps) {
  const uc = useCheck(p, "sf_gov_sensitive_columns_unprotected");
  const cc = useCheck(p, "sf_gov_classification_coverage");
  const lin = useCheck(p, "sf_secx_sensitive_lineage_untagged");
  const den = useCheck(p, "sf_gov_classification_denominator");
  const open = (uc.rows || []).filter((r) => !isTrue(r.is_masked));
  const tables = distinct(uc.rows || [], "table_fqn");
  const openTables = distinct(open, "table_fqn");
  const tagged = (den.rows || []).reduce((s, r) => s + numOrZero(r.tagged_columns), 0);
  const cols = (den.rows || []).reduce((s, r) => s + numOrZero(r.total_columns), 0);
  useLede(p, uc.loading || den.loading, [
    uc.rows ? `The classifier found sensitive columns in ${plural(tables, "table")}; ${fmtInt(openTables)} of them have a column with no masking policy.` : null,
    den.rows && cols ? `Only ${fmtShare(pctOf(tagged, cols))} of all columns carry a tag.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={uc} label="Sensitive columns with no mask" badge build={(rows) => ({
          headline: fmtShare(pctOf(openTables, tables)), unit: " of tables",
          base: `${fmtInt(openTables)} of ${plural(tables, "table")}; ${fmtInt(open.length)} of ${plural(rows.length, "sensitive column")} have no masking policy.`,
          cause: "No masking policy reaches them: every reader sees the value in clear.", openLabel: "By database ↓",
        })} />
        <AffTile c={cc} label="Found sensitive, left untagged" noun="columns" openLabel="By category ↓"
          cause={(rows) => `Found sensitive by the classifier, but no tag was applied. ${fmtInt(rows.filter((r) => isFlagged(r) && !isTrue(r.is_masked)).length)} of them are also unmasked.`} />
        <AffTile c={lin} label="Copied into untagged columns" as="count" noun="columns"
          cause={() => "Copied by CTAS or INSERT … SELECT into columns with no tag or mask."} />
        <CheckTile c={den} label="Columns tagged, of all columns" badge build={(rows) => {
          const withTag = rows.filter((r) => numOrZero(r.tagged_columns) > 0).length;
          return {
            headline: fmtShare(pctOf(tagged, cols)), unit: " of columns",
            base: `${fmtInt(tagged)} of ${plural(cols, "column")} carry a tag. ${fmtInt(rows.length - withTag)} of ${plural(rows.length, "database")} have none.`,
            cause: "Tag-based masking cannot start where nothing is tagged.", openLabel: "By database ↓",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={uc} title="Unmasked sensitive columns, by database" subtitle="Unmasked columns · bar = share of the database's sensitive columns">
          {(rows) => (
            <div>
              <CxStat>{<span><b>{`${fmtInt(open.length)} of ${plural(rows.length, "sensitive column")}`}</b>{` are unmasked (${fmtShare(pctOf(open.length, rows.length))}).`}</span>}</CxStat>
              <div className="cx-block"><RankedMore items={unmaskedRanked(rows, (r) => String(r.database_name || "(no database)"), "database_name")} noun="databases" labelWidth={190} ariaLabel="Unmasked sensitive columns by database" /></div>
            </div>
          )}
        </Slot>
        <Slot c={uc} title="Unmasked sensitive columns, by kind" subtitle="What the unmasked columns hold · share of each kind left unmasked">
          {(rows) => {
            const items = unmaskedRanked(rows, category, null, true);
            if (items.length < 2) return null;
            // Kinds with the same share read as one sentence, not identical bars.
            if (new Set(items.map((x) => x.value)).size === 1) return <CxStat>{`${items.map((x) => x.label).join(", ")}: each ${items[0].rest} unmasked.`}</CxStat>;
            return <RankedMore items={items} noun="kinds" ariaLabel="Unmasked sensitive columns by kind" />;
          }}
        </Slot>
      </Row2>
      <GovLineageUntagged p={p} />
      <Slot c={uc} title="Tables with unmasked sensitive columns" subtitle="Worst first · bar = unmasked share of the table's sensitive columns · select a row">
        {(rows) => {
          const groups = tally(rows, (r) => String(r.table_fqn || "(no table)")).map((g) => ({ ...g, open: g.rows.filter((r) => !isTrue(r.is_masked)) }))
            .filter((g) => g.open.length > 0).sort((a, b) => b.open.length - a.open.length || b.n - a.n);
          if (!groups.length) return okNote("Every sensitive column has a masking policy.");
          return (
            <CxTable ariaLabel="Tables with unmasked sensitive columns" n={10}
              cols={[{ label: "Table" }, { label: "Unmasked", width: "28%" }, { label: "Columns", num: true }, { label: "Holds" }]}
              rows={groups.map((g) => ({
                key: g.name, status: g.status, onClick: drawerBy("sf_gov_sensitive_columns_unprotected", "table_fqn", g.name, g.name),
                cells: [<CxObjName full={g.name} />, <CxTwoBar part={g.open.length} whole={g.n} max={g.n} />, `${fmtInt(g.open.length)} of ${fmtInt(g.n)}`,
                  [...new Set(g.open.map(category))].slice(0, 3).join(", ")],
              }))} />
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ PII › Masking & row policies ═══════════════════════

// A policy's state, from what it is attached to and whether any query ever evaluated it.
function policyState(r: Row): string {
  const att = numOrZero(r.attachments), inactive = numOrZero(r.inactive_attachments);
  if (att === 0) return "Attached to nothing";
  if (inactive >= att) return "Only on dropped objects";
  if (numOrZero(r.queries_evaluated) === 0) return "Attached, never evaluated";
  if (inactive > 0) return "Partly on dropped objects";
  return "In use";
}
const POLICY_COLORS: Record<string, string> = {
  "In use": "var(--c1)", "Attached, never evaluated": "var(--c2)", "Partly on dropped objects": "var(--c3)",
  "Only on dropped objects": "var(--c4)", "Attached to nothing": "var(--c5)",
};

export function ApPiiPolicies(p: ApPageProps) {
  const up = useCheck(p, "sf_secx_unused_policies");
  const ex = useCheck(p, "sf_secx_policy_body_exemptions");
  const pp = useCheck(p, "sf_gov_privacy_policies_unattached");
  const uc = { ...useCheck(everyCheck(p), "sf_gov_sensitive_columns_unprotected"), open: () => p.goTo({ tab: "pii", subtab: "sensitive", focusQueryId: null }) };
  const aU = up.rows ? affOf(up.f, up.rows, "policies") : null;
  const aE = ex.rows ? affOf(ex.f, ex.rows, "policies") : null;
  useLede(p, up.loading || ex.loading, [
    aU ? `${ofText(aU)} protect nothing: unattached, never evaluated or on dropped objects.` : null,
    aE ? `${ofText(aE)} let an admin role or PUBLIC straight through.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <AffTile c={up} label="Policies that protect nothing" noun="policies" openLabel="By state ↓"
          cause={(rows) => {
            const fl = rows.filter(isFlagged);
            const n = (s: string) => fl.filter((r) => policyState(r) === s).length;
            return `${fmtInt(n("Attached to nothing"))} attached to nothing, ${fmtInt(n("Attached, never evaluated"))} never evaluated, ${fmtInt(n("Only on dropped objects") + n("Partly on dropped objects"))} on dropped objects.`;
          }} />
        <AffTile c={ex} label="Policies that let admins through" noun="policies" openLabel="By role ↓"
          cause={(rows) => `Let roles straight through: ${fmtInt(rows.filter((r) => isTrue(r.exempts_public)).length)} exempt PUBLIC, ${fmtInt(rows.filter((r) => isTrue(r.exempts_admin)).length)} exempt an admin role.`} />
        <AffTile c={pp} label="Aggregation & projection policies" as="count" noun="policies"
          cause={() => "Attached nowhere or in a broken state."} />
        <CheckTile c={uc} label="Sensitive columns covered" build={(rows) => {
          const masked = rows.filter((r) => isTrue(r.is_masked)).length;
          return {
            headline: fmtShare(pctOf(masked, rows.length)), unit: " of sensitive columns",
            base: `${fmtInt(masked)} of ${fmtInt(rows.length)} are covered; ${fmtInt(rows.length - masked)} are still in clear.`,
            cause: "For context.", openLabel: "Sensitive data →",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <div>
          <Slot c={up} title="Masking and row policies, by state" subtitle="Every policy the audit role can see">
            {(rows) => {
              const items: CxRankItem[] = Object.keys(POLICY_COLORS).map((label) => {
                const v = rows.filter((r) => policyState(r) === label).length;
                return { key: label, label, value: v, color: POLICY_COLORS[label], strong: plural(v, "policy", "policies"), rest: fmtShare(pctOf(v, rows.length)) };
              }).filter((x) => x.value > 0);
              const kinds: CxRankItem[] = tally(rows, (r) => words(r.policy_kind) || "(no kind)").map((g) => {
                const v = g.rows.filter((r) => policyState(r) === "In use").length;
                return { key: g.name, label: `${g.name.charAt(0).toUpperCase()}${g.name.slice(1)}`, value: pctOf(v, g.n) ?? 0, strong: fmtShare(pctOf(v, g.n)), rest: `${fmtInt(v)} of ${fmtInt(g.n)}` };
              });
              return (
                <div>
                  <CxRanked items={items} ariaLabel="Policies by state" />
                  {kinds.length >= 2 && <div className="cx-block"><CxEyebrow>Share in use, by kind</CxEyebrow><CxRanked items={kinds} max={100} ariaLabel="Share of policies in use by kind" /></div>}
                </div>
              );
            }}
          </Slot>
          <GovMaskAttachment p={p} />
        </div>
        <Slot c={ex} title="Who the policies let through" subtitle="Roles a policy body exempts · bar = policies · dot = status">
          {(rows) => {
            const by = new Map<string, { n: number; status: string }>();
            rows.forEach((r) => String(r.exempt_roles || "").split(",").map((x) => x.trim()).filter(Boolean).forEach((role) => {
              const cur = by.get(role) || { n: 0, status: "OK" };
              cur.n += 1;
              cur.status = worse(cur.status, r.status);
              by.set(role, cur);
            }));
            const items: CxBarRow[] = [...by.entries()].map(([role, v]) => ({ key: role, name: role, value: v.n, status: v.status, strong: plural(v.n, "policy", "policies"), onClick: () => ex.open() }))
              .sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Roles exempted by policies" />
              : <div className="chart-note-oneline">No policy body exempts a role.</div>;
          }}
        </Slot>
      </Row2>
      <Slot c={up} title="Policies that protect nothing" subtitle="Attached to nothing, never evaluated, or on dropped objects · snapshot at export · select a row">
        {(rows) => {
          const fl = rows.filter(isFlagged).sort((a, b) => numOrZero(a.attachments) - numOrZero(b.attachments));
          if (!fl.length) return okNote("Every policy protects something.");
          return (
            <CxTable ariaLabel="Policies that protect nothing" n={10}
              cols={[{ label: "Policy" }, { label: "Kind" }, { label: "State" }, { label: "References", num: true }, { label: "Last evaluated", num: true }]}
              rows={fl.map((r) => ({
                key: `${r.account_id}|${r.policy_id ?? r.policy_fqn}`, status: r.status,
                onClick: drawerBy("sf_secx_unused_policies", "policy_fqn", r.policy_fqn, nameId(r.policy_name, r.policy_id)),
                cells: [nameId(r.policy_name, r.policy_id, "(unnamed policy)"), words(String(r.policy_kind || "").replace(/_POLICY$/i, "")),
                  <CxChip status={policyState(r) === "In use" ? "OK" : r.status}>{policyState(r)}</CxChip>,
                  numOrZero(r.inactive_attachments) > 0 ? `${fmtInt(numOrZero(r.attachments) - numOrZero(r.inactive_attachments))} of ${fmtInt(r.attachments)}` : fmtInt(numOrZero(r.attachments)),
                  r.last_evaluated ? lastDay(r.last_evaluated) : "Never"],
              }))} />
          );
        }}
      </Slot>
      <GovPolicyOwnerFit p={p} />
    </div>
  );
}

// ═══════════════════════ PII › Who reads it, where it goes ═══════════════════════

/** Every day of the window (so a day with no egress is an empty slot, not skipped), else the rows' own days. */
function egressDays(rows: Row[], p: ApPageProps): string[] {
  const span = windowSpan(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
  if (span) {
    const out: string[] = [];
    for (let t = span.first; t <= span.last; t += 86400000) out.push(new Date(t).toISOString().slice(0, 10));
    return out;
  }
  return [...new Set(rows.map((r) => day(r.day)).filter((d): d is string => !!d))].sort();
}
const destOf = (r: Row) => {
  const cloud = r.target_cloud ? String(r.target_cloud) : "";
  // The region often repeats the cloud ("AWS_EU_WEST_1"): say the cloud once.
  const region = r.target_region ? String(r.target_region).replace(new RegExp(`^${cloud}[_ ]`, "i"), "") : "";
  return `${words(r.transfer_type || r.row_kind)} → ${[cloud, region].filter(Boolean).join(" ") || "(no destination)"}`;
};

export function ApPiiReads(p: ApPageProps) {
  const sa = useCheck(p, "sf_gov_sensitive_data_access");
  const eg = useCheck(p, "sf_gov_data_egress");
  const sh = useCheck(p, "sf_gov_shares_sensitive_columns");
  const dm = useCheck(p, "sf_sec_data_movement_violations");
  const saRows = sa.rows || [];
  const roles = distinct(saRows, "role_name"), flRoles = distinct(saRows.filter(isFlagged), "role_name");
  const gb = (eg.rows || []).reduce((s, r) => s + numOrZero(r.gb_window), 0);
  const dests = new Set((eg.rows || []).filter((r) => numOrZero(r.gb_window) > 0).map(destOf));
  useLede(p, sa.loading || eg.loading, [
    sa.rows ? `${fmtInt(flRoles)} of ${plural(roles, "role")} read sensitive columns in clear.` : null,
    eg.rows ? `${fmtSize(gb)} left the account to ${plural(dests.size, "destination")}.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={sa} label="Roles that read sensitive columns" badge build={(rows) => ({
          headline: fmtShare(pctOf(flRoles, roles)), unit: " of roles",
          base: `${fmtInt(flRoles)} of ${plural(roles, "role")}: ${fmtInt(rows.reduce((s, r) => s + numOrZero(r.queries), 0))} queries by ${plural(distinct(rows, "user_name"), "user")}.`,
          cause: `${fmtInt(distinct(rows.filter((r) => isFlagged(r) && ADMIN_RE.test(String(r.role_name || ""))), "role_name"))} of them are admin roles.`, openLabel: "By role ↓",
        })} />
        <CheckTile c={eg} label="Data leaving the account" badge build={(rows) => {
          const fl = new Set(rows.filter(isFlagged).map(destOf));
          return {
            headline: fmtSize(gb), unit: " in the window",
            base: `${fmtInt(fl.size)} of ${plural(dests.size, "destination")} flagged; ${plural(distinct(rows, "role_name"), "role")} unloading.`,
            cause: "Unloads, copies and replication, by cloud and region.", openLabel: "By destination ↓",
          };
        }} />
        <AffTile c={sh} label="Shares carrying sensitive columns" as="count" noun="shares" openLabel="Sharing & org →"
          onOpen={() => p.goTo({ tab: "sharing", subtab: "shares", focusQueryId: null })}
          cause={(rows) => `${plural(rows.reduce((s, r) => s + numOrZero(r.unmasked_sensitive_columns), 0), "sensitive column")} shared with no mask. As of the export snapshot.`} />
        <AffTile c={dm} label="Data movement policy hits" as="count" noun="users"
          cause={(rows) => { const t = [...new Set(rows.filter(isFlagged).map((r) => words(r.movement_type)))]; return t.length ? `Moved protected tables to ${t.slice(0, 3).join(", ")}.` : "No blocked move in the window."; }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={sa} title="Sensitive reads, by role" subtitle="Queries that read a sensitive column in clear · bar = queries">
          {(rows) => {
            const items: CxBarRow[] = tally(rows, (r) => String(r.role_name || "(no role)"), (r) => numOrZero(r.queries)).map((g) => ({
              key: g.name, name: g.name, value: g.value, status: g.status, strong: fmtInt(g.value), rest: plural(distinct(g.rows, "user_name"), "user"),
              onClick: () => DrawerBus.open({ id: "sf_gov_sensitive_data_access", col: "role_name", val: g.name, label: g.name }),
            })).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Sensitive reads by role" /> : null;
          }}
        </Slot>
        <Slot c={eg} title="Where data goes" subtitle="Data leaving the account, by transfer type and destination · in the window">
          {(rows) => {
            const items: CxBarRow[] = tally(rows, destOf, (r) => numOrZero(r.gb_window)).filter((g) => g.value > 0).map((g) => ({
              key: g.name, name: `${g.name}${g.rows.some((r) => isTrue(r.new_destination)) ? " (new)" : ""}`, value: g.value, status: g.status, strong: fmtSize(g.value), onClick: () => eg.open(),
            })).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Data leaving the account by destination" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={eg} title="Data leaving per day, by destination" subtitle="GB a day leaving the account · every day of the window">
        {(rows) => {
          const days = rows.some((r) => r.day != null) ? egressDays(rows, p) : [];
          const series = days.length ? tally(rows.filter((r) => r.day != null), destOf, (r) => numOrZero(r.gb_window)).filter((g) => g.value > 0).map((g) => {
            const m = new Map<string, number>();
            g.rows.forEach((r) => { const d = day(r.day)!; m.set(d, (m.get(d) || 0) + numOrZero(r.gb_window)); });
            return { name: g.name, id: g.name, values: days.map((d) => m.get(d) || 0) };
          }) : [];
          return series.length ? <div><div className="cx-axis-unit">GB / day</div><Columns days={days} series={series} unitLabel="GB / day" valueFmt={(v: number) => fmtSize(v)} ariaLabel="Data leaving the account per day by destination" /></div> : null;
        }}
      </Slot>
      <Slot c={sa} title="The people behind the reads" subtitle="Users who read sensitive columns in clear · worst first · select a row">
        {(rows) => (
          <CxTable ariaLabel="Users reading sensitive columns" n={10}
            cols={[{ label: "User" }, { label: "Roles used" }, { label: "Queries", num: true }, { label: "Tables", num: true }, { label: "Last read", num: true }]}
            rows={tally(rows, (r) => String(r.user_name || "(no user)"), (r) => numOrZero(r.queries)).sort((a, b) => (STATUS_RANK[b.status] ?? 0) - (STATUS_RANK[a.status] ?? 0) || b.value - a.value).map((g) => ({
              key: g.name, status: g.status, onClick: drawerBy("sf_gov_sensitive_data_access", "user_name", g.name, g.name),
              cells: [g.name, [...new Set(g.rows.map((r) => String(r.role_name || "")))].filter(Boolean).join(", ") || "–", fmtInt(g.value),
                fmtInt(distinct(g.rows, "table_fqn")), lastDay(g.rows.map((r) => String(r.last_read || "")).sort().pop())],
            }))} />
        )}
      </Slot>
      <GovAgentsFit p={p} />
    </div>
  );
}

// ═══════════════════════ PII › Data quality ═══════════════════════

export function ApPiiQuality(p: ApPageProps) {
  const dmf = useCheck(p, "sf_gov_dmf_coverage");
  const ex = useCheck(p, "sf_gov_dmf_expectation_failures");
  const st = useCheck(p, "sf_gov_dmf_static_table_schedules");
  const rows0 = dmf.rows || [];
  const cov = rows0.reduce((s, r) => s + numOrZero(r.covered_tables), 0);
  const all = rows0.reduce((s, r) => s + numOrZero(r.base_tables), 0);
  const none = rows0.filter((r) => numOrZero(r.base_tables) > 0 && numOrZero(r.covered_tables) === 0).length;
  useLede(p, dmf.loading, dmf.rows && all ? `A data metric function watches ${fmtInt(cov)} of ${plural(all, "base table")}; ${fmtInt(none)} of ${plural(rows0.length, "database")} have none.` : null);
  return (
    <div className="ais-page cx-e">
      <div className="summary-tile-row compact ln-tiles-3">
        <CheckTile c={dmf} label="Tables watched by a DMF" badge build={(rows) => ({
          headline: fmtShare(pctOf(cov, all)), unit: " of base tables",
          base: `${fmtInt(cov)} of ${plural(all, "table")}. ${fmtInt(none)} of ${plural(rows.length, "database")} have none.`,
          cause: `${plural(rows.reduce((s, r) => s + numOrZero(r.sensitive_uncovered), 0), "table")} holding sensitive columns are unwatched.`, openLabel: "By database ↓",
        })} />
        <AffTile c={ex} label="Expectations failing" as="count" noun="tables" openLabel="Expectations ↓" onOpen={() => scrollToAnchor("dq-exp")}
          cause={(rows) => {
            const worst = Math.max(0, ...rows.filter(isFlagged).map((r) => numOrZero(r.failing_days)));
            return `Expectations that fail, or error and are never checked.${worst ? ` The worst has failed ${plural(worst, "day")} running.` : ""}`;
          }} />
        <MoneyTile c={st} label="DMF billed, table unchanged"
          cause={() => "DMF runs on tables where no rows were added, removed or updated."} />
      </div>
      <Row2>
        <Slot c={dmf} title="Unwatched databases that matter most" subtitle="Most sensitive tables with no DMF first · select a row">
          {(rows) => (
            <CxTable ariaLabel="Databases by unwatched tables" n={8}
              cols={[{ label: "Database" }, { label: "Base tables", num: true }, { label: "Watched", num: true }, { label: "Sensitive unwatched", num: true }]}
              rows={[...rows].sort((a, b) => numOrZero(b.sensitive_uncovered) - numOrZero(a.sensitive_uncovered) || (numOrZero(b.base_tables) - numOrZero(b.covered_tables)) - (numOrZero(a.base_tables) - numOrZero(a.covered_tables)))
                .map((r) => ({
                  key: String(r.database_name), status: r.status, onClick: drawerBy("sf_gov_dmf_coverage", "database_name", r.database_name, String(r.database_name)),
                  cells: [String(r.database_name || "(no database)"), fmtInt(numOrZero(r.base_tables)), fmtInt(numOrZero(r.covered_tables)), <b>{fmtInt(numOrZero(r.sensitive_uncovered))}</b>],
                }))} />
          )}
        </Slot>
        <Slot c={dmf} title="Tables watched, by database" subtitle="Share of base tables with a DMF · lowest first">
          {(rows) => {
            const items: CxRankItem[] = rows.filter((r) => numOrZero(r.base_tables) > 0).map((r) => ({
              key: String(r.database_name), label: String(r.database_name || "(no database)"), value: pctOf(numOrZero(r.covered_tables), numOrZero(r.base_tables)) ?? 0,
              strong: fmtShare(pctOf(numOrZero(r.covered_tables), numOrZero(r.base_tables))), rest: `${fmtInt(r.covered_tables)} of ${fmtInt(r.base_tables)}`,
              onClick: drawerBy("sf_gov_dmf_coverage", "database_name", r.database_name, String(r.database_name)),
            })).sort((x, y) => x.value - y.value);
            if (!items.length) return null;
            // Databases at 0% read as a list, not as empty bars.
            const zero = items.filter((x) => x.value === 0);
            const some = items.filter((x) => x.value > 0);
            return (
              <div>
                <CxStat>{<span>{zero.length ? `${plural(zero.length, "database")} ${zero.length === 1 ? "is" : "are"} at ` : ""}{zero.length ? <b>0%</b> : null}{zero.length ? "; " : ""}{"account-wide it is "}<b>{fmtShare(pctOf(cov, all))}</b>{"."}</span>}</CxStat>
                {zero.length > 0 && <div className="cx-stat cx-muted cx-dblist">{zero.map((x) => x.label).join(" · ")}</div>}
                {some.length > 0 && <div className="cx-block"><CxRanked items={some} max={100} layout="above" ariaLabel="Share of base tables watched by database" /></div>}
              </div>
            );
          }}
        </Slot>
      </Row2>
      <GovQualityFit p={p} />
    </div>
  );
}

// ═══════════════════════ Lineage › Dependencies & lineage ═══════════════════════

/** A day as "Sep 19", with the year when it falls before the window. */
function dayYear(v: any, p: ApPageProps): string {
  const d = day(v);
  if (!d) return "–";
  const span = windowSpan(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
  const t = Date.parse(`${d}T00:00:00Z`);
  return span && Number.isFinite(t) && t < span.first ? `${fmtDayShort(d)}, ${d.slice(0, 4)}` : fmtDayShort(d);
}

/** Label-above-bar rows, the first 8, then "Show N more". */
function RankedAbove({ items, noun, ariaLabel, n = 8 }: { items: CxRankItem[]; noun: string; ariaLabel: string; n?: number }) {
  const [all, setAll] = React.useState(false);
  return (
    <div>
      <CxRanked items={all ? items : items.slice(0, n)} layout="above" max={Math.max(1, ...items.map((x) => x.value))} ariaLabel={ariaLabel} />
      {items.length > n && <div className="cx-foot"><button type="button" className="cx-linkbtn" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show ${fmtInt(items.length - n)} more ${noun}`}</button></div>}
    </div>
  );
}

export function ApLineageDeps(p: ApPageProps) {
  const br = useCheck(p, "sf_obj_broken_views");
  const bl = useCheck(p, "sf_lin_blast_radius");
  const tf = useCheck(p, "sf_lin_table_flows");
  const aB = br.rows ? affOf(br.f, br.rows, "views") : null;
  const deps = (bl.rows || []).reduce((s, r) => s + numOrZero(r.total_dependents), 0);
  useLede(p, br.loading || bl.loading, [
    aB ? `${ofText(aB)} the role can see point at objects that no longer exist.` : null,
    bl.rows && bl.rows.length ? `${plural(bl.rows.length, "source object")} carry ${plural(deps, "declared dependent")}.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <AffTile c={br} label="Views pointing at dropped objects" as="count" noun="views" openLabel="Which ones ↓"
          cause={(rows) => {
            const fns = rows.filter((r) => /FUNCTION/i.test(String(r.object_type || ""))).length;
            return `${plural(rows.length - fns, "view")} and ${plural(fns, "function")}. ${plural(rows.reduce((s, r) => s + numOrZero(r.dependents), 0), "dependent")} break with them.`;
          }} />
        <AffTile c={bl} label="Objects most depended on" as="count" noun="source objects" openLabel="By source ↓"
          extra={(rows) => `${plural(deps, "declared dependent")}, up to ${plural(Math.max(0, ...rows.map((r) => numOrZero(r.max_depth))), "level")} deep.`}
          cause={(rows) => { const t = [...rows].sort((a, b) => numOrZero(b.total_dependents) - numOrZero(a.total_dependents))[0]; return t ? `${t.source_fqn} carries ${fmtShare(pctOf(numOrZero(t.total_dependents), deps))} of the declared lineage.` : undefined; }} />
        <AffTile c={tf} label="Tables that feed the most tables" as="count" noun="tables" openLabel="By source ↓"
          extra={(rows) => `${plural(rows.filter(isFlagged).reduce((s, r) => s + numOrZero(r.feeds_tables), 0), "downstream table")}`}
          cause={() => "From what queries actually wrote (CTAS, INSERT … SELECT and MERGE), not declared lineage."} />
      </SummaryTileRow>
      <Row2>
        <Slot c={bl} title="Declared dependents, by source" subtitle={`Objects downstream of a table or view · all ${plural((bl.rows || []).length, "source")}`}>
          {(rows) => {
            const items: CxRankItem[] = [...rows].sort((x, y) => numOrZero(y.total_dependents) - numOrZero(x.total_dependents)).map((r) => ({
              key: String(r.source_fqn), label: <span className="cx-dotlabel"><CxDot status={r.status} /><CxObjName full={String(r.source_fqn || "(unnamed object)")} /></span>, value: numOrZero(r.total_dependents),
              strong: plural(numOrZero(r.total_dependents), "dependent"), rest: `depth ${fmtInt(numOrZero(r.max_depth))}`,
              onClick: () => DrawerBus.open({ id: "sf_lin_blast_radius", col: "source_fqn", val: String(r.source_fqn), label: String(r.source_fqn) }),
            }));
            return items.length ? <div><CxDotLegend statuses={rows.map((r) => r.status)} /><RankedAbove items={items} noun="sources" ariaLabel="Dependents per source object" /><div className="cx-foot">{"Bar = declared dependents · depth = levels downstream."}</div></div> : null;
          }}
        </Slot>
        <Slot c={tf} title="Tables that feed the most other tables" subtitle="Downstream tables written from each source in the window">
          {(rows) => {
            const items: CxRankItem[] = rows.filter((r) => numOrZero(r.feeds_tables) > 0).sort((x, y) => numOrZero(y.feeds_tables) - numOrZero(x.feeds_tables)).map((r) => ({
              key: String(r.table_fqn), label: <span className="cx-dotlabel"><CxDot status={r.status} /><CxObjName full={String(r.table_fqn || "(unnamed table)")} /></span>, value: numOrZero(r.feeds_tables),
              strong: plural(numOrZero(r.feeds_tables), "table"), rest: plural(numOrZero(r.writers), "writer"),
              onClick: () => DrawerBus.open({ id: "sf_lin_table_flows", col: "table_fqn", val: String(r.table_fqn), label: String(r.table_fqn) }),
            }));
            return items.length ? <div><CxDotLegend statuses={rows.map((r) => r.status)} /><RankedAbove items={items} noun="tables" ariaLabel="Tables feeding other tables" /></div> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={br} title="Views and functions that point at dropped objects" subtitle="They fail on first use · select a row for the fix">
        {(rows) => rows.length ? (
          <CxTable ariaLabel="Broken views and functions" n={10}
            cols={[{ label: "Object" }, { label: "Kind" }, { label: "Points at (missing)" }, { label: "Dependents", num: true }]}
            rows={[...rows].sort((a, b) => numOrZero(b.dependents) - numOrZero(a.dependents)).map((r) => ({
              key: `${r.account_id}|${r.object_id ?? r.object_fqn}`, status: r.status,
              onClick: drawerBy("sf_obj_broken_views", "object_fqn", r.object_fqn, nameId(r.object_fqn, r.object_id)),
              cells: [<CxObjName full={String(r.object_fqn || "(unnamed object)")} id={r.object_id} />, words(r.object_type),
                <code className="cx-code">{String(r.missing_refs || "–").split(",")[0]}</code>, fmtInt(numOrZero(r.dependents))],
            }))} />
        ) : okNote("No view or function points at a dropped object.")}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Lineage › Usage ═══════════════════════

const LOGIN_BANDS: [string, number, number][] = [["within 7 days", 0, 8], ["8-30 days", 8, 31], ["31-90 days", 31, 91], ["over 90 days", 91, Infinity]];

export function ApLineageUsage(p: ApPageProps) {
  const ua = useCheck(p, "sf_use_user_activity");
  const uv = useCheck(p, "sf_lin_unused_views");
  const da = useCheck(p, "sf_use_database_activity");
  const asOf = p.meta && p.meta.as_of_date ? Date.parse(`${String(p.meta.as_of_date).slice(0, 10)}T00:00:00Z`) : NaN;
  const idle = (ua.rows || []).filter((r) => isTrue(r.idle_with_roles));
  const schemas = (da.rows || []).filter((r) => r.schema_name);
  const never = schemas.filter((r) => isTrue(r.never_used));
  const aV = uv.rows ? affOf(uv.f, uv.rows, "views") : null;
  useLede(p, ua.loading || uv.loading || da.loading, [
    ua.rows ? `${fmtInt(idle.length)} of ${plural(ua.rows.length, "user")} hold roles but ran nothing.` : null,
    aV ? `${ofText(aV)} were never read.` : null,
    da.rows && schemas.length ? `${fmtInt(never.length)} of ${plural(schemas.length, "schema")} were never queried.` : null,
  ].filter(Boolean).join(" ") || null);
  const usd = (r: Row) => numOrZero(r.est_storage_usd_month) * (1 - da.disc);
  return (
    <div className="ais-page cx-e">
      <SummaryTileRow compact>
        <CheckTile c={ua} label="Hold roles, run nothing" badge build={(rows) => ({
          headline: fmtShare(pctOf(idle.length, rows.length)), unit: " of users",
          base: `${fmtInt(idle.length)} of ${plural(rows.length, "user")} hold roles but ran nothing.`,
          cause: `${fmtInt(idle.filter((r) => isTrue(r.has_admin_role)).length)} of them can use an admin role.`, openLabel: "By last sign-in ↓",
        })} />
        <AffTile c={uv} label="Views never read" as="count" noun="views" openLabel="Which ones ↓"
          cause={(rows) => `No query in the window; ${fmtInt(rows.filter((r) => isFlagged(r) && isTrue(r.is_secure)).length)} of them are secure views.`} />
        <CheckTile c={da} label="Databases nobody queries" badge build={(rows) => {
          const dbs = tally(rows.filter((r) => r.schema_name), (r) => String(r.database_name || "(no database)"));
          const deadDbs = dbs.filter((g) => g.rows.every((r) => isTrue(r.never_used)));
          const priced = rows.some((r) => r.price_basis === "priced");
          return {
            headline: fmtInt(deadDbs.length), unit: ` of ${plural(dbs.length, "database")}`,
            base: `${fmtInt(never.length)} of ${plural(schemas.length, "schema")} were never used.`,
            cause: priced ? `${fmtMoney(never.reduce((s, r) => s + usd(r), 0), 0)} a month of storage sits in never-used schemas.` : undefined, openLabel: "By schema ↓",
          };
        }} />
        <CheckTile c={da} label="Where the reads go" build={() => {
          const reads = schemas.map((r) => numOrZero(r.read_queries)).sort((a, b) => b - a);
          const all = reads.reduce((s, v) => s + v, 0);
          const top = reads.slice(0, 3).reduce((s, v) => s + v, 0);
          return {
            headline: fmtShare(pctOf(top, all)), unit: " of read queries",
            base: `${fmtInt(top)} of ${fmtInt(all)} read queries hit 3 of ${plural(schemas.length, "schema")}. For context.`, openLabel: "By schema ↓",
          };
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={ua} title="Users by last sign-in" subtitle="days since the last successful sign-in, as of the export · dark bar = can use an admin role">
          {(rows) => {
            const bandOfRow = (r: Row) => {
              const s = r.last_success_login ? String(r.last_success_login) : "";
              const t = s ? Date.parse(s.slice(0, 19) + (s.length <= 10 ? "T00:00:00Z" : "Z")) : NaN;
              if (!Number.isFinite(t) || !Number.isFinite(asOf)) return s ? null : "never";
              const d = Math.max(0, Math.floor((asOf - t) / 86400000));
              const b = LOGIN_BANDS.find(([, lo, hi]) => d >= lo && d < hi);
              return b ? b[0] : null;
            };
            const by = new Map<string, { value: number; whole: number }>();
            [...LOGIN_BANDS.map((b) => b[0]), "never"].forEach((k) => by.set(k, { value: 0, whole: 0 }));
            rows.forEach((r) => {
              const k = bandOfRow(r);
              if (!k) return;
              const cur = by.get(k)!;
              cur.whole += 1;
              if (isTrue(r.has_admin_role)) cur.value += 1;
            });
            // Bands stay in time order, the most recent first; "never" last.
            const items = [...by.entries()].filter(([, v]) => v.whole > 0).map(([name, v]) => ({ name: name === "never" ? "Never signed in" : name.charAt(0).toUpperCase() + name.slice(1), value: v.value, whole: v.whole }));
            if (items.length < 2) return null;
            const old = by.get("over 90 days")!.whole + by.get("never")!.whole;
            const max = Math.max(...items.map((x) => x.whole));
            return (
              <div>
                <CxStat>{<span><b>{`${fmtInt(old)} of ${plural(rows.length, "user")}`}</b>{" have not signed in for over 90 days, or never."}</span>}</CxStat>
                <div className="cx-block"><CxTable ariaLabel="Users by last sign-in, admins" cols={[{ label: "Last sign-in" }, { label: "", width: "40%" }, { label: "Users", num: true }, { label: "Admins", num: true }]}
                  foot="Dark part: can use an admin role."
                  rows={items.map((x) => ({ key: x.name, cells: [x.name, <CxTwoBar part={x.value} whole={x.whole} max={max} />, fmtInt(x.whole), x.value ? <b>{fmtInt(x.value)}</b> : "–"] }))} /></div>
              </div>
            );
          }}
        </Slot>
        <Slot c={da} title="Schemas: storage against reads" subtitle="Storage per month, with the queries that used each schema · amber dot = never used">
          {(rows) => {
            const list = rows.filter((r) => r.schema_name);
            if (!list.length) return null;
            const priced = list.some((r) => r.price_basis !== "unpriced" && r.est_storage_usd_month != null);
            const valOf = (r: Row) => (priced ? usd(r) : numOrZero(r.storage_gb));
            const fmtV = (v: number) => (priced ? `${fmtMoney(v, 0)}/mo` : fmtSize(v));
            const items: CxBarRow[] = list.map((r) => {
              const q = numOrZero(r.read_queries) + numOrZero(r.write_queries);
              return {
                key: `${r.database_name}.${r.schema_name}`, name: `${r.database_name}.${r.schema_name}`, id: r.schema_id, value: valOf(r),
                status: isTrue(r.never_used) ? "WARN" : "OK", strong: fmtV(valOf(r)), rest: isTrue(r.never_used) ? "never used" : `${fmtInt(q)} queries`, onClick: () => da.open(),
              };
            }).filter((it) => it.value > 0).sort((x, y) => y.value - x.value);
            return items.length ? <CxBarRows rows={items} ariaLabel="Schema storage and queries" /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={uv} title="Never read in the window" subtitle="Views with no reader · select a row for the fix">
        {(rows) => (
          rows.some(isFlagged) ? <CxTable ariaLabel="Views never read" n={10}
            cols={[{ label: "View" }, { label: "Owner" }, { label: "Created", num: true }, { label: "Last changed", num: true }]}
            rows={rows.filter(isFlagged).map((r) => ({
              key: `${r.account_id}|${r.view_fqn}`, status: r.status, onClick: drawerBy("sf_lin_unused_views", "view_fqn", r.view_fqn, String(r.view_fqn)),
              cells: [<span><CxObjName full={String(r.view_fqn)} />{isTrue(r.is_secure) ? <div className="cx-muted">{"Secure view"}</div> : null}</span>, String(r.view_owner || "–"),
                dayYear(r.created, p), dayYear(r.last_altered, p)],
            }))} /> : okNote("Every view was read in the window.")
        )}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Sharing › Shares & listings ═══════════════════════

export function ApSharingShares(p: ApPageProps) {
  const sl = useCheck(p, "sf_gov_shares_and_listings");
  const ib = useCheck(p, "sf_share_inbound_databases");
  const ra = useCheck(p, "sf_share_reader_accounts");
  const pl = useCheck(p, "sf_cost_marketplace_paid_listings");
  const ss = useCheck(everyCheck(p), "sf_gov_shares_sensitive_columns");
  const out = (sl.rows || []).filter((r) => String(r.share_kind || "").toUpperCase() === "OUTBOUND");
  const consumers = out.reduce((s, r) => s + numOrZero(r.consumer_count), 0);
  const aI = ib.rows ? affOf(ib.f, ib.rows, "inbound databases") : null;
  useLede(p, sl.loading || ib.loading, [
    sl.rows ? `${plural(distinct(out, "database_name"), "database")} leave the account through ${plural(out.length, "share")} to ${plural(consumers, "consumer account")}.` : null,
    aI ? `Inbound, ${ofText(aI)} went unread.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={sl} label="Data shared out" badge build={() => ({
          headline: fmtInt(out.length), unit: ` outbound ${out.length === 1 ? "share" : "shares"}`,
          base: `${plural(distinct(out, "database_name"), "database")} · ${plural(consumers, "consumer account")}`,
          cause: `${fmtInt(out.filter((r) => !r.last_listing_access).length)} of ${fmtInt(out.length)} have no read seen.`, openLabel: "By share ↓",
        })} />
        <AffTile c={ib} label="Inbound databases not read" as="count" noun="databases" openLabel="By database ↓"
          cause={() => "From shares, listings and installed apps."} />
        <CheckTile c={ra} label="Reader accounts" badge build={(rows, c) => {
          const priced = rows.some((r) => r.price_basis === "priced");
          const usd = rows.reduce((s, r) => s + numOrZero(r.est_reader_usd_list), 0) * (1 - c.disc);
          return {
            headline: priced ? fmtMoney(usd, 0) : `${fmtInt(rows.reduce((s, r) => s + numOrZero(r.credits_used), 0))} credits`, unit: " spend", pill: <KindChip>Context</KindChip>,
            base: `${fmtInt(rows.filter(isFlagged).length)} of ${plural(rows.length, "reader account")} flagged`,
            cause: `${fmtInt(rows.filter((r) => numOrZero(r.resource_monitors) === 0).length)} run on your credits with no resource monitor.`,
          };
        }} />
        <MoneyTile c={pl} label="Paid listings" cause={(rows) => {
          const unread = rows.filter((r) => numOrZero(r.read_queries) === 0 && numOrZero(r.charge_amount) > 0).length;
          return `${fmtInt(unread)} of ${plural(rows.length, "paid listing")} nobody queried · billed in its own currency, kept apart`;
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={sl} title="Outbound shares → consumers → last read" subtitle="shares this account gives out · bar = consumer accounts · dot = status">
          {(rows) => {
            const o = rows.filter((r) => String(r.share_kind || "").toUpperCase() === "OUTBOUND");
            if (!o.length) return <div className="chart-note-oneline">No outbound share in this account.</div>;
            const items: StatusBarItem[] = o.map((r) => ({
              key: String(r.share_name), name: String(r.share_name || "(unnamed share)"), value: numOrZero(r.consumer_count), status: r.status,
              valueText: `${plural(numOrZero(r.consumer_count), "consumer")} · ${r.last_listing_access ? `last read ${lastDay(r.last_listing_access)}` : "no read seen"}`,
            }));
            return <StatusBars items={items} n={8} unitLabel="consumers" ariaLabel="Outbound shares by consumers"
              onBarClick={(it) => DrawerBus.open({ id: "sf_gov_shares_and_listings", col: "share_name", val: String(it.key), label: it.name })} />;
          }}
        </Slot>
        <Slot c={ib} title="Inbound databases, by reads" subtitle="databases from shares, listings and installed apps · read queries in the window">
          {(rows) => {
            const items: StatusBarItem[] = rows.map((r) => ({
              key: String(r.database_name), name: String(r.database_name || "(no database)"), value: numOrZero(r.read_queries), status: r.status,
              valueText: numOrZero(r.read_queries) ? `${fmtInt(numOrZero(r.read_queries))} · last ${lastDay(r.last_read_at)}` : "never read",
            }));
            return items.length ? <StatusBars items={items} n={8} unitLabel="read queries" ariaLabel="Inbound databases by read queries"
              onBarClick={(it) => DrawerBus.open({ id: "sf_share_inbound_databases", col: "database_name", val: String(it.key), label: it.name })} /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={{ ...ss, open: () => p.goTo({ tab: "pii", subtab: "reads", focusQueryId: null }) }} title="Sensitive columns inside shares" subtitle="shared tables that hold a column tagged sensitive · bar = sensitive columns · snapshot">
        {(rows) => {
          const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.sensitive_columns) > 0).map((r) => ({
            key: String(r.share_name), name: String(r.share_name || "(unnamed share)"), value: numOrZero(r.sensitive_columns), status: r.status,
            valueText: `${fmtInt(numOrZero(r.unmasked_sensitive_columns))} of ${fmtInt(numOrZero(r.sensitive_columns))} unmasked`,
          }));
          return items.length ? <StatusBars items={items} n={8} ariaLabel="Sensitive columns in shares" /> : <div className="chart-note-oneline">No share carries a sensitive column.</div>;
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Sharing › Accounts ═══════════════════════

export function ApSharingAccounts(p: ApPageProps) {
  const inv = useCheck(p, "sf_org_account_inventory");
  const la = useCheck(p, "sf_org_login_activity_by_account");
  const ef = useCheck(p, "sf_org_edition_fit");
  const dorm = useCheck(p, "sf_org_dormant_accounts");
  const rs = useCheck(p, "sf_org_region_spread");
  const live = (inv.rows || []).filter((r) => !r.deleted_on);
  const noOwner = live.filter((r) => !String(r.account_comment || "").trim());
  const pw = (la.rows || []).reduce((s, r) => s + numOrZero(r.password_only_logins), 0);
  const logins = (la.rows || []).reduce((s, r) => s + numOrZero(r.logins), 0);
  useLede(p, inv.loading || la.loading, [
    inv.rows ? `${plural(live.length, "account")}: ${fmtInt(noOwner.length)} have no owner recorded.` : null,
    la.rows && logins ? `${fmtShare(pctOf(pw, logins))} of sign-ins used a password only.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={inv} label="No owner recorded" badge build={(rows) => {
          const cur = oneCurrency(rows);
          return {
            headline: fmtInt(noOwner.length), unit: ` of ${plural(live.length, "account")}`,
            base: `${fmtShare(pctOf(noOwner.length, live.length))} · ${cur.ok ? `${cur.fmt(rows.reduce((s, r) => s + numOrZero(r.amount), 0))} spend across ${fmtInt(rows.length)} · context` : "more than one currency"}`,
            cause: "Edition, region and bill are known; who answers for them is not.", openLabel: "All accounts ↓",
          };
        }} />
        <CheckTile c={la} label="Password only" badge build={(rows) => {
          const withLogins = rows.filter((r) => numOrZero(r.logins) > 0);
          return {
            headline: fmtShare(pctOf(pw, logins)), unit: " of sign-ins",
            base: `${fmtInt(pw)} of ${fmtInt(logins)} sign-ins · ${fmtInt(withLogins.filter((r) => numOrZero(r.password_only_logins) > 0).length)} of ${plural(withLogins.length, "account")}`,
            cause: [...withLogins].sort((a, b) => numOrZero(b.password_only_pct) - numOrZero(a.password_only_pct)).slice(0, 2).map((r) => `${acct(r)} ${fmtShare(numOrZero(r.password_only_pct))}`).join(", ") || undefined,
            openLabel: "By account ↓",
          };
        }} />
        <MoneyTile c={ef} label="Edition not used" cause={(rows) => {
          const judged = rows.filter((r) => r.status !== "NOT_ASSESSED");
          return `${plural(judged.filter((r) => /downgrade/i.test(String(r.fit || ""))).length, "account")} use no feature of their edition · ${fmtInt(judged.length)} of ${fmtInt(rows.length)} judged`;
        }} />
        <MoneyTile c={dorm} label="Dormant accounts" cause={(rows) => `${fmtInt(rows.filter(isFlagged).length)} of ${plural(rows.length, "account")} · storage, no compute`} />
      </SummaryTileRow>
      <Row2>
        <Slot c={la} title="Password-only sign-ins, by account" subtitle="share of each account's sign-ins">
          {(rows) => {
            const items: ShareItem[] = rows.map((r) => ({
              key: acct(r), name: acct(r),
              value: r.password_only_logins == null ? null : numOrZero(r.password_only_logins),
              total: numOrZero(r.logins) > 0 ? numOrZero(r.logins) : null,
              onClick: drawerBy("sf_org_login_activity_by_account", "account_locator", r.account_locator, acct(r)),
            }));
            return items.length ? <ShareBarList items={items} n={10} noun="sign-ins" /> : null;
          }}
        </Slot>
        <Slot c={rs} title="Spend and transfer per cloud region" subtitle="invoice spend by region · dot = status">
          {(rows) => {
            const cur = oneCurrency(rows);
            if (!cur.ok) return <div className="chart-note-oneline">{MIXED_CURRENCY}</div>;
            const items: StatusBarItem[] = rows.map((r) => ({
              key: `${r.cloud}|${r.region}`, name: `${r.region || r.cloud || "(no region)"} · ${plural(numOrZero(r.live_accounts), "account")}`, value: numOrZero(r.amount), status: r.status,
              valueText: `${cur.fmt(numOrZero(r.amount))}${numOrZero(r.transfer_amount) > 0 ? ` · ${cur.fmt(numOrZero(r.transfer_amount))} transfer` : ""}`,
            }));
            return items.length ? <StatusBars items={items} n={8} ariaLabel="Spend per cloud region" onBarClick={() => rs.open()} /> : null;
          }}
        </Slot>
      </Row2>
      <Slot c={inv} title="Accounts: edition, region and spend" subtitle="ranked by spend · click a row">
        {(rows) => {
          const cur = oneCurrency(rows);
          return (
            <DrillTable aria="Accounts" n={12}
              cols={[{ label: "Account" }, { label: "Edition", width: "auto" }, { label: "Region", width: "minmax(70px, 1fr)" }, { label: "Spend", num: true, width: "auto" }, { label: "Owner", width: "auto" }]}
              rows={[...rows].sort((a, b) => numOrZero(b.amount) - numOrZero(a.amount)).map((r) => ({
                key: String(r.account_locator), status: r.status, onOpen: drawerBy("sf_org_account_inventory", "account_locator", r.account_locator, acct(r)),
                cells: [acct(r), words(r.edition) || "–", String(r.snowflake_region || "–"), cur.ok ? cur.fmt(numOrZero(r.amount)) : fmtInt(numOrZero(r.amount)),
                  r.deleted_on ? dtChip("deleted", "CRITICAL") : String(r.account_comment || "").trim() ? "recorded" : dtChip("no owner", "WARN")],
              }))} />
          );
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Sharing › Spend across accounts ═══════════════════════

export function ApSharingSpend(p: ApPageProps) {
  const sp = useCheck(p, "sf_org_spend_by_account");
  const ss = useCheck(p, "sf_org_spend_by_account_and_service");
  const ov = useCheck(p, "sf_org_overage_and_adjustments");
  const cs = useCheck(p, "sf_org_cloud_services_billed_by_account");
  const sv = useCheck(p, "sf_org_serverless_by_account");
  const spRows = sp.rows || [];
  const cur0 = oneCurrency(spRows);
  const now = spRows.reduce((s, r) => s + numOrZero(r.amount), 0);
  const prev = spRows.reduce((s, r) => s + numOrZero(r.prev_amount), 0);
  const change = prev > 0 ? `${now >= prev ? "+" : "−"}${fmtShare(Math.abs(((now - prev) / prev) * 100))}` : null;
  useLede(p, sp.loading, sp.rows && cur0.ok
    ? `${cur0.fmt(now)} across ${plural(spRows.length, "account")}${change ? `, ${change} on the period before` : ""}.`
    : null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <CheckTile c={sp} label="Organization spend" build={() => ({
          headline: cur0.ok ? cur0.fmt(now) : null, missingReason: cur0.ok ? undefined : "more than one currency: not added", unit: " spend", pill: <KindChip>Context</KindChip>,
          base: `${plural(spRows.length, "account")}${change && cur0.ok ? ` · ${change} vs ${cur0.fmt(prev)} before` : ""}`,
          cause: (() => { const t = [...spRows].sort((a, b) => numOrZero(b.amount) - numOrZero(a.amount))[0]; return t && now > 0 ? `${acct(t)} is ${fmtShare(pctOf(numOrZero(t.amount), now))} of it.` : undefined; })(),
          openLabel: "By account ↓",
        })} />
        <MoneyTile c={ov} label="On-demand overage" cause={(rows) => `${fmtInt(distinct(rows.filter(isFlagged), "account_locator"))} of ${plural(distinct(rows, "account_locator"), "account")} · billed above the contract rate`} />
        <MoneyTile c={cs} label="Cloud services over 10%" cause={(rows) => `${fmtInt(rows.filter(isFlagged).length)} of ${plural(rows.length, "account")} · priced after the 10% adjustment`} />
        <FindingTile p={p} id="cost_chargeback_by_account" label="Chargeback" tab="cost" subtab="chargeback" openLabel="Chargeback →" />
      </SummaryTileRow>
      <Row2>
        <Slot c={sp} title="Spend by account, now vs the period before" subtitle="invoice amounts, same-length periods · change shown apart, never added">
          {(rows) => {
            const cur = oneCurrency(rows);
            if (!cur.ok) return <div className="chart-note-oneline">{MIXED_CURRENCY}</div>;
            const items = rows.filter((r) => r.amount != null && r.prev_amount != null).map((r) => {
              const pv = numOrZero(r.prev_amount), nw = numOrZero(r.amount);
              const ch = pv > 0 ? `${nw >= pv ? "+" : "−"}${fmtShare(Math.abs(((nw - pv) / pv) * 100))}` : "new";
              return { name: `${acct(r)} ${ch}`, before: pv, after: nw };
            });
            return items.length ? <Dumbbell items={items} n={8} only="all" valueFmt={cur.fmt} unitLabel="" ariaLabel="Spend by account, previous vs now" /> : null;
          }}
        </Slot>
        <Slot c={ss} title="Spend by service type" subtitle="all accounts, this period">
          {(rows) => {
            const cur = oneCurrency(rows);
            if (!cur.ok) return <div className="chart-note-oneline">{MIXED_CURRENCY}</div>;
            const by = tally(rows, (r) => words(r.service_type || r.usage_type || "(no service type)"), (r) => numOrZero(r.amount));
            const segs = by.map((g) => ({ key: g.name, label: g.name, value: g.value }));
            if (!segs.some((s) => s.value > 0)) return null;
            const grew = by.map((g) => ({ k: g.name, d: g.value - g.rows.reduce((s, r) => s + numOrZero(r.prev_amount), 0) })).sort((a, b) => b.d - a.d)[0];
            return (
              <div>
                <StackedShareBar segments={segs} pareto valueFmt={cur.fmt} ariaLabel="Spend by service type" />
                {grew && grew.d > 0 && <div className="chart-note-oneline">{`Grew most: ${grew.k}, +${cur.fmt(grew.d)} vs the period before.`}</div>}
              </div>
            );
          }}
        </Slot>
      </Row2>
      <Slot c={sv} title="Serverless feature credits by account" subtitle="serverless spend per account the role can read · dot = status">
        {(rows) => {
          const cur = oneCurrency(rows);
          if (!cur.ok) return <div className="chart-note-oneline">{MIXED_CURRENCY}</div>;
          const items: StatusBarItem[] = tally(rows, acct, (r) => numOrZero(r.est_cost)).map((g) => ({
            key: String(g.rows[0].account_locator), name: g.name, value: g.value, status: g.status,
            valueText: `${cur.fmt(g.value)} · ${plural(distinct(g.rows, "service_type"), "service")}`,
          }));
          return items.length ? <StatusBars items={items} n={8} ariaLabel="Serverless spend by account"
            onBarClick={(it) => DrawerBus.open({ id: "sf_org_serverless_by_account", col: "account_locator", val: String(it.key), label: it.name })} /> : null;
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ Sharing › Replication & transfer ═══════════════════════

const tb = (v: number) => `${v >= 10 ? fmtInt(Math.round(v)) : v.toFixed(1)} TB`;

export function ApSharingReplication(p: ApPageProps) {
  const rg = useCheck(p, "sf_repl_group_health");
  const rc = useCheck(p, "sf_org_replication_cost");
  const af = useCheck(p, "sf_org_listing_auto_fulfillment");
  const dt = useCheck(p, "sf_org_data_transfer_by_account");
  const aR = rg.rows ? affOf(rg.f, rg.rows, "replication groups") : null;
  const crossTb = (dt.rows || []).reduce((s, r) => s + numOrZero(r.tb_cross_region) + numOrZero(r.tb_cross_cloud), 0);
  useLede(p, rg.loading || dt.loading, [
    aR ? `${ofText(aR)} are behind or failing.` : null,
    dt.rows ? `${tb(crossTb)} left its region or cloud.` : null,
  ].filter(Boolean).join(" ") || null);
  return (
    <div className="ais-page">
      <SummaryTileRow compact>
        <AffTile c={rg} label="Replication groups behind" as="count" noun="replication groups" openLabel="By group ↓"
          extra={(rows) => {
            if (!rows.some((r) => r.price_basis === "priced")) return null;
            const all = rows.reduce((s, r) => s + numOrZero(r.est_replication_usd_list), 0) * (1 - rg.disc);
            const fl = rows.filter(isFlagged).reduce((s, r) => s + numOrZero(r.est_replication_usd_list), 0) * (1 - rg.disc);
            return `${fmtMoney(fl, 0)} of ${fmtMoney(all, 0)} replication spend · context`;
          }}
          cause={(rows) => { const t = [...rows].filter((r) => r.lag_hours != null).sort((a, b) => numOrZero(b.lag_hours) - numOrZero(a.lag_hours))[0]; return t ? `${nameId(t.group_name, t.group_id)} is ${fmtInt(Math.round(numOrZero(t.lag_hours)))} h behind.` : undefined; }} />
        <CheckTile c={dt} label="Transfer out of region or cloud" badge build={(rows) => {
          const cur = oneCurrency(rows);
          return {
            headline: tb(crossTb), unit: " sent",
            base: `${cur.ok ? `${cur.fmt(rows.reduce((s, r) => s + numOrZero(r.amount), 0))} transfer spend · ` : ""}${fmtInt(rows.filter(isFlagged).length)} of ${plural(rows.length, "account")}`,
            cause: crossTb > 0 ? `${fmtShare(pctOf(rows.reduce((s, r) => s + numOrZero(r.tb_cross_cloud), 0), crossTb))} of it crosses clouds.` : undefined, openLabel: "By account ↓",
          };
        }} />
        <MoneyTile c={af} label="Listing auto-fulfillment" cause={(rows) => `${fmtInt(distinct(rows.filter(isFlagged), "provider_account_locator"))} of ${plural(distinct(rows, "provider_account_locator"), "provider account")} · replication + storage`} />
        <MoneyTile c={rc} label="Replication cost by database" cause={(rows) => {
          const t = [...rows].sort((a, b) => numOrZero(b.est_cost) - numOrZero(a.est_cost))[0];
          const all = rows.reduce((s, r) => s + numOrZero(r.est_cost), 0);
          return t ? `${t.database_name} is ${fmtShare(pctOf(numOrZero(t.est_cost), all))} of it` : "No replication billed";
        }} />
      </SummaryTileRow>
      <Row2>
        <Slot c={rg} title="Replication lag, by group" subtitle="hours since the secondary's last good refresh · dot = status">
          {(rows) => {
            const withLag = rows.filter((r) => r.lag_hours != null && Number.isFinite(Number(r.lag_hours)));
            const priced = rows.some((r) => r.price_basis !== "unpriced" && r.est_replication_usd_list != null);
            const items: StatusBarItem[] = withLag.map((r) => ({
              key: String(r.group_name), name: nameId(r.group_name, r.group_id, "(unnamed group)"), value: numOrZero(r.lag_hours), status: r.status,
              valueText: `${fmtInt(Math.round(numOrZero(r.lag_hours)))} h${priced ? ` · ${fmtMoney(numOrZero(r.est_replication_usd_list) * (1 - rg.disc), 0)}` : ""}`,
            }));
            if (!items.length) return null;
            const noLag = rows.length - withLag.length;
            return (
              <div>
                <StatusBars items={items} n={8} unitLabel="hours" ariaLabel="Replication lag by group"
                  onBarClick={(it) => DrawerBus.open({ id: "sf_repl_group_health", col: "group_name", val: String(it.key), label: it.name })} />
                {noLag > 0 && <div className="chart-note-oneline">{`– ${plural(noLag, "group")} with no lag reading: no secondary refresh seen.`}</div>}
              </div>
            );
          }}
        </Slot>
        <Slot c={dt} title="Cross-region and cross-cloud transfer" subtitle="TB sent in the window · dark bar = cross-region or cross-cloud">
          {(rows) => {
            const sum = (col: string) => rows.reduce((s, r) => s + numOrZero(r[col]), 0);
            const total = sum("tb_total"), region = sum("tb_cross_region"), cloud = sum("tb_cross_cloud");
            if (!(total > 0)) return null;
            const items = rows.filter((r) => numOrZero(r.tb_total) > 0).map((r) => ({ name: acct(r), value: numOrZero(r.tb_cross_region) + numOrZero(r.tb_cross_cloud), whole: numOrZero(r.tb_total) }));
            return (
              <div className="ais-stack-pair">
                <StackedShareBar ariaLabel="Transfer by route" valueFmt={tb}
                  segments={[
                    { label: "cross-cloud", value: cloud, color: "var(--c1)" },
                    { label: "cross-region", value: region, color: "var(--c2)" },
                    { label: "same region", value: Math.max(0, total - region - cloud), color: "var(--c-other)" },
                  ]} />
                {items.length >= 2 && <RankedBars items={items} n={8} valueFmt={tb} unitLabel="TB" ariaLabel="Cross-region and cross-cloud TB by account"
                  note="Dark bar: cross-region or cross-cloud. Light track: all TB sent." />}
              </div>
            );
          }}
        </Slot>
      </Row2>
      <Slot c={rc} title="Replication $ by database and region" subtitle="replication spend in the window · dot = status">
        {(rows) => {
          const cur = oneCurrency(rows);
          if (!cur.ok) return <div className="chart-note-oneline">{MIXED_CURRENCY}</div>;
          const items: StatusBarItem[] = rows.filter((r) => numOrZero(r.est_cost) > 0).map((r) => ({
            key: `${r.account_locator}|${r.database_name}`, name: `${r.database_name || "(no database)"} → ${r.region || "–"} · ${acct(r)}`, value: numOrZero(r.est_cost), status: r.status,
            valueText: `${cur.fmt(numOrZero(r.est_cost))} · ${tb(numOrZero(r.tb_transferred))}`,
          }));
          return items.length ? <StatusBars items={items} n={8} ariaLabel="Replication spend by database" onBarClick={() => rc.open()} /> : null;
        }}
      </Slot>
    </div>
  );
}

// ═══════════════════════ governance fit: DQ expectations, agents, policy owners, unused grants ═══════════════════════

const okNote = (text: string) => <div className="chart-note-oneline">{text}</div>;
const byStatus = (a: Row, b: Row) => (STATUS_RANK[String(b.status)] ?? 0) - (STATUS_RANK[String(a.status)] ?? 0);
const flaggedFirst = (rows: Row[]) => rows.filter(isFlagged).sort(byStatus);

/** PII › Data quality: expectations that fail, and DMFs billed on tables that did not change. */
function GovQualityFit({ p }: { p: ApPageProps }) {
  const ex = useCheck(p, "sf_gov_dmf_expectation_failures");
  const st = useCheck(p, "sf_gov_dmf_static_table_schedules");
  return (
    <div>
      <div id="dq-exp">
      <Slot c={ex} title="Expectations failing or never checked" subtitle="Latest run per expectation · longest failing first · select a row">
        {(rows) => {
          const fl = flaggedFirst(rows).sort((a, b) => byStatus(a, b) || numOrZero(b.failing_days) - numOrZero(a.failing_days));
          return fl.length ? (
            <CxTable ariaLabel="Failing expectations" n={8}
              cols={[{ label: "Table" }, { label: "Expectation" }, { label: "Latest" }, { label: "Days failing", num: true }, { label: "Runs failed", num: true }]}
              rows={fl.map((r, i) => ({
                key: `${r.table_fqn}-${r.expectation_id}-${i}`, status: r.status, onClick: drawerBy("sf_gov_dmf_expectation_failures", "table_fqn", r.table_fqn, String(r.table_fqn)),
                cells: [<CxObjName full={String(r.table_fqn)} />, <code className="cx-code">{String(r.expectation_name || "–")}</code>, words(r.latest_state).replace(/^./, (x) => x.toUpperCase()),
                  r.failing_days == null ? "–" : fmtInt(numOrZero(r.failing_days)), `${fmtInt(numOrZero(r.violations))} of ${fmtInt(numOrZero(r.evaluations))}`],
              }))} />
          ) : okNote(`All ${plural(rows.length, "expectation")} passed on their latest run.`);
        }}
      </Slot>
      </div>
      <Slot c={st} title="DMFs billed on tables that did not change" subtitle="no rows added, removed or updated in the window · possible waste, part of DMF spend">
        {(rows) => {
          const fl = flaggedFirst(rows).sort((a, b) => numOrZero(b.dmf_credits) - numOrZero(a.dmf_credits));
          return fl.length ? (
            <CxTable ariaLabel="DMFs on unchanged tables" n={8}
              cols={[{ label: "Table" }, { label: "Schedule" }, { label: "Credits", num: true }, { label: "Possible waste", num: true }]}
              rows={fl.map((r) => ({
                key: String(r.table_fqn), status: r.status, onClick: drawerBy("sf_gov_dmf_static_table_schedules", "table_fqn", r.table_fqn, String(r.table_fqn)),
                cells: [<CxObjName full={String(r.table_fqn)} />, r.shortest_interval_min != null ? `every ${fmtInt(numOrZero(r.shortest_interval_min))} min` : String(r.schedule_kinds || "–"), fmtInt(Math.round(numOrZero(r.dmf_credits))), r.est_wasted_usd_list == null ? "–" : fmtMoney(numOrZero(r.est_wasted_usd_list))],
              }))} />
          ) : okNote(`All ${plural(rows.length, "table")} with billed DMFs changed in the window.`);
        }}
      </Slot>
    </div>
  );
}

/** PII › Who reads it: what AI agents read. */
function GovAgentsFit({ p }: { p: ApPageProps }) {
  const ag = useCheck(p, "sf_gov_ai_agent_data_access");
  return (
    <Slot c={ag} title="Tables AI agents read" subtitle="The agent nearest each read · unmasked sensitive columns first · select a row">
      {(rows) => rows.length ? (
        <CxTable ariaLabel="Tables read by AI agents" n={8}
          cols={[{ label: "Agent" }, { label: "Kind" }, { label: "Table" }, { label: "Queries", num: true }, { label: "Users", num: true }, { label: "Unmasked sensitive" }]}
          rows={[...rows].sort((a, b) => byStatus(a, b) || numOrZero(b.queries) - numOrZero(a.queries)).map((r, i) => ({
            key: `${r.agent_name}-${r.table_fqn}-${i}`, status: r.status, onClick: drawerBy("sf_gov_ai_agent_data_access", "table_fqn", r.table_fqn, String(r.table_fqn)),
            cells: [<CxObjName full={String(r.agent_name || "–")} />, words(r.agent_type).replace(/^./, (x) => x.toUpperCase()), <CxObjName full={String(r.table_fqn)} />,
              fmtInt(numOrZero(r.queries)), fmtInt(numOrZero(r.users)), r.unmasked_columns ? String(r.unmasked_columns) : "–"],
          }))} />
      ) : okNote("No agent read a table in the window.")}
    </Slot>
  );
}

/** PII › Masking & row policies: policies the data's own owner can change. */
function GovPolicyOwnerFit({ p }: { p: ApPageProps }) {
  const so = useCheck(p, "sf_gov_policy_separation_of_duties");
  return (
    <Slot c={so} title="Policies owned by the role that owns the data" subtitle="That role can change or drop the protection on its own · sensitive tables first">
      {(rows) => {
        const fl = flaggedFirst(rows);
        return fl.length ? (
          <CxTable ariaLabel="Policies owned by the data owner" n={8}
            cols={[{ label: "Table" }, { label: "Policy" }, { label: "Owner of both" }, { label: "Applied through" }]}
            rows={fl.map((r, i) => ({
              key: `${r.table_fqn}-${r.policy_fqn}-${i}`, status: r.status, onClick: drawerBy("sf_gov_policy_separation_of_duties", "table_fqn", r.table_fqn, String(r.table_fqn)),
              cells: [<CxObjName full={String(r.table_fqn)} />, <CxObjName full={String(r.policy_fqn)} />, String(r.table_owner), r.via_tag ? `Tag ${r.via_tag}` : "The policy itself"],
            }))} />
        ) : okNote(`A different role owns the policy on all ${plural(rows.length, "protected table")}.`);
      }}
    </Slot>
  );
}

/** Access › Roles & grants: table grants that roles in use left unused. */
function GovUnusedGrantsFit({ p }: { p: ApPageProps }) {
  const ug = useCheck(p, "sf_gov_unused_object_grants");
  return (
    <Slot c={ug} title="Table grants roles in use did not use" subtitle="role × database · granted before the window · write grants first · click a row">
      {(rows) => {
        const fl = flaggedFirst(rows);
        return fl.length ? (
          <DrillTable aria="Unused table grants" n={8}
            cols={[{ label: "Role" }, { label: "Database" }, { label: "Unused", num: true, width: "auto" }, { label: "Of them writes", num: true, width: "auto" }]}
            rows={fl.map((r) => ({
              key: `${r.role_name}-${r.database_name}`, status: r.status, onOpen: drawerBy("sf_gov_unused_object_grants", "role_name", r.role_name, String(r.role_name)),
              cells: [String(r.role_name), String(r.database_name), `${fmtInt(numOrZero(r.unused_grants))} of ${fmtInt(numOrZero(r.grants))}`, fmtInt(numOrZero(r.unused_write_grants))],
            }))} />
        ) : okNote(`Roles used most of their table grants in ${plural(rows.length, "database")}.`);
      }}
    </Slot>
  );
}

// The check's fixed cause columns, in its own order; "other" stays last.
const FAIL_CAUSES: [string, string, string][] = [
  ["fails_network_policy", "Network policy", "var(--c1)"], ["fails_password", "Password", "var(--c2)"],
  ["fails_mfa", "MFA", "var(--c3)"], ["fails_locked_or_disabled", "User locked or disabled", "var(--c4)"],
  ["fails_key_or_token", "Key or token", "var(--c5)"], ["fails_sso", "SSO", "var(--seq-3)"], ["fails_other", "Other", "var(--c-other)"],
];

/** An empty window keeps "No data for this in <range>" and says what that means for this check. */
function emptyAs(c: Chk, meaning: string): Chk {
  return c.empty && c.why && /^No data for this/.test(c.why) ? { ...c, why: `${c.why}: ${meaning}` } : c;
}

/** A check summed on the server, as a Chk whose rows are its groups ({key, value, row_count, also}):
 * exact past the 5,000-row fetch cap. */
function useAggChk(p: ApPageProps, id: string, group: string[], agg: string, value: string, also?: string[]): Chk {
  const f = findingOf(p, id);
  const st = useFindingAgg(f ? id : null, p.filters.window, p.filters.accountIds, group, agg, value, also ? { also } : null) as FetchState;
  const base: Chk = { f, rows: null, allRows: null, why: null, empty: false, loading: false, disc: 0, open: openCheck(p, id) };
  if (!f) return { ...base, why: "Not in this export yet: run the export again." };
  if (st.phase === "loading") return { ...base, loading: true };
  if (st.phase === "error") return { ...base, why: st.error || "Could not load" };
  const d: Row = st.data || {};
  switch (st.outcome) {
    case "not_assessed": return { ...base, why: notAssessedText(d) };
    case "error": return { ...base, why: d.error || "The check failed." };
    case "ok_empty_window": {
      const w = windowShortLabel(p.meta && p.meta.as_of_date, p.filters.window, p.meta && p.meta.snapshot_days);
      return { ...base, empty: true, why: `No data for this in ${w || `the last ${p.filters.window} days`}` };
    }
    case "ok_empty_filters": return { ...base, empty: true, why: "The current filters exclude every row." };
    case "ok_rows": return { ...base, rows: d.groups || [], allRows: d.groups || [] };
    default: return { ...base, why: "Not in this export." };
  }
}
/** One distinct count off the aggregate route; null until it reads. */
const aggOne = (c: Chk) => (c.rows && c.rows.length ? numOrZero(c.rows[0].value) : null);

/** Access › Users & sign-ins: failed sign-ins split by cause, summed on the server over every user × IP row. */
function GovFailedByCause({ p }: { p: ApPageProps }) {
  const [first, ...rest] = FAIL_CAUSES.map(([col]) => col);
  const fl = emptyAs(useAggChk(p, "sf_sec_failed_logins", [], "sum", first, rest), "no sign-in failed.");
  const users = aggOne(useAggChk(p, "sf_sec_failed_logins", [], "count_distinct", "user_name"));
  const ips = aggOne(useAggChk(p, "sf_sec_failed_logins", [], "count_distinct", "client_ip"));
  // A raw server error is logged, never shown; a not-assessed reason reads as it is.
  if (!fl.loading && fl.why && !fl.empty) {
    const raw = /^\d{3}\b|column|exception|error/i.test(fl.why);
    if (raw) console.warn(`sf_sec_failed_logins: ${fl.why}`);
    return <CxMissing title="Failed sign-ins by cause" reason={raw ? "Couldn't read failed sign-ins from this export." : fl.why} onOpen={fl.open} />;
  }
  return (
    <Slot c={fl} title="Failed sign-ins by cause" subtitle="Every failed sign-in in the window · read from Snowflake's error code and message">
      {(rows) => {
        const g = rows[0] || {};
        const sumOf = (col: string) => numOrZero(col === first ? g.value : (g.also || {})[col]);
        const segs: ShareSegment[] = FAIL_CAUSES.map(([col, label, color]) => ({ key: col, label, color, value: sumOf(col) }));
        const total = segs.reduce((s, x) => s + x.value, 0);
        if (!total) return okNote("No failed sign-in has a cause recorded.");
        const who = users === null || ips === null ? " · …" : ` · ${plural(users, "user name")} · ${plural(ips, "IP")}`;
        return (
          <StackedShareBar segments={segs} pareto maxSegments={FAIL_CAUSES.length} valueFmt={(v) => plural(v, "failed sign-in")} ariaLabel="Failed sign-ins by cause"
            totalLabel={<span><b>{plural(total, "failed sign-in")}</b>{who}</span>} />
        );
      }}
    </Slot>
  );
}

// Grants of one role to another role or user: the role hierarchy, not access to an object.
const ROLE_SCOPES = new Set(["ROLE", "DATABASE_ROLE", "INSTANCE_ROLE", "APPLICATION_ROLE"]);

/** Access › Roles & grants: grants on objects the role can see, summed by privilege on the server. */
function GovGrantsByPrivilege({ p }: { p: ApPageProps }) {
  const gi = useAggChk(p, "access_grants_inventory", ["privilege_type", "object_scope"], "sum", "grant_count");
  return (
    <Slot c={gi} title="Grants by privilege" subtitle="grants on objects the audit role can see · role grants left out · snapshot at export · click a bar for its rows">
      {(rows) => {
        const keyOf = (r: Row) => (Array.isArray(r.key) ? r.key : []);
        const isRoleGrant = (r: Row) => ROLE_SCOPES.has(String(keyOf(r)[1] || "").toUpperCase());
        const by = tally(rows.filter((r) => !isRoleGrant(r)), (r) => String(keyOf(r)[0] || "(no privilege)"), (r) => numOrZero(r.value));
        const total = by.reduce((s, g) => s + g.value, 0);
        if (!total) return null;
        const top = [...by].sort((a, b) => b.value - a.value)[0];
        const roleN = rows.filter(isRoleGrant).reduce((s, r) => s + numOrZero(r.value), 0);
        return (
          <div>
            <Headline><b>{plural(total, "grant")}</b>{` on objects across ${plural(by.length, "privilege type")} · ${top.name} is ${fmtShare(pctOf(top.value, total))}`}
              {roleN > 0 && ` · ${plural(roleN, "role grant")} not counted`}</Headline>
            <RankedBars items={by.map((g) => ({ name: g.name, value: g.value }))} n={10} valueFmt={(v) => fmtInt(v)} unitLabel="grants" ariaLabel="Grants by privilege"
              onItemClick={(it) => DrawerBus.open({ id: "access_grants_inventory", col: "privilege_type", val: String(it.name), label: String(it.name) })} />
          </div>
        );
      }}
    </Slot>
  );
}

/** PII › Sensitive data: target tables that took sensitive columns into columns with no tag or mask. */
function GovLineageUntagged({ p }: { p: ApPageProps }) {
  const lin = emptyAs(useCheck(p, "sf_secx_sensitive_lineage_untagged"), "no sensitive column was copied to another table.");
  return (
    <Slot c={lin} title="Sensitive data copied into untagged columns" subtitle="Copied from a source into a table with no tag or mask · select a row">
      {(rows) => {
        // OK rows landed in a tagged or masked column: protected, so not drawn here.
        const fl = rows.filter(isFlagged);
        if (!fl.length) return okNote(`Every copy landed in a tagged or masked column (${plural(rows.length, "column")}).`);
        const items: StatusBarItem[] = tally(fl, (r) => String(r.target_table || "(no target)")).map((g) => {
          const src = [...new Set(g.rows.map((r) => String(r.source_table || "(no source)")))];
          // Each row counts its own distinct queries, so the table's floor is the largest one.
          const q = Math.max(...g.rows.map((r) => numOrZero(r.queries)));
          return {
            key: g.name, name: g.name, value: g.n, status: g.status,
            valueText: `${plural(g.n, "column")} · from ${src[0]}${src.length > 1 ? ` +${src.length - 1}` : ""}`,
            title: `${g.name} ← ${src.join(", ")} · at least ${plural(q, "query", "queries")} · ${[...new Set(g.rows.map(category))].join(", ")}`,
          };
        });
        // Equal bars carry nothing: list target, count and source as rows.
        return (
          <CxTable ariaLabel="Target tables that took sensitive columns into untagged columns"
            cols={[{ label: "Target table" }, { label: "Copied", num: true }, { label: "From" }]}
            rows={items.map((it) => {
              const g = fl.filter((r) => String(r.target_table || "(no target)") === it.key);
              const src = [...new Set(g.map((r) => String(r.source_table || "(no source)")))];
              return { key: String(it.key), status: it.status, onClick: () => DrawerBus.open({ id: "sf_secx_sensitive_lineage_untagged", col: "target_table", val: String(it.key), label: String(it.name) }),
                cells: [<CxObjName full={String(it.name)} />, plural(Number(it.value), "column"), <span>{src.map((x) => <CxObjName key={x} full={x} />)}</span>] };
            })} />
        );
      }}
    </Slot>
  );
}

/** PII › Masking & row policies: masked columns by how the mask reaches them, then by tag. */
function GovMaskAttachment({ p }: { p: ApPageProps }) {
  const raw = useCheck(p, "access_column_masks_inventory");
  // A snapshot, not a window: an empty result means no mask the role can see, not a quiet week.
  const mk = raw.empty && /^No data for this/.test(raw.why || "") ? { ...raw, why: "No masking policy is attached to a column the audit role can see (snapshot at export)." } : raw;
  return (
    <Slot c={mk} title="Masking by tag vs directly" subtitle="A tag carries the mask to new columns; a direct mask does not · snapshot at export">
      {(rows) => {
        // One row per policy reference: count columns, and a direct mask wins over a tag's.
        const cols = new Map<string, { direct: boolean; tags: Set<string> }>();
        rows.forEach((r) => {
          const k = [r.table_catalog, r.table_schema, r.table_name, r.column_name].join(".");
          const c = cols.get(k) || { direct: false, tags: new Set<string>() };
          if (String(r.attachment).toLowerCase() === "tag") c.tags.add(String(r.tag_name || "(no tag)"));
          else c.direct = true;
          cols.set(k, c);
        });
        const viaTag = [...cols.values()].filter((c) => !c.direct);
        const segs: ShareSegment[] = [
          { key: "tag", label: "Through a tag", value: viaTag.length, color: "var(--c1)" },
          { key: "direct", label: "Directly on the column", value: cols.size - viaTag.length, color: "var(--c2)" },
        ];
        const byTag = new Map<string, number>();
        viaTag.forEach((c) => c.tags.forEach((t) => byTag.set(t, (byTag.get(t) || 0) + 1)));
        const tags = [...byTag.entries()].map(([name, value]) => ({ name, value }));
        if (viaTag.length === 0 || viaTag.length === cols.size) {
          return <CxStat>{<span><b>{`${fmtInt(viaTag.length)} of ${plural(cols.size, "masked column")}`}</b>{viaTag.length === 0
            ? ` are masked through a tag. All ${fmtInt(cols.size)} carry the mask directly on the column, so a new column made from them starts unmasked.`
            : " are masked through a tag, so the mask follows the tag to new columns."}</span>}</CxStat>;
        }
        return (
          <div className="ais-stack-pair">
            <StackedShareBar segments={segs} valueFmt={(v) => plural(v, "column")} ariaLabel="Masked columns by attachment"
              totalLabel={<span><b>{`${fmtInt(viaTag.length)} of ${plural(cols.size, "masked column")}`}</b>{" masked through a tag"}</span>} />
            {tags.length >= 2 && <RankedBars items={tags} n={6} valueFmt={(v) => fmtInt(v)} unitLabel="columns" ariaLabel="Tag-masked columns by tag" />}
          </div>
        );
      }}
    </Slot>
  );
}

/** The governance sub-tab pages, merged into AREA_CHART_PAGES by area_pages.tsx. Each leads with its
 * own tiles and lede (`ownsTiles`, `ownsLede`). */
export const GOV_CHART_PAGES: Record<string, Record<string, (p: ApPageProps) => React.JSX.Element>> = {
  access: { roles: ApAccessRoles, users: ApAccessUsers, perimeter: ApAccessPerimeter },
  audit: { admins: ApAuditAdmins, changes: ApAuditChanges },
  pii: { sensitive: ApPiiSensitive, policies: ApPiiPolicies, reads: ApPiiReads, quality: ApPiiQuality },
  lineage: { dependencies: ApLineageDeps, usage: ApLineageUsage },
  sharing: { shares: ApSharingShares, accounts: ApSharingAccounts, spend: ApSharingSpend, replication: ApSharingReplication },
};
Object.values(GOV_CHART_PAGES).forEach((m) => Object.values(m).forEach((fn) => { (fn as any).ownsTiles = true; (fn as any).ownsLede = true; }));
