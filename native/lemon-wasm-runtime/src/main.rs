mod capabilities;
mod protocol;
mod runtime;

use std::collections::{HashMap, VecDeque};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::json;

use protocol::{OutboundMessage, Request};
use runtime::{Runtime, RuntimeDefaults};

const PROTOCOL_VERSION: u32 = 1;
const HOST_CALL_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone)]
struct HostCallResultPayload {
    ok: bool,
    output_json: Option<String>,
    error: Option<String>,
}

#[derive(Debug)]
struct RequestQueue {
    rx: Receiver<Request>,
    deferred: VecDeque<Request>,
    pending_host_results: HashMap<String, HostCallResultPayload>,
}

impl RequestQueue {
    fn new(rx: Receiver<Request>) -> Self {
        Self {
            rx,
            deferred: VecDeque::new(),
            pending_host_results: HashMap::new(),
        }
    }

    fn recv_next(&mut self) -> Option<Request> {
        if let Some(req) = self.deferred.pop_front() {
            return Some(req);
        }

        self.rx.recv().ok()
    }

    fn recv_next_timeout(&mut self, timeout: Duration) -> Option<Request> {
        if let Some(req) = self.deferred.pop_front() {
            return Some(req);
        }

        self.rx.recv_timeout(timeout).ok()
    }

    fn stash_deferred(&mut self, req: Request) {
        self.deferred.push_back(req);
    }

    fn store_host_result(&mut self, call_id: String, payload: HostCallResultPayload) {
        self.pending_host_results.insert(call_id, payload);
    }

    fn take_host_result(&mut self, call_id: &str) -> Option<HostCallResultPayload> {
        self.pending_host_results.remove(call_id)
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("fatal sidecar error: {err:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let (tx, rx) = mpsc::channel::<Request>();

    std::thread::spawn(move || {
        let stdin = io::stdin();
        let mut reader = io::BufReader::new(stdin.lock());
        let mut line = String::new();

        loop {
            line.clear();

            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    let trimmed = line.trim();
                    if trimmed.is_empty() {
                        continue;
                    }

                    match serde_json::from_str::<Request>(trimmed) {
                        Ok(req) => {
                            if tx.send(req).is_err() {
                                break;
                            }
                        }
                        Err(err) => {
                            eprintln!("invalid sidecar request: {err}");
                        }
                    }
                }
                Err(err) => {
                    eprintln!("stdin read error: {err}");
                    break;
                }
            }
        }
    });

    let queue = Arc::new(Mutex::new(RequestQueue::new(rx)));
    let call_seq = Arc::new(AtomicU64::new(0));

    let mut runtime = Runtime::new(RuntimeDefaults::default())?;

    loop {
        let request = {
            let mut guard = queue.lock().expect("request queue lock poisoned");
            guard.recv_next()
        };

        let Some(request) = request else {
            break;
        };

        match request {
            Request::Hello { id, version } => {
                if let Some(version) = version {
                    if version != PROTOCOL_VERSION {
                        emit_message(&OutboundMessage::response_err(
                            id,
                            format!(
                                "unsupported protocol version {version}; expected {PROTOCOL_VERSION}"
                            ),
                        ))?;
                        continue;
                    }
                }

                emit_message(&OutboundMessage::response_ok(
                    id,
                    json!({
                        "version": PROTOCOL_VERSION,
                        "name": "lemon-wasm-runtime"
                    }),
                ))?;
            }
            Request::Discover {
                id,
                paths,
                defaults,
            } => {
                let discover_paths = paths.into_iter().map(PathBuf::from).collect();
                let result = runtime.discover(discover_paths, RuntimeDefaults::from(defaults));

                emit_message(&OutboundMessage::response_ok(
                    id,
                    serde_json::to_value(result).context("failed to encode discover response")?,
                ))?;
            }
            Request::Invoke {
                id,
                tool,
                params_json,
                context_json,
            } => {
                let queue_for_host = queue.clone();
                let call_seq_for_host = call_seq.clone();
                let request_id_for_host = id.clone();

                let host_invoke = Arc::new(move |target: String, params: String| {
                    let seq = call_seq_for_host.fetch_add(1, Ordering::Relaxed) + 1;
                    let call_id = format!("host_call_{seq}");

                    emit_message(&OutboundMessage::Event {
                        event: "host_call".to_string(),
                        request_id: request_id_for_host.clone(),
                        call_id: call_id.clone(),
                        tool: target,
                        params_json: params,
                    })
                    .map_err(|err| format!("failed to emit host_call event: {err}"))?;

                    wait_for_host_call_result(&queue_for_host, &call_id)
                });

                match runtime.invoke(&tool, &params_json, context_json, host_invoke) {
                    Ok(result) => emit_message(&OutboundMessage::response_ok(
                        id,
                        serde_json::to_value(result).context("failed to encode invoke response")?,
                    ))?,
                    Err(err) => {
                        emit_message(&OutboundMessage::response_err(id, err.to_string()))?;
                    }
                }
            }
            Request::HostCallResult {
                id,
                call_id,
                ok,
                output_json,
                error,
            } => {
                let payload = HostCallResultPayload {
                    ok,
                    output_json,
                    error,
                };

                let mut guard = queue.lock().expect("request queue lock poisoned");
                guard.store_host_result(call_id, payload);

                emit_message(&OutboundMessage::response_ok(id, json!({"accepted": true})))?;
            }
            Request::Shutdown { id } => {
                emit_message(&OutboundMessage::response_ok(id, json!({"stopped": true})))?;
                break;
            }
        }
    }

    Ok(())
}

fn wait_for_host_call_result(
    queue: &Arc<Mutex<RequestQueue>>,
    target_call_id: &str,
) -> std::result::Result<String, String> {
    let deadline = Instant::now() + HOST_CALL_TIMEOUT;

    loop {
        let maybe_req = {
            let mut guard = queue
                .lock()
                .map_err(|_| "request queue lock poisoned".to_string())?;

            if let Some(payload) = guard.take_host_result(target_call_id) {
                return host_result_payload_to_result(payload);
            }

            let now = Instant::now();
            if now >= deadline {
                return Err(format!(
                    "timed out waiting for host_call_result for {target_call_id}"
                ));
            }

            let remaining = deadline.saturating_duration_since(now);
            guard.recv_next_timeout(remaining)
        };

        let Some(req) = maybe_req else {
            return Err(format!(
                "sidecar input closed while waiting for host_call_result {target_call_id}"
            ));
        };

        match req {
            Request::HostCallResult {
                call_id,
                ok,
                output_json,
                error,
                ..
            } => {
                if call_id == target_call_id {
                    return host_result_payload_to_result(HostCallResultPayload {
                        ok,
                        output_json,
                        error,
                    });
                }

                let payload = HostCallResultPayload {
                    ok,
                    output_json,
                    error,
                };

                let mut guard = queue
                    .lock()
                    .map_err(|_| "request queue lock poisoned".to_string())?;
                guard.store_host_result(call_id, payload);
            }
            other => {
                let mut guard = queue
                    .lock()
                    .map_err(|_| "request queue lock poisoned".to_string())?;
                guard.stash_deferred(other);
            }
        }
    }
}

fn host_result_payload_to_result(
    payload: HostCallResultPayload,
) -> std::result::Result<String, String> {
    if payload.ok {
        Ok(payload.output_json.unwrap_or_else(|| "null".to_string()))
    } else {
        Err(payload
            .error
            .unwrap_or_else(|| "host tool invocation failed".to_string()))
    }
}

fn emit_message(message: &OutboundMessage) -> Result<()> {
    let stdout = io::stdout();
    let mut lock = stdout.lock();

    serde_json::to_writer(&mut lock, message).context("failed to serialize outbound message")?;
    lock.write_all(b"\n")
        .context("failed to write outbound newline")?;
    lock.flush().context("failed to flush outbound message")?;

    Ok(())
}
