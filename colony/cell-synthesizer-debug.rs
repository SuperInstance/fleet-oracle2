/// Correlate data across all cell types to detect patterns.
/// Reads each cell's RESULTS.json and synthesizes a high-level observation.
fn task_synthesizer(_state: &State) -> Result<HashMap<String, serde_json::Value>> {
    let colony_path = get_colony_path();
    let mut findings: Vec<String> = Vec::new();
    let mut observations: HashMap<String, serde_json::Value> = HashMap::new();

    // Debug: include colony path in output
    let colony_str = colony_path.to_string_lossy().to_string();

    // Try to read each specialized result
    let read_cell = |id: &str| -> Option<(String, serde_json::Value)> {
        let path = colony_path.join(format!("cell-{}/RESULTS.json", id));
        let content = fs::read_to_string(&path).ok()?;
        let val: serde_json::Value = serde_json::from_str(&content).ok()?;
        Some((path.to_string_lossy().to_string(), val))
    };

    // gc-warden data
    if let Some((path, val)) = read_cell("gc-warden") {
        if let Some(out) = val.get("output") {
            let disk = out.get("disk_pct").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let c_val = out.get("c_value").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let ratio = out.get("ratio").and_then(|v| v.as_f64()).unwrap_or(0.0);
            let gc_needed = out.get("gc_needed").and_then(|v| v.as_bool()).unwrap_or(false);
            observations.insert("disk_pct".into(), serde_json::json!(disk));
            observations.insert("c_value".into(), serde_json::json!(c_val));
            observations.insert("ratio".into(), serde_json::json!(ratio));
            observations.insert("read_gc_warden_from".into(), serde_json::json!(path));
            if gc_needed {
                findings.push("DISK WARNING: GC needed".to_string());
            }
        } else {
            findings.push(format!("NO_OUTPUT_KEY in gc-warden RESULTS.json at {}", path));
            observations.insert("gc_warden_keys".into(), serde_json::json!(
                val.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>()).unwrap_or_default()
            ));
        }
    } else {
        findings.push("FAILED_TO_READ gc-warden RESULTS.json".to_string());
    }

    // bottle-counter data
    if let Some((path, val)) = read_cell("bottle-counter") {
        if let Some(out) = val.get("output") {
            let count = out.get("bottle_count").and_then(|v| v.as_u64()).unwrap_or(0);
            let delta = out.get("delta").and_then(|v| v.as_u64()).unwrap_or(0);
            observations.insert("harbor_bottles".into(), serde_json::json!(count));
            observations.insert("bottle_delta".into(), serde_json::json!(delta));
            observations.insert("read_bottle_counter_from".into(), serde_json::json!(path));
            if delta > 50 {
                findings.push(format!("HIGH BOTTLE FLUX: {} new bottles since last cycle", delta));
            }
        }
    }

    // pulse-check data
    if let Some((path, val)) = read_cell("pulse-check") {
        if let Some(out) = val.get("output") {
            let alive = out.get("alive").and_then(|v| v.as_u64()).unwrap_or(0);
            let total = out.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
            observations.insert("services_alive".into(), serde_json::json!(alive));
            observations.insert("services_total".into(), serde_json::json!(total));
            observations.insert("read_pulse_check_from".into(), serde_json::json!(path));
            if alive < total {
                findings.push(format!("SERVICE DEGRADATION: {}/{} services alive", alive, total));
            }
        }
    }

    observations.insert("colony_path".into(), serde_json::json!(colony_str));

    let mut output = HashMap::new();
    output.insert("observations".into(), serde_json::json!(observations));
    output.insert("findings".into(), serde_json::json!(findings));
    output.insert("finding_count".into(), serde_json::json!(findings.len()));

    Ok(output)
}
