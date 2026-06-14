use crate::bottle::{ClientCommand, CommandResponse};
use crate::store::SharedStore;

/// Process a single client command line, return a JSON response.
pub async fn process_command(
    store: &SharedStore,
    cmd: &ClientCommand,
) -> CommandResponse {
    match cmd.command.as_str() {
        "get" => {
            if cmd.uuid.is_empty() {
                return CommandResponse {
                    status: "error".to_string(),
                    message: "uuid required for 'get' command".to_string(),
                    bottles: None,
                };
            }

            match store.get_by_uuid(&cmd.uuid).await {
                Some(bottle) => {
                    let json = serde_json::to_string(&bottle).unwrap_or_default();
                    CommandResponse {
                        status: "ok".to_string(),
                        message: format!("found bottle {}", cmd.uuid),
                        bottles: Some(vec![json]),
                    }
                }
                None => CommandResponse {
                    status: "not_found".to_string(),
                    message: format!("no bottle with uuid {}", cmd.uuid),
                    bottles: None,
                },
            }
        }

        "list" => {
            if cmd.sender.is_empty() {
                return CommandResponse {
                    status: "error".to_string(),
                    message: "sender required for 'list' command".to_string(),
                    bottles: None,
                };
            }

            let uuids = store.get_by_sender(&cmd.sender).await;
            CommandResponse {
                status: "ok".to_string(),
                message: format!("{} bottles from sender '{}'", uuids.len(), cmd.sender),
                bottles: Some(uuids),
            }
        }

        "list-undelivered" => {
            let uuids = store.list_undelivered().await;
            CommandResponse {
                status: "ok".to_string(),
                message: format!("{} undelivered bottles", uuids.len()),
                bottles: Some(uuids),
            }
        }

        other => CommandResponse {
            status: "error".to_string(),
            message: format!("unknown command: '{}'; supported: get, list, list-undelivered", other),
            bottles: None,
        },
    }
}

/// Parse a single line as a bottle or a client command.
pub enum InboundMessage {
    Bottle(crate::bottle::Bottle),
    Command(ClientCommand),
    Invalid(String),
}

/// Parse an inbound line. First checks if it's a command (`command` key),
/// otherwise tries to parse as a bottle.
pub fn parse_inbound(line: &str) -> InboundMessage {
    let line = line.trim();
    if line.is_empty() {
        return InboundMessage::Invalid("empty line".to_string());
    }

    // First try as a JSON object
    match serde_json::from_str::<serde_json::Value>(line) {
        Ok(val) => {
            // If it has a "command" key, it's a client command
            if val.get("command").and_then(|c| c.as_str()).is_some() {
                match serde_json::from_str::<ClientCommand>(line) {
                    Ok(cmd) => InboundMessage::Command(cmd),
                    Err(e) => InboundMessage::Invalid(format!("bad command: {}", e)),
                }
            } else {
                // Otherwise try as a bottle
                match serde_json::from_str::<crate::bottle::Bottle>(line) {
                    Ok(bottle) => InboundMessage::Bottle(bottle),
                    Err(e) => InboundMessage::Invalid(format!("invalid bottle: {}", e)),
                }
            }
        }
        Err(e) => InboundMessage::Invalid(format!("invalid JSON: {}", e)),
    }
}

/// Format a response as JSON bytes for sending over TCP.
pub fn format_response(response: &CommandResponse) -> Vec<u8> {
    let json = serde_json::to_string(response).unwrap_or_else(|_| {
        r#"{"status":"error","message":"internal serialization error"}"#.to_string()
    });
    let mut bytes = json.into_bytes();
    bytes.push(b'\n');
    bytes
}
