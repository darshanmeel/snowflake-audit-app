import { afterEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { ApPanel } from "../components/area_pages";

const FINDING = { query_id: "sf_test_check", outcome: "ok_rows", row_count: 2 };
const FILTERS = { window: 30, accountIds: null };

function mount(body: Record<string, unknown>) {
  vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify(body), { status: 200 })));
  const build = vi.fn(() => <div data-testid="chart">chart</div>);
  render(
    <ApPanel id="sf_test_check" title="A chart" subtitle="sub" area="cost" subtab="service"
      findings={[FINDING]} filters={FILTERS} dims={{}} meta={{ as_of_date: "2026-09-22" }} goTo={() => {}} build={build} />,
  );
  return build;
}

describe("a chart is drawn only from ok_rows", () => {
  afterEach(() => { vi.unstubAllGlobals(); });

  it("draws the chart when the fetch returns rows", async () => {
    const build = mount({ outcome: "ok_rows", rows: [{ a: 1 }, { a: 2 }], rows_total: 2 });
    expect(await screen.findByTestId("chart")).toBeInTheDocument();
    expect(build).toHaveBeenCalled();
  });

  it.each([
    [{ outcome: "not_assessed", not_assessed: { label: "needs Enterprise edition" } }, "– Not assessed: needs Enterprise edition."],
    [{ outcome: "error", error: "The check failed." }, "– The check failed."],
    [{ outcome: "ok_empty_filters" }, "Rows exist, but the current filters exclude all of them."],
  ])("shows the note, not a chart, for %j", async (body, note) => {
    const build = mount(body);
    expect(await screen.findByText(note)).toBeInTheDocument();
    expect(screen.queryByTestId("chart")).toBeNull();
    expect(build).not.toHaveBeenCalled();
  });

  it("says no data for the window on an empty result", async () => {
    mount({ outcome: "ok_empty_window" });
    await waitFor(() => expect(screen.getByText(/^No data for this in /)).toBeInTheDocument());
    expect(screen.queryByTestId("chart")).toBeNull();
  });

  it("says the check is not in the export when it has no finding", async () => {
    vi.stubGlobal("fetch", vi.fn());
    render(<ApPanel id="missing" title="A chart" area="cost" subtab="service" findings={[]} filters={FILTERS} dims={{}} meta={{}} goTo={() => {}} build={() => <div data-testid="chart" />} />);
    expect(screen.getByText("– Not in this export yet: run the export again.")).toBeInTheDocument();
    expect(screen.queryByTestId("chart")).toBeNull();
  });

  it("shows … while loading, never an interim value", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise(() => {})));
    render(<ApPanel id="sf_test_check" title="A chart" area="cost" subtab="service" findings={[FINDING]} filters={FILTERS} dims={{}} meta={{}} goTo={() => {}} build={() => <div data-testid="chart" />} />);
    expect(screen.getByText("…")).toBeInTheDocument();
  });
});
