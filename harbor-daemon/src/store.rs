use chrono::Utc;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::bottle::Bottle;

/// The in-memory index + JSONL-backed store for bottles.
pub struct Store {
    /// Append-only log of all bottles received.
    jsonl_path: PathBuf,
    /// In-memory UUID -> Bottle index.
    bottles: HashMap<String, Bottle>,
    /// In-memory sender -> list of UUIDs index.
    sender_index: HashMap<String, Vec<String>>,
    /// Total bottles received since startup (including expired).
    total_received: u64,
}

impl Store {
    /// Open or create a new store backed by `data_dir/bottles.jsonl`.
    pub fn new(data_dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(data_dir)
            .map_err(|e| format!("failed to create data dir {}: {}", data_dir.display(), e))?;

        let jsonl_path = data_dir.join("bottles.jsonl");

        // If the file already exists, replay it into memory
        let mut bottles: HashMap<String, Bottle> = HashMap::new();
        let mut sender_index: HashMap<String, Vec<String>> = HashMap::new();
        let mut total_received: u64 = 0;

        if jsonl_path.exists() {
            let file = File::open(&jsonl_path)
                .map_err(|e| format!("failed to open {}: {}", jsonl_path.display(), e))?;
            let reader = BufReader::new(file);
            for line in reader.lines() {
                match line {
                    Ok(raw) => {
                        let raw = raw.trim().to_string();
                        if raw.is_empty() {
                            continue;
                        }
                        match serde_json::from_str::<Bottle>(&raw) {
                            Ok(bottle) => {
                                let uuid = bottle.uuid.clone();
                                let sender = bottle.sender.clone();
                                bottles.insert(uuid.clone(), bottle);
                                sender_index
                                    .entry(sender)
                                    .or_default()
                                    .push(uuid);
                                total_received += 1;
                            }
                            Err(e) => {
                                eprintln!(
                                    "[{}] WARN: skipping malformed line in {}: {}",
                                    Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                                    jsonl_path.display(),
                                    e
                                );
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!(
                            "[{}] WARN: read error from {}: {}",
                            Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                            jsonl_path.display(),
                            e
                        );
                    }
                }
            }
        }

        eprintln!(
            "[{}] Store loaded: {} bottles replayed from {}",
            Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
            total_received,
            jsonl_path.display()
        );

        Ok(Store {
            jsonl_path,
            bottles,
            sender_index,
            total_received,
        })
    }

    /// Append a bottle to the JSONL file and update in-memory indexes.
    pub fn append(&mut self, bottle: Bottle) -> Result<(), String> {
        let json = serde_json::to_string(&bottle)
            .map_err(|e| format!("serialization error: {}", e))?;

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.jsonl_path)
            .map_err(|e| format!("failed to open {}: {}", self.jsonl_path.display(), e))?;

        writeln!(file, "{}", json)
            .map_err(|e| format!("write error: {}", e))?;

        let uuid = bottle.uuid.clone();
        let sender = bottle.sender.clone();

        self.bottles.insert(uuid.clone(), bottle);
        self.sender_index
            .entry(sender)
            .or_default()
            .push(uuid);
        self.total_received += 1;

        Ok(())
    }

    /// Retrieve a bottle by UUID.
    pub fn get_by_uuid(&self, uuid: &str) -> Option<&Bottle> {
        self.bottles.get(uuid)
    }

    /// Retrieve all UUIDs for a given sender.
    pub fn get_by_sender(&self, sender: &str) -> Vec<String> {
        self.sender_index
            .get(sender)
            .cloned()
            .unwrap_or_default()
    }

    /// Return UUIDs of all non-expired bottles.
    pub fn list_undelivered(&self) -> Vec<String> {
        self.bottles
            .iter()
            .filter(|(_, b)| !b.is_expired())
            .map(|(uuid, _)| uuid.clone())
            .collect()
    }

    /// Run garbage collection: remove all expired bottles.
    pub fn gc(&mut self) -> u64 {
        let expired_uuids: Vec<String> = self
            .bottles
            .iter()
            .filter(|(_, b)| b.is_expired())
            .map(|(uuid, _)| uuid.clone())
            .collect();

        let count = expired_uuids.len() as u64;

        for uuid in &expired_uuids {
            self.bottles.remove(uuid);
        }

        // Rebuild sender index (inefficient for massive GC, fine for harbor scale)
        if count > 0 {
            let mut new_sender_index: HashMap<String, Vec<String>> = HashMap::new();
            for (uuid, bottle) in &self.bottles {
                new_sender_index
                    .entry(bottle.sender.clone())
                    .or_default()
                    .push(uuid.clone());
            }
            self.sender_index = new_sender_index;
        }

        count
    }

    /// Current number of bottles in memory.
    pub fn bottle_count(&self) -> usize {
        self.bottles.len()
    }

    /// Total received since startup.
    pub fn total_received(&self) -> u64 {
        self.total_received
    }
}

/// Thread-safe wrapper around Store.
#[derive(Clone)]
pub struct SharedStore {
    inner: Arc<RwLock<Store>>,
}

impl SharedStore {
    pub fn new(store: Store) -> Self {
        SharedStore {
            inner: Arc::new(RwLock::new(store)),
        }
    }

    pub async fn append(&self, bottle: Bottle) -> Result<(), String> {
        self.inner.write().await.append(bottle)
    }

    pub async fn get_by_uuid(&self, uuid: &str) -> Option<Bottle> {
        self.inner.read().await.get_by_uuid(uuid).cloned()
    }

    pub async fn get_by_sender(&self, sender: &str) -> Vec<String> {
        self.inner.read().await.get_by_sender(sender)
    }

    pub async fn list_undelivered(&self) -> Vec<String> {
        self.inner.read().await.list_undelivered()
    }

    pub async fn gc(&self) -> u64 {
        self.inner.write().await.gc()
    }

    pub async fn bottle_count(&self) -> usize {
        self.inner.read().await.bottle_count()
    }
}
