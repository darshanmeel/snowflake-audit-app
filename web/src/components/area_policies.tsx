// web/src/components/area_policies.tsx -- masking and row access policies in use, on PII › Masking & row policies
// (who saw clear text, who can bypass each policy, policy use by role) and Audit › Changes (policy changes).
// Read through /api/policies/*, which joins the policy log, the policy bodies' exempt roles and the grant links.
import React from "react";
import { fmtDayShort, fmtInt } from "../format";
import { numOrZero } from "./hooks";
import type { ApPageProps } from "./area_pages";
import { ChartCard } from "./primitives";
import { useAggCheck } from "./area_ai_storage";
import { CxObjName, CxStat, CxTable } from "./cx_e";
import { useJson } from "./use_json";
import type { Row } from "../types";

const plural = (n: number, one: string) => `${fmtInt(n)} ${n === 1 ? one : `${one}s`}`;
const day = (v: any) => (v ? fmtDayShort(String(v).slice(0, 10)) : "–");
const short = (fqn: any) => String(fqn || "–").split(".").pop();

/** "…" while loading, "–" and why when the check or the route has nothing. */
function Gate({ c, st, children }: { c: { loading: boolean; why: string | null; empty: boolean }; st: { loading: boolean; err: string | null; data: any }; children: () => React.ReactNode }) {
  if (c.loading || st.loading) return <CxStat>…</CxStat>;
  if (c.why) return <CxStat>{c.empty ? c.why : `– ${c.why}`}</CxStat>;
  if (st.err) return <CxStat>{`– ${st.err}`}</CxStat>;
  return st.data ? <>{children()}</> : null;
}

export function PolicyUse({ p }: { p: ApPageProps }) {
  const c = useAggCheck(p, "sf_gov_policy_hits", [], "queries", []);
  const ran = !c.loading && !c.why;
  const clear = useJson(ran ? "/api/policies/clear-text" : null, { window: p.filters.window });
  const hits = useJson(ran ? "/api/policies/hits" : null, { window: p.filters.window });
  const reach = useJson("/api/policies/reach", {});
  const cl: Row[] = clear.data?.clear || [];
  return (
    <>
      <ChartCard title="Who saw clear text" subtitle="Masked columns read under a role the policy lets through · from the policy log and each policy's exempt roles" takeaway={null}>
        <Gate c={c} st={clear}>{() => (
          <div>
            <CxStat>{<span><b>{plural(new Set(cl.map((r) => r.user_name)).size, "user")}</b>{` read masked columns in clear; ${fmtInt(numOrZero(clear.data.masked))} reads were masked, ${fmtInt(numOrZero(clear.data.unknown))} can't be told (lookup or no role check in the body).`}</span>}</CxStat>
            {!clear.data.exemptions_read && <CxStat>– The policy bodies were not readable, so exemptions are unknown.</CxStat>}
            {cl.length > 0 && (
              <CxTable ariaLabel="Clear-text reads of masked columns" n={10}
                cols={[{ label: "User" }, { label: "Role" }, { label: "Policy" }, { label: "Table" }, { label: "Columns" }, { label: "Queries", num: true }, { label: "Why" }, { label: "Last", num: true }]}
                rows={cl.map((r, i) => ({
                  key: `${r.user_name}|${r.role_name}|${r.policy_fqn}|${r.object_fqn}|${i}`, status: "WARN",
                  cells: [String(r.user_name), String(r.role_name), short(r.policy_fqn), <CxObjName full={String(r.object_fqn)} />,
                    <span className="cx-code">{String(r.columns || "–")}</span>, fmtInt(numOrZero(r.queries)), String(r.why), day(r.last_at)],
                }))} />
            )}
          </div>
        )}</Gate>
      </ChartCard>
      <ChartCard title="Who can bypass each policy" subtitle="Users who hold an exempt role, directly or through other roles · now, from the grant links" takeaway={null}>
        {reach.loading ? <CxStat>…</CxStat> : reach.err ? <CxStat>{`– ${reach.err}`}</CxStat> : reach.data && (
          <div>
            <CxTable ariaLabel="Users who can bypass each policy" n={8}
              cols={[{ label: "Policy" }, { label: "Body checks" }, { label: "Exempt roles" }, { label: "Users who bypass", num: true }, { label: "Who" }]}
              rows={(reach.data.policies as Row[]).map((r) => ({
                key: String(r.policy_fqn), status: r.users && r.users.length ? "WARN" : undefined,
                cells: [short(r.policy_fqn), String(r.check || "–").toLowerCase().replace(/_/g, " "), (r.exempt_roles || []).join(", ") || "–",
                  r.users ? fmtInt(r.users.length) : "–", r.users ? r.users.slice(0, 4).join(", ") + (r.users.length > 4 ? ` +${r.users.length - 4}` : "") : String(r.how)],
              }))} />
            <CxTable ariaLabel="Protected tables and who bypasses" n={8}
              cols={[{ label: "Table" }, { label: "Protection" }, { label: "Columns" }, { label: "Policy" }, { label: "Users who bypass", num: true }]}
              rows={(reach.data.tables as Row[]).map((t, i) => ({
                key: `${t.table}|${t.policy_fqn}|${i}`,
                cells: [<CxObjName full={String(t.table)} />, String(t.kind), <span className="cx-code">{String(t.columns || "every row")}</span>,
                  short(t.policy_fqn), t.bypass_users == null ? "–" : fmtInt(t.bypass_users)],
              }))} />
          </div>
        )}
      </ChartCard>
      <ChartCard title="Policy use by role" subtitle="Queries each policy was enforced on, by the query's role · a policy never enforced protects nothing in use" takeaway={null}>
        <Gate c={c} st={hits}>{() => (hits.data.rows as Row[]).length ? (
          <CxTable ariaLabel="Policy use by role" n={10}
            cols={[{ label: "Policy" }, { label: "Kind" }, { label: "Role" }, { label: "Queries", num: true }, { label: "Users", num: true }, { label: "Objects", num: true }, { label: "Last", num: true }]}
            rows={(hits.data.rows as Row[]).map((r, i) => ({
              key: `${r.policy_fqn}|${r.role_name}|${i}`,
              cells: [short(r.policy_fqn), r.policy_kind === "ROW_ACCESS_POLICY" ? "row access" : "masking", String(r.role_name),
                fmtInt(numOrZero(r.queries)), fmtInt(numOrZero(r.users)), fmtInt(numOrZero(r.objects)), day(r.last_at)],
            }))} />
        ) : <CxStat>{`No data for this in ${day(hits.data.start)}–${day(hits.data.end)}`}</CxStat>}</Gate>
      </ChartCard>
    </>
  );
}

export function PolicyChanges({ p }: { p: ApPageProps }) {
  const c = useAggCheck(p, "sf_use_access_log", [], "ddl_queries", []);
  const st = useJson(!c.loading && !c.why ? "/api/policies/changes" : null, { window: p.filters.window });
  return (
    <ChartCard title="Policy changes" subtitle="Who created, altered or dropped a masking, row access or other policy · attaching one to a table shows as that table's ALTER" takeaway={null}>
      <Gate c={c} st={st}>{() => (st.data.rows as Row[]).length ? (
        <CxTable ariaLabel="Policy changes" n={10}
          cols={[{ label: "Day", num: true }, { label: "User" }, { label: "Role" }, { label: "Policy" }, { label: "Kind" }, { label: "Change" }]}
          rows={(st.data.rows as Row[]).map((r, i) => ({
            key: `${r.day}|${r.user_name}|${r.object_fqn}|${i}`, status: "WARN",
            cells: [day(r.day), String(r.user_name), String(r.role_name), <CxObjName full={String(r.object_fqn)} />,
              String(r.object_domain || "").toLowerCase(), String(r.operations || "–")],
          }))} />
      ) : <CxStat>{`No policy was changed in ${day(st.data.start)}–${day(st.data.end)}`}</CxStat>}</Gate>
    </ChartCard>
  );
}
