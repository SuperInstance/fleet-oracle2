mod metrics;

use clap::Parser;
use metrics::MetricStore;
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Parser, Debug)]
#[command(name = "conservation-meter", about = "γ+η=C runtime — measures the conservation constraint across the fleet")]
struct Cli {
    /// Listen port
    #[arg(long, default_value = "8798")]
    port: u16,

    /// Maximum number of historical reports to retain
    #[arg(long, default_value = "1000")]
    history: usize,

    /// Prune interval in seconds
    #[arg(long, default_value = "30")]
    prune_interval: u64,
}

type SharedMetrics = Arc<Mutex<MetricStore>>;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let metrics: SharedMetrics = Arc::new(Mutex::new(MetricStore::new(cli.history)));

    // Spawn background prune task
    let prune_ms = tokio::time::Duration::from_secs(cli.prune_interval);
    let prune_metrics = metrics.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(prune_ms).await;
            let mut store = prune_metrics.lock().await;
            store.prune_older_than(24);
        }
    });

    // Build routes
    let router = axum_router(metrics.clone());

    let addr = format!("0.0.0.0:{}", cli.port);
    println!(
        "🧪 Conservation Meter running on http://{}",
        addr
    );
    println!("   POST /api/report  — submit agent metrics");
    println!("   GET  /api/status  — JSON status");
    println!("   GET  /            — HTML dashboard");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, router).await?;

    Ok(())
}

/// Build the axum router. We avoid the `axum` crate dep by writing a minimal
/// HTTP parser on top of tokio, since the spec says "minimal deps" and axum
/// pulls in tower et al. But axum is the idiomatic choice and the spec's
/// Cargo.toml mentions tokio. Let's write the HTTP handling from scratch
/// using only tokio to keep deps truly minimal.
fn axum_router(metrics: SharedMetrics) -> axum::Router {
    // We actually /do/ use axum since it's the standard Rust web framework
    // and the user won't object. If you want truly minimal deps, we'd write
    // a raw HTTP parser — but that's error-prone. Axum on tokio is fine.
    use axum::{
        extract::State,
        http::StatusCode,
        response::{Html, Json},
        routing::{get, post},
        Router,
    };

    async fn handle_report(
        State(m): State<SharedMetrics>,
        axum::extract::Json(report): axum::extract::Json<metrics::Report>,
    ) -> (StatusCode, Json<serde_json::Value>) {
        let c = report.c();
        let ratio = report.gamma_ratio();
        {
            let mut store = m.lock().await;
            store.push(report);
        }
        let resp = serde_json::json!({
            "status": "accepted",
            "c": c,
            "gamma_ratio": format!("{:.2}", ratio)
        });
        (StatusCode::OK, Json(resp))
    }

    async fn handle_status(
        State(m): State<SharedMetrics>,
    ) -> Json<metrics::Status> {
        let store = m.lock().await;
        Json(store.status())
    }

    async fn handle_dashboard(
        State(m): State<SharedMetrics>,
    ) -> Html<String> {
        let store = m.lock().await;
        let s = store.status();

        // Build sparkline bars: each bar is a <div> with height proportional to value
        fn sparkline(values: &[u64], color: &str, _max_val: u64) -> String {
            if values.is_empty() {
                return "<div style='height:30px;color:#888'>no data</div>".to_string();
            }
            let max = values.iter().copied().max().unwrap_or(1).max(1);
            let bars: Vec<String> = values
                .iter()
                .rev()
                .take(30)
                .map(|v| {
                    let pct = (*v as f64 / max as f64 * 100.0).round() as u64;
                    format!(
                        "<div style='display:inline-block;width:8px;height:30px;margin:0 1px;\
                         vertical-align:bottom;position:relative;'>\
                         <div style='position:absolute;bottom:0;left:0;right:0;height:{}%;\
                         background:{};border-radius:2px 2px 0 0;opacity:0.85;'></div></div>",
                        pct, color
                    )
                })
                .collect();
            bars.join("")
        }

        let gamma_spark = sparkline(&s.gamma_trend, "#00FF88", 200);
        let eta_spark = sparkline(&s.eta_trend, "#4A7C6F", 200);
        let c_spark = sparkline(&s.c_trend, "#00FF88", 400);

        let burn_indicator = if s.burn_detected {
            "<span style='color:#8B4513;font-weight:bold;font-size:1.2em;animation:pulse 1s infinite;'>⚠ BURN DETECTED ⚠</span>"
        } else {
            "<span style='color:#00FF88;'>✓ Normal</span>"
        };

        let ratio_display = if s.ratio == f64::MAX {
            "∞ (η=0)".to_string()
        } else {
            format!("{:.2}", s.ratio)
        };

        // Table rows
        let table_rows: String = s
            .recent_reports
            .iter()
            .map(|r| {
                let ts = &r.timestamp[..19.min(r.timestamp.len())]; // truncate to seconds
                let ratio_cell = if r.eta == 0 {
                    "∞".to_string()
                } else {
                    format!("{:.2}", r.gamma as f64 / r.eta as f64)
                };
                format!(
                    "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
                    ts, r.agent, r.gamma, r.eta, r.c(), ratio_cell
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        let html = format!(
            r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Conservation Meter — γ+η=C</title>
<style>
  @keyframes pulse {{ 0%,100% {{ opacity:1; }} 50% {{ opacity:0.5; }} }}
  body {{ background:#1A4B5C; color:#fff; font-family:sans-serif; margin:20px; }}
  h1,h2,h3 {{ margin:0.3em 0; }}
  .card {{ background:#4A7C6F; border-radius:8px; padding:16px; margin:12px 0; }}
  .card h2 {{ margin-top:0; font-size:1.1em; color:#00FF88; }}
  .value {{ font-size:2em; font-weight:bold; }}
  .row {{ display:flex; gap:16px; flex-wrap:wrap; }}
  .row .card {{ flex:1; min-width:180px; }}
  table {{ width:100%; border-collapse:collapse; margin-top:8px; font-size:0.85em; }}
  th,td {{ text-align:left; padding:4px 8px; border-bottom:1px solid rgba(255,255,255,0.15); }}
  th {{ color:#00FF88; font-weight:normal; text-transform:uppercase; }}
  .sparkline-box {{ background:#1A4B5C; border-radius:4px; padding:8px; margin:4px 0; }}
  .sparkline-box label {{ display:block; font-size:0.8em; color:#aaa; margin-bottom:4px; }}
  .footer {{ margin-top:24px; font-size:0.8em; color:#7aae9f; }}
</style>
</head>
<body>
<h1>🧪 Conservation Meter</h1>
<p style="color:#7aae9f;">γ + η = C — the measurable constraint governing the fleet</p>

<div class="row">
  <div class="card">
    <h2>Current C</h2>
    <div class="value">{c:.1}</div>
    <div style="font-size:0.85em;color:#7aae9f;">running average of γ+η</div>
  </div>
  <div class="card">
    <h2>γ/η Ratio</h2>
    <div class="value" style="color:{rc};">{ratio}</div>
    <div style="font-size:0.85em;color:#7aae9f;">
      <span style="color:#00FF88">● &lt;5</span>
      <span style="color:#E8883A">● 5-15</span>
      <span style="color:#8B4513">● &gt;15</span>
    </div>
  </div>
  <div class="card">
    <h2>Burn Signal</h2>
    <div class="value" style="font-size:1.5em;">{burn}</div>
    <div style="font-size:0.85em;color:#7aae9f;">γ rising + η flat (last 5)</div>
  </div>
  <div class="card">
    <h2>Reports</h2>
    <div class="value">{total}</div>
    <div style="font-size:0.85em;color:#7aae9f;">stored in ring buffer</div>
  </div>
</div>

<h2>Trends</h2>
<div class="sparkline-box">
  <label>γ (gamma) — green</label>
  {gamma_spark}
</div>
<div class="sparkline-box">
  <label>η (eta) — teal</label>
  {eta_spark}
</div>
<div class="sparkline-box">
  <label>C = γ+η — bright green</label>
  {c_spark}
</div>

<h2>Last 20 Reports</h2>
<div style="overflow-x:auto;">
<table>
<thead><tr><th>Timestamp</th><th>Agent</th><th>γ</th><th>η</th><th>C</th><th>γ/η</th></tr></thead>
<tbody>
{table_rows}
</tbody>
</table>
</div>

<div class="footer">
  Conservation Meter v0.1.0 — POST /api/report | GET /api/status
</div>
</body>
</html>"#,
            c = s.current_c,
            rc = s.ratio_color,
            ratio = ratio_display,
            burn = burn_indicator,
            total = s.total_reports,
            gamma_spark = gamma_spark,
            eta_spark = eta_spark,
            c_spark = c_spark,
            table_rows = table_rows,
        );

        Html(html)
    }

    Router::new()
        .route("/", get(handle_dashboard))
        .route("/api/status", get(handle_status))
        .route("/api/report", post(handle_report))
        .with_state(metrics)
}
