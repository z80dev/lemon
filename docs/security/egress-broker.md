# Enforced terminal sandbox and egress credential broker

Status: implementation design; human security review is required before production use.

## Authority and threat model

`sandbox: true` is a sticky tool-policy restriction: intersection is logical OR.
It forces terminal launches through Docker, irrespective of the requested backend.
The attacker controls the command, its descendants, environment overrides and all
workspace files. The trusted computing base is Lemon/OTP, Docker and the host
kernel, the operator-selected image, and the operator's broker configuration.
This is a terminal boundary, not a claim that every Lemon tool runs in Docker.
Do not grant host-executing tools (eval, extensions, browser/node execution, etc.)
to an untrusted principal merely because its terminal policy is sandboxed.

## Network enforcement

The sandbox always uses `--network none`, the host broker owner's numeric UID/GID,
drops all capabilities and enables no-new-privileges. It never mounts the Docker
socket or host network namespace. A read-only mount exposes a run-private Unix-domain proxy socket and public CA
certificate, not the host filesystem. A small Python 3 adapter in the container
bridges loopback HTTP proxy connections to that socket. The selected sandbox
image must contain Python 3 and its ordinary CA bundle; missing prerequisites
fail closed. Clearing `HTTPS_PROXY`, killing/replacing the adapter or opening raw
TCP/UDP sockets cannot create an external network route. The default ordinary
Docker backend/image is unchanged.
Host Unix socket bind mounts must work in the selected Docker installation.
Linux Docker supports this directly; Docker Desktop/remote daemons that cannot
forward that socket are unsupported and fail closed, not switched to bridge or
host networking.


Lemon accepts only HTTP CONNECT requests with an exact operator-allowlisted DNS
host and port. No wildcard, suffix, caller-selected upstream, arbitrary forward
HTTP, redirect following or client DNS resolution is used. Connections to hosts
without a secret are opaque tunnels. For bound hosts the proxy terminates TLS,
checks HTTP authority against CONNECT, and connects to the same upstream using
normal certificate verification and hostname verification. Operators must not
allowlist services that themselves offer an open proxy, arbitrary URL fetch or
credential-reflection/transformation API. DNS and trusted upstream compromise
are outside this boundary; do not allowlist internal management services.

## Credential handling and TLS

Bindings contain secret references, never values. Only the host broker resolves
`LemonCore.Secrets`; the configured header replaces any client copy. Secrets,
master keys and CA private keys never enter container environment, argv or
mounted files. A fresh per-boot CA and leaf certificates are created with OTP
`:public_key`; only the public CA is mounted. The CA is valid for ten years but
discarded at VM exit; leaves are valid for 24 hours and never beyond CA expiry.
The container receives trust-store
environment settings for common TLS clients. Applications that ignore these
settings must explicitly trust the mounted CA or fail TLS; verification is never
disabled. No host/system trust store is modified.

For intercepted HTTP/1.1 traffic, requests and responses are bounded by explicit
operator limits. Responses are fully framed before release, decoded transfer
framing is removed and literal secret occurrences in headers/body are replaced
with `[REDACTED]`. Compression, upgrades and unsupported framing are rejected
rather than passing uninspected bytes. No HTTP/2 ALPN is advertised. Encoded,
encrypted, hashed, split across separate responses or otherwise transformed
secret reflections cannot be comprehensively detected; the allowlisted upstream
must be trusted not to deliberately disclose credentials. Redaction does not
prevent an authorized command from using the granted remote capability.

## Lifetime, configuration and limits

Each sandbox launch owns a broker; owner termination closes its listener and
connections. Proxy configuration is operator-owned, not command arguments or
workspace policy. Empty configuration denies every destination. Broker resources
are private temporary files, removed when their owner terminates; stale resources
from a VM/host crash carry only a public certificate, adapter and dead socket. A later
runtime never reuses that CA. Do not place host secret files in the mounted
workspace: workspace read/write access is intentional and is not secret storage.

The broker is in `lemon_core`, alongside secret resolution and terminal backend
contracts, without umbrella dependencies. `coding_agent` owns launch lifetime.
This adds the validated `sandbox` boolean to the published ToolPolicy API.

### Operator setup

Select a locally available Python-equipped Docker image using
`LEMON_DOCKER_TERMINAL_IMAGE` (a reviewed, pinned Python Alpine image, for example).
It must also pass the normal Docker image allowlist. Images are never pulled
automatically. Configure the trusted runtime, not workspace tool input:

```elixir
config :lemon_core, :egress_broker,
  allowlist: [{"api.example.com", 443}, {"downloads.example.com", 443}],
  bindings: %{
    "api.example.com" => %{
      secret: "EXAMPLE_API_TOKEN",
      header: "authorization",
      prefix: "Bearer "
    }
  }
```

The secret reference uses the normal `LemonCore.Secrets.resolve/2` resolution
contract. No binding grants egress by itself; its exact host/port must also be
allowlisted. `header_bytes` (32768), `body_bytes` (8388608), `timeout` (15000 ms)
and `max_connections` (32) are operator resource policies, not protocol limits.
Increasing them increases host memory/connection exposure. With no configuration,
all CONNECT destinations are denied.


## Validation and review

Normal ExUnit tests use local TLS upstreams and Unix sockets, never Docker.
Command-construction tests prove network isolation and absence of broker secret
material from Docker argv/environment. Opt-in `:docker` tests inspect the actual
container's environment, mounted files and processes, authenticate through the
broker, and attempt direct and disallowed-host egress. These require Docker and
an appropriate Python-equipped image and are excluded by default. The review
criterion is a human action and is not satisfied by writing this document.
