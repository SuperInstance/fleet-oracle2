mod bottle;
mod harbor;
mod local;

use std::process;

use clap::{Parser, Subcommand};

use bottle::Bottle;

/// A CLI tool for the Bottle protocol — async communication units for agents and humans.
#[derive(Parser)]
#[command(name = "bottle", version, about = "Write, read, forward, and toss bottles")]
struct Cli {
    /// Harbor daemon address (default: 127.0.0.1:8796, or BOTTLE_HARBOR env)
    #[arg(long, global = true, default_value_t = harbor::DEFAULT_HARBOR.to_string())]
    harbor: String,

    /// Override sender name (default: whoami / $USER)
    #[arg(long, global = true)]
    from: Option<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Write a new bottle
    Write {
        /// Recipient name
        #[arg(long, default_value = "unknown")]
        to: String,

        /// Bottle type: TASK, STATUS, BOTTLES, or DELIVERABLE
        #[arg(long, default_value = "STATUS")]
        r#type: String,

        /// Priority 1-5 (1=low, 5=urgent)
        #[arg(long, default_value_t = 3)]
        priority: u8,

        /// TTL in hours (default: 24)
        #[arg(long, default_value_t = 24)]
        ttl_hours: i64,

        /// Immediately send via harbor (instead of storing locally)
        #[arg(long, default_value_t = false)]
        send: bool,

        /// Bottle payload text
        message: Vec<String>,
    },

    /// Get a single bottle by UUID
    Get {
        /// UUID of the bottle
        uuid: String,
    },

    /// List bottles
    List {
        /// Filter by sender
        #[arg(long)]
        sender: Option<String>,

        /// Only show undelivered (non-expired) bottles
        #[arg(long, default_value_t = false)]
        undelivered: bool,
    },

    /// Forward a bottle to a new recipient
    Forward {
        /// UUID of bottle to forward
        uuid: String,

        /// New recipient
        #[arg(long)]
        to: String,

        /// Override forwarder name
        #[arg(long)]
        from: Option<String>,
    },

    /// Delete a bottle
    Toss {
        /// UUID of the bottle
        uuid: String,
    },

    /// Show summary of all bottles
    Summary,
}

fn get_sender(from_opt: Option<&str>) -> String {
    from_opt
        .map(|s| s.to_string())
        .or_else(|| std::env::var("USER").ok())
        .or_else(|| std::env::var("USERNAME").ok())
        .unwrap_or_else(|| "unknown".to_string())
}

fn main() {
    let cli = Cli::parse();
    let sender = get_sender(cli.from.as_deref());
    let harbor_addr = std::env::var("BOTTLE_HARBOR").unwrap_or(cli.harbor);

    match cli.command {
        Command::Write {
            to,
            r#type,
            priority,
            ttl_hours,
            send,
            message,
        } => {
            let payload = message.join(" ");
            if payload.trim().is_empty() {
                eprintln!("error: message text cannot be empty");
                process::exit(1);
            }

            let bottle = Bottle::new(sender, to, &r#type, payload, priority, ttl_hours);

            if send {
                match harbor::send_bottle(&harbor_addr, &bottle) {
                    Ok(response) => {
                        let resp: serde_json::Value =
                            serde_json::from_str(&response).unwrap_or_default();
                        let status = resp.get("status").and_then(|s| s.as_str()).unwrap_or("?");
                        let msg = resp.get("message").and_then(|s| s.as_str()).unwrap_or("");
                        if status == "ok" {
                            println!("✓ Bottle sent to harbor");
                            println!("  UUID: {}", bottle.uuid);
                            println!("  To:   {}", bottle.recipient);
                            println!("  Type: {}", bottle.r#type);
                            if !msg.is_empty() {
                                println!("  Harbor: {msg}");
                            }
                        } else {
                            println!("⚠ Harbor responded: {status}: {msg}");
                            println!("  Falling back to local storage...");
                            fallback_write_local(&bottle);
                        }
                    }
                    Err(e) => {
                        eprintln!("⚠ Harbor unreachable ({e})");
                        eprintln!("  Falling back to local storage...");
                        fallback_write_local(&bottle);
                    }
                }
            } else {
                fallback_write_local(&bottle);
            }
        }

        Command::Get { uuid } => {
            match harbor::get_bottle(&harbor_addr, &uuid) {
                Ok(response) => {
                    let resp: serde_json::Value =
                        serde_json::from_str(&response).unwrap_or_default();
                    let status = resp.get("status").and_then(|s| s.as_str()).unwrap_or("?");
                    if status == "ok" {
                        if let Some(bottles) = resp.get("bottles").and_then(|b| b.as_array()) {
                            for b_json in bottles {
                                if let Some(s) = b_json.as_str() {
                                    if let Ok(b) = serde_json::from_str::<Bottle>(s) {
                                        println!("{}", b.preview());
                                    } else {
                                        println!("{s}");
                                    }
                                }
                            }
                        }
                    } else {
                        let msg = resp.get("message").and_then(|s| s.as_str()).unwrap_or("");
                        eprintln!("⚠ Harbor: {msg}");
                        // Fall back to local
                        match local::get_bottle(&uuid) {
                            Ok(bottle) => {
                                println!("{}", bottle.preview());
                            }
                            Err(e2) => {
                                eprintln!("error: {e2}");
                                process::exit(1);
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("⚠ Harbor unreachable ({e})");
                    eprintln!("  Falling back to local storage...");
                    match local::get_bottle(&uuid) {
                        Ok(bottle) => {
                            println!("{}", bottle.preview());
                        }
                        Err(e2) => {
                            eprintln!("error: {e2}");
                            process::exit(1);
                        }
                    }
                }
            }
        }

        Command::List {
            sender: filter_sender,
            undelivered,
        } => {
            if undelivered {
                // Harbor supports list-undelivered command
                match harbor::list_undelivered(&harbor_addr) {
                    Ok(response) => display_harbor_list_response(&response, &harbor_addr),
                    Err(e) => {
                        eprintln!("⚠ Harbor unreachable ({e})");
                        eprintln!("  Falling back to local storage...");
                        display_local_list(filter_sender.as_deref(), true);
                    }
                }
            } else if let Some(ref s) = filter_sender {
                match harbor::list_bottles(&harbor_addr, s) {
                    Ok(response) => display_harbor_list_response(&response, &harbor_addr),
                    Err(e) => {
                        eprintln!("⚠ Harbor unreachable ({e})");
                        eprintln!("  Falling back to local storage...");
                        display_local_list(Some(s), false);
                    }
                }
            } else {
                // No harbor filter — go local
                eprintln!("ℹ No sender filter; listing local bottles");
                display_local_list(None, false);
            }
        }

        Command::Forward {
            uuid,
            to,
            from,
        } => {
            let forwarder = get_sender(from.as_deref());

            // Harbor doesn't have a forward command — we do it locally
            // First try to read from harbor, then rewrite
            match harbor::get_bottle(&harbor_addr, &uuid) {
                Ok(response) => {
                    let resp: serde_json::Value =
                        serde_json::from_str(&response).unwrap_or_default();
                    let status = resp.get("status").and_then(|s| s.as_str()).unwrap_or("?");
                    if status == "ok" {
                        if let Some(bottles) = resp.get("bottles").and_then(|b| b.as_array()) {
                            for b_json in bottles {
                                if let Some(s) = b_json.as_str() {
                                    if let Ok(mut bottle) =
                                        serde_json::from_str::<Bottle>(s)
                                    {
                                        bottle.hop_count += 1;
                                        bottle.recipient = to.clone();
                                        bottle.sender = forwarder.clone(); // update sender for the forward
                                        // Send the forwarded bottle to harbor
                                        match harbor::send_bottle(&harbor_addr, &bottle) {
                                            Ok(_) => {
                                                println!("✓ Bottle forwarded via harbor");
                                                println!("  UUID: {}", bottle.uuid);
                                                println!("  To:   {}", bottle.recipient);
                                            }
                                            Err(e) => {
                                                eprintln!("⚠ Could not send forwarded bottle to harbor ({e})");
                                                fallback_write_local(&bottle);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        eprintln!("⚠ Harbor: bottle not found, trying local...");
                        forward_local(&uuid, &to, &forwarder);
                    }
                }
                Err(e) => {
                    eprintln!("⚠ Harbor unreachable ({e})");
                    eprintln!("  Falling back to local forward...");
                    forward_local(&uuid, &to, &forwarder);
                }
            }
        }

        Command::Toss { uuid } => {
            // Harbor doesn't have a delete command — just remove locally
            match local::toss_bottle(&uuid) {
                Ok(_) => {
                    println!("✓ Bottle {uuid} tossed from local storage");
                    eprintln!("Note: harbor has no toss command; bottle may still exist there.");
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    process::exit(1);
                }
            }
        }

        Command::Summary => {
            match harbor::get_bottle(&harbor_addr, "") {
                Ok(_) => {
                    // Harbor doesn't have a summary command. Show what we can.
                    println!("🔍 Bottle Summary");
                    println!("─────────────────");
                    println!("Harbor is at {harbor_addr}");
                    println!("Use `bottle list --undelivered` to see harbor bottles.");
                    println!();
                    println!("Local bottles:");
                    match local::get_summary() {
                        Ok(summary) => println!("{summary}"),
                        Err(e) => eprintln!("error: {e}"),
                    }
                }
                Err(_) => {
                    eprintln!("ℹ Harbor unreachable — showing local summary only.\n");
                    match local::get_summary() {
                        Ok(summary) => println!("{summary}"),
                        Err(e) => {
                            eprintln!("error: {e}");
                            process::exit(1);
                        }
                    }
                }
            }
        }
    }
}

fn fallback_write_local(bottle: &Bottle) {
    match local::write_bottle(bottle) {
        Ok(path) => {
            println!("✓ Bottle written to local file");
            println!("  Path: {}", path.display());
            println!("  UUID: {}", bottle.uuid);
        }
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

fn forward_local(uuid: &str, new_recipient: &str, forwarder: &str) {
    match local::get_bottle(uuid) {
        Ok(mut bottle) => {
            bottle.hop_count += 1;
            bottle.recipient = new_recipient.to_string();
            bottle.sender = forwarder.to_string();
            if let Err(e) = local::toss_bottle(uuid) {
                eprintln!("warning: could not remove original bottle: {e}");
            }
            match local::write_bottle(&bottle) {
                Ok(path) => {
                    println!("✓ Bottle forwarded locally");
                    println!("  Path: {}", path.display());
                    println!("  UUID: {}", bottle.uuid);
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    process::exit(1);
                }
            }
        }
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}

fn display_harbor_list_response(response: &str, harbor_addr: &str) {
    let resp: serde_json::Value = serde_json::from_str(response).unwrap_or_default();
    let status = resp.get("status").and_then(|s| s.as_str()).unwrap_or("?");
    if status == "ok" {
        if let Some(bottles) = resp.get("bottles").and_then(|b| b.as_array()) {
            if bottles.is_empty() {
                println!("No bottles found in harbor.");
                return;
            }
            println!("Found {} bottle(s) in harbor:\n", bottles.len());
            for (i, b_str) in bottles.iter().enumerate() {
                if let Some(s) = b_str.as_str() {
                    // Harbor list returns UUIDs, not full bottles — fetch each
                    println!("─── Bottle {} ───", i + 1);
                    println!("  UUID: {s}");
                    // Optionally fetch details
                    match harbor::get_bottle(harbor_addr, s) {
                        Ok(detail) => {
                            let d: serde_json::Value =
                                serde_json::from_str(&detail).unwrap_or_default();
                            if let Some(b_arr) = d.get("bottles").and_then(|b| b.as_array()) {
                                for bj in b_arr {
                                    if let Some(bs) = bj.as_str() {
                                        if let Ok(b) = serde_json::from_str::<Bottle>(bs) {
                                            println!("  From:      {}", b.sender);
                                            println!("  To:        {}", b.recipient);
                                            println!("  Type:      {}", b.r#type);
                                            println!("  Priority:  P{}", b.priority);
                                            let preview = if b.payload.len() > 80 {
                                                format!("{}...", &b.payload[..77])
                                            } else {
                                                b.payload.clone()
                                            };
                                            println!("  Message:   {preview}");
                                            println!();
                                        }
                                    }
                                }
                            }
                        }
                        Err(_) => {
                            println!();
                        }
                    }
                }
            }
        }
    } else {
        let msg = resp.get("message").and_then(|s| s.as_str()).unwrap_or("unknown");
        eprintln!("⚠ Harbor error: {msg}");
    }
}

fn display_local_list(sender: Option<&str>, undelivered: bool) {
    match local::list_bottles(sender, undelivered) {
        Ok(bottles) => {
            if bottles.is_empty() {
                println!("No bottles found.");
                return;
            }
            println!("Found {} bottle(s):\n", bottles.len());
            for (i, b) in bottles.iter().enumerate() {
                let expiry = if b.is_expired() { " (EXPIRED)" } else { "" };
                println!("─── Bottle {} ───{}", i + 1, expiry);
                println!("{}", b.preview());
                println!();
            }
        }
        Err(e) => {
            eprintln!("error: {e}");
            process::exit(1);
        }
    }
}
