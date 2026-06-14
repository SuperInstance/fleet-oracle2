use chrono::{DateTime, Utc, Duration};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A Bottle is the unit of async communication.
/// Fields match the harbor-daemon's Bottle struct exactly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Bottle {
    pub uuid: String,
    pub sender: String,
    #[serde(default)]
    pub recipient: String,
    #[serde(default = "default_priority")]
    pub priority: u8,
    #[serde(rename = "type")]
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
    /// Create a new bottle.
    pub fn new(
        sender: String,
        recipient: String,
        bottle_type: &str,
        payload: String,
        priority: u8,
        ttl_hours: i64,
    ) -> Self {
        let now = Utc::now();
        let expires = now + Duration::hours(ttl_hours);
        let expires_at = expires.to_rfc3339();
        let priority = priority.clamp(1, 5);

        Bottle {
            uuid: Uuid::new_v4().to_string(),
            sender,
            recipient,
            priority,
            r#type: bottle_type.to_uppercase(),
            payload,
            expires_at,
            hop_count: 0,
        }
    }

    /// True if this bottle has expired.
    pub fn is_expired(&self) -> bool {
        match DateTime::parse_from_rfc3339(&self.expires_at) {
            Ok(expires) => expires < Utc::now(),
            Err(_) => true,
        }
    }

    /// Readable preview of the bottle.
    pub fn preview(&self) -> String {
        let preview = if self.payload.len() > 80 {
            format!("{}...", &self.payload[..77])
        } else {
            self.payload.clone()
        };
        let created = self
            .expires_at
            .as_str()
            .split('+')
            .next()
            .unwrap_or(&self.expires_at);
        format!(
            "  UUID:      {}\n  From:      {}\n  To:        {}\n  Type:      {}\n  Priority:  P{}\n  Expires:   {}\n  Hop count: {}\n  Message:   {}",
            self.uuid, self.sender, self.recipient, self.r#type, self.priority, created, self.hop_count, preview
        )
    }
}
