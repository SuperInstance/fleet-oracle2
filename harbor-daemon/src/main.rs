mod bottle;
mod cli;
mod store;

use chrono::Utc;
use clap::Parser;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::RwLock;
use tokio::time;

use cli::{format_response, parse_inbound, process_command, InboundMessage};
use store::{SharedStore, Store};

/// Harbor Daemon — lightweight bottle message listener for the fleet.
#[derive(Parser, Debug)]
#[command(name = "harbor-daemon", version, about)]
struct Args {
    /// TCP port for bottle messages and command retrieval.
    #[arg(long, default_value = "8796")]
    port: u16,

    /// Port for HTTP health endpoint.
    #[arg(long, default_value = "8797")]
    health_port: u16,

    /// Data directory for JSONL storage.
    #[arg(long, default_value = "./harbor/")]
    data_dir: PathBuf,

    /// TTL in hours for bottle expiry (default when no expires_at is provided).
    #[arg(long, default_value = "24")]
    ttl_hours: u64,

    /// GC interval in seconds.
    #[arg(long, default_value = "60")]
    gc_interval: u64,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    eprintln!(
        "[{}] Harbor Daemon starting — TCP port {}, health port {}, data dir {}",
        Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
        args.port,
        args.health_port,
        args.data_dir.display()
    );

    // Initialize store
    let store = match Store::new(&args.data_dir) {
        Ok(s) => SharedStore::new(s),
        Err(e) => {
            eprintln!(
                "[{}] FATAL: Failed to initialize store: {}",
                Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                e
            );
            std::process::exit(1);
        }
    };

    // Keep a count for the health endpoint
    let bottle_count: Arc<RwLock<usize>> = Arc::new(RwLock::new(0));
    {
        let cnt = store.bottle_count().await;
        *bottle_count.write().await = cnt;
    }

    let store_gc = store.clone();
    let gc_interval = args.gc_interval;
    let bc_gc = bottle_count.clone();

    // --- Background GC task ---
    tokio::spawn(async move {
        let mut interval = time::interval(Duration::from_secs(gc_interval));
        loop {
            interval.tick().await;
            let removed = store_gc.gc().await;
            let cnt = store_gc.bottle_count().await;
            *bc_gc.write().await = cnt;
            if removed > 0 {
                eprintln!(
                    "[{}] GC removed {} expired bottles ({} remaining)",
                    Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                    removed,
                    cnt
                );
            }
        }
    });

    // --- TCP bottle listener ---
    let tcp_addr = format!("0.0.0.0:{}", args.port);
    let tcp_listener = match TcpListener::bind(&tcp_addr).await {
        Ok(l) => {
            eprintln!(
                "[{}] TCP listener bound to {}",
                Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                tcp_addr
            );
            l
        }
        Err(e) => {
            eprintln!(
                "[{}] FATAL: Failed to bind TCP to {}: {}",
                Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                tcp_addr,
                e
            );
            std::process::exit(1);
        }
    };

    let store_tcp = store.clone();
    let bc_tcp = bottle_count.clone();

    tokio::spawn(async move {
        loop {
            match tcp_listener.accept().await {
                Ok((stream, addr)) => {
                    eprintln!(
                        "[{}] TCP connection from {}",
                        Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                        addr
                    );
                    let store = store_tcp.clone();
                    let bc = bc_tcp.clone();
                    tokio::spawn(async move {
                        handle_tcp_connection(stream, store, bc).await;
                    });
                }
                Err(e) => {
                    eprintln!(
                        "[{}] TCP accept error: {}",
                        Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                        e
                    );
                    // Brief pause to avoid tight loop on persistent error
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    });

    // --- HTTP health listener ---
    let health_addr = format!("0.0.0.0:{}", args.health_port);
    let health_listener = match TcpListener::bind(&health_addr).await {
        Ok(l) => {
            eprintln!(
                "[{}] HTTP health bound to {}",
                Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                health_addr
            );
            l
        }
        Err(e) => {
            eprintln!(
                "[{}] FATAL: Failed to bind HTTP to {}: {}",
                Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                health_addr,
                e
            );
            std::process::exit(1);
        }
    };

    let bc_health = bottle_count.clone();

    loop {
        match health_listener.accept().await {
            Ok((stream, _addr)) => {
                let bc = bc_health.clone();
                tokio::spawn(async move {
                    handle_http_connection(stream, bc).await;
                });
                // We don't log every HTTP hit to avoid noise
            }
            Err(e) => {
                eprintln!(
                    "[{}] HTTP accept error: {}",
                    Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                    e
                );
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
    }
}

/// Handle a single TCP connection: read lines, dispatch bottles/commands.
async fn handle_tcp_connection(
    stream: TcpStream,
    store: SharedStore,
    bottle_count: Arc<RwLock<usize>>,
) {
    let (reader, mut writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        match buf_reader.read_line(&mut line).await {
            Ok(0) => {
                // EOF
                break;
            }
            Ok(_) => {
                // Process the line
                match parse_inbound(&line) {
                    InboundMessage::Bottle(bottle) => {
                        // Validate
                        if let Err(e) = bottle.validate() {
                            let resp = format_response(&bottle::CommandResponse {
                                status: "error".to_string(),
                                message: format!("validation failed: {}", e),
                                bottles: None,
                            });
                            let _ = writer.write_all(&resp).await;
                            continue;
                        }

                        // Store
                        match store.append(bottle).await {
                            Ok(()) => {
                                let cnt = store.bottle_count().await;
                                *bottle_count.write().await = cnt;
                                let resp = format_response(&bottle::CommandResponse {
                                    status: "ok".to_string(),
                                    message: format!("bottle received. {} bottles in harbor", cnt),
                                    bottles: None,
                                });
                                let _ = writer.write_all(&resp).await;
                            }
                            Err(e) => {
                                let resp = format_response(&bottle::CommandResponse {
                                    status: "error".to_string(),
                                    message: format!("store error: {}", e),
                                    bottles: None,
                                });
                                let _ = writer.write_all(&resp).await;
                            }
                        }
                    }
                    InboundMessage::Command(cmd) => {
                        let resp = process_command(&store, &cmd).await;
                        let bytes = format_response(&resp);
                        let _ = writer.write_all(&bytes).await;
                    }
                    InboundMessage::Invalid(reason) => {
                        let resp = format_response(&bottle::CommandResponse {
                            status: "error".to_string(),
                            message: format!("invalid input: {}", reason),
                            bottles: None,
                        });
                        let _ = writer.write_all(&resp).await;
                    }
                }
            }
            Err(e) => {
                eprintln!(
                    "[{}] TCP read error: {}",
                    Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ"),
                    e
                );
                break;
            }
        }
    }
}

/// Handle a single HTTP health check connection.
async fn handle_http_connection(
    stream: TcpStream,
    bottle_count: Arc<RwLock<usize>>,
) {
    let (reader, mut writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);
    let mut request_line = String::new();

    // Read the first line (request line)
    if buf_reader.read_line(&mut request_line).await.is_err() {
        return;
    }

    let request_line = request_line.trim();

    // We only care about GET /health
    if request_line.starts_with("GET /health") {
        let count = *bottle_count.read().await;
        let body = format!(
            r#"{{"status":"ok","bottles":{}}}"#,
            count
        );
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let _ = writer.write_all(response.as_bytes()).await;
    } else {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\nConnection: close\r\n\r\nNot Found\n";
        let _ = writer.write_all(response.as_bytes()).await;
    }
}
