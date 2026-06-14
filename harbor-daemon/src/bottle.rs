use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::str::FromStr;
use uuid::Uuid;

/// A single bottle message floating in the harbor.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bottle {
    pub uuid: String,
    pub sender: String,
    #[serde(default)]
    pub recipient: String,
    #[serde(default = "default_priority")]
    pub priority: u8,
    #[serde(default)]
    pub r#type: String,
    #[serde(default)]
    pub payload: String,
    pub expires_at: String,
    #[serde(default)]
    pub hop_count: u32,
}

fn default_priority() -> u8 {
    1
}

impl Bottle {
    /// Check whether this bottle has expired based on its expires_at field.
    pub fn is_expired(&self) -> bool {
        match DateTime::parse_from_rfc3339(&self.expires_at) {
            Ok(expires) => {
                let now = Utc::now();
                // Compare as UTC timestamps
                expires < now
            }
            Err(_) => {
                // If we can't parse the timestamp, assume expired
                eprintln!(
                    "[{}] WARN: could not parse expires_at for bottle {}: {}",
                    Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                    self.uuid,
                    self.expires_at
                );
                true
            }
        }
    }

    /// Validate a bottle has required fields.
    pub fn validate(&self) -> Result<(), String> {
        if Uuid::from_str(&self.uuid).is_err() {
            return Err(format!("invalid uuid: {}", self.uuid));
        }
        if self.sender.is_empty() {
            return Err("sender cannot be empty".to_string());
        }
        if self.recipient.is_empty() {
            return Err("recipient cannot be empty".to_string());
        }
        if self.expires_at.is_empty() {
            return Err("expires_at cannot be empty".to_string());
        }
        // Validate timestamp format by attempting parse
        DateTime::parse_from_rfc3339(&self.expires_at)
            .map_err(|e| format!("invalid expires_at '{}': {}", self.expires_at, e))?;

        Ok(())
    }
}

/// A command from a client over the TCP socket.
#[derive(Debug, Deserialize)]
pub struct ClientCommand {
    pub command: String,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub sender: String,
}

/// The response sent back to clients.
#[derive(Debug, Serialize)]
pub struct CommandResponse {
    pub status: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bottles: Option<Vec<String>>,
}
