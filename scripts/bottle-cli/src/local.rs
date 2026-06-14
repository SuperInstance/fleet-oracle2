use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use crate::bottle::Bottle;

/// Get the local bottles directory ($HOME/BOTTLES).
fn bottles_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join("BOTTLES")
}

/// Ensure the bottles directory exists.
fn ensure_dir() -> std::io::Result<()> {
    let dir = bottles_dir();
    fs::create_dir_all(&dir)
}

/// Write a bottle to a local JSON file: ~/BOTTLES/<sender>-<uuid>.json
pub fn write_bottle(bottle: &Bottle) -> Result<PathBuf, String> {
    ensure_dir().map_err(|e| format!("Cannot create bottles directory: {e}"))?;

    let filename = format!("{}-{}.json", bottle.sender, bottle.uuid);
    let path = bottles_dir().join(&filename);

    let json = serde_json::to_string_pretty(bottle)
        .map_err(|e| format!("Failed to serialize bottle: {e}"))?;

    fs::write(&path, &json).map_err(|e| format!("Failed to write bottle file: {e}"))?;

    Ok(path)
}

/// List local bottles, optionally filtered.
pub fn list_bottles(sender: Option<&str>, _undelivered: bool) -> Result<Vec<Bottle>, String> {
    let dir = bottles_dir();
    if !dir.exists() {
        return Ok(Vec::new());
    }

    let mut bottles = Vec::new();
    let entries = fs::read_dir(&dir).map_err(|e| format!("Cannot read bottles dir: {e}"))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("Cannot read entry: {e}"))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }

        let content = fs::read_to_string(&path).map_err(|e| format!("Cannot read {path:?}: {e}"))?;
        if let Ok(bottle) = serde_json::from_str::<Bottle>(&content) {
            if let Some(s) = sender {
                if bottle.sender != s {
                    continue;
                }
            }
            // Filter undelivered: skip expired if flag set
            if _undelivered && bottle.is_expired() {
                continue;
            }
            bottles.push(bottle);
        }
    }

    // Sort by creation time descending (infer from expires_at - 24h default as proxy)
    // For simplicity, just keep order as found (most recent file last)
    bottles.reverse();

    Ok(bottles)
}

/// Get a single bottle by UUID from local storage.
pub fn get_bottle(uuid: &str) -> Result<Bottle, String> {
    let dir = bottles_dir();
    if !dir.exists() {
        return Err(format!("Bottle {} not found (no bottles directory)", uuid));
    }

    let entries = fs::read_dir(&dir).map_err(|e| format!("Cannot read bottles dir: {e}"))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("Cannot read entry: {e}"))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }

        let content = fs::read_to_string(&path).map_err(|e| format!("Cannot read {path:?}: {e}"))?;
        if let Ok(bottle) = serde_json::from_str::<Bottle>(&content) {
            if bottle.uuid == uuid {
                return Ok(bottle);
            }
        }
    }

    Err(format!("Bottle {} not found in local storage", uuid))
}

/// Remove a bottle from local storage.
pub fn toss_bottle(uuid: &str) -> Result<(), String> {
    let dir = bottles_dir();
    if !dir.exists() {
        return Err(format!("Bottle {} not found", uuid));
    }

    let entries = fs::read_dir(&dir).map_err(|e| format!("Cannot read bottles dir: {e}"))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("Cannot read entry: {e}"))?;
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }

        let content = fs::read_to_string(&path).map_err(|e| format!("Cannot read {path:?}: {e}"))?;
        if let Ok(bottle) = serde_json::from_str::<Bottle>(&content) {
            if bottle.uuid == uuid {
                fs::remove_file(&path).map_err(|e| format!("Cannot toss bottle: {e}"))?;
                return Ok(());
            }
        }
    }

    Err(format!("Bottle {} not found", uuid))
}

/// Get a local summary.
pub fn get_summary() -> Result<String, String> {
    let bottles = list_bottles(None, false)?;
    let total = bottles.len();
    let expired = bottles.iter().filter(|b| b.is_expired()).count();
    let active = total - expired;

    let by_type = {
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for b in &bottles {
            *m.entry(b.r#type.clone()).or_insert(0) += 1;
        }
        m
    };

    let by_sender = {
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for b in &bottles {
            *m.entry(b.sender.clone()).or_insert(0) += 1;
        }
        m
    };

    let by_priority = {
        let mut m: BTreeMap<u8, usize> = BTreeMap::new();
        for b in &bottles {
            *m.entry(b.priority).or_insert(0) += 1;
        }
        m
    };

    Ok(format!(
        "📊 Bottle Summary (local)\n\
         ─────────────────────────\n\
         Total:     {}\n\
         Active:    {} (not expired)\n\
         Expired:   {}\n\
         \n\
         By type:\n\
         {}\n\
         \n\
         By sender:\n\
         {}\n\
         \n\
         By priority:\n\
         {}",
        total,
        active,
        expired,
        by_type.iter().map(|(k, v)| format!("  {k}: {v}")).collect::<Vec<_>>().join("\n"),
        by_sender.iter().map(|(k, v)| format!("  {k}: {v}")).collect::<Vec<_>>().join("\n"),
        by_priority.iter().map(|(k, v)| format!("  P{k}: {v}")).collect::<Vec<_>>().join("\n"),
    ))
}
