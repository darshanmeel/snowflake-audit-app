// A CSV of what a card or list shows: the columns given, in order, one row per item.
import { csvField } from "./findings_table";

export interface CsvColumn<T> { label: string; value: (row: T) => unknown }

export function downloadCsv<T>(fileName: string, columns: CsvColumn<T>[], rows: T[]) {
  const lines = [columns.map((c) => csvField(c.label)).join(",")];
  rows.forEach((r) => lines.push(columns.map((c) => csvField(c.value(r))).join(",")));
  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName.endsWith(".csv") ? fileName : `${fileName}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

export function CsvButton<T>({ fileName, columns, rows, label = "CSV" }: { fileName: string; columns: CsvColumn<T>[]; rows: T[]; label?: string }) {
  return (
    <button type="button" className="csv-download-btn" disabled={!rows.length} onClick={() => downloadCsv(fileName, columns, rows)}
      title="Download these rows as a CSV file.">
      {label}
    </button>
  );
}
