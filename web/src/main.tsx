// The entry: styles once, in the order index.html used to link them, then the app.
import * as ReactDOM from "react-dom/client";
import "./styles/fonts/fonts.css";
import "./styles/styles.css";
import "./styles/names.css";
import "./styles/css/c_shell.css";
import "./styles/css/p_overview_waste.css";
import "./styles/css/p_cost_mlai.css";
import "./styles/css/p_compute_jobs.css";
import "./styles/css/p_queries_gov_storage.css";
import "./styles/css/p_findings_coverage.css";
import "./styles/css/p_guide.css";
import "./styles/css/p_findings_detail.css";
import "./styles/css/p_money.css";
import "./styles/css/p_actions.css";
import "./styles/css/c_exec.css";
import "./styles/css/c_blocks.css";
import "./styles/css/c_redesign.css";
import "./styles/css/c_pattern.css";
import "./styles/css/c_landing.css";
import "./styles/css/cx_a.css";
import "./styles/css/cx_b.css";
import "./styles/css/cx_c.css";
import "./styles/css/cx_d.css";
import { App } from "./App";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(<App />);
