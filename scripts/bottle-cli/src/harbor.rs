use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::bottle::Bottle;

/// The default harbor address.
pub const DEFAULT_HARBOR: &str = "127.0.0.1:8796";

/// Send a JSON line to the harbor and read the response.
fn send_command(harbor: &str, json: &str) -> Result<String, String> {
    let timeout = Duration::from_secs(5);
    let addr = harbor
        .parse()
        .map_err(|e| format!("Invalid harbor address '{harbor}': {e}"))?;

    let mut stream = TcpStream::connect_timeout(&addr, timeout)
        .map_err(|e| format!("Cannot connect to harbor at {harbor}: {e}"))?;

    stream
        .set_write_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set write timeout: {e}"))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|e| format!("Failed to set read timeout: {e}"))?;

    // Send the command with newline
    let mut line = json.as_bytes().to_vec();
    line.push(b'\n');
    stream
        .write_all(&line)
        .map_err(|e| format!("Failed to write to harbor: {e}"))?;

    // Read the response (single line)
    let mut buf = [0u8; 65536];
    let n = stream
        .read(&mut buf)
        .map_err(|e| format!("Failed to read from harbor: {e}"))?;

    Ok(String::from_utf8_lossy(&buf[..n]).trim().to_string())
}

/// Send a raw bottle JSON to the harbor.
pub fn send_bottle(harbor: &str, bottle: &Bottle) -> Result<String, String> {
    let json = serde_json::to_string(bottle)
        .map_err(|e| format!("Failed to serialize bottle: {e}"))?;
    send_command(harbor, &json)
}

/// Request a bottle by UUID from the harbor.
pub fn get_bottle(harbor: &str, uuid: &str) -> Result<String, String> {
    let cmd = serde_json::json!({
        "command": "get",
        "uuid": uuid,
    });
    send_command(harbor, &cmd.to_string())
}

/// List bottles by sender from the harbor.
pub fn list_bottles(harbor: &str, sender: &str) -> Result<String, String> {
    let cmd = serde_json::json!({
        "command": "list",
        "sender": sender,
    });
    send_command(harbor, &cmd.to_string())
}

/// List undelivered bottles.
pub fn list_undelivered(harbor: &str) -> Result<String, String> {
    let cmd = serde_json::json!({
        "command": "list-undelivered",
    });
    send_command(harbor, &cmd.to_string())
}
