//! ccm-pid — POST a γ/η report to the conservation-meter from CLI.
//!
//! Usage:
//!   ccm-pid --disk-pct 63 --services 34 --agent my-agent --task verify
//!
//! γ (gamma, complexity) = disk_pct * 10 + load * 100
//! η (eta, efficiency)  = services * 10

use std::env;
use std::process;
use std::time::{SystemTime, UNIX_EPOCH};

/// Minimal JSON builder — no serde dependency needed in this binary.
#[derive(Debug)]
struct Report {
    agent: String,
    gamma: u64,
    eta: u64,
    task: String,
    timestamp: String,
}

impl Report {
    fn to_json(&self) -> String {
        format!(
            r#"{{"agent":"{}","gamma":{},"eta":{},"task":"{}","timestamp":"{}"}}"#,
            self.agent.replace('"', "\\\""),
            self.gamma,
            self.eta,
            self.task.replace('"', "\\\""),
            self.timestamp
        )
    }

    fn post(&self, url: &str) -> Result<String, String> {
        let body = self.to_json();
        let response = ureq::post(url)
            .set("Content-Type", "application/json")
            .send_string(&body)
            .map_err(|e| format!("request failed: {}", e))?;

        let status = response.status();
        let text = response
            .into_string()
            .map_err(|e| format!("read response failed: {}", e))?;

        if status == 200 {
            Ok(text)
        } else {
            Err(format!("HTTP {}: {}", status, text))
        }
    }
}

/// Read the 1-minute load average from /proc/loadavg.
/// Falls back to 0.0 if the file is unreadable.
fn read_loadavg() -> f64 {
    let content = match std::fs::read_to_string("/proc/loadavg") {
        Ok(s) => s,
        Err(_) => return 0.0,
    };
    if let Some(space) = content.find(' ') {
        content[..space].parse::<f64>().unwrap_or(0.0)
    } else {
        0.0
    }
}

/// Return an ISO 8601 timestamp (seconds precision).
fn iso_now() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();

    // Manual UTC breakdown — avoids pulling in chrono for this binary.
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    // Days since Unix epoch → year/month/day.
    // Algorithm from Howard Hinnant (public domain).
    let z = days as i64 + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // day of era [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // year of era [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // day of year [0, 365]
    let mp = (5 * doy + 2) / 153; // month phase [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // day [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // month [1, 12]
    let y = if m <= 2 { y + 1 } else { y }; // year

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        y, m, d, hours, minutes, seconds
    )
}

fn print_usage(program: &str) {
    eprintln!(
        "Usage: {} --disk-pct <f64> --services <u64> [--agent <string>] [--task <string>]",
        program
    );
    eprintln!();
    eprintln!(
        "  --disk-pct <f64>    Disk usage percentage (e.g. 63.0)"
    );
    eprintln!(
        "  --services <u64>    Number of active services (e.g. 34)"
    );
    eprintln!(
        "  --agent <string>    Agent name (default: ccm-pid)"
    );
    eprintln!(
        "  --task <string>     Task name (default: report)"
    );
    eprintln!(
        "  --endpoint <string> Conservation meter URL (default: http://localhost:8798/api/report)"
    );
    eprintln!();
    eprintln!(
        "  γ = disk_pct × 10 + load × 100"
    );
    eprintln!("  η = services × 10");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args.first().map(|s| s.as_str()).unwrap_or("ccm-pid");

    if args.len() < 2 {
        print_usage(program);
        process::exit(1);
    }

    let mut disk_pct: Option<f64> = None;
    let mut services: Option<u64> = None;
    let mut agent = "ccm-pid".to_string();
    let mut task = "report".to_string();
    let mut endpoint = "http://localhost:8798/api/report".to_string();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--disk-pct" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --disk-pct requires a value");
                    process::exit(1);
                }
                disk_pct = Some(args[i].parse().unwrap_or_else(|_| {
                    eprintln!("error: --disk-pct must be a number");
                    process::exit(1);
                }));
            }
            "--services" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --services requires a value");
                    process::exit(1);
                }
                services = Some(args[i].parse().unwrap_or_else(|_| {
                    eprintln!("error: --services must be an integer");
                    process::exit(1);
                }));
            }
            "--agent" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --agent requires a value");
                    process::exit(1);
                }
                agent = args[i].clone();
            }
            "--task" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --task requires a value");
                    process::exit(1);
                }
                task = args[i].clone();
            }
            "--endpoint" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("error: --endpoint requires a value");
                    process::exit(1);
                }
                endpoint = args[i].clone();
            }
            "--help" | "-h" => {
                print_usage(program);
                process::exit(0);
            }
            _ => {
                eprintln!("error: unknown flag '{}'", args[i]);
                print_usage(program);
                process::exit(1);
            }
        }
        i += 1;
    }

    let disk_pct = disk_pct.unwrap_or_else(|| {
        eprintln!("error: --disk-pct is required");
        process::exit(1);
    });
    let services = services.unwrap_or_else(|| {
        eprintln!("error: --services is required");
        process::exit(1);
    });

    let load = read_loadavg();

    // γ (gamma, complexity) = disk_pct * 10 + load * 100
    let gamma = (disk_pct * 10.0 + load * 100.0).round() as u64;
    // η (eta, efficiency) = services * 10
    let eta = services * 10;

    let report = Report {
        agent,
        gamma,
        eta,
        task,
        timestamp: iso_now(),
    };

    match report.post(&endpoint) {
        Ok(response) => {
            println!("{}", response);
            process::exit(0);
        }
        Err(e) => {
            eprintln!("error: {}", e);
            process::exit(1);
        }
    }
}
