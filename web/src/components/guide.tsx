// web/src/components/guide.tsx -- the "How it works" page (hash tab=guide). Renders from GET /api/guide:
// home (rules, every tab at a glance, statuses), one page per tab, one per check, topics,
// troubleshooting, glossary and the check reference. Deep links go through nav_hash.tsx's navHref:
// #tab=guide&focus=<query_id> (a check), how-<slug> (a topic), how-area-<key> (a tab page),
// how-troubleshooting, how-glossary, how-checks; the topics and concept pages are GUIDE_SECTIONS. Links to docs.snowflake.com come from
// config/snowflake_docs.yml through the API (data.docs), never from this file.
import React from "react";
import { ACCOUNT_COLUMN, Api, acctId } from "../api";
import { fmtCell, fmtInt, fmtPct } from "../format";
import { acctPhrase } from "./names";
import { useDims, useFindingData } from "./hooks";
import { AREA_ORDER, AREA_REGISTRY, OVERVIEW_IDS, WASTE_IDS, WASTE_ITEMS, homeForQuery } from "./tab_registry";
import { Badge, Card, RANKED_QUERY_IDS, ranCountsText } from "./primitives";
import { getCheckLabel } from "./labels";
import type { CheckLabel } from "./labels";
import { columnMeta, planColumns } from "./columns";
import { actionTier } from "./overview_tile";
import { wasteUnitOf } from "./waste_total";
import { rowLabelOf } from "../tabs/tab_area";
import { ACTION_TEMPLATES } from "../tabs/tab_actions";
import { navHref } from "./nav_hash";
import { ROLES, ROLE_AREAS, ROLE_LABEL, fmtSnapshotWhen } from "../App";
import type { Dims, Filters, Finding, Meta } from "../types";

/** One docs.snowflake.com page from config/snowflake_docs.yml. */
interface DocEntry { title?: string; url?: string }
type DocsMap = Record<string, DocEntry>;
/** GET /api/guide's app facts (window options, pricing, floors ...). */
type GuideApp = Record<string, any>;
/** One check's guide header from GET /api/guide (summary, reads, columns, actions ...). */
interface GuideCheck { query_id: string; title?: string; [key: string]: any }
type GuideIndex = Record<string, GuideCheck>;
/** GET /api/guide body. */
interface GuideData {
  app: GuideApp;
  findings: GuideCheck[];
  docs?: DocsMap | null;
  concept_docs?: DocsMap | null;
  [key: string]: any;
}
type AreaKey = keyof typeof AREA_REGISTRY;
interface GuideSubtab { key: string; label: string; ids?: string[]; refIds?: string[] }
/** A screen as the Guide reads it: AREA_REGISTRY's entry, or the Guide-only money/tags pages. */
interface GuideArea { label: string; scope: string; subtabs: GuideSubtab[]; refIds?: string[] }
/** Where a check lives in the app (homeForQuery). */
interface GuideHomeRef { tab: string; subtab?: string | null; [key: string]: any }
/** One screen's Guide page content. */
interface GuideTabInfo {
  lens: string;
  represents: string;
  flags: string;
  wrong: string;
  lede: string;
  questions: string[];
  screen: { t?: string; sub?: string; d: string }[];
  measure: string;
  judge: string;
  price: string;
  troubles: { see: string; why: string; doit: string }[];
  limits: string[];
}


export const GUIDE_SECTIONS = [
  { slug: "flow", title: "Where the data comes from", teaser: "Your own credentials ran every check on Snowflake, read-only; only the result rows are saved here. Nothing is sent anywhere else." },
  { slug: "window", title: "Windows and exports", teaser: "Most checks cover the last 7, 30 or 90 days up to the export, today partial. A snapshot check shows today's settings, not a period." },
  { slug: "status", title: "What each status means", teaser: "Critical and Warning are flagged. OK is a verified pass. Not assessed and No data are never a pass." },
  { slug: "floors", title: "Materiality floors", teaser: "A row under its floor (\"Under $50\") is too small to matter: it reads OK instead of Critical or Warn and is left out of every count." },
  { slug: "money", title: "How dollars are worked out", teaser: "Credits × your effective $ per credit, from your rate sheet or invoice where the role can see it. Storage at your $ per TB." },
  { slug: "pricing", title: "Price basis", teaser: "The label next to a $ says where the price came from: invoice, export option, settings, or none. A discount never stacks on an invoice rate." },
  { slug: "money-kinds", title: "Money kinds", teaser: "Spend, change, waste, saving, gap, context and balance are different things. They are shown side by side and never added." },
  { slug: "steps", title: "Free, config and spend steps", teaser: "Free is a setting or a read. Config changes how something is configured. Spend costs money to carry out." },
  { slug: "tags", title: "Tags and chargeback", teaser: "Spend follows the most specific tag: query tag, then object tag, then warehouse tag, then user or role tag, then account tag. Untagged spend is shown, never dropped." },
  { slug: "names", title: "Names, not ids", teaser: "A row shows a name wherever one is known. When it can't be found, the row says why instead of guessing." },
  { slug: "screens", title: "Reading an area page", teaser: "Charts first, then the checks. Tables are for drill-down; click a task name to open its panel, and the arrow opens the object in Snowsight (best-guess link)." },
  { slug: "links", title: "Links and filters", teaser: "The address bar holds the tab, window, accounts and the warehouse, database and schema filters, so a pasted link opens the same view." },
  { slug: "cloud-services", group: "concept", title: "Cloud services and the 10% adjustment", teaser: "Only cloud services above 10% of a day's compute credits are billed, so they are priced after that adjustment." },
  { slug: "attribution", group: "concept", title: "Query attribution is not a total", teaser: "Per-query and per-user dollars leave out idle time and very short queries, so they add up to less than the warehouse bill." },
  { slug: "latency", group: "concept", title: "Latency and retention", teaser: "Usage views lag by hours (organization billing by up to 72 hours) and keep a limited history. The newest days can be low." },
  { slug: "failsafe", group: "concept", title: "Time Travel and Fail-safe", teaser: "Storage kept for recovery is billed until its retention ends, including for dropped tables. Fail-safe tables have no name." },
  { slug: "visibility", group: "concept", title: "Editions and role visibility", teaser: "A view that is missing, needs a higher edition or is hidden from the role reads Not assessed with the reason, never clean." },
  { slug: "pressure", group: "concept", title: "Warehouse pressure: scale up or out", teaser: "Memory pressure (spill) wants a bigger size; capacity pressure (queueing) wants more clusters or a warm one." },
  { slug: "upper-bound", group: "concept", title: "\"Up to\" figures", teaser: "Some storage figures are an upper bound per month: what the stored bytes could cost, not a measured bill." },
  { slug: "idle", group: "concept", title: "Idle time and auto-suspend", teaser: "Idle is billed time with no query. Each auto-suspend option is replayed on the real gaps: a saving estimate on its own, never added to idle." },
  { slug: "adaptive", group: "concept", title: "Adaptive warehouses", teaser: "Query attribution is empty on adaptive warehouses, so their spend is split by user from a separate view." },
  { slug: "freshness", group: "concept", title: "Source freshness", teaser: "How far behind each usage view is. A stale view makes the newest days of spend too low." },
  { slug: "coverage", title: "Coverage and gaps", teaser: "An empty panel means couldn't look or nothing happened, never all clear. Coverage & Gaps says which." },
  { slug: "coverage-data-sources", title: "Coverage & Gaps: Data sources", teaser: "Which Snowflake views this audit could read, which came back empty, and which need a grant." },
  { slug: "coverage-couldnt-check", title: "Coverage & Gaps: Not assessed", teaser: "Not assessed, a read error, nothing in the window, or excluded by your filters: never a pass." },
  { slug: "coverage-known-limitations", title: "Coverage & Gaps: Known limitations", teaser: "How Snowflake records usage, and what that means for reading a number." },
];

// The Snowflake views each topic points to; the titles and URLs come from config/snowflake_docs.yml.
export const TOPIC_CONCEPT_KEYS: Record<string, string[]> = {
  money: ["overall_cost", "compute_cost"],
  pricing: ["overall_cost", "organization_usage"],
  "money-kinds": ["attribution", "snowpipe_billing", "cortex_search_costs"],
  tags: ["tagging", "attribution"],
  screens: ["query_history_ui"],
  "cloud-services": ["cloud_services", "compute_cost"],
  attribution: ["attribution", "exploring_cost"],
  latency: ["latency", "retention", "usage_vs_info_schema"],
  failsafe: ["failsafe", "time_travel", "backups", "storage_lifecycle"],
  visibility: ["role_access", "editions", "access_control", "organization_usage"],
  pressure: ["warehouse_sizing", "multicluster", "warehouses", "snowpark_optimized", "gen2", "tasks"],
  "upper-bound": ["backups"],
  adaptive: ["adaptive", "gen2"],
  idle: ["warehouses", "warehouse_sizing", "compute_cost", "adaptive", "gen2", "dt_target_lag"],
  freshness: ["latency", "anomalies"],
  floors: ["controlling_cost"],
  coverage: ["role_access", "editions"],
};
// A check's trap slug -> the topic page that explains it.
export const GUIDE_TRAP_PAGE: Record<string, string> = { editions: "visibility", backups: "upper-bound" };

export const TOPIC_DOC_KEYS: Record<string, string[]> = {
  flow: ["ACCOUNT_USAGE.QUERY_HISTORY", "ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY"],
  money: ["ACCOUNT_USAGE.METERING_DAILY_HISTORY", "ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY", "ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY"],
  tags: ["ACCOUNT_USAGE.TAG_REFERENCES", "ACCOUNT_USAGE.QUERY_ATTRIBUTION_HISTORY"],
  "coverage-data-sources": ["ACCOUNT_USAGE.QUERY_HISTORY"],
  idle: ["ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY", "ACCOUNT_USAGE.QUERY_HISTORY", "ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY"],
};

// The Coverage & Gaps sub-topics apply to that one screen, not every screen: "Start here" shows
// them nested under the "Coverage and gaps" topic instead of counted alongside the universal ones.
export const GUIDE_UNIVERSAL_SECTIONS = GUIDE_SECTIONS.filter((s) => !s.slug.startsWith("coverage-") && s.group !== "concept");
export const GUIDE_CONCEPT_SECTIONS = GUIDE_SECTIONS.filter((s) => s.group === "concept");
export const GUIDE_COVERAGE_SUBSECTIONS = GUIDE_SECTIONS.filter((s) => s.slug.startsWith("coverage-"));

// Every screen with a Guide page, in sidebar order (All findings is the same checks as one list).
// "money" is the executive overview: the CFO's only page and the CTO's Overview.
export const GUIDE_SCREEN_ORDER = AREA_ORDER.filter((k) => k !== "findings").flatMap((k) => (k === "actions" ? [k, "money"] : k === "cost" ? [k, "tags"] : [k]));
export const MONEY_CHECK_IDS = [
  "cost_period_over_period", "cost_dollarized_by_service_day", "cost_monthly_actuals", "sf_chg_tag_coverage",
  "cost_chargeback_by_warehouse", "cost_chargeback_by_service", "cost_chargeback_by_account", "sf_cost_contract_balance_burn",
  "sf_cost_month_end_forecast", "sf_cost_invoice_vs_metered", "query_failed_queries_daily", "query_queuing_waits",
  "sf_task_failures", "sf_task_duration_regression",
];
// Checks that read tags; their home is Cost, the Tags page only links to them.
export const GUIDE_TAGS_CHECK_IDS = ["sf_chg_tag_coverage", "sf_gov_tag_hygiene", "sf_chg_tag_based_allocation", "sf_cost_query_attribution_by_query_tag"];
export function guideArea(k: string): GuideArea | null {
  if (k === "money") return { label: "Executive overview", subtabs: [], scope: "" };
  if (k === "tags") return { label: "Tags", subtabs: [], scope: "Tag coverage and untagged spend" };
  return AREA_REGISTRY[k as AreaKey] || null;
}
// A waste source is priced only when its item names a dollar column (waste, saving or month); the
// rest are flagged, not priced.
export function isPricedWaste(id: string) { return WASTE_ITEMS.some((w) => w.id === id && wasteUnitOf(w)); }

// One entry per screen: the "Every tab at a glance" row on Guide home and that screen's own page.
// `screen` items without a `sub` describe a panel; with one, they name the sub-tab they describe.
export const GUIDE_TABS: Record<string, GuideTabInfo> = {
  overview: {
    lens: "Everyone",
    represents: "The bill on one page: spend in credits and dollars, what moved it, possible waste and what to fix first.",
    flags: "Open the linked check or the Actions page.",
    wrong: "A jump from near zero reads as a multiple or \"new\"; today is partial; checks that did not run read \"-\".",
    lede: "Credits and dollars for the window, possible waste, and the few checks worth opening first.",
    questions: [
      "What did we use, and is it rising?",
      "What could stop being paid for?",
      "What should someone open first?",
    ],
    screen: [
      { t: "Six tiles", d: "Spend, possible waste, warehouses, tasks, queries and access, each a number and a link." },
      { t: "Credits per day", d: "The daily trend, spike days marked, today shown as partial." },
      { t: "Where the credits go", d: "The split by service, and warehouse against serverless." },
      { t: "Fix these first", d: "Flagged checks ranked by money; waste, saving and storage each in its own unit." },
      { t: "Price basis", d: "Next to every $: invoice, export option or settings, so you know where the price came from." },
      { t: "How much this audit could see", d: "Checks that ran, out of all checks: the one count the top bar and Coverage & Gaps show too." },
    ],
    measure: "Net credits per day, account and service type; the period before is the same number of days just before.",
    judge: "Nothing here is judged itself; each tile shows the headline of the check behind it.",
    price: "Credits × your effective $ per credit, for every billed unit.",
    troubles: [
      { see: "A change reads 6.2× or \"new\"", why: "The previous period was near zero or empty.", doit: "Open Cost › Trend to see which service started." },
      { see: "A tile reads \"-\"", why: "The check did not run: the role can't see a view, or the edition is too low.", doit: "Coverage & Gaps says which view and how to get it." },
      { see: "Dollars read \"-\" but credits show", why: "No price per credit is available for this export.", doit: "Pass a credit price to the export, or grant the organization billing view." },
    ],
    limits: [
      "Monthly bars are calendar months; the tiles use the rolling window.",
      "Today is included up to the export and is partial; billing lags by hours.",
    ],
  },
  actions: {
    lens: "Everyone",
    represents: "Flagged checks grouped into fixes: what to change, where, and what it saves.",
    flags: "Open the fix, apply the change in Snowflake, run the export again.",
    wrong: "A fix without a dollar figure has no priced source; a saving is possible waste, not a forecast.",
    lede: "The flagged checks as a short list of fixes, each with the objects it touches and the money it frees.",
    questions: [
      "What should we fix first?",
      "How much possible waste does each fix remove?",
      "Which security risks need a change?",
    ],
    screen: [
      { t: "Six numbers", d: "Possible waste, possible saving and storage each apart, then security risks, fixes not priced and flagged checks with no fix yet." },
      { t: "Kinds", d: "Savings, risks, policies and hygiene." },
      { t: "Fix these first", d: "Three groups that are never added: priced in the window, storage per month, and critical findings with no $ (for example an admin without MFA)." },
      { t: "Fix list", d: "One row per fix: how many objects and the money or severity." },
      { t: "Fix detail", d: "Impact, effort, the statement to run, the worst objects, and the checks behind it." },
    ],
    measure: "Every flagged row of a check maps to one fix template; rows for the same fix merge into one fix.",
    judge: "A fix exists only while a check behind it reads Critical or Warn.",
    price: "The same dollars as Waste & savings; risks carry the check's severity instead.",
    troubles: [
      { see: "A fix shows no dollars", why: "Its checks have no priced column.", doit: "Rank it by severity and effort." },
      { see: "A fix you made still shows", why: "The window still holds days from before the change.", doit: "Wait until those days leave the window, then run the export again." },
      { see: "Other flagged checks", why: "Those checks have no fix template yet.", doit: "Open them in All findings." },
    ],
    limits: [
      "Fixes and their statements are templates; check the setting on your account before you change it.",
      "Auto-suspend is never suggested below 60 seconds.",
    ],
  },
  money: {
    lens: "CFO · CTO",
    represents: "The bill for executives: spend against the period before, contract runway, possible waste and the biggest drivers.",
    flags: "Open the driver's own tab; tag the untagged spend.",
    wrong: "A jump from near zero reads as a multiple or \"new\"; spend with no cost-center tag can't be charged back.",
    lede: "Spend, forecast, runway and possible waste for the window, what moved it, and the services, accounts and warehouses behind it.",
    questions: [
      "What did we spend, and is it rising?",
      "How long does the contract last at this rate?",
      "Which services, accounts and warehouses drive it?",
    ],
    screen: [
      { t: "Six numbers", d: "Spend, month-end forecast, contract runway, invoice against metered, possible waste and untagged warehouse spend." },
      { t: "What moved spend", d: "The previous total, the services that added or removed the most, and the current total." },
      { t: "Spend by month", d: "The last 12 calendar months, this month in progress." },
      { t: "Top cost drivers", d: "By service, by account and the top 10 warehouses, and spend by cost center." },
      { t: "Performance", d: "CTO lens only: failed queries, queueing, failing tasks and tasks getting slower." },
    ],
    measure: "Net credits per day, account and service; the period before is the same number of days just before.",
    judge: "Nothing on this page is judged; each card adds up the checks behind it.",
    price: "Credits × your effective $ per credit, less your what-if discount.",
    troubles: [
      { see: "A change reads 6.2× or \"new\"", why: "The previous period was near zero or empty.", doit: "Open What moved spend to see which service started." },
      { see: "Most warehouse spend is untagged", why: "Warehouses were created without a cost-center tag.", doit: "Tag them: Cost › Chargeback & tags lists which." },
      { see: "Contract runway reads \"-\"", why: "The organization billing views are not visible to this role.", doit: "Grant an organization billing role, or read the balance in Snowsight." },
    ],
    limits: [
      "Monthly bars are calendar months; the cards use the rolling window.",
      "Dollars are credits at your effective price, not your invoice line by line.",
    ],
  },
  cost: {
    lens: "FinOps · finance",
    represents: "Who spent what, whether it can be charged back, and which services and accounts grew.",
    flags: "Tag the owner at the source; open the spike's check.",
    wrong: "Untagged and idle usage, query attribution that leaves out idle time, cloud services above the free allowance.",
    lede: "Every credit in the window: the trend, the service split, who spent it, what can't be charged back, the contract rate and the guardrails.",
    questions: [
      "Which account, warehouse, user or tag spent the most?",
      "How much spend can't be charged back?",
      "Are we covered by resource monitors and budgets?",
    ],
    screen: [
      { sub: "trend", d: "Spend by day and month, month-end forecast, spike days marked and set against Snowflake's own anomaly list." },
      { sub: "service", d: "Spend by service type, cloud services billed and data transfer." },
      { sub: "who", d: "Warehouse spend by user, role, BI tool and dbt model." },
      { sub: "chargeback", d: "Spend by tag, warehouse, database and schema, tag hygiene, and how much of the bill can be charged back." },
      { sub: "before", d: "Pick a warehouse, task or pipe and the day a change went in: spend and query measures before against after." },
      { sub: "contract", d: "Contract rates, invoice against metered credits, and the balance runway." },
      { sub: "budgets", d: "Budgets, resource monitors and account parameters that cap spend." },
    ],
    measure: "Metering rows joined to your effective price; query attribution splits a warehouse's credits across its queries.",
    judge: "Coverage and spike checks flag against config/thresholds.yml.",
    price: "Credits × your effective $ per credit; a warehouse's cloud services priced after the warehouse service's own daily 10% adjustment. Archive storage has no list price: it is named, never priced at $0.",
    troubles: [
      { see: "Most spend is untagged", why: "Warehouses, users or roles carry no cost tag.", doit: "Tag them: CREATE TAG, then ALTER WAREHOUSE ... SET TAG." },
      { see: "By-user dollars are below the warehouse bill", why: "Idle time and statements under about 100 ms are not attributed to any query.", doit: "Charge back at the warehouse level, or use the idle-allocation check." },
      { see: "Invoice and metered credits differ", why: "Billing adjustments, or a different price basis.", doit: "Open Contract & rate for the gap by usage type." },
    ],
    limits: [
      "Query attribution is not a total: it is empty on adaptive warehouses and lags up to 8 hours.",
      "Organization billing views lag up to 72 hours.",
      "An attributed query with no QUERY_HISTORY row keeps its credits under \"(no query history row)\" for role, database and schema.",
    ],
  },
  tags: {
    lens: "FinOps · finance",
    represents: "Which warehouses, databases, users and roles miss the required cost tags, and how much spend each tag key reaches.",
    flags: "Tag the objects listed, then run the export again.",
    wrong: "A tag on a warehouse covers the whole warehouse; a query tag covers only its own slice. Objects the export did not list show \"-\", not zero.",
    lede: "Tag coverage by object type, and how much of the priced spend each required tag key reaches.",
    questions: [
      "Which objects are missing a required tag?",
      "How much spend has no tag of each required key?",
      "Which tag keys does the account actually use?",
    ],
    screen: [
      { t: "Required keys", d: "The tag keys you require (Settings). With none set, the ten most used keys are shown instead." },
      { t: "Coverage by object type", d: "Tagged against total per key, with examples of what is missing as name (id)." },
      { t: "Spend by key", d: "Priced spend covered and untagged per key, with the price basis. Each key is its own view of the same spend, never added." },
    ],
    measure: "Tag references joined to warehouses, databases, users, roles and the priced spend of the window.",
    judge: "A missing required tag is listed; nothing on this page reads Critical.",
    price: "Credits × your effective $ per credit; the label next to the $ says which price.",
    troubles: [
      { see: "The page reads \"-\" and a reason", why: "The tag tables were not built in this export.", doit: "Run the export again; Coverage & Gaps names what failed." },
      { see: "A total reads \"-\"", why: "The export lists only tagged objects of that type, so the total is unknown.", doit: "Grant the role the read on the objects, then export again." },
      { see: "Untagged $ is high", why: "No tag of that key reaches the spend: no warehouse tag and no query tag.", doit: "Tag the warehouses, or set QUERY_TAG in the tools that run the work." },
    ],
    limits: [
      "TAG_REFERENCES lags up to a few hours and lists only what the role can see.",
      "The tag filter follows the most specific tag level for each check.",
    ],
  },
  waste: {
    lens: "FinOps · platform",
    represents: "What could stop being paid for: idle and failed work, priced where a source allows it.",
    flags: "Open the biggest offender and apply its fix.",
    wrong: "Only priced rows add up; flagged-but-unpriced checks are counted, not summed; the three money units are never added.",
    lede: "Possible waste, possible saving and storage per month, each on its own, and the objects that make most of each.",
    questions: [
      "How much are we paying for idle or failed work?",
      "Which objects make most of it?",
      "What is flagged but can't be priced?",
    ],
    screen: [
      { sub: "priced", d: "The three figures and the ranked sources behind each." },
      { sub: "unpriced", d: "Checks that flag something with no dollar figure." },
      { sub: "method", d: "Which check counts in which unit, and what is never added." },
    ],
    measure: "Idle warehouse credits, failed statements, no-op task runs, unread dynamic tables, retries, resized warehouses, unused provisioned throughput.",
    judge: "Rows below each check's floor read OK and stay out of the figures.",
    price: "Only the idle, failed or unused share, at your effective $ per credit. Storage is $ per month.",
    troubles: [
      { see: "Waste is \"-\" but checks flag", why: "The waste checks did not run, or have no priced column.", doit: "Coverage & Gaps says which view is missing." },
      { see: "A small object is missing", why: "It is under that check's materiality floor.", doit: "config/materiality.yml holds each floor." },
    ],
    limits: [
      "It prices what was measured, never what might happen.",
      "Overlapping checks (idle time seen twice) are priced once; the second is flagged only.",
    ],
  },
  warehouses: {
    lens: "Platform",
    represents: "Whether warehouses are sized, scaled and suspended right.",
    flags: "Lower auto-suspend, resize, consolidate, cap with a resource monitor.",
    wrong: "A warehouse the role can't see, with no load history or no known size (adaptive) reads Not assessed, never clean.",
    lede: "Idle time, auto-suspend, sizing, queue and spill pressure, multi-cluster scaling and query acceleration.",
    questions: [
      "Which warehouses run while nobody queries them, and what does that cost?",
      "Which are too big, or too small at peak?",
      "Would a shorter auto-suspend save credits, and is the warehouse cache worth keeping warm?",
    ],
    screen: [
      { sub: "idle", d: "Idle credits, auto-suspend tuning and setup risks." },
      { sub: "sizing", d: "Oversized, undersized, pressured and consolidation candidates. Pressure says scale up (memory) or scale out (queueing)." },
      { sub: "load", d: "Load per hour, multi-cluster scaling, Query Acceleration and adaptive warehouses split by user." },
    ],
    measure: "Metering history gives credits per hour; query history gives busy time; gaps over the idle limit are idle.",
    judge: "Limits live in config/thresholds.yml, e.g. the idle gap and the auto-suspend limit.",
    price: "Only the idle share × the warehouse's credit rate × your effective price; an auto-suspend saving is never more than the idle credits.",
    troubles: [
      { see: "A warehouse is 100% idle", why: "Auto-suspend is off, or its queries run under another account.", doit: "Check AUTO_SUSPEND; read the Account filter." },
      { see: "Idle credits are high but idle cost is \"-\"", why: "No price per credit for this export.", doit: "Pass a credit price to the export." },
      { see: "A warehouse is missing", why: "SHOW WAREHOUSES lists only what the role can see.", doit: "Grant MONITOR on the warehouse." },
      { see: "A warehouse reads Not assessed", why: "It is not in SHOW WAREHOUSES, has no load history, or is adaptive (no fixed size).", doit: "Read the reason in its row; grant MONITOR if it is not in SHOW." },
    ],
    limits: [
      "Serverless features are on their own tab; they bill outside any warehouse.",
    ],
  },
  serverless: {
    lens: "Platform · FinOps",
    represents: "What automatic and serverless features cost and whether they pay for themselves.",
    flags: "Drop clustering, materialized views or search optimization that cost more than they save.",
    wrong: "Cost against value uses reads in the window; a table read rarely may still need its feature.",
    lede: "Serverless spend by feature, automatic clustering, materialized views and search optimization against how much they are used.",
    questions: [
      "Which serverless features cost the most?",
      "Which clustering keys, views or search optimization cost more than they save?",
      "Are there large tables that should be clustered?",
    ],
    screen: [
      { sub: "feature", d: "Spend by serverless feature and object, period over period." },
      { sub: "clustering", d: "Automatic clustering cost against reads, candidates and key mismatches." },
      { sub: "mvso", d: "Materialized view refresh and search optimization cost against reads." },
    ],
    measure: "Serverless usage histories per object, joined to how often each object is read.",
    judge: "Cost per read and growth against config/thresholds.yml.",
    price: "Credits × your effective $ per credit.",
    troubles: [
      { see: "A feature shows cost but no reads", why: "Nothing read the object in the window.", doit: "Suspend the feature; resume it if a read returns." },
    ],
    limits: [
      "Value is judged from reads in the window, not from every future use.",
    ],
  },
  queries: {
    lens: "Data and analytics engineering",
    represents: "Which SQL costs most, spills, scans too much, fails or waits, and who runs it.",
    flags: "Tune the costliest query shapes; resize warehouses that queue or spill.",
    wrong: "Per-query credits leave out idle time and short statements; queries with no session record have no known client; statement text is never stored.",
    lede: "The costliest SQL, inefficient shapes, failures, waiting, and cost by source and team.",
    questions: [
      "Which queries cost the most?",
      "Which ones spill, scan everything or miss the cache?",
      "Are queries waiting for capacity or locks?",
    ],
    screen: [
      { sub: "heavy", d: "Queries ranked by credits, repeated expensive ones and long runners." },
      { sub: "efficiency", d: "Spill per warehouse and day, pruning, full scans, compilation, result-cache misses, and statement shapes and tables that got slower (always over a fixed 30 and 56 days, so a week still compares)." },
      { sub: "failures", d: "Failed statements by error, retries and the credits they used." },
      { sub: "waiting", d: "Queue waits, lock waits and workload by hour." },
      { sub: "team", d: "Cost by source, client tool, statement type and tag." },
      { sub: "trend", d: "One measure per warehouse by day or month: queries, failures, time, queueing, spill and cache, against the earlier period." },
    ],
    measure: "Query history and query attribution, grouped by statement shape, never by text.",
    judge: "Spill, scan and queue limits from config/thresholds.yml.",
    price: "Attributed credits (compute plus query acceleration) × your effective $ per credit; failed statements count as possible waste.",
    troubles: [
      { see: "Query dollars below the warehouse bill", why: "Idle time isn't attributed to any statement.", doit: "Use Warehouses › Idle & settings for idle." },
      { see: "Attribution is empty for a warehouse", why: "Adaptive warehouses have no query attribution.", doit: "Read that warehouse at the warehouse level." },
      { see: "A client reads \"(no session record)\"", why: "Its session is not in SESSIONS: opened long before the window or past retention.", doit: "Nothing to fix; it is a gap in the data, never judged." },
    ],
    limits: [
      "Query attribution lags up to 8 hours and leaves out queries under about 100 ms.",
      "Top queries by cost keeps the 5,000 costliest groups and costly statements the 500 longest shapes; a count of them is of those kept.",
      "Queue status is judged per warehouse and day and repeated on that day's hour rows; counts on screen are of warehouses.",
    ],
  },
  tasks: {
    lens: "Data engineering",
    represents: "Which tasks fail, slow down or run for nothing, what they cost, and how dynamic tables and streams behave.",
    flags: "Fix by error; move short tasks off a warehouse; drop stale tasks.",
    wrong: "Slowdown needs enough runs on both sides; tasks the role can't see are missing.",
    lede: "Failed and slow tasks, what they cost, hygiene gaps, dynamic tables and streams.",
    questions: [
      "Which tasks are failing, and why?",
      "Which tasks got slower or run for nothing?",
      "Which dynamic tables refresh for nobody?",
    ],
    screen: [
      { sub: "failures", d: "Failing and silently failing tasks, broken task graphs and alerts, including alerts nobody is told about." },
      { sub: "cost", d: "Task cost, warehouse against serverless, slowdowns, skipped overlaps and no-op runs." },
      { sub: "hygiene", d: "Suspended or stale tasks and tasks whose owner role is gone." },
      { sub: "dynamic", d: "Dynamic table failures, lag and cost, and streams that are stale or unconsumed." },
    ],
    measure: "Task history and graph history joined to the metering of the warehouse or serverless task that ran them.",
    judge: "Failure rate, slowdown and staleness from config/thresholds.yml.",
    price: "Task credits × your effective $ per credit; idle warehouse time kept awake by short tasks is possible waste.",
    troubles: [
      { see: "A slow task isn't flagged", why: "It needs enough successful runs before and after.", doit: "Widen the window to 90 days." },
      { see: "A task is missing", why: "SHOW TASKS lists only what the role can see.", doit: "Grant MONITOR on the tasks." },
    ],
    limits: [
      "Task history keeps 365 days; serverless task cost is metered separately from warehouse tasks.",
    ],
  },
  loading: {
    lens: "Data engineering",
    represents: "What loading costs and whether pipes, streaming channels and COPY loads are healthy.",
    flags: "Fix load errors, merge small files, stop pipes that no longer load.",
    wrong: "Loads by another tool leave no pipe history; external tables read as stale when nothing changed.",
    lede: "Snowpipe and Snowpipe Streaming cost and health, COPY errors, small files, external and Iceberg tables.",
    questions: [
      "What does each pipe cost per GB and per file?",
      "Which loads fail or make too many small files?",
      "Which pipes stopped loading?",
    ],
    screen: [
      { sub: "pipes", d: "Pipe cost, inactive pipes, streaming cost, latency and channel errors." },
      { sub: "copy", d: "COPY errors, small files, external tables and Iceberg tables." },
    ],
    measure: "Pipe usage, COPY history and streaming histories per table.",
    judge: "Error rate, file size and latency from config/thresholds.yml.",
    price: "Load credits × your effective $ per credit.",
    troubles: [
      { see: "A pipe shows cost but few files", why: "Many tiny files, or a burst.", doit: "Batch the files before they land." },
    ],
    limits: [
      "COPY history keeps 365 days; a table loaded by another tool has no pipe row.",
    ],
  },
  ai: {
    lens: "ML platform · FinOps",
    represents: "What Cortex, containers and apps cost and who uses them.",
    flags: "Cap unused provisioned throughput; move heavy AI functions to a smaller model or warehouse.",
    wrong: "AI spend is billed by feature; the reconciled view shows any part that no feature explains.",
    lede: "AI and container spend by feature and user, and what Streamlit apps, functions and installed apps use.",
    questions: [
      "What do AI functions, Analyst, Search and Agents cost?",
      "Are we paying for provisioned throughput we do not use?",
      "Which apps and containers run on our compute?",
    ],
    screen: [
      { sub: "cortex", d: "AI spend trend, by function, user, Analyst, Search, Agents and Code, reconciled to the bill; who can call Cortex, AI credits lost to failed statements and Search indexes that stopped taking rows." },
      { sub: "apps", d: "Container services and compute pools, services that can take internet traffic, notebook runtime, Streamlit apps, functions and procedures, and installed Native Apps." },
      { sub: "serving", d: "Model serving spend." },
    ],
    measure: "Cortex and container usage histories, reconciled to the billed AI services total.",
    judge: "Growth and unexplained share against config/thresholds.yml.",
    price: "Credits × your effective $ per credit.",
    troubles: [
      { see: "Unexplained credits in AI spend", why: "A feature bills without its own usage view.", doit: "Read the reconciled check for the gap." },
    ],
    limits: [
      "New AI features appear in the reconciled total before they have their own view.",
    ],
  },
  access: {
    lens: "Security · data governance",
    represents: "Who can reach what, how people sign in, and which perimeter settings need a look.",
    flags: "Narrow grants, enrol MFA, restrict networks, retire stale users.",
    wrong: "Grants and users cover the whole account and ignore the Account filter; a view the role can't see reads Not assessed, not clean.",
    lede: "Roles and grants, users and sign-ins, and the account perimeter.",
    questions: [
      "Who has broad access?",
      "Who signs in without MFA, with a password, or not at all?",
      "Is the account perimeter (network, sessions, integrations) set up?",
    ],
    screen: [
      { sub: "roles", d: "Broad and PUBLIC grants, role hygiene, direct and grant-option privileges." },
      { sub: "users", d: "MFA, password and key-pair age, stale users, failed and new sign-ins, clients and SSO." },
      { sub: "perimeter", d: "Trust Center findings and their age, network, session, password and authentication policies, integrations, PrivateLink, failover readiness and secrets." },
    ],
    measure: "Grants, users, login history and account parameters from ACCOUNT_USAGE and SHOW.",
    judge: "Broad grantees, stale days and failed sign-ins flag against config/thresholds.yml.",
    price: "Not priced; risks carry a severity.",
    troubles: [
      { see: "A check reads Not assessed", why: "The role can't see that view, or the edition doesn't have it.", doit: "Coverage & Gaps names the view and the grant." },
      { see: "POLICY_REFERENCES lacks session policies", why: "It does not list session, password or authentication policies.", doit: "Those are read from the account and user settings instead." },
    ],
    limits: [
      "It sees only what the audit role can see.",
      "Login history keeps 365 days.",
    ],
  },
  audit: {
    lens: "Security · data governance",
    represents: "Who holds the admin roles, how they use them, and what changed in grants and security settings.",
    flags: "Confirm each admin change with the person who made it; remove admin roles nobody needs.",
    wrong: "Changes come from query history and grants; a change made through a tool the role can't see reads Not assessed, not clean.",
    lede: "Admin role holders, sign-ins and sessions, privileged grant changes, security setting changes, everyday grants and object DDL.",
    questions: [
      "Who holds ACCOUNTADMIN, SECURITYADMIN and the other admin roles?",
      "Which grants and security settings changed, and who changed them?",
    ],
    screen: [
      { sub: "admins", d: "Admin role holders, their daily use, sign-ins and sessions." },
      { sub: "changes", d: "Privileged grant changes, security setting changes, everyday grant activity and object DDL." },
    ],
    measure: "Grants, login history and query history from ACCOUNT_USAGE.",
    judge: "Admin holders, unusual use and changes flag against config/thresholds.yml.",
    price: "Not priced; risks carry a severity.",
    troubles: [
      { see: "A check reads Not assessed", why: "The role can't see that view.", doit: "Coverage & Gaps names the view and the grant." },
    ],
    limits: [
      "Query and grant history keep 365 days; ACCOUNT_USAGE lags up to a few hours.",
    ],
  },
  pii: {
    lens: "Security · data governance",
    represents: "Where sensitive data is, whether it is masked, who reads it and where it goes.",
    flags: "Mask sensitive columns, remove exempt readers, fix unused policies.",
    wrong: "Untagged does not prove no PII; policy bodies are never stored, only who they let through.",
    lede: "Sensitive columns and coverage, masking and row policies, who reads sensitive data and where data leaves.",
    questions: [
      "Which sensitive columns have no mask?",
      "Which policies are unused, broken or too open?",
      "Who read sensitive data, and where did data leave the account?",
    ],
    screen: [
      { sub: "sensitive", d: "Classification coverage, unprotected sensitive columns and untagged copies." },
      { sub: "policies", d: "Unused or broken policies and who a policy lets through." },
      { sub: "reads", d: "Who read sensitive columns and what left the account, including shares that carry sensitive columns." },
      { sub: "quality", d: "Data quality: which databases have data metric functions on their tables." },
    ],
    measure: "Data classification, policy references and access history.",
    judge: "Unprotected sensitive columns and sensitive reads flag against config/thresholds.yml.",
    price: "Not priced; risks carry a severity.",
    troubles: [
      { see: "Classification checks are empty", why: "Data classification isn't turned on, or the edition is too low.", doit: "Enable it, then run the export again." },
      { see: "A masked column is still read", why: "Reads come from access history whether or not the mask applied.", doit: "Use the policy inventory to confirm." },
    ],
    limits: [
      "Access history needs Enterprise edition and keeps 365 days.",
    ],
  },
  lineage: {
    lens: "Data governance",
    represents: "What depends on what, which databases, users and views are used, and which views point at objects that are gone.",
    flags: "Retire unused databases and views; fix broken views; review the objects most others depend on.",
    wrong: "Usage is from query history; an object read only by shares shows less use.",
    lede: "Objects the most others depend on, table flows, broken views, and the most and least used databases, users and views.",
    questions: [
      "Which databases and schemas are used, and which are not?",
      "Who holds roles but runs nothing?",
      "Which views point at dropped objects?",
    ],
    screen: [
      { sub: "dependencies", d: "Blast radius of a change, broken views, table flows and the view inventory." },
      { sub: "usage", d: "Database, user and view activity, unused views and object counts." },
    ],
    measure: "Access history, query history and object dependencies.",
    judge: "Unused days and broken references against config/thresholds.yml.",
    price: "Storage of unused objects is $ per month.",
    troubles: [
      { see: "A used database reads unused", why: "It is read only through a share or outside the window.", doit: "Confirm before you drop it." },
    ],
    limits: [
      "Dependencies are declared ones; a table read only through a pipeline or copy shows in Table flows, not in Blast radius.",
    ],
  },
  sharing: {
    lens: "Governance · FinOps",
    represents: "What this account shares out, what it takes in, and, with an organization role, how every account spends.",
    flags: "Retire unread shares and dormant accounts; cap reader accounts.",
    wrong: "The organization sub-tabs are hidden when the role has no organization access, and list what is missing on Coverage & Gaps.",
    lede: "Shares and listings, reader accounts, accounts across the organization, spend by account, replication and transfer.",
    questions: [
      "What data is shared out, and who reads it?",
      "Which accounts still bill but do little?",
      "What does replication and data transfer cost?",
    ],
    screen: [
      { sub: "shares", d: "Shares and listings, reader accounts, inbound databases and paid Marketplace listings against what is read." },
      { sub: "accounts", d: "Account inventory, dormant accounts, edition fit and region spread (organization only)." },
      { sub: "spend", d: "Spend by account and service, spikes, serverless and storage by account (organization only)." },
      { sub: "replication", d: "Replication and failover groups, their cost, and data transfer by account." },
    ],
    measure: "Data sharing usage and, with access, the organization billing views.",
    judge: "Growth, share and dormancy against config/thresholds.yml.",
    price: "Credits × each account's billed rate where the organization view gives it.",
    troubles: [
      { see: "The organization sub-tabs are missing", why: "The role can't read ORGANIZATION_USAGE.", doit: "Use a role in the organization account (README, Roles and privileges)." },
    ],
    limits: [
      "Organization billing views lag up to 72 hours.",
    ],
  },
  storage: {
    lens: "Platform · FinOps",
    represents: "Where storage sits, what nobody reads, and what Time Travel and Fail-safe add.",
    flags: "Drop unused tables and clones; shorten Time Travel; make staging tables transient.",
    wrong: "A table nobody read in the window may still be needed; Fail-safe tables have no name and are labelled \"Fail-safe table (id)\"; clones are judged only under unread clones.",
    lede: "Database growth, stage files, unused tables and clones, Time Travel and Fail-safe.",
    questions: [
      "Which databases grow fastest, and which tables look unused?",
      "What do Time Travel and Fail-safe cost?",
      "Which clones and dropped tables still bill?",
    ],
    screen: [
      { sub: "growth", d: "Database growth, stage files and the table inventory." },
      { sub: "unused", d: "Unused tables, schema sprawl, unread clones and dropped-not-purged tables." },
      { sub: "retention", d: "Time Travel and retention, Fail-safe on staging tables, clone-retained bytes, table churn and lifecycle policies that fail." },
      { sub: "backups", d: "Backup and snapshot sets: storage per month as an upper bound (\"up to\"), never added to window spend." },
    ],
    measure: "Table storage metrics and access history, at TABLE_ID and BASE_TABLE_ID while the rename rolls out.",
    judge: "Unread days and retention against config/thresholds.yml.",
    price: "Bytes × your $ per TB per month, never added to window dollars. A table flagged by several checks counts once, at its largest figure. A dropped table saves only the bytes clones keep; its Time Travel and Fail-safe age out by themselves.",
    troubles: [
      { see: "A used table reads unused", why: "It is read only through a share or outside the window.", doit: "Confirm before you drop it." },
      { see: "Dropped tables still bill", why: "Time Travel and Fail-safe keep them for their retention.", doit: "Shorten retention, or wait it out." },
    ],
    limits: [
      "Storage figures are $ per month; they are shown apart from compute credits.",
    ],
  },
  coverage: {
    lens: "Everyone",
    represents: "What this audit could see, what it couldn't, and why.",
    flags: "Grant the missing view, then run the export again.",
    wrong: "No data means nothing happened or nothing was readable, never zero.",
    lede: "Which Snowflake views were readable, which checks couldn't run and why, and the fixed limits of this audit.",
    questions: [
      "Which checks ran?",
      "Which views were missing or empty?",
      "What can't this audit see at all?",
    ],
    screen: [
      { sub: "sources", d: "Every view and command: read, empty or refused, and the grant it needs. Also source freshness: how far behind each usage view is." },
      { sub: "couldnt", d: "Checks that couldn't run, with the reason and the fix. Also role visibility (how many billed warehouses the role sees) and the detected edition." },
      { sub: "limits", d: "How Snowflake records usage, and what that means for a number." },
    ],
    measure: "Each source is read by the checks that need it; the export records which checks failed and why.",
    judge: "A source is read, empty or refused.",
    price: "Not priced.",
    troubles: [
      { see: "A view is refused", why: "The role can't see it, or the edition doesn't have it.", doit: "Grant IMPORTED PRIVILEGES on the SNOWFLAKE database; organization views need an organization role." },
      { see: "A view is empty", why: "Nothing happened, or the feature isn't in use.", doit: "Not a verified zero." },
    ],
    limits: [
      "SHOW commands list only what the role can see.",
    ],
  },
};


export function guideSearchText(f: GuideCheck, label: CheckLabel) {
  const parts = [
    label.title, label.why, f.title, f.query_id, f.summary, f.read_this, f.investigate_if,
    ...(f.reads || []), ...(f.docs || []),
    ...((f.columns || []).map((c: any) => c.name)),
    ...((f.library_corrections || []).map((c: any) => `${c.problem} ${c.effect} ${c.fix}`)),
  ];
  return parts.filter(Boolean).join(" ").toLowerCase();
}

export function splitSentences(text: string | null | undefined): string[] {
  if (!text) return [];
  const trimmed = String(text).trim();
  if (!trimmed || trimmed.toLowerCase().startsWith("n/a")) return [];
  return trimmed.split(/(?<=[.!?])\s+/).filter(Boolean);
}

export const ANYWHERE_TIER_BRACKET_RE = /\(([^()]*(?:free|config|spend)[^()]*)\)/i;
export const TRAILING_TIER_BRACKET_RE = /\s*\(([^()]*)\)\s*[;.]?\s*$/;
// A rung's tier comes only from a bracket that names free/config/spend -- never a bare word
// match on the whole sentence, which would tag "does not itself justify new spend" as SPEND.
export function rungTier(action: string) {
  const m = String(action || "").match(ANYWHERE_TIER_BRACKET_RE);
  return m ? actionTier(m[1]) : null;
}
// The chip already says the tier, so a trailing tier bracket is stripped from the shown text.
export function rungText(action: string) {
  const full = String(action || "").trim();
  const trailing = full.match(TRAILING_TIER_BRACKET_RE);
  return trailing && actionTier(trailing[1]) ? full.slice(0, trailing.index).trim() : full;
}

// A header's free-text fields (read_this/healthy/investigate_if/actions, already cleaned
// server-side by app/api/guide.py's _clean_prose) still name real column identifiers, not English
// words. A reference page keeps those in code font, verbatim, so a reader can match one straight to
// the Columns table below, rather than guessing a rewording.
export const PROSE_SNAKE_RE = /\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b/g;
export function codeifyProse(text: string | null | undefined) {
  if (!text) return null;
  const s = String(text);
  const nodes: (string | React.ReactElement)[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  const re = new RegExp(PROSE_SNAKE_RE);
  // eslint-disable-next-line no-cond-assign
  while ((m = re.exec(s)) !== null) {
    if (m.index > last) nodes.push(s.slice(last, m.index));
    nodes.push(<code key={m.index}>{m[0]}</code>);
    last = m.index + m[0].length;
  }
  if (last < s.length) nodes.push(s.slice(last));
  return nodes;
}

// Plain-string sibling of codeifyProse, for the few spots that need a string, not JSX nodes: an HTML
// attribute (title=) can't hold an array of <code> elements.
export function desnakeProse(text: string | null | undefined) {
  if (!text) return text;
  return String(text).replace(PROSE_SNAKE_RE, (m) => m.replace(/_/g, " "));
}

// healthy/investigate_if lead with a "status = OK - " (or WARN/CRITICAL) prefix that only repeats
// the Badge shown beside the text, and resolve_params() (service.py) writes a threshold as
// "30 (default) percent". Both are plain string shape, so this is a client-side format pass. Runs
// before codeifyProse, which handles snake_case.
export const STATUS_PREFIX_RE = /^status\s*=\s*\w+\s*-\s*/i;
export const DEFAULT_PERCENT_RE = /(\d+(?:\.\d+)?)\s*\(default\)\s*percent/gi;
export function cleanFlagPrefix(text: string) {
  if (!text) return text;
  let s = String(text).replace(STATUS_PREFIX_RE, "");
  s = s.replace(DEFAULT_PERCENT_RE, "$1% (default)");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

// A link within the Guide itself (a check's article, or a home topic): always a real hash change,
// so back/forward and a shared link both work like any other in-app jump.
export function guideLinkProps(focusId?: string | null) {
  const href = navHref({ tab: "guide", focus: focusId || null });
  return {
    href,
    onClick: (e: React.MouseEvent<HTMLElement>) => {
      e.preventDefault();
      if (href === window.location.hash) return; // already there
      window.location.hash = href;
    },
  };
}

export function appTabLinkProps(tab: string, subtab?: string | null) {
  const href = navHref({ tab, subtab: subtab || null, focus: null });
  return { href, onClick: (e: React.MouseEvent<HTMLElement>) => { e.preventDefault(); window.location.hash = href; } };
}

export function openInAppLinkProps(f: GuideCheck) {
  const home: GuideHomeRef = homeForQuery(f);
  const build = () => navHref({
    tab: home.tab, subtab: home.subtab, domain: home.domain, focusQueryId: f.query_id, view: null,
  });
  return {
    href: build(),
    onClick: (e: React.MouseEvent<HTMLElement>) => { e.preventDefault(); window.location.hash = build(); },
  };
}

export function fallbackCopyText(text: string) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  try { document.execCommand("copy"); } finally { document.body.removeChild(ta); }
}

export function copyGuideLink(queryId: string, onDone?: () => void) {
  const url = `${window.location.origin}${window.location.pathname}#${new URLSearchParams({ tab: "guide", focus: queryId })}`;
  const clip = window.navigator && window.navigator.clipboard;
  const done = () => onDone && onDone();
  if (clip && clip.writeText) {
    clip.writeText(url).then(done).catch(() => { try { fallbackCopyText(url); done(); } catch (e) { /* nothing more to try */ } });
    return;
  }
  try { fallbackCopyText(url); done(); } catch (e) { /* nothing more to try */ }
}

// One docs.snowflake.com page, from config/snowflake_docs.yml through the API: data.docs[key] is
// {title, url}. A source with no entry shows its name alone, never a made-up link.
export function DocsLink({ docsKey, docs }: { docsKey: string; docs?: DocsMap | null }) {
  const entry = docs && docs[docsKey];
  if (!entry) return null;
  return (
    <div className="guide2-doclink">
      {entry.url ? <a href={entry.url} target="_blank" rel="noreferrer">{entry.title || docsKey}</a> : <span className="muted">{entry.title || docsKey}</span>}
    </div>
  );
}

// What a tag filter follows for each group of checks, most specific first.
export const TAG_REACH_GROUPS = [
  { key: "spend", label: "Query tag → object tag → warehouse tag → user or role tag → account tag", note: "Spend is recomputed from each billed credit's most specific tag." },
  { key: "work", label: "Query tag → object tag → warehouse tag", note: "Each row names the task, pipe, dynamic table or statement." },
  { key: "compute", label: "Warehouse tag → account tag", note: "Each row names the warehouse." },
  { key: "object", label: "Table, schema or database tag", note: "Each row names a table or other data object." },
  { key: "row", label: "The row's own tag", note: "These checks list tag values themselves." },
  { key: "account", label: "Account tag only", note: "Rows carry no query, object or warehouse, so the filter keeps or drops whole accounts." },
  { key: "none", label: "Not filtered by tags", note: "Price lists, grants and other lists no tag can reach; they always cover everything." },
];

export function tagReachGroup(reach: { kind?: string; words?: string[] } | null | undefined) {
  if (!reach) return null;
  const w = reach.words || [];
  if (reach.kind === "spend") return "spend";
  if (reach.kind === "none") return "none";
  if (reach.kind === "row_tags") return "row";
  if (w.some((x) => x === "query" || x === "job" || x === "pipeline" || x === "task")) return "work";
  if (w.includes("object")) return "object";
  if (w.includes("compute") || w.includes("warehouse")) return "compute";
  return "account";
}

export function TagReachTable({ findings }: { findings?: GuideCheck[] | null }) {
  const byGroup: Record<string, string[]> = {};
  let unknown = 0;
  (findings || []).forEach((f) => {
    const g = tagReachGroup(f.tag_reach);
    if (!g) { unknown += 1; return; }
    (byGroup[g] = byGroup[g] || []).push(getCheckLabel(f.query_id, f.title).title);
  });
  return (
    <div>
      <h3>What the tag filter reaches</h3>
      <table className="tag-rollup-table" style={{ width: "100%", fontSize: 12, borderCollapse: "collapse" }}>
        <thead>
          <tr className="faint">
            <th style={{ textAlign: "left" }}>The filter follows</th>
            <th style={{ textAlign: "right" }}>Checks</th>
          </tr>
        </thead>
        <tbody>
          {TAG_REACH_GROUPS.filter((g) => byGroup[g.key]).map((g) => (
            <tr key={g.key}>
              <td>
                <div>{g.label}</div>
                <div className="faint">{g.note}</div>
                <details>
                  <summary className="faint">Show checks</summary>
                  <div className="faint">{byGroup[g.key].sort().join(", ")}</div>
                </details>
              </td>
              <td className="mono" style={{ textAlign: "right", verticalAlign: "top" }}>{byGroup[g.key].length}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {unknown > 0 && <p className="faint">{`${unknown} checks are not in this export, so their reach is not known yet.`}</p>}
    </div>
  );
}

export function renderHowBody(slug: string, app: GuideApp, findings: GuideCheck[], meta?: Meta | null) {
  switch (slug) {
    case "flow": {
      const direct = app.direct_export;
      const steps = ["Snowflake ACCOUNT_USAGE views", "Checks run with your credentials", "Result files", "This app"];
      return (
        <div>
          <div className="guide2-flow">
            {steps.map((step, i) => (
              <React.Fragment key={step}>
                {i > 0 && <span className="guide2-flow-arrow">&rarr;</span>}
                <span className="guide2-flow-step">{step}</span>
              </React.Fragment>
            ))}
          </div>
          <p>
            Your own credentials ran every check on Snowflake, read-only (only SELECT, WITH and SHOW),
            and saved only the result rows locally: nothing is sent anywhere else, and no query text,
            SQL literal, secret or policy body is stored. Every check names the exact view(s) it reads
            ("Reads" on its own page)
            {direct ? <span>, and the data on screen was computed on <span className="mono">{(direct.as_of || "").slice(0, 10)}</span></span> : null}.
          </p>
          <p>
            When the role cannot read ACCOUNT_USAGE, five checks (query load per warehouse, failed
            queries, queue waits, sign-ins and database storage growth) read INFORMATION_SCHEMA table
            functions instead. Those keep 7 days of query and sign-in history and only what the role can
            see, and use names in place of ids; the page says so under its sub-tabs.
          </p>
        </div>
      );
    }
    case "window":
      return (
        <p>
          Most checks use a rolling window (<span className="mono">{app.window_options.join("/")}</span> days)
          up to the export. Today counts up to the moment the export ran and the top bar marks it
          "today partial"; billing views lag by hours, so its last hours can be missing
          (<span className="mono">include_today: false</span> exports full days only). An export
          shorter than the window you picked is marked, so a partial window never reads as a complete
          one. A "snapshot" check has no window at all: it shows the current state (the latest known
          configuration), not a period.
        </p>
      );
    case "status":
      return <StatusMeaningsGrid />;
    case "floors":
      return (
        <div>
        <p>
          Some checks also carry a materiality floor: a row that would flag Critical or Warn, but
          whose own dollar or unit column sits under a set minimum, reads OK instead and is marked{" "}
          <span className="mono">below_floor</span>: too small to be worth judging. Every count, the
          worst status shown and every $ total already exclude floored rows; a "Not assessed" row is
          never touched by a floor. Floors are set per check in{" "}
          <span className="mono">config/materiality.yml</span>
          {app.materiality_floors_configured != null
            ? `, ${app.materiality_floors_configured} checks have one today.`
            : "."}
          {" "}A floor reads as "Under $50" (dollar floors are per 30 days and scale with the window) or "Under 100 GB".
        </p>
        {(findings || []).some((f) => f.floor) && (
          <GuideMiniTable
            head={["Check", "Floor"]}
            rows={(findings || []).filter((f) => f.floor).map((f) => [<GuideCheckLink key={f.query_id} id={f.query_id} />, `Under ${f.floor.label || f.floor.column}`])}
          />
        )}
        </div>
      );
    case "money":
      return (
        <div>
          <p>
            Snowflake bills in credits. Every dollar figure here is credits &times; your effective
            price per credit
            {app.direct_export && app.direct_export.pricing && app.direct_export.pricing.credit_price_usd != null
              ? <span> (<span className="mono">{`$${Number(app.direct_export.pricing.credit_price_usd).toFixed(2)}`}</span> in this export, {app.direct_export.pricing.source === "usage_in_currency_daily" ? "derived from your invoice through the organization billing view" : app.direct_export.pricing.source === "rate_sheet_daily" ? "your contract rate from the organization rate sheet" : app.direct_export.pricing.source === "settings" ? "the default price in config/settings.yml, not your invoice" : "the price given to the export"})</span>
              : ". This export has no price, so dollars read \"-\" and credits are shown instead"}
            {guideDiscountNote(app, meta)} <a {...guideLinkProps("how-pricing")}>Where the price comes from</a>. Cloud
            services are priced after Snowflake's daily 10% adjustment, and storage at your price per TB per
            month. It is not your invoice line by line.
          </p>
          <p>
            "Possible waste" means credits billed for nothing: warehouses running with no query
            {app.idle_gap_seconds != null ? ` for more than ${app.idle_gap_seconds}s at a stretch` : ""}, failed
            statements, task runs that changed nothing, dynamic tables nobody reads, query retries,
            warehouses left at a bigger size and provisioned AI throughput that was not used. A
            "possible saving" (a resize) and storage per month are separate figures. The three are never
            added, and none is a forecast: each states the dates it covers.
          </p>
          <p>
            Waste &amp; savings reads checks that already run on their own pages; nothing there is a
            separate measurement. A check adds the sum of its money column over the rows it flagged
            Critical or Warning, after its materiality floor, at your effective $ per credit. A resource's
            ordinary spend is never counted as waste, only the idle, failed or unused part. Checks that
            overlap (idle time seen by two checks) are priced once: idle waste has one home, the warehouse
            idle check, and the saving from a shorter auto-suspend is shown on Warehouses and Actions as
            the fix's impact with the idle cost as context. A check whose $ is spend or context is listed
            as flagged and links to its own figure, never added to a total. A check that did not run reads
            "-" with the reason, never $0.
          </p>
        </div>
      );
    case "steps":
      return (
        <p>
          Every step in a check's "What to do" is tagged{" "}
          <Badge kind="info">FREE</Badge> (a setting change or a read, no spend),{" "}
          <Badge kind="info">CONFIG</Badge> (changes how something is configured, not what it
          costs directly) or <Badge kind="info">SPEND</Badge> (a step that costs money to carry
          out). A threshold named inside a step shows "default" when nobody has changed it, or
          "your setting" once <span className="mono">config/thresholds.yml</span> overrides it.
        </p>
      );
    case "tags":
      return (
        <div>
          <p>
            Spend follows the most specific tag it can find: the query's own tag first, then the tag
            on the object (table, schema, database, task or pipe), then the warehouse's tag, then the
            user's or role's tag, then the account's. Each level shows its own "untagged" row with a
            count and a dollar figure, and the levels sum back to the same total: attribution narrows
            the picture, it never invents or drops spend. The filters this app offers are whichever
            tag keys your own account actually uses, never a fixed list.
          </p>
          <p>
            A query tag is free text, so it is matched as a whole unless the tag rules in{" "}
            <span className="mono">config/tag_aliases.yml</span> say how to read key=value or JSON.
          </p>
          <TagReachTable findings={findings} />
        </div>
      );
    case "names":
      return (
        <p>
          Once a name is known, a row shows it as "name (id)" rather than the bare id, for
          warehouses, databases, tasks, users and roles. When no name could be resolved, the row
          says why instead of leaving a blank or guessing at one. User names and emails can be
          masked on screen in Settings. Warehouse, database, role and other names can be replaced with
          tokens in the export itself (Settings, or the export's --mask), the same token everywhere.
        </p>
      );
    case "coverage":
      return (
        <p>
          Coverage &amp; Gaps shows which Snowflake views this export could read, and what reading one
          needs: most need only <span className="mono">IMPORTED PRIVILEGES</span> on the SNOWFLAKE
          database, the organization views need an organization role, and SHOW commands list only
          what the role can see. A check whose view is missing, whose edition is too low or whose
          role can't see it reads NOT ASSESSED with that reason, never "nothing found".
        </p>
      );
    case "coverage-data-sources":
      return (
        <div>
          <p>
            The Data sources tab lists every view and command this app reads: how many checks
            depend on it, how many ran clean, what it covers and, if it was refused or empty, why.
            It splits them into <b>Read</b>, <b>Empty</b> (read fine, 0 rows: not a verified zero),{" "}
            <b>Could not read</b> (the role can't see it, the view isn't in this account, a timeout) and{" "}
            <b>Not in this export</b>. The one "checks that ran" count is the same one the top bar and
            Overview show. <b>What this audit cost</b> is a reference figure showing how much of each
            warehouse's spend was this audit itself.
          </p>
          <p>
            <b>What to do:</b> for a refused source, grant the audit role the read it needs (the row
            names it); for an empty one, read its note: some are a true zero, others need a feature
            turned on first.
          </p>
          <a className="ck-link" {...appTabLinkProps("coverage", "sources")}>{"Back to Coverage & Gaps › Data sources →"}</a>
        </div>
      );
    case "coverage-couldnt-check":
      return (
        <div>
          <p>
            The Not assessed tab lists every check that judged nothing this window: it was{" "}
            <b>not assessed</b> (skipped or failed), it hit a <b>read error</b>, it found{" "}
            <b>nothing in this window</b>, or your filters excluded every row. None of these is a
            pass, even the ones that ran cleanly and found nothing.
          </p>
          <p>
            <b>What to do:</b> open the check's own page and read "Why the number could be off" for the
            exact reason and, where there is one, the grant or setting that fixes it.
          </p>
          <a className="ck-link" {...appTabLinkProps("coverage", "couldnt")}>{"Back to Coverage & Gaps › Not assessed →"}</a>
        </div>
      );
    case "coverage-known-limitations":
      return (
        <div>
          <p>
            The Known limitations tab lists how Snowflake records usage and what that means for
            reading a number: cloud services priced after the 10% adjustment, query attribution that
            leaves out idle time, views that show only what the role can see, data lag, Fail-safe
            tables with no name, and policies that POLICY_REFERENCES does not list.
          </p>
          <p><b>What to do:</b> nothing to configure; read the affected number with its own note in mind.</p>
          <a className="ck-link" {...appTabLinkProps("coverage", "limits")}>{"Back to Coverage & Gaps › Known limitations →"}</a>
        </div>
      );
    default:
      return guideConceptBody(slug, app, meta, findings);
  }
}

// ═══════════════════════════════════ Concept and reference topics ═══════════════════════════════════

// A check's own page, by its Guide title.
export function GuideCheckLink({ id }: { id: string }) {
  return <a {...guideLinkProps(id)}>{getCheckLabel(id, id).title}</a>;
}

// One small table the concept pages share: head row, then rows of plain strings or nodes.
export function GuideMiniTable({ head, rows }: { head: string[]; rows: React.ReactNode[][] }) {
  return (
    <div className="gd-table-wrap">
      <table className="gd-table">
        <thead><tr>{head.map((h) => <th key={h}>{h}</th>)}</tr></thead>
        <tbody>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => <td key={j} className={j === 0 ? "gd-small" : undefined}>{j === 0 ? <b>{c}</b> : c}</td>)}</tr>)}</tbody>
      </table>
    </div>
  );
}

// The what-if discount sentence of "How dollars are worked out", from /api/meta's discount object.
export function guideDiscountNote(app: GuideApp, meta?: Meta | null) {
  const d = meta && meta.discount;
  if (d && d.ignored) return `. The what-if discount is not applied: ${d.reason || "the price is already your invoice rate"}.`;
  const pct = d && d.effective != null ? d.effective : app.discount_pct;
  return pct ? `, less a what-if discount of ${fmtPct(pct * 100)}.` : ".";
}

// Reason codes a check can carry in not_assessed_reason, with what they mean and the fix.
export const GUIDE_NOT_ASSESSED_CODES = [
  { code: "previous_window_not_covered", d: "The account is younger than the window, so there is no period before to compare with.", fix: "Wait, or pick a shorter window." },
  { code: "last_month_not_covered / too_early_in_month", d: "The month-end forecast needs a full last month and at least a few days of this one.", fix: "Read it again later in the month." },
  { code: "baseline_too_short", d: "Too few days of earlier spend to judge a spike against.", fix: "Wait for more history." },
  { code: "too_few_scanned_queries", d: "Too few scanned statements that day on that warehouse to judge cache behaviour.", fix: "None; a small sample is not judged." },
  { code: "not_in_show_warehouses / warehouse_not_visible", d: "The warehouse bills, but SHOW WAREHOUSES does not list it for this role. It is not deleted.", fix: "GRANT MONITOR on the warehouse." },
  { code: "monitor_not_visible / integrations_not_visible / integration_not_visible / stages_not_visible / tasks_not_visible / alerts_not_visible / streams_not_visible_or_none", d: "SHOW lists only what the role owns or can see, so a blind role cannot tell none from hidden.", fix: "Use a role that owns or can monitor the objects." },
  { code: "access_history_unavailable / edition_too_low", d: "The feature (for example ACCESS_HISTORY) needs a higher edition.", fix: "None on Standard edition; no grant helps." },
  { code: "not_consumption", d: "The billing line is not consumption (for example a prepaid purchase), so it is not compared with metered credits.", fix: "None; it is left out on purpose." },
  { code: "unpriced", d: "No price exists for this product (for example archive storage), so its $ reads \"-\", never 0.", fix: "Read the credits or TB-days instead." },
  { code: "no_credential_record", d: "The user has no row in the credentials view, so key-pair age is not known.", fix: "Check the user in Snowsight." },
];

export const GUIDE_GRANT_LINES = [
  "GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <audit_role>;",
  "GRANT DATABASE ROLE SNOWFLAKE.ORGANIZATION_BILLING_VIEWER TO ROLE <audit_role>;   -- organization account",
  "GRANT APPLICATION ROLE SNOWFLAKE.TRUST_CENTER_VIEWER TO ROLE <audit_role>;",
  "GRANT APPLICATION ROLE SNOWFLAKE.BUDGET_VIEWER TO ROLE <audit_role>;",
  "GRANT MONITOR ON WAREHOUSE <warehouse> TO ROLE <audit_role>;   -- one per warehouse",
  "GRANT MONITOR EXECUTION ON ACCOUNT TO ROLE <audit_role>;",
  "GRANT APPLY AUTHENTICATION POLICY ON ACCOUNT TO ROLE <audit_role>;",
  "GRANT APPLY PASSWORD POLICY ON ACCOUNT TO ROLE <audit_role>;",
];

export const GUIDE_LINK_KEYS = [
  ["tab, subtab", "The page and sub-tab (for example cost and trend)."],
  ["focus", "A check to open on that page, or a How it works topic."],
  ["view", "The status filter of the checks table: critical, warning, ok, not_assessed or reference."],
  ["domain", "The domain filter of All findings."],
  ["w", "The window in days (7, 30 or 90)."],
  ["ws", "The accounts picked, by account id, comma separated."],
  ["attr_<key>", "An attribute filter, for example a cost-center value."],
  ["tags", "The tag filter (key and values)."],
  ["owner", "The owner filter."],
  ["role", "The lens (finops, cfo and so on)."],
  ["wh", "Warehouse filter: warehouse names, separated by |."],
  ["db", "Database filter: database names, separated by |."],
  ["sch", "Schema filter: DATABASE.SCHEMA, separated by |."],
  ["task", "The task whose panel is open, by full name."],
];

// The body of every topic added for the Snowflake Guide; renderHowBody falls through to this.
export function guideConceptBody(slug: string, app: GuideApp, meta: Meta | null | undefined, findings: GuideCheck[]) {
  switch (slug) {
    case "pricing": {
      const pb = meta && meta.price_basis;
      const d = meta && meta.discount;
      return (
        <div>
          <p>
            Every dollar is credits × an effective price per credit. The label next to a $ says where that
            price came from. Storage is priced the same way, at your $ per TB per month.
          </p>
          <GuideMiniTable
            head={["Label", "Where the price came from"]}
            rows={[
              ["invoice", "Your contract rate from the organization rate sheet (RATE_SHEET_DAILY) or, without it, your effective rate over the last 90 days of the invoice view (USAGE_IN_CURRENCY_DAILY): consumption lines only, with no adjustments or overage."],
              ["cli", "The price given to the export (--credit-price, --ai-credit-price, --storage-price)."],
              ["settings", "credit_price_usd, ai_credit_price_usd or storage_price_usd_tb_month in settings (3.00 per credit and 2.00 per AI credit by default)."],
              ["unpriced", "No price is known. The $ reads \"-\" and the credits are shown; never $0."],
              ["invoice currency", "Charges already in your invoice currency (for example paid Marketplace listings). They are never discounted and never added across currencies."],
            ]}
          />
          <p>
            Credits, AI credits (Cortex AI, Copilot) and storage each have their own price. For each, the
            export takes the first it finds: the export option, then the rate sheet, then the invoice
            rate, then settings. Refresh keeps a price you typed in and reads the invoice again.
            The what-if discount is meant for a list price. A price read from the invoice is already discounted, so the
            discount is then ignored and the page says why; it is never stacked on top.
          </p>
          {pb ? (
            <p>
              <b>This export: </b>{pb.label || pb.source_short || "unpriced"}
              {pb.credit_price_usd != null ? <span>, <span className="mono">{`$${Number(pb.credit_price_usd).toFixed(2)}`}</span> per credit</span> : null}
              {pb.ai_credit_price_usd != null ? <span>, <span className="mono">{`$${Number(pb.ai_credit_price_usd).toFixed(2)}`}</span> per AI credit</span> : null}
              {pb.storage_price_usd_tb_month != null ? <span>, storage <span className="mono">{`$${Number(pb.storage_price_usd_tb_month).toFixed(2)}`}</span> per TB per month{pb.storage_source ? ` (${pb.storage_source})` : ""}</span> : null}
              {d && d.ignored ? `. Discount not applied: ${d.reason}.` : "."}
            </p>
          ) : <p className="muted">…</p>}
        </div>
      );
    }
    case "money-kinds":
      return (
        <div>
          <p>A dollar column always has a kind. A kind is never added to another, and credits are never added to dollars.</p>
          <GuideMiniTable
            head={["Kind", "What it is"]}
            rows={[
              ["spend", "What was billed or estimated for the window: credits × price."],
              ["spend per month", "Storage run-rate per month. Never added to window spend."],
              ["change", "Difference against the period before."],
              ["waste", "Credits billed for nothing, priced. A lower bound, counted on flagged rows."],
              ["saving", "What a change would save over the window (for example a resize). Its own figure."],
              ["saving per month", "What storage work would free each month."],
              ["gap", "The difference between two sources (for example invoice against metered)."],
              ["context", "Shown to orient you and counted elsewhere (for example idle credits that the idle check already prices). Never waste."],
              ["balance", "A contract balance or runway: a stock, not a flow."],
            ]}
          />
          <p>Fix these first shows three groups (priced in the window, storage per month, critical with no $). They are listed side by side and never summed.</p>
          <p>Some figures are marked estimate because they rest on weak signals. <GuideCheckLink id="sf_load_bulk_copy_vs_snowpipe" /> compares the warehouse time of frequent small COPY loads with Snowpipe's credits per GB, with an assumed compression ratio: it is shown on its own and never added to the savings total. <GuideCheckLink id="sf_load_copy_listing_overhead" /> shows no $ at all, because file listing runs in cloud services, which are billed only above the daily 10% allowance.</p>
          <p><GuideCheckLink id="sf_perf_query_shape_regression" /> prices the extra credits of a statement shape that got slower as a change, not waste. <GuideCheckLink id="sf_ai_cortex_search_stale_index_serving" /> shows the serving spend of a search index that stopped taking rows as spend: neither is added to the waste total.</p>
        </div>
      );
    case "screens":
      return (
        <div>
          <ul className="gd-bullets">
            <li>An area opens on its <b>Overview</b>: charts first, then the checks. Tables are for drill-down.</li>
            <li>A tile is a label, a number, one line and a link. It shows "…" while loading and "-" with the reason when its check did not run; never $0.</li>
            <li>An empty result names the window, for example "No data for this in 16–22 Sep 2026". A missing source says which view and how to get access.</li>
            <li>Click a <b>task name</b> to open its panel without leaving the page.</li>
            <li>The arrow <b>↗</b> opens the object in Snowsight. These are best-guess Snowsight paths that may change; a link can land on the parent page.</li>
            <li>A check's table has a <b>CSV</b> download of every matching row; masking applies when it is on.</li>
            <li>Warehouse, database and schema filters narrow the checks that have that column. A check without one says "not filtered by warehouse" and shows all rows.</li>
            <li>Masking is optional and off: user names on screen, and any kind of name in the export (Settings, "Mask in the next Refresh"). A masked name reads as a token such as wh_3f2a9c1b, the same on every page.</li>
            <li>A number is shown as name (id) wherever a name is known.</li>
          </ul>
          <p>Each sub-tab, and the checks on it, has its own page under Tabs on the left.</p>
        </div>
      );
    case "links":
      return (
        <div>
          <p>The address bar is the view. Copy it and the same tab, window, accounts and filters open on another machine.</p>
          <GuideMiniTable head={["Key", "What it holds"]} rows={GUIDE_LINK_KEYS.map(([k, d]) => [k, d])} />
          <p className="muted gd-small">The ↗ links to Snowsight use best-guess paths (warehouse, database, schema, table, task, user, role, query) built from the account's organization and name. They may change, so a link can be wrong. They show only when both names are known.</p>
          <p className="muted gd-small">A name with a comma survives because filter lists use | between names.</p>
        </div>
      );
    case "cloud-services":
      return (
        <div>
          <p>
            Cloud services (metadata, compilation, access control) are billed only for the part above 10% of the day's
            warehouse compute credits. The audit applies that per day before pricing, so a quiet day can bill cloud services
            in full and a busy day none. Credits used can therefore be higher than credits billed, and a dollar figure can
            read lower than the raw credits suggest.
          </p>
          <p>Reader accounts follow the same rule. See <GuideCheckLink id="sf_cost_cloud_services_billed" /> and <GuideCheckLink id="sf_cost_cloud_services_drivers" />.</p>
        </div>
      );
    case "attribution":
      return (
        <div>
          <p>
            Per-query attribution splits a warehouse's credits across the queries that ran. It is not a total. It leaves out
            idle time (the warehouse on with nothing running) and queries under about 100 ms, it lags up to 8 hours, and it is
            empty (NULL) on adaptive warehouses. By-user, by-query and by-tag dollars therefore add up to less than the warehouse bill.
          </p>
          <p>
            Chargeback by warehouse is the total. Idle time is shown as its own line (<GuideCheckLink id="sf_chg_idle_allocation" />),
            and adaptive warehouses are split from a separate view (see Adaptive warehouses).
          </p>
        </div>
      );
    case "latency":
      return (
        <div>
          <GuideMiniTable
            head={["Source", "Lag", "History kept"]}
            rows={[
              ["ACCOUNT_USAGE views", "Minutes to a few hours, per view", "Most keep 365 days; the view's docs page says."],
              ["Query attribution", "Up to 8 hours", "365 days"],
              ["ORGANIZATION_USAGE billing views", "Up to 72 hours", "Per view; see its docs page"],
              ["SHOW commands", "None: the state now", "Current state only"],
            ]}
          />
          <p>
            Today is always partial and is marked so. A lagging view makes the newest days look low, and activity older
            than a view's history is gone. Source freshness shows how far behind each view is. Org checks wait
            three days before judging a day.
          </p>
        </div>
      );
    case "failsafe":
      return (
        <div>
          <p>
            Time Travel (recover after a change) and Fail-safe (seven more days of recovery by Snowflake, permanent tables only)
            keep bytes that are billed as storage. A dropped table keeps billing until both end. Storage is split into active,
            Time Travel, Fail-safe and stage bytes, each at your $ per TB per month.
          </p>
          <ul className="gd-bullets">
            <li>Fail-safe tables have no name in the metrics view, so they can pass as live tables. The audit keeps them apart.</li>
            <li>Both TABLE_ID and BASE_TABLE_ID are read while the rename rolls out.</li>
            <li>Per-month storage figures are never added to the dollars of a window.</li>
          </ul>
          <p>See <GuideCheckLink id="sf_storage_dropped_not_purged" />, <GuideCheckLink id="sf_storage_retention_policy" /> and <GuideCheckLink id="sf_storage_failsafe_on_staging" />.</p>
        </div>
      );
    case "visibility": {
      const ed = meta && meta.edition;
      return (
        <div>
          <p>
            A check that could not run reads "-" and says why. It never reads clean. The causes are: the role cannot see a view,
            the view is not in this account yet, the edition is too low (no grant helps), the statement timed out, or it failed.
            SHOW commands and several views show only what the role can see, so a blind role cannot tell "none" from "hidden".
          </p>
          <h3>Edition</h3>
          <p>
            The edition is read from the organization accounts view when the role can see it, otherwise inferred from features that worked.
            "Enterprise" inferred that way means at least Enterprise. Unknown is never taken as Standard.
            {ed && ed.edition ? <span> This export: <b>{String(ed.edition).replace(/_/g, " ").toLowerCase()}</b>{ed.source === "feature_evidence" ? " (at least)" : ""}.</span> : null}
          </p>
          <h3>Grants that open the sources</h3>
          <pre className="mono gd-small" style={{ whiteSpace: "pre-wrap", overflowX: "auto" }}>{GUIDE_GRANT_LINES.join("\n")}</pre>
          <p className="muted gd-small">Everything the audit reads is read-only. Replace <span className="mono">&lt;audit_role&gt;</span> with your audit role.</p>
          <h3>Reason codes</h3>
          <GuideMiniTable head={["Reason", "Meaning", "Fix"]} rows={GUIDE_NOT_ASSESSED_CODES.map((c) => [c.code, c.d, c.fix])} />
          <p>Coverage &amp; Gaps shows, for warehouses, how many billed ones the role sees ("Role sees 32 of 40 billed warehouses") and the detected edition.</p>
        </div>
      );
    }
    case "pressure":
      return (
        <div>
          <p>
            <GuideCheckLink id="query_warehouse_pressure" /> reads each warehouse two ways. Memory pressure is statements
            that spill to disk: they do not fit, so the lever is a bigger size (scale up). Capacity pressure is statements
            that queue because every cluster is busy: the lever is more clusters (scale out) or a warm cluster.
          </p>
          <GuideMiniTable
            head={["Pressure", "What it means"]}
            rows={[
              ["MEMORY", "Spill time or worst-day spill is over its threshold."],
              ["CAPACITY", "Share of time queued at capacity is over its threshold."],
              ["MEMORY_AND_CAPACITY", "Both."],
              ["NONE", "Neither."],
            ]}
          />
          <GuideMiniTable
            head={["Lever", "What to do"]}
            rows={[
              ["SCALE_UP", "Larger warehouse size: more memory per statement."],
              ["SCALE_OUT", "Raise the maximum clusters: the warehouse already runs at its ceiling."],
              ["KEEP_WARM", "Raise the minimum clusters so one is running when the load arrives."],
              ["SCALE_UP_THEN_OUT / SCALE_UP_THEN_WARM", "Size first, then clusters."],
              ["NONE", "Nothing to change."],
            ]}
          />
          <p>The thresholds are in Settings (config/thresholds.yml). A warehouse the role cannot list reads "not visible to this role", never "deleted".</p>
          <p>Queueing also makes scheduled work late. <GuideCheckLink id="sf_task_start_delay" /> splits each task's late start into the scheduler, the warehouse resume and the queue behind other work.</p>
        </div>
      );
    case "upper-bound":
      return (
        <div>
          <p>
            Neither the backups nor the snapshots usage view has a date, so the figure is what the sets hold now, priced at your
            storage $ per TB. The estimate is an upper bound, so it is labelled "up to". It is a per-month figure and is never added to window spend.
          </p>
          <p>See <GuideCheckLink id="sf_storage_backup_snapshot" />. Snapshots are deprecated; any snapshot set that holds storage is flagged.</p>
        </div>
      );
    case "adaptive":
      return (
        <div>
          <p>
            The per-query attribution views are NULL on adaptive warehouses, so a chargeback by user would show nothing for them.
            <GuideCheckLink id="sf_wh_adaptive_attribution" /> splits each adaptive warehouse's billed spend by user from the query metering view,
            with the remainder as one row named "(not attributed)". The rows add up to the warehouse's billed spend.
          </p>
          <ul className="gd-bullets">
            <li>It is a split of the warehouse number, never a second amount on top of it.</li>
            <li>Credits per hour are not defined for adaptive warehouses, so hour-based checks skip them.</li>
            <li>With no adaptive warehouse it reads "No adaptive warehouses in this window".</li>
          </ul>
        </div>
      );
    case "idle":
      return (
        <div>
          <p>
            <GuideCheckLink id="sf_wh_idle_minutes" /> takes each warehouse's compute credits less the credits Snowflake gives to
            queries: the rest is time it ran with no query. It is possible waste, priced at your $ per credit. Hours newer than
            8 hours and adaptive warehouses are left out, because Snowflake has not split them yet.
          </p>
          <p>
            <GuideCheckLink id="sf_wh_auto_suspend_tuning" /> replays the gaps between each warehouse's queries against its current
            auto-suspend and against 60 s, 2, 5 and 10 minutes. A gap is billed up to the suspend time; a longer gap becomes a resume.
          </p>
          <ul className="gd-bullets">
            <li>Each option's saving is an estimate, capped at what the warehouse billed. It is part of the idle $, so it is never added to it, and options are never added to each other.</li>
            <li>Each resume bills at least 60 s. With a setting of 60 s or more every resume already stays up that long, so the minimum adds nothing; a setting under 60 s is replayed as 60 s.</li>
            <li>Extra resumes are the cost of a shorter setting: a suspend empties the warehouse cache, and the first queries wait for the resume (the p95 time is shown).</li>
            <li>"Keep warm" means at least half of the scanned bytes come from the warehouse cache, at least half of the queries repeat a shape, and the median gap is 5 minutes or less. Then 5 minutes is recommended, not 60 s. The result cache survives a suspend, so it does not count.</li>
            <li>One cluster is assumed, so multi-cluster warehouses are understated.</li>
            <li>"Consider adaptive" shows only when at least two of these hold: 30% or more idle, 10 or more resumes a day, two or more manual resizes, queueing at the maximum clusters. It needs Enterprise edition and a standard warehouse up to 4X-Large.</li>
            <li>The Gen2 hint shows for Gen1 warehouses that spend at least half their run time on delete, update and merge. Gen2 bills 1.35× per hour (1.25× on Azure), so it is a test to run, not a saving. <GuideCheckLink id="sf_wh_gen2_fit" /> lists them with the same rule, and compares credits per query before and after each generation change.</li>
            <li><GuideCheckLink id="sf_wh_keepalive_pollers" /> finds a tiny statement one user repeats sooner than the auto-suspend, so the warehouse never gets to suspend. It replays the gaps with and without those polls; the difference is part of the idle $, never added to it.</li>
            <li><GuideCheckLink id="sf_wh_resume_churn" /> pairs each resume with the next suspend. A run under 60 s still bills 60 s; those top-ups are part of the idle $ too, at the same rate as the auto-suspend options.</li>
            <li><GuideCheckLink id="sf_dt_lag_keeps_warehouse_awake" /> does the same for dynamic tables that refresh sooner than their warehouse's auto-suspend. Target lag is a staleness goal, not an interval, but a short one means frequent refreshes. The refreshes' own run time is work and is left out; the rest is part of the idle $.</li>
          </ul>
        </div>
      );
    case "freshness":
      return (
        <div>
          <p>
            <GuideCheckLink id="sf_cost_source_freshness" /> reads the newest row of each usage view and how far behind it is. Views are
            billing, always-on or activity feeds. A billing or always-on view a day or more behind flags Warn (more behind,
            Critical): the spend of the newest days is then too low. Activity views never read Critical, because no activity is normal.
          </p>
          <p>The lag is against the export's clock. It lives on Coverage &amp; Gaps; its rows never count as waste or fixes.</p>
        </div>
      );
    default:
      return null;
  }
}

// ═══════════════════════════════════ Status legend ═══════════════════════════════════

export const STATUS_MEANING_ROWS = [
  { kind: "critical", word: "Critical", d: "Flagged as the worst kind of problem this check looks for." },
  { kind: "warn", word: "Warning", d: "Flagged, but not the worst kind this check has." },
  { kind: "ok", word: "OK", d: "Ran on real data in this window and found nothing. A verified pass." },
  { kind: "reference", word: "Reference", d: "A list to look things up in, sorted by size only — no pass or fail. Big isn't the same as wrong." },
  { kind: "not_assessed", word: "Not assessed", d: "Did not run in this export: the role can't see a view, the edition is too low, or it failed. Never a pass; the row says why. Shown as \"–\"." },
  { kind: "reference", word: "No data", d: "Ran, but nothing happened in this window, or your Account or tag filters exclude every row. Not a verified zero — the checks table keeps these on its own \"No data\" tab." },
];
export function StatusMeaningsGrid() {
  return (
    <div className="guide2-status-grid">
      {STATUS_MEANING_ROWS.map((r, i) => (
        <div className="guide2-status-row" key={i}>
          <Badge kind={r.kind}>{r.word}</Badge>
          <span>{r.d}</span>
        </div>
      ))}
    </div>
  );
}

export function guideFaqs() {
  return [
    {
      q: "Is this my Snowflake invoice?",
      a: (
        <React.Fragment>
          No. Every dollar is credits &times; your effective price per credit: a price given to the export,
          else your contract rate from the organization rate sheet, else your invoice rate, else the
          default in settings. A what-if discount applies only to a price that is not from your invoice
          or rate sheet. Storage is at your price per TB per month.
          Use it to compare and rank, not to reconcile an invoice line by line.{" "}
          <a {...guideLinkProps("how-money")}>How the dollar figures are worked out &rarr;</a>
        </React.Fragment>
      ),
    },
    {
      q: "Why is a panel empty, or a whole screen \"no data\"?",
      a: (
        <React.Fragment>
          An empty panel means the check ran and found nothing, or the view behind it isn't available
          to this export: never "all clear" by omission.{" "}
          <a {...appTabLinkProps("coverage", "sources")}>Coverage & Gaps &rarr;</a> says which views are missing and what reading them would unlock.
        </React.Fragment>
      ),
    },
    {
      q: "What counts as possible waste, and what doesn't?",
      a: (
        <React.Fragment>
          Idle warehouse time, failed statements, task runs that changed nothing, dynamic tables
          nobody reads, retries, warehouses left oversized and unused AI throughput, each priced at
          your effective price: a lower bound, never a forecast. A resize is a possible saving and
          storage is $ per month; they are separate figures and never added.{" "}
          <a {...guideLinkProps("how-money")}>More on how dollars are worked out &rarr;</a>
        </React.Fragment>
      ),
    },
    {
      q: "Why does a check say \"Not assessed\"?",
      a: "The check did not run in this export: the audit role can't see a view, the edition is too low, or it failed. It is never a verified pass. Open the check's own page, or Coverage & Gaps, for the exact reason.",
    },
    {
      q: "How do I change a threshold, like the 60-second idle rule?",
      a: (
        <React.Fragment>
          Every threshold this app uses lives in <span className="mono">config/thresholds.yml</span>.
          A check's own "Flags when" line shows each value and whether it is still the default
          or has been set there.
        </React.Fragment>
      ),
    },
    {
      q: "Which grants does Snowflake need for the missing views?",
      a: (
        <React.Fragment>
          <a {...appTabLinkProps("coverage", "sources")}>Coverage & Gaps &rarr;</a> lists which view
          each refused source needs, next to that source. Most need IMPORTED PRIVILEGES on the
          SNOWFLAKE database; the README's "Roles and privileges" has the full set.
        </React.Fragment>
      ),
    },
    {
      q: "Why do some numbers differ between screens?",
      a: "Two screens can show different numbers for the same thing when one counts rows and the other counts distinct objects, or when the Account or tag filter applies to one screen but not the other (account-wide Access and Storage checks ignore the Account filter). Each screen states its own basis in its footer.",
    },
  ];
}

export const GUIDE_GLOSSARY = [
  { k: "Credit", d: "The unit Snowflake bills compute in. Dollars = credits × your effective price per credit." },
  { k: "Effective price", d: "Your invoice amount divided by credits, read from the organization billing view where the role can see it. Not the list price." },
  { k: "Cloud services", d: "Metadata and coordination work. The first 10% of daily compute credits is free; only the rest is billed." },
  { k: "Possible waste", d: "Measured idle time and failed work, priced at your effective price. A lower bound, never a forecast." },
  { k: "Window", d: "The days a check covers: the last 7, 30 or 90, up to the export." },
  { k: "Auto-suspend", d: "How long a warehouse waits after its last query before it suspends. Below 60 seconds it restarts more than it saves." },
  { k: "Spill", d: "A query ran out of memory and wrote to local or remote storage, which slows it down." },
  { k: "Price basis", d: "Where the $ per credit came from: invoice, export option, settings or none. Shown next to every $." },
  { k: "Money kind", d: "What a dollar column is: spend, change, waste, saving, gap, context or balance. Kinds are never added." },
  { k: "Upper bound", d: "An \"up to\" figure: what the stored bytes could cost per month, not a measured bill." },
  { k: "Materiality floor", d: "A row under its floor (\"Under $50\") reads OK and is left out of every count." },
  { k: "Time Travel and Fail-safe", d: "Storage Snowflake keeps for recovery after a change or a drop: billed until the retention ends." },
];

// ═══════════════════════════════════ Shared ═══════════════════════════════════

// Every check id a screen shows, in its own sub-tab order -- the same lists the screen reads.
export function tabCheckIds(areaKey: string): string[] {
  if (areaKey === "money") return MONEY_CHECK_IDS.slice();
  if (areaKey === "tags") return [];
  const area: GuideArea | undefined = AREA_REGISTRY[areaKey as AreaKey];
  if (!area) return [];
  if (areaKey === "overview") return OVERVIEW_IDS.slice();
  if (areaKey === "waste") return WASTE_IDS.slice();
  if (areaKey === "actions") return [...new Set(ACTION_TEMPLATES.flatMap((t) => t.checks))];
  const ids: string[] = [];
  const add = (id: string) => { if (!ids.includes(id)) ids.push(id); };
  (area.subtabs || []).forEach((s) => { (s.ids || []).forEach(add); (s.refIds || []).forEach(add); });
  (area.refIds || []).forEach(add);
  return ids;
}

export function shortTable(key: string) { return String(key).replace(/^(ACCOUNT_USAGE|ORGANIZATION_USAGE|DATA_SHARING_USAGE|TRUST_CENTER)\./, ""); }

// Views and commands read by these checks, most used first.
export function tablesFor(ids: string[], guideIndex: GuideIndex): string[] {
  const count: Record<string, number> = {};
  ids.forEach((id) => ((guideIndex[id] && guideIndex[id].reads) || []).forEach((t: string) => {
    count[t] = (count[t] || 0) + 1;
  }));
  return Object.keys(count).sort((a, b) => count[b] - count[a] || a.localeCompare(b));
}

// The schemas those views live in (ACCOUNT_USAGE, ORGANIZATION_USAGE, ...): the grants a reader needs.
export function schemasFor(tables: string[]) {
  return [...new Set(tables.filter((t) => String(t).indexOf(".") > 0 && !/^SHOW /i.test(t)).map((t) => String(t).split(".")[0]))];
}

export function checkRan(s: Finding | null | undefined) { return !!s && String(s.outcome || "").indexOf("ok") === 0; }
export function checkFlagged(s: Finding | null | undefined) {
  if (!s || RANKED_QUERY_IDS.has(s.query_id)) return false;
  const c = s.status_counts || {};
  return (c.CRITICAL || 0) + (c.WARN || 0) > 0;
}

export function tabGuideId(areaKey: string) { return `how-area-${areaKey}`; }

export function TableChips({ tables, max }: { tables: string[]; max?: number }) {
  const shown = max ? tables.slice(0, max) : tables;
  return (
    <span className="gd-tables">
      {shown.map((t) => <code key={t} className="gd-code">{shortTable(t)}</code>)}
      {tables.length > shown.length && <span className="muted">{`+${tables.length - shown.length} more`}</span>}
    </span>
  );
}

// The Guide's own left column on every page but home: topics, tabs, reference.
export function GuideDocsNav({ current, guideIndex, checkArea }: { current: string; guideIndex: GuideIndex; checkArea?: string | null }) {
  const [query, setQuery] = React.useState("");
  const needle = query.trim().toLowerCase();
  const matches = needle
    ? Object.values(guideIndex).filter((f) => {
      const t = getCheckLabel(f.query_id, f.title).title.toLowerCase();
      return t.includes(needle) || f.query_id.includes(needle);
    }).slice(0, 30)
    : null;
  const item = (id: string, label: string, extra?: number | string) => (
    <a key={id} className={`gd-nav-item${current === id ? " active" : ""}`} {...guideLinkProps(id)}>
      {label}{extra != null && <span className="muted">{` · ${extra}`}</span>}
    </a>
  );
  const areaChecks = checkArea ? tabCheckIds(checkArea).filter((id) => guideIndex[id]) : [];
  return (
    <nav className="gd-nav" aria-label="How it works">
      <a className="gd-nav-back" {...guideLinkProps(null)}>&larr; How it works</a>
      <input
        className="gd-nav-search"
        aria-label="Filter checks"
        placeholder={`Filter ${Object.keys(guideIndex).length} checks`}
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      {matches ? (
        <div className="gd-nav-group">
          <div className="gd-nav-h">{`${matches.length} match${matches.length === 1 ? "" : "es"}`}</div>
          {matches.map((f) => item(f.query_id, getCheckLabel(f.query_id, f.title).title))}
        </div>
      ) : (
        <React.Fragment>
          {checkArea && (
            <div className="gd-nav-group">
              <div className="gd-nav-h">{`${AREA_REGISTRY[checkArea as AreaKey].label} · ${areaChecks.length}`}</div>
              {areaChecks.map((id) => item(id, getCheckLabel(id, guideIndex[id].title).title))}
            </div>
          )}
          {!checkArea && (
            <div className="gd-nav-group">
              <div className="gd-nav-h">Start here</div>
              {GUIDE_UNIVERSAL_SECTIONS.map((s) => item(`how-${s.slug}`, s.title))}
            </div>
          )}
          {!checkArea && (
            <div className="gd-nav-group">
              <div className="gd-nav-h">Concepts</div>
              {GUIDE_CONCEPT_SECTIONS.map((s) => item(`how-${s.slug}`, s.title))}
            </div>
          )}
          <div className="gd-nav-group">
            <div className="gd-nav-h">{checkArea ? "Other tabs" : "Tabs"}</div>
            {GUIDE_SCREEN_ORDER.filter((k) => k !== checkArea).map((k) => item(tabGuideId(k), guideArea(k)!.label))}
          </div>
          <div className="gd-nav-group">
            <div className="gd-nav-h">Reference</div>
            {item("how-checks", "Check reference", Object.keys(guideIndex).length)}
            {item("how-troubleshooting", "Troubleshooting")}
            {item("how-glossary", "Glossary")}
          </div>
        </React.Fragment>
      )}
    </nav>
  );
}

interface GuidePageProps {
  current: string;
  guideIndex: GuideIndex;
  checkArea?: string | null;
  rail?: React.ReactNode;
  children?: React.ReactNode;
}

export function GuidePage({ current, guideIndex, checkArea, rail, children }: GuidePageProps) {
  React.useEffect(() => { window.scrollTo(0, 0); }, [current]);
  return (
    <div className={`gd-layout${rail ? " has-rail" : ""}`}>
      <GuideDocsNav current={current} guideIndex={guideIndex} checkArea={checkArea} />
      <main className="gd-main">{children}</main>
      {rail && <aside className="gd-rail">{rail}</aside>}
    </div>
  );
}

export function Crumbs({ items }: { items: { label: string; focus?: string | null }[] }) {
  return (
    <nav className="gd-crumbs" aria-label="Breadcrumb">
      <a {...guideLinkProps(null)}>How it works</a>
      {items.map((it, i) => (
        <React.Fragment key={i}>
          <span className="gd-crumb-sep">/</span>
          {it.focus ? <a {...guideLinkProps(it.focus)}>{it.label}</a> : <span>{it.label}</span>}
        </React.Fragment>
      ))}
    </nav>
  );
}

export function RailCard({ title, children }: { title?: string; children?: React.ReactNode }) {
  return (
    <div className="gd-rail-card">
      {title && <div className="gd-rail-h">{title}</div>}
      {children}
    </div>
  );
}

// ═══════════════════════════════════ Guide home ═══════════════════════════════════

// The picker's own lens names for an area; the CFO lens has its own page, not these areas.
export function lensesForArea(areaKey: string) {
  const roles = ROLES.filter((r) => r !== "cfo" && (ROLE_AREAS[r as keyof typeof ROLE_AREAS] || []).includes(areaKey));
  return roles.length ? roles.map((r) => ROLE_LABEL[r as keyof typeof ROLE_LABEL]).join(", ") : null;
}

export const GUIDE_RULES = [
  "Dollars are credits × your effective price per credit. Not your invoice line by line.",
  "Windows are the last 7, 30 or 90 days up to the export; today is partial.",
  "A check that did not run reads \"-\" and why. Empty never means all clear; only OK is a verified pass.",
];

export const HOME_QUESTIONS = [
  { q: "Why is this panel empty?", focus: "how-troubleshooting" },
  { q: "Why don't two screens agree?", focus: "how-troubleshooting" },
  { q: "Is this my invoice?", focus: "how-money" },
  { q: "Where does the $ price come from?", focus: "how-pricing" },
  { q: "How is idle time counted?", focus: "sf_wh_idle_minutes" },
];

export const SCREEN_ANATOMY = [
  { h: "The headline", d: "is the finding, written from the data. Start there." },
  { h: "Every number has a baseline", d: "— a total or the period before. No baseline, no conclusion." },
  { h: "How is this worked out?", d: "opens the check's page here: the formula and the views behind it." },
  { h: "Status is a word", d: "as well as a colour. See the legend." },
  { h: "The scope note", d: "says which checks the Account filter does not narrow." },
];

export function AnatomyMock() {
  const dot = (n: number) => <span className="gd-anat-dot">{n}</span>;
  return (
    <div className="gd-anat-mock" aria-hidden="true">
      <div className="gd-anat-banner">{dot(5)}<span className="gd-anat-line w40" /></div>
      <div className="gd-anat-head">{dot(1)}<span className="gd-anat-line w80 dark" /></div>
      <div className="gd-anat-cards">
        <div className="gd-anat-card">{dot(2)}<span className="gd-anat-line w40" /><span className="gd-anat-num" /><span className="gd-anat-line w60" /></div>
        <div className="gd-anat-card">{dot(3)}<span className="gd-anat-line w40" /><span className="gd-anat-num" /><span className="gd-anat-line w50" /></div>
      </div>
      <div className="gd-anat-row"><span className="gd-anat-line w50" />{dot(4)}<Badge kind="critical">Critical</Badge></div>
    </div>
  );
}

export function GuideHome({ data, guideIndex, meta }: { data: GuideData; guideIndex: GuideIndex; meta?: Meta | null }) {
  const [query, setQuery] = React.useState("");
  const needle = query.trim().toLowerCase();
  const results = React.useMemo(() => {
    if (!needle) return [];
    return data.findings.filter((f) => guideSearchText(f, getCheckLabel(f.query_id, f.title)).includes(needle));
  }, [needle, data.findings]);
  const allTables = tablesFor(Object.keys(guideIndex), guideIndex);

  return (
    <div className="gd-home">
      <div className="gd-home-top">
        <div className="gd-home-intro">
          <div className="gd-eyebrow-row">
            <span className="gd-eyebrow">{`How it works · ${data.findings.length} checks · ${allTables.length} Snowflake views and commands · ${ranCountsText(meta)}`}</span>
          </div>
          <h1 className="gd-display">How it works</h1>
          <p className="gd-lede">What every tab shows, where its numbers come from, and what to do when they look wrong.</p>
          <p className="muted gd-intro">This app reads your Snowflake usage views and shows what you spend, what is wasted and what is risky, at your price per credit. New here? Start on Overview, then Fix these first. Pick the lens for your role at the top left.</p>
          <label className="guide2-search">
            <svg width="18" height="18" viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true"><circle cx="9" cy="9" r="6"></circle><path d="M13.5 13.5L18 18"></path></svg>
            <input
              type="search"
              aria-label="Search checks and topics"
              placeholder="Type a check, a table or a number you saw"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
          <div className="gd-qchips">
            {HOME_QUESTIONS.map((x) => <a key={x.q} className="gd-qchip" {...guideLinkProps(x.focus)}>{x.q}</a>)}
          </div>
        </div>
        <div className="gd-rules">
          <div className="gd-rules-h">Three rules for every screen</div>
          <ol>{GUIDE_RULES.map((r, i) => <li key={i}><span className="gd-rules-n">{i + 1}</span><span>{r}</span></li>)}</ol>
        </div>
      </div>

      {needle && (
        <Card title={`${results.length} matching check${results.length === 1 ? "" : "s"}`}>
          {results.length === 0 ? (
            <div className="muted">{`No check matches "${query}".`}</div>
          ) : (
            <ul className="guide2-search-results">
              {results.map((f) => {
                const label = getCheckLabel(f.query_id, f.title);
                return (
                  <li key={f.query_id}>
                    <a {...guideLinkProps(f.query_id)}>{label.title}</a>
                    {label.why && <span className="muted">{` — ${label.why}`}</span>}
                  </li>
                );
              })}
            </ul>
          )}
        </Card>
      )}

      <section className="gd-section">
        <div className="gd-section-head"><h2>Every tab at a glance</h2><span className="muted">Open a row for its page: what's on screen, how it's worked out, its checks</span></div>
        <div className="gd-table-wrap">
          <table className="gd-table gd-glance">
            <thead><tr><th>Tab</th><th>What it represents</th><th>How the data gets there</th><th>If it flags something</th><th>Why it can look wrong</th></tr></thead>
            <tbody>
              {GUIDE_SCREEN_ORDER.map((k) => {
                const g = GUIDE_TABS[k];
                const ids = tabCheckIds(k).filter((id) => guideIndex[id]);
                const link = guideLinkProps(tabGuideId(k));
                return (
                  <tr key={k} className="gd-glance-row" onClick={link.onClick}>
                    <td>
                      <a className="gd-glance-name" {...link}>{guideArea(k)!.label}</a>
                      <div className="muted gd-small">{`${g.lens} · ${ids.length} checks`}</div>
                    </td>
                    <td>{g.represents}</td>
                    <td><TableChips tables={tablesFor(ids, guideIndex)} max={4} /></td>
                    <td>{g.flags}</td>
                    <td className="muted">{g.wrong}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>

      <section className="gd-section">
        <div className="gd-section-head"><h2>Concepts</h2><span className="muted">The traps behind the numbers, each with its docs.snowflake.com pages</span></div>
        <div className="gd-home-trio">
          {GUIDE_CONCEPT_SECTIONS.map((s) => (
            <a key={s.slug} className="gd-card gd-link-card" {...guideLinkProps(`how-${s.slug}`)}>
              <span className="gd-link-card-h">{s.title}</span>
              <span className="muted">{s.teaser}</span>
            </a>
          ))}
        </div>
      </section>

      <div className="gd-home-pair">
        <section className="gd-card">
          <h2 className="gd-card-h">Read any screen in 30 seconds</h2>
          <div className="gd-anat">
            <AnatomyMock />
            <ol className="gd-anat-list">
              {SCREEN_ANATOMY.map((a, i) => (
                <li key={i}><span className="gd-anat-dot">{i + 1}</span><span><b>{a.h}</b>{` ${a.d}`}</span></li>
              ))}
            </ol>
          </div>
        </section>
        <section className="gd-card">
          <div className="gd-card-head"><h2 className="gd-card-h">What each status means</h2><span className="muted gd-small">Only OK is a pass</span></div>
          <StatusMeaningsGrid />
          <div className="muted gd-small gd-legend-note">Rows below a materiality floor read OK and are left out of every count.</div>
        </section>
      </div>

      <div className="gd-home-trio">
        <a className="gd-card gd-link-card" {...guideLinkProps("how-troubleshooting")}>
          <span className="gd-eyebrow">Troubleshooting</span>
          <span className="gd-link-card-h">A number looks wrong or a panel is empty</span>
          <span className="muted">Follow the status word to the cause and the fix.</span>
          <span className="gd-card-link">{"Troubleshoot a panel →"}</span>
        </a>
        <a className="gd-card gd-link-card" {...guideLinkProps("how-checks")}>
          <span className="gd-eyebrow">{`Check reference · ${data.findings.length}`}</span>
          <span className="gd-link-card-h">Every check, one page each</span>
          <span className="muted">What it flags, how it's worked out, thresholds, fixes, and when it misreads.</span>
          <span className="gd-card-link">{`Browse all ${data.findings.length} checks →`}</span>
        </a>
        <a className="gd-card gd-link-card" {...guideLinkProps("how-glossary")}>
          <span className="gd-eyebrow">Glossary</span>
          {GUIDE_GLOSSARY.slice(0, 4).map((g) => (
            <span key={g.k} className="gd-gloss-mini"><b>{g.k}</b><span className="muted">{g.d}</span></span>
          ))}
        </a>
      </div>

      {data.app.docs_error && <div className="muted guide2-footnote">{`Documentation links unavailable: ${data.app.docs_error}`}</div>}
    </div>
  );
}

// ═══════════════════════════════════ Topic page ═══════════════════════════════════

export function GuideTopicPage({ slug, data, guideIndex, meta }: { slug: string; data: GuideData; guideIndex: GuideIndex; meta?: Meta | null }) {
  const section = GUIDE_SECTIONS.find((s) => s.slug === slug);
  const isCoverage = slug.indexOf("coverage-") === 0;
  const isConcept = section!.group === "concept";
  const conceptDocs = data.concept_docs || {};
  const exposed = isConcept && slug !== "latency"
    ? data.findings.filter((f) => (f.traps || []).some((tr: any) => (GUIDE_TRAP_PAGE[tr.concept] || tr.concept) === slug))
    : [];
  return (
    <GuidePage current={`how-${slug}`} guideIndex={guideIndex}>
      <Crumbs items={isCoverage ? [{ label: "Tabs" }, { label: AREA_REGISTRY.coverage.label, focus: tabGuideId("coverage") }] : [{ label: isConcept ? "Concepts" : "Start here" }]} />
      <h1 className="gd-title">{section!.title}</h1>
      <p className="gd-lede">{section!.teaser}</p>
      <div className="gd-prose">{renderHowBody(slug, data.app, data.findings, meta)}</div>
      {exposed.length > 0 && (
        <details className="gd-details">
          <summary>{`${exposed.length} checks are exposed to this`}</summary>
          <ul className="gd-bullets">
            {exposed.map((f) => <li key={f.query_id}><a {...guideLinkProps(f.query_id)}>{getCheckLabel(f.query_id, f.title).title}</a></li>)}
          </ul>
        </details>
      )}
      {((TOPIC_DOC_KEYS[slug] || []).some((k) => data.docs && data.docs[k]) || (TOPIC_CONCEPT_KEYS[slug] || []).some((k) => conceptDocs[k])) && (
        <div className="guide2-topic-docs">
          <div className="muted gd-small">On docs.snowflake.com</div>
          {(TOPIC_CONCEPT_KEYS[slug] || []).map((k) => <DocsLink key={k} docsKey={k} docs={conceptDocs} />)}
          {(TOPIC_DOC_KEYS[slug] || []).map((k) => <DocsLink key={k} docsKey={k} docs={data.docs} />)}
        </div>
      )}
    </GuidePage>
  );
}

// ═══════════════════════════════════ Tab page ═══════════════════════════════════

interface GuideTabPageProps {
  areaKey: string;
  data: GuideData;
  guideIndex: GuideIndex;
  findingsById: Record<string, Finding>;
  meta?: Meta | null;
}

/** Test queries per tab: a file in the export kit's verify/ folder, each query recomputing a figure the tab shows. */
export const VERIFY_FILES: Record<string, string> = {
  warehouses: "warehouses.sql", queries: "queries.sql", storage: "storage.sql", tasks: "pipelines.sql", loading: "pipelines.sql",
  overview: "cost.sql", money: "cost.sql", cost: "cost.sql", waste: "cost.sql",
  access: "governance.sql", audit: "governance.sql", pii: "governance.sql", lineage: "governance.sql", sharing: "governance.sql",
  ai: "ai.sql", serverless: "cost.sql",
};

export function GuideTabPage({ areaKey, data, guideIndex, findingsById, meta }: GuideTabPageProps) {
  const area = guideArea(areaKey)!;
  const g = GUIDE_TABS[areaKey];
  const ids = tabCheckIds(areaKey).filter((id) => guideIndex[id]);
  const tables = tablesFor(ids, guideIndex);
  const loaded = Object.keys(findingsById || {}).length > 0;
  const flagged = ids.filter((id) => checkFlagged(findingsById[id])).length;
  const subLabel = (key: string) => ((area.subtabs || []).find((s) => s.key === key) || {}).label || key;
  const accountWide = area.scope && area.scope.indexOf("Account-wide") === 0;
  const refreshed = meta && meta.generated_at ? fmtSnapshotWhen(meta.generated_at) : null;

  const rail = (
    <React.Fragment>
      <RailCard title="On this page">
        {["What this tab answers", "What's on the screen", "How the numbers get here", "Checks on this tab", "When something looks wrong", "Known limitations", ...(VERIFY_FILES[areaKey] ? ["Test it yourself"] : [])].map((h, i) => (
          <a key={h} className="gd-rail-link" href={`#gd-s${i}`} onClick={(e) => { e.preventDefault(); const el = document.getElementById(`gd-s${i}`); if (el) el.scrollIntoView({ behavior: "smooth", block: "start" }); }}>{h}</a>
        ))}
      </RailCard>
      <RailCard title="This build">
        <div className="gd-kv"><span>Checks that ran (whole audit)</span><b className="mono">{ranCountsText(meta)}</b></div>
        <div className="gd-kv"><span>Checks flagged here</span><b className="mono">{loaded ? `${flagged} of ${ids.length} checks` : "…"}</b></div>
        {refreshed && <div className="gd-kv"><span>Refreshed</span><b className="mono">{refreshed}</b></div>}
        <a className="ck-link" {...appTabLinkProps("coverage", "sources")}>Coverage & Gaps &rarr;</a>
      </RailCard>
      {tables.length > 0 && (
        <RailCard title="Access needed">
          <div className="muted gd-small">Read access to the schemas</div>
          <TableChips tables={schemasFor(tables)} />
        </RailCard>
      )}
      <a className="gd-open-btn" {...appTabLinkProps(areaKey, null)}>{`Open ${area.label} →`}</a>
    </React.Fragment>
  );

  return (
    <GuidePage current={tabGuideId(areaKey)} guideIndex={guideIndex} rail={rail}>
      <Crumbs items={[{ label: "Tabs" }, { label: area.label }]} />
      <h1 className="gd-title">{area.label}</h1>
      <p className="gd-lede">{g.lede}</p>
      <div className="gd-chips">
        <span className="gd-chip">{`In lenses: ${lensesForArea(areaKey) || g.lens}`}</span>
        <span className="gd-chip">{`${ids.length} checks`}</span>
        <span className="gd-chip">Window: 7 / 30 / 90 days</span>
        {accountWide && <span className="gd-chip warn">Whole account</span>}
      </div>

      <h2 className="gd-h2" id="gd-s0">What this tab answers</h2>
      <div className="gd-qgrid">
        {g.questions.map((q, i) => (
          <div key={i} className="gd-card gd-q"><span className="gd-eyebrow">{`Q${i + 1}`}</span><span>{q}</span></div>
        ))}
      </div>

      <h2 className="gd-h2" id="gd-s1">What's on the screen</h2>
      <ol className="gd-numlist">
        {g.screen.map((s, i) => (
          <li key={i}>
            <span className="gd-num">{i + 1}</span>
            <span>
              {s.sub
                ? <a className="gd-strong-link" {...appTabLinkProps(areaKey, s.sub)}>{subLabel(s.sub)}</a>
                : <b>{s.t}</b>}
              {` — ${s.d}`}
            </span>
          </li>
        ))}
      </ol>

      <h2 className="gd-h2" id="gd-s2">How the numbers get here</h2>
      <p className="gd-prose muted">Every figure is the output of a check: a read-only SQL query run with your own credentials against Snowflake's account views. Only the result rows are stored, never the query text.</p>
      <div className="gd-flow">
        <div className="gd-card gd-flow-step"><span className="gd-eyebrow">1 · Read</span><b>Snowflake views</b>{tables.length > 0 ? <TableChips tables={tables} max={8} /> : <span className="muted">No view of its own.</span>}</div>
        <span className="gd-flow-arrow" aria-hidden="true">&rarr;</span>
        <div className="gd-card gd-flow-step"><span className="gd-eyebrow">2 · Measure</span><span>{g.measure}</span></div>
        <span className="gd-flow-arrow" aria-hidden="true">&rarr;</span>
        <div className="gd-card gd-flow-step"><span className="gd-eyebrow">3 · Judge</span><span>{codeifyProse(g.judge)}</span></div>
        <span className="gd-flow-arrow" aria-hidden="true">&rarr;</span>
        <div className="gd-card gd-flow-step"><span className="gd-eyebrow">4 · Price</span><span>{g.price}</span></div>
      </div>

      <div className="gd-section-head" id="gd-s3"><h2 className="gd-h2">Checks on this tab</h2><span className="muted">{`${ids.length} checks`}</span></div>
      {ids.length > 0 && <p className="muted gd-small">Each check's page ends with the SQL it runs, to paste into a Snowflake worksheet.</p>}
      {ids.length === 0 ? (
        <p className="muted">
          {areaKey === "tags" ? "This page shows tag compliance, not a check. The tag checks live on Cost: " : "This page has no checks of its own; it rolls up the others."}
          {areaKey === "tags" && GUIDE_TAGS_CHECK_IDS.filter((id) => guideIndex[id]).map((id, i) => (
            <React.Fragment key={id}>{i > 0 && ", "}<GuideCheckLink id={id} /></React.Fragment>
          ))}
        </p>
      ) : (
        <div className="gd-table-wrap">
          <table className="gd-table">
            <thead><tr><th>Check</th><th>Flags when</th><th>Money</th><th>This build</th></tr></thead>
            <tbody>
              {ids.map((id) => {
                const f = guideIndex[id];
                const s = findingsById[id];
                const money = f.money && f.money.column;
                return (
                  <tr key={id}>
                    <td>
                      <a {...guideLinkProps(id)}>{getCheckLabel(id, f.title).title}</a>
                      <div className="mono muted gd-small">{id}</div>
                    </td>
                    <td className="gd-small">{f.is_finding ? codeifyProse(cleanFlagPrefix(f.investigate_if || "")) || "—" : <span className="muted">Reference list, no pass or fail.</span>}</td>
                    <td>{money ? <span className={`gd-chip ${isPricedWaste(id) ? "ok" : ""}`}>{isPricedWaste(id) ? "In Waste" : "Priced"}</span> : <span className="muted">--</span>}</td>
                    <td className="gd-small">{!s ? <span className="muted">—</span> : checkFlagged(s) ? <span className="gd-flag">Flagged</span> : checkRan(s) ? <span className="muted">Ran</span> : <span className="muted">Not assessed</span>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <h2 className="gd-h2" id="gd-s4">When something looks wrong</h2>
      <div className="gd-table-wrap">
        <table className="gd-table">
          <thead><tr><th>You see</th><th>Why it happens</th><th>What to do</th></tr></thead>
          <tbody>
            {g.troubles.map((t, i) => <tr key={i}><td><b>{t.see}</b></td><td>{t.why}</td><td>{t.doit}</td></tr>)}
          </tbody>
        </table>
      </div>

      <h2 className="gd-h2" id="gd-s5">Known limitations</h2>
      <ul className="gd-bullets">
        {g.limits.map((l, i) => <li key={i}>{l}</li>)}
        {accountWide && <li>Some of these checks cover the whole account; the Account filter doesn't change those.</li>}
      </ul>

      {VERIFY_FILES[areaKey] && (
        <>
          <h2 className="gd-h2" id="gd-s6">Test it yourself</h2>
          <p>{"Open "}<code>{`verify/${VERIFY_FILES[areaKey]}`}</code>{" in the export kit and paste one query at a time into a Snowflake worksheet. Each one recomputes a figure on this tab straight from ACCOUNT_USAGE, read-only; set the window and your $ per credit at its top, then compare."}</p>
        </>
      )}
    </GuidePage>
  );
}

// ═══════════════════════════════════ Troubleshooting ═══════════════════════════════════

export const STATUS_PATHS = [
  {
    badge: "not_assessed", word: "Not assessed", d: "The check didn't run. Never a pass.",
    causes: [
      { h: "The role can't see the view", d: "The row names the view it couldn't read.", doit: "Grant IMPORTED PRIVILEGES on the SNOWFLAKE database (below)." },
      { h: "Not in this account", d: "The view needs a higher edition, or an organization account.", doit: "Read the reason on Coverage & Gaps; some checks need Enterprise edition." },
      { h: "Not in this export", d: "The check is newer than the export, or it failed.", doit: "Run the export again." },
      { h: "Timed out", d: "A statement hit the export's 15-minute limit; the export moved on.", doit: "Export again with a higher --statement-timeout, or fewer days." },
    ],
  },
  {
    badge: "reference", word: "No data", d: "It ran and saw nothing. Not a verified zero.",
    causes: [
      { h: "Nothing happened in the window", d: "No runs, queries or events of that kind.", doit: "Widen to 90 days to confirm." },
      { h: "No data (filtered)", d: "Rows exist, but your Account or tag filters exclude them.", doit: "Clear the filters." },
    ],
  },
  {
    badge: "critical", word: "A number", d: "It has a value you don't believe.",
    steps: [
      "Press How is this worked out? next to it to see the formula and the views it reads.",
      "Read the scope note: some checks ignore the Account filter.",
      "If another screen shows a different figure, use the table below.",
    ],
  },
];

export const SCREENS_DIFFER = [
  { r: "Different window", ex: "Monthly bars use calendar months; the cards use the last 7, 30 or 90 full days.", fix: "Compare like for like." },
  { r: "Filter doesn't apply", ex: "Grants, users, policies and storage checks cover the whole account; picking an account doesn't narrow them.", fix: "Read the tab's scope note." },
  { r: "Different attribution level", ex: "Spend follows the most specific tag. A per-query view adds up to less than the warehouse bill: idle time and statements under about 100 ms are not attributed.", fix: "Use the level that matches the question." },
  { r: "Priced vs counted", ex: "Possible waste sums only priced rows; unpriced findings are counted, not added. Waste, saving and storage are separate figures.", fix: "Read the three separately." },
  { r: "Ranked vs judged", ex: "A spend ranking never reads Critical; checks judge against a rule.", fix: "Open the check for the rule." },
  { r: "Data lag", ex: "Account views lag up to a few hours, query attribution up to 8 hours and the organization billing views up to 72 hours. Today is partial.", fix: "Compare full days." },
  { r: "Different price basis", ex: "One figure is priced from your invoice, another from a price given to the export or set in Settings. The label next to the $ names which.", fix: "Read the label; see Price basis." },
  { r: "Different money kind", ex: "Spend, change, waste, saving and storage per month are different things, so they are listed apart and never added.", fix: "Compare the same kind." },
  { r: "Fallback source", ex: "Without ACCOUNT_USAGE, five checks read INFORMATION_SCHEMA: 7 days of history and only what the role can see.", fix: "Read the note under the sub-tabs; grant ACCOUNT_USAGE for the full window." },
  { r: "Cloud services", ex: "Cloud services are priced after the 10% daily adjustment, so they can read lower than their credits suggest.", fix: "See Cost › By service." },
];

export const GRANT_SCHEMAS = [
  { s: "SNOWFLAKE.ACCOUNT_USAGE", d: "Metering, queries, tasks, storage, grants, logins: needs IMPORTED PRIVILEGES on the SNOWFLAKE database" },
  { s: "SNOWFLAKE.ORGANIZATION_USAGE", d: "Spend by account, invoices, contracts: needs a role in the organization account" },
  { s: "SNOWFLAKE.DATA_SHARING_USAGE", d: "Listings and shares" },
  { s: "SNOWFLAKE.TRUST_CENTER", d: "Trust Center findings: needs the TRUST_CENTER_VIEWER application role" },
  { s: "SNOWFLAKE.BUDGET_VIEWER", d: "Budgets: needs the BUDGET_VIEWER application role" },
  { s: "APPLY PASSWORD / AUTHENTICATION POLICY", d: "SHOW PASSWORD POLICIES and SHOW AUTHENTICATION POLICIES need it on the account" },
  { s: "MONITOR on warehouses", d: "SHOW WAREHOUSES lists only warehouses the role can see" },
  { s: "MONITOR EXECUTION", d: "SHOW TASKS and SHOW PIPES list only what the role can monitor" },
  { s: "MONITOR USAGE", d: "Account-level usage and billing in the metering views" },
];

export function GuideTroubleshooting({ guideIndex }: { guideIndex: GuideIndex }) {
  const faqs = guideFaqs().filter((x) => !/differ between screens|Not assessed/.test(x.q));
  return (
    <GuidePage current="how-troubleshooting" guideIndex={guideIndex}>
      <Crumbs items={[{ label: "Troubleshooting" }]} />
      <h1 className="gd-title">A panel is empty, or a number looks wrong</h1>
      <p className="gd-lede">Start with the status word on the panel. It tells you whether the audit couldn't look, looked and found nothing, or found something you don't expect.</p>

      <h2 className="gd-h2">Follow the status word</h2>
      <div className="gd-path">
        <div className="gd-path-start">
          <span className="gd-eyebrow">Start</span>
          <span className="gd-path-q">What does the panel say?</span>
          <span className="gd-small">The word is in the panel header or the row's status pill.</span>
        </div>
        <div className="gd-path-branches">
          {STATUS_PATHS.map((p) => (
            <div key={p.word} className="gd-card gd-path-branch">
              <div className="gd-path-word">
                <Badge kind={p.badge}>{p.word}</Badge>
                <span className="gd-small">{p.d}</span>
              </div>
              {p.causes ? (
                <div className="gd-path-causes">
                  {p.causes.map((c) => (
                    <div key={c.h} className="gd-path-cause">
                      <b>{c.h}</b>
                      <span className="muted gd-small">{c.d}</span>
                      <span className="gd-small"><b>Do: </b>{c.doit}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <ol className="gd-path-steps">{p.steps.map((s, i) => <li key={i}>{s}</li>)}</ol>
              )}
            </div>
          ))}
        </div>
      </div>

      <h2 className="gd-h2">Why two screens can show different numbers</h2>
      <div className="gd-table-wrap">
        <table className="gd-table">
          <thead><tr><th>Reason</th><th>Example</th><th>How to line them up</th></tr></thead>
          <tbody>{SCREENS_DIFFER.map((x) => <tr key={x.r}><td><b>{x.r}</b></td><td>{x.ex}</td><td>{x.fix}</td></tr>)}</tbody>
        </table>
      </div>

      <div className="gd-faq-grid">
        {faqs.map((x) => (
          <div key={x.q} className="gd-card gd-faq">
            <h3>{x.q}</h3>
            <div className="muted">{x.a}</div>
          </div>
        ))}
      </div>

      <div className="gd-card gd-grants">
        <div>
          <h2 className="gd-h2 flush">Access for missing views</h2>
          <p className="muted">An account admin grants the audit role read access once (README, "Roles and privileges"). Everything is read-only. <a {...guideLinkProps("how-visibility")}>Editions, visibility and reason codes</a></p>
        </div>
        <div className="gd-grants-grid">
          {GRANT_SCHEMAS.map((x) => <div key={x.s}><code className="gd-code">{x.s}</code><div className="gd-small">{x.d}</div></div>)}
        </div>
      </div>
    </GuidePage>
  );
}

// ═══════════════════════════════════ Glossary and check reference ═══════════════════════════════════

export function GuideGlossaryPage({ guideIndex }: { guideIndex: GuideIndex }) {
  return (
    <GuidePage current="how-glossary" guideIndex={guideIndex}>
      <Crumbs items={[{ label: "Glossary" }]} />
      <h1 className="gd-title">Glossary</h1>
      <div className="gd-card">
        {GUIDE_GLOSSARY.map((g) => (
          <div className="guide2-glossary-row" key={g.k}>
            <div className="guide2-glossary-k">{g.k}</div>
            <div className="muted">{g.d}</div>
          </div>
        ))}
      </div>
    </GuidePage>
  );
}

export function GuideCheckReference({ guideIndex, findingsById }: { guideIndex: GuideIndex; findingsById: Record<string, Finding> }) {
  const placed = new Set<string>();
  const groups = GUIDE_SCREEN_ORDER.filter((k) => k !== "actions" && k !== "waste" && k !== "money").map((k) => {
    const ids = tabCheckIds(k).filter((id) => guideIndex[id] && !placed.has(id));
    ids.forEach((id) => placed.add(id));
    return { key: k, label: guideArea(k)!.label, ids };
  });
  const rest = Object.keys(guideIndex).filter((id) => !placed.has(id)).sort();
  if (rest.length) groups.push({ key: "other", label: "Not on a screen", ids: rest });
  return (
    <GuidePage current="how-checks" guideIndex={guideIndex}>
      <Crumbs items={[{ label: "Check reference" }]} />
      <h1 className="gd-title">Check reference</h1>
      <p className="gd-lede">{`All ${Object.keys(guideIndex).length} checks by the tab they live on, with the views each reads.`}</p>
      {groups.filter((gr) => gr.ids.length).map((gr) => (
        <section key={gr.key} className="gd-section">
          <div className="gd-section-head">
            <h2 className="gd-h2 flush">{gr.label}</h2>
            <span className="muted">{`${gr.ids.length} checks`}</span>
          </div>
          <div className="gd-table-wrap">
            <table className="gd-table">
              <tbody>
                {gr.ids.map((id) => {
                  const f = guideIndex[id];
                  const s = findingsById[id];
                  return (
                    <tr key={id}>
                      <td className="gd-ref-name"><a {...guideLinkProps(id)}>{getCheckLabel(id, f.title).title}</a><div className="mono muted gd-small">{id}</div></td>
                      <td><TableChips tables={f.reads || []} max={4} /></td>
                      <td className="gd-small">{!s ? "" : checkFlagged(s) ? <span className="gd-flag">Flagged</span> : checkRan(s) ? <span className="muted">Ran</span> : <span className="muted">Not assessed</span>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      ))}
    </GuidePage>
  );
}

// ═══════════════════════════════════ Check page ═══════════════════════════════════

// grainText -- summary_line()'s "Each row is ..." sentence (app/api/guide.py), with that lead-in
// dropped, so the article can show it as a labelled "Grain: ..." line instead of a repeated clause.
export function grainText(summary: string | null | undefined) {
  if (!summary) return null;
  return String(summary).replace(/^Each row is\s*/, "").replace(/\.\s*$/, "");
}

// The check's own read-only SQL (GET /api/guide/sql/{id}), fetched only when the reader opens it.
export function GuideSqlViewer({ queryId }: { queryId: string }) {
  const [open, setOpen] = React.useState(false);
  const [st, setSt] = React.useState<{ phase: string; sql: string; error: string | null }>({ phase: "idle", sql: "", error: null });
  const [copied, setCopied] = React.useState(false);
  React.useEffect(() => {
    if (!open || st.phase !== "idle") return;
    setSt({ phase: "loading", sql: "", error: null });
    Api.guideSql(queryId)
      .then((d) => setSt({ phase: "ready", sql: [...(d.pre || []), d.sql].map((s) => `${String(s).trim()};`).join("\n\n"), error: null }))
      .catch((e) => setSt({ phase: "error", sql: "", error: e.message || String(e) }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  const copy = () => {
    const done = () => { setCopied(true); setTimeout(() => setCopied(false), 1200); };
    const clip = window.navigator && window.navigator.clipboard;
    if (clip && clip.writeText) { clip.writeText(st.sql).then(done).catch(() => { try { fallbackCopyText(st.sql); done(); } catch (e) { /* nothing more to try */ } }); return; }
    try { fallbackCopyText(st.sql); done(); } catch (e) { /* nothing more to try */ }
  };
  return (
    <details className="gd-details" onToggle={(e) => setOpen(e.currentTarget.open)}>
      <summary>The SQL this check runs</summary>
      {st.phase === "loading" && <p className="muted">…</p>}
      {st.phase === "error" && <p className="muted gd-small">{`The SQL is not available: ${st.error}`}</p>}
      {st.phase === "ready" && (
        <div>
          <p className="muted gd-small">The audit's own read-only statement with the values in effect filled in. It holds no customer query text.</p>
          <button type="button" className="ck-link" onClick={copy}>{copied ? "Copied" : "Copy SQL"}</button>
          <pre className="mono gd-small" style={{ whiteSpace: "pre-wrap", overflow: "auto", maxHeight: 420 }}>{st.sql}</pre>
        </div>
      )}
    </details>
  );
}

// The reviewer block (query origin, corrections) is for the hands-on lenses only.
let _guideRole: string | null = null;
export function showReviewerBlock() { return !_guideRole || _guideRole === "finops" || _guideRole === "data_engineer"; }

export function ReviewerDetails({ f }: { f: GuideCheck }) {
  const [openKey, setOpenKey] = React.useState<string | null>(null);
  const rows: { key: string; label: string; summary: string; body: React.ReactNode }[] = [
    { key: "confidence", label: "Confidence", summary: f.confidence === "needs_confirmation" ? "Needs confirmation" : "Confirmed", body: codeifyProse(f.confidence_note) },
  ];
  if (f.library_corrections && f.library_corrections.length > 0) {
    rows.push({
      key: "issues", label: "Known issues", summary: `${f.library_corrections.length}`, body: (
        <div>
          {f.library_corrections.map((c: any) => (
            <div key={c.id} className="guide2-issue">
              <Badge kind={c.status === "fixed" ? "ok" : "warn"}>{c.status === "fixed" ? "Corrected" : "Open"}</Badge>
              <div><b>Problem: </b>{c.problem}</div>
              <div><b>Effect: </b>{c.effect}</div>
              <div><b>{c.status === "fixed" ? "Fix: " : "Fix or plan: "}</b>{c.fix}</div>
            </div>
          ))}
        </div>
      ),
    });
  }
  rows.push({ key: "query", label: "Query", summary: `${f.query_id} · ${f.origin || "unknown origin"}${f.library_corrections && f.library_corrections.length ? "" : " · no known issues"}`, body: null });

  return (
    <section className="guide2-sec">
      <div className="card guide2-reviewer">
        <div className="muted guide2-reviewer-head">For reviewers and admins</div>
        {rows.map((r) => {
          const open = openKey === r.key;
          return (
            <div className="guide2-reviewer-row" key={r.key}>
              <button type="button" className="guide2-reviewer-toggle" onClick={() => setOpenKey(open ? null : r.key)} aria-expanded={open}>
                <span className="caret">{open ? "▾" : "▸"}</span>
                <span className="guide2-reviewer-label">{r.label}</span>
                <span className="muted guide2-reviewer-summary">{r.summary}</span>
              </button>
              {open && r.body && <div className="guide2-reviewer-body">{r.body}</div>}
            </div>
          );
        })}
      </div>
    </section>
  );
}

// One live row from the current build: the worst flagged row, or the first row of a list.
export function ExampleRow({ f, filters }: { f: GuideCheck; filters: Filters }) {
  const dims = useDims();
  const statuses = f.is_finding ? ["CRITICAL", "WARN"] : undefined;
  const st = useFindingData(f.query_id, filters.window, filters.accountIds, 1, statuses);
  if (st.phase === "loading") return <p className="muted">Loading a row...</p>;
  const rows = (st.data && st.data.rows) || [];
  if (st.phase !== "ready" || rows.length === 0) {
    return <p className="muted">{f.is_finding ? "No flagged row in this export for the current filters." : "No row in this export for the current filters."}</p>;
  }
  const d = st.data!;
  const row = rows[0];
  const plan = planColumns(d.columns, rows, d.discount_pct, d.order_by);
  const byName = (n: string) => plan.visible.find((c) => c.name === n);
  const cells: any[] = [];
  const add = (c: any) => { if (c && cells.length < 5 && !cells.some((x) => x.name === c.name)) cells.push(c); };
  const entity = plan.entity ? byName(plan.entityDisplayCol || plan.entity) || byName(plan.entity) : null;
  add(entity);
  add(plan.keyMetric);
  plan.visible.filter((c) => c.numeric && c.name !== "status").forEach((c) => { if (cells.length < 4) add(c); });
  const status = row.status;
  const cellText = (c: any) => {
    if (entity && c.name === entity.name && plan.entity) return rowLabelOf(row, plan.entity, dims as Dims) || String(row[c.name]);
    return fmtCell(row[c.name], c.kind, row);
  };
  return (
    <div className="gd-card gd-example">
      {cells.map((c) => (
        <div key={c.name} className="gd-example-cell">
          <span className="muted gd-small">{c.label}{c.unit ? ` (${c.unit})` : ""}</span>
          <span className={`mono gd-example-v${c.kind === "money" && status && status !== "OK" ? " tone-crit" : ""}`}>{cellText(c)}</span>
          {entity && c.name === entity.name && acctId(row) != null && plan.entity !== ACCOUNT_COLUMN && (
            <span className="muted gd-small">{acctPhrase(acctId(row))}</span>
          )}
        </div>
      ))}
      {status && (
        <div className="gd-example-cell">
          <span className="muted gd-small">Status</span>
          <Badge kind={String(status).toLowerCase()}>{status === "WARN" ? "Warning" : status === "CRITICAL" ? "Critical" : status === "OK" ? "OK" : status}</Badge>
        </div>
      )}
    </div>
  );
}

interface CheckRailProps {
  f: GuideCheck;
  data: GuideData;
  home: GuideHomeRef;
  area: GuideArea | null;
  findingsById: Record<string, Finding>;
}

export function CheckRail({ f, data, home, area, findingsById }: CheckRailProps) {
  const s = findingsById[f.query_id];
  const moneyCol = f.money && f.money.column;
  const subLabel = area && home.subtab ? ((area.subtabs.find((x) => x.key === home.subtab) || {}).label) : null;
  const params = f.params.filter((p: any) => p.name !== "period_days" && p.name !== "top_n");
  const reads = (f.reads || []);
  const related = (f.next || []).filter((n: any) => n.title);
  let buildLine = "Not in this export";
  if (s && checkRan(s)) {
    const a = s.affected || {};
    if (f.is_finding && a.total != null) buildLine = `${fmtInt(a.flagged || 0)} of ${fmtInt(a.total)} ${a.noun || "rows"} flagged`;
    else buildLine = s.row_count != null ? `${fmtInt(s.row_count)} rows` : "Ran";
  } else if (s) {
    buildLine = "Not assessed";
  }
  return (
    <React.Fragment>
      <RailCard title="At a glance">
        <div className="gd-rail-field">
          <span className="muted">Appears on</span>
          {area ? <a {...openInAppLinkProps(f)}>{subLabel ? `${area.label} › ${subLabel}` : area.label}</a> : <span>All findings</span>}
        </div>
        {moneyCol && <div className="gd-rail-field"><span className="muted">Money column</span><code className="gd-code">{moneyCol}</code></div>}
        {params.map((p: any) => (
          <div key={p.name} className="gd-rail-field">
            <span className="muted">{p.meaning || p.name}</span>
            <span><span className="mono">{String(p.value)}</span> <span className="muted gd-small">{p.source === "default" ? "default" : "config/thresholds.yml"}</span></span>
          </div>
        ))}
        <div className="gd-rail-field"><span className="muted">This build</span><span className="mono">{buildLine}</span></div>
      </RailCard>
      {reads.length > 0 && (
        <RailCard title="Reads">
          <div className="gd-rail-reads">
            {reads.map((key: string) => {
              const entry = data.docs && data.docs[key];
              return entry && entry.url
                ? <a key={key} className="gd-code" href={entry.url} target="_blank" rel="noreferrer" title={entry.title || ""}>{key}</a>
                : <code key={key} className="gd-code">{key}</code>;
            })}
          </div>
          <div className="muted gd-small">If one can't be read, this check reads Not assessed, never OK.</div>
          {f.learn_url && <div className="gd-small"><a href={f.learn_url} target="_blank" rel="noreferrer">docs.snowflake.com</a></div>}
        </RailCard>
      )}
      {related.length > 0 && (
        <RailCard title="Related checks">
          {related.map((n: any) => <a key={n.query_id} className="gd-rail-link" title={desnakeProse(n.if) || ""} {...guideLinkProps(n.query_id)}>{n.title}</a>)}
        </RailCard>
      )}
      <a className="gd-open-btn" {...openInAppLinkProps(f)}>Open in the app &rarr;</a>
    </React.Fragment>
  );
}

interface GuideArticleProps {
  f: GuideCheck;
  data: GuideData;
  filters: Filters;
  home: GuideHomeRef;
  area: GuideArea | null;
}

export function GuideArticle({ f, data, filters, home, area }: GuideArticleProps) {
  const label = getCheckLabel(f.query_id, f.title);
  const summary = label.why || f.summary;
  const subLabel = area && home.subtab ? ((area.subtabs.find((s) => s.key === home.subtab) || {}).label) : null;
  const moneyCol = f.money && f.money.column;
  const isWaste = isPricedWaste(f.query_id);
  const wasteItem = WASTE_ITEMS.find((w) => w.id === f.query_id);
  const windowChip = f.period_kind === "days" ? "Window check" : f.period_kind === "fixed" ? "Own period" : "Snapshot";
  const [copied, setCopied] = React.useState(false);

  const grain = grainText(f.summary);
  const readRest = splitSentences(f.read_this).slice(1).join(" ");
  const steps: { h: string; t: React.ReactNode }[] = [];
  if (grain) steps.push({ h: "Each row", t: `is ${grain}.` });
  if (readRest) steps.push({ h: "Reading it.", t: codeifyProse(readRest) });
  if (f.is_finding && f.investigate_if) steps.push({ h: "Flags when", t: codeifyProse(cleanFlagPrefix(f.investigate_if)) });
  if (f.is_finding && f.healthy) steps.push({ h: "Reads OK when", t: codeifyProse(cleanFlagPrefix(f.healthy)) });
  if (moneyCol) {
    steps.push({
      h: "Dollars.",
      t: wasteItem ? wasteItem.why : "Credits in the window × your effective $ per credit; the label next to the $ says which price. Not your invoice line by line.",
    });
  }
  if (f.period_kind === "days") steps.push({ h: "Window.", t: `The last ${filters.window} days, up to the export.` });

  const rungs: { tier: ReturnType<typeof rungTier>; text: ReturnType<typeof codeifyProse> }[] = (f.actions || [])
    .map((a: any) => String(a).trim())
    .filter((a: string) => a && !a.toLowerCase().startsWith("n/a"))
    .map((a: string) => ({ tier: rungTier(a), text: codeifyProse(rungText(a)) }));
  const caveats = splitSentences(f.caveats);
  const offCards: { h: string | null; t?: React.ReactNode; list?: string[] }[] = [
    ...caveats.map((c) => ({ h: null, t: codeifyProse(c) })),
    ...(f.not_assessed_reasons.length ? [{ h: "Not assessed when", list: f.not_assessed_reasons }] : []),
    ...(f.empty_if_words.length ? [{ h: "No data when", list: f.empty_if_words }] : []),
  ];

  return (
    <article className="gd-article">
      <Crumbs items={[
        area ? { label: area.label, focus: GUIDE_TABS[home.tab] ? tabGuideId(home.tab) : null } : { label: "All findings" },
        ...(subLabel ? [{ label: subLabel }] : []),
      ]} />
      <div className="gd-title-row">
        <h1 className="gd-title">{label.title}</h1>
        <button type="button" className="ck-link" onClick={() => copyGuideLink(f.query_id, () => { setCopied(true); setTimeout(() => setCopied(false), 1200); })}>
          {copied ? "Copied" : "Copy link"}
        </button>
      </div>
      <div className="gd-chips">
        <code className="gd-code">{f.query_id}</code>
        {isWaste && <span className="gd-chip warn">Possible waste</span>}
        {moneyCol && <span className="gd-chip ok">Priced</span>}
        {!f.is_finding && <span className="gd-chip">Reference list</span>}
        <span className="gd-chip">{windowChip}</span>
        {rungs[0] && rungs[0].tier && <span className="gd-chip">{`Fix: ${rungs[0].tier}`}</span>}
      </div>
      {summary && <p className="gd-lede">{summary}</p>}

      {steps.length > 0 && (
        <React.Fragment>
          <h2 className="gd-h2">How it's worked out</h2>
          <ol className="gd-steps">
            {steps.map((s, i) => (
              <li key={i}><span className="gd-step-n mono">{String(i + 1).padStart(2, "0")}</span><span><b>{s.h}</b> {s.t}</span></li>
            ))}
          </ol>
          <p className="muted gd-small"><a {...guideLinkProps("how-money")}>How every dollar figure is worked out &rarr;</a></p>
        </React.Fragment>
      )}

      <h2 className="gd-h2">{f.is_finding ? "A flagged row from this export" : "A row from this export"}</h2>
      <ExampleRow f={f} filters={filters} />

      {rungs.length > 0 && (
        <React.Fragment>
          <h2 className="gd-h2">What to do</h2>
          <div className="gd-todo">
            {rungs.map((r, i) => (
              <div key={i} className="gd-card gd-todo-card">
                <span className={`gd-chip ${r.tier === "free" ? "ok" : r.tier === "spend" ? "warn" : ""}`}>{r.tier ? `${i + 1} · ${r.tier}` : `Step ${i + 1}`}</span>
                <span>{r.text}</span>
              </div>
            ))}
          </div>
        </React.Fragment>
      )}

      {offCards.length > 0 && (
        <React.Fragment>
          <h2 className="gd-h2">Why the number could be off</h2>
          <div className="gd-off">
            {offCards.map((c, i) => (
              <div key={i} className="gd-card gd-off-card">
                {c.h && <b>{c.h}</b>}
                {c.list ? <ul>{c.list.map((x: string, j: number) => <li key={j}>{codeifyProse(x)}</li>)}</ul> : <span>{c.t}</span>}
              </div>
            ))}
          </div>
        </React.Fragment>
      )}

      {(f.traps || []).length > 0 && (
        <React.Fragment>
          <h2 className="gd-h2">Traps to know</h2>
          <div className="gd-off">
            {f.traps.map((tr: any) => (
              <div key={tr.concept} className="gd-card gd-off-card">
                <span>{tr.text} <a {...guideLinkProps(`how-${GUIDE_TRAP_PAGE[tr.concept] || tr.concept}`)}>Read more</a></span>
              </div>
            ))}
          </div>
        </React.Fragment>
      )}

      <h2 className="gd-h2">Run it yourself</h2>
      <p className="muted gd-small">The exact query the export runs for this check, with the window and the export date filled in. Paste it into a Snowflake worksheet; it only reads.</p>
      <GuideSqlViewer key={f.query_id} queryId={f.query_id} />

      {f.columns && f.columns.length > 0 && (
        <details className="gd-details">
          <summary>{`Columns (${f.columns.length})`}</summary>
          <table className="guide2-cols">
            <thead><tr><th>Column</th><th>Meaning</th><th>Unit</th></tr></thead>
            <tbody>
              {f.columns.map((c: any) => {
                const meta = columnMeta(c.name, c.kind);
                return (
                  <tr key={c.name}>
                    <td className="mono">{c.name}</td>
                    <td>{meta.label}{meta.help && <div className="muted">{meta.help}</div>}</td>
                    <td className="muted">{meta.unit || "—"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </details>
      )}
      {f.requires && f.requires.trim().toLowerCase() !== "n/a" && <p className="muted gd-small">Needs: {codeifyProse(f.requires)}</p>}
      {f.floor && <p className="muted gd-small">{`Materiality floor: under ${f.floor.label || f.floor.column} reads OK and is left out of every count.`}</p>}
      {(f.grants || []).length > 0 && (
        <details className="gd-details">
          <summary>Grant needed</summary>
          <pre className="mono gd-small" style={{ whiteSpace: "pre-wrap", overflowX: "auto" }}>{f.grants.join("\n")}</pre>
          {f.needs_enterprise && <p className="muted gd-small">This check also needs Enterprise edition or higher; no grant changes that.</p>}
        </details>
      )}
      {(f.docs || []).length > 0 && (
        <div className="guide2-topic-docs">
          <div className="muted gd-small">Views it reads, on docs.snowflake.com</div>
          {f.docs.map((k: string) => <DocsLink key={k} docsKey={k} docs={data.docs} />)}
        </div>
      )}
      {showReviewerBlock() && <ReviewerDetails f={f} />}
    </article>
  );
}

interface GuideCheckPageProps {
  data: GuideData;
  guideIndex: GuideIndex;
  f: GuideCheck;
  filters: Filters;
  findingsById: Record<string, Finding>;
}

export function GuideCheckPage({ data, guideIndex, f, filters, findingsById }: GuideCheckPageProps) {
  const home: GuideHomeRef = homeForQuery(f);
  const area: GuideArea | null = AREA_REGISTRY[home.tab as AreaKey] || null;
  return (
    <GuidePage
      current={f.query_id}
      guideIndex={guideIndex}
      checkArea={area && GUIDE_TABS[home.tab] ? home.tab : null}
      rail={<CheckRail f={f} data={data} home={home} area={area} findingsById={findingsById} />}
    >
      <GuideArticle f={f} data={data} filters={filters} home={home} area={area} />
    </GuidePage>
  );
}

// ═══════════════════════════════════ Root ═══════════════════════════════════

interface GuideTabProps {
  focus?: string | null;
  filters?: Filters | null;
  findingsById?: Record<string, Finding> | null;
  meta?: Meta | null;
  role?: string | null;
}

export function GuideTab({ focus, filters, findingsById, meta, role }: GuideTabProps) {
  _guideRole = role || null;
  const [data, setData] = React.useState<GuideData | null>(null);
  const [error, setError] = React.useState<string | null>(null);

  React.useEffect(() => {
    Api.guide().then(setData).catch((e) => setError(e.message || String(e)));
  }, []);

  const guideIndex = React.useMemo(() => {
    const idx: GuideIndex = {};
    (data ? data.findings : []).forEach((f: GuideCheck) => { idx[f.query_id] = f; });
    return idx;
  }, [data]);

  if (error) {
    return (
      <div className="honest-card error">
        <div className="h-title">Could not load How it works</div>
        <div className="h-note mono">{error}</div>
      </div>
    );
  }
  if (!data) {
    return <div className="loading-note">…</div>;
  }

  const safeFilters = filters || { window: 30, accountIds: [] };
  const byId = findingsById || {};
  const topic = focus && String(focus).indexOf("how-") === 0 ? String(focus).slice(4) : null;

  if (topic && topic.indexOf("area-") === 0 && GUIDE_TABS[topic.slice(5)] && guideArea(topic.slice(5))) {
    return <GuideTabPage areaKey={topic.slice(5)} data={data} guideIndex={guideIndex} findingsById={byId} meta={meta} />;
  }
  if (topic === "troubleshooting") return <GuideTroubleshooting guideIndex={guideIndex} />;
  if (topic === "glossary") return <GuideGlossaryPage guideIndex={guideIndex} />;
  if (topic === "checks") return <GuideCheckReference guideIndex={guideIndex} findingsById={byId} />;
  if (topic && GUIDE_SECTIONS.some((s) => s.slug === topic)) {
    return <GuideTopicPage slug={topic} data={data} guideIndex={guideIndex} meta={meta} />;
  }
  const checkF = focus && !topic ? guideIndex[focus] : null;
  if (checkF) {
    return <GuideCheckPage data={data} guideIndex={guideIndex} f={checkF} filters={safeFilters} findingsById={byId} />;
  }

  return <GuideHome data={data} guideIndex={guideIndex} meta={meta} />;
}

