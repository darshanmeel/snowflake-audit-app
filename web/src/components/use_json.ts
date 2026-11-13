// web/src/components/use_json.ts -- a GET hook for the routes that are not check findings (access log, policies).
import React from "react";
import { getJson } from "../api";

/** A GET that keeps only the answer to the last request. */
export function useJson(path: string | null, params: Record<string, any>): { data: any; err: string | null; loading: boolean } {
  const [st, setSt] = React.useState<{ data: any; err: string | null; loading: boolean }>({ data: null, err: null, loading: false });
  const key = JSON.stringify(params);
  React.useEffect(() => {
    if (!path) return undefined;
    let live = true;
    setSt({ data: null, err: null, loading: true });
    getJson(path, params).then((d) => { if (live) setSt({ data: d, err: null, loading: false }); })
      .catch((e) => { if (live) setSt({ data: null, err: String(e.message || e), loading: false }); });
    return () => { live = false; };
  }, [path, key]);   // eslint-disable-line react-hooks/exhaustive-deps
  return st;
}
