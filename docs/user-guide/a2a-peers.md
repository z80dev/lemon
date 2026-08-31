# Persistent A2A peer conversations

Lemon implements the A2A v1.0 JSON-RPC protocol in both directions. A Lemon
agent can receive work from Hermes or another A2A peer, and the built-in
`peer` tool can initiate or resume a long-running conversation with a
configured peer.

This is separate from named execution nodes. A named node moves one Lemon run
to another machine; an A2A peer remains an independent agent with its own
identity, memory, tools, and task lifecycle.

## What persists

For every configured peer, Lemon stores a default outbound A2A context. Calling
the `peer` tool with `action = "message"` reuses that context automatically.
`action = "new"` is the explicit escape hatch for starting a separate chat.

Inbound A2A `contextId` values are mapped to stable private Lemon sessions.
The remote value is hashed before it enters the session key, so a peer cannot
select or discover an arbitrary Lemon session. Contexts, messages, task state,
run IDs, and turn counts use the canonical Lemon store and survive a runtime
restart when the configured store is durable.

## Lemon configuration

Store a shared bearer token in Lemon's encrypted secret store:

```bash
lemon secrets set a2a/hermes '<random-token>'
```

Then add this to `~/.lemon/config.toml`:

```toml
[gateway]
enable_a2a = true

[gateway.a2a]
host = "127.0.0.1"
port = 9901
public_url = "http://127.0.0.1:9901"
name = "Lemon"
agent_id = "default"
skills = ["coordination", "coding"]
reply_timeout_ms = 300000
rate_limit_per_minute = 60
max_context_turns = 100

[gateway.a2a.peers.hermes]
url = "http://127.0.0.1:9900"
token_secret = "a2a/hermes"
agent_id = "default"
capabilities = ["coordination", "coding"]
timeout_ms = 300000
```

`token_secret` is used in both directions. Use `inbound_token_secret` and
`outbound_token_secret` when the peer uses different credentials. Literal
tokens are not accepted in this section.

The listener is tokenless only when it is bound to a direct loopback address
and no inbound token secret is configured. A non-loopback listener fails
validation unless at least one inbound peer token secret is present. Across
machines, use HTTPS/WSS termination or a verified encrypted overlay and set
`public_url` to the URL peers can actually reach.

## Hermes configuration

Hermes' A2A platform listens on port 9900 by default. Its configuration shape
is:

```yaml
gateway:
  platforms:
    a2a:
      enabled: true
      extra:
        port: 9900

a2a_agents:
  lemon:
    url: "http://127.0.0.1:9901"
    auth:
      type: bearer
      token: "<same-random-token>"
    timeout: 300
    capabilities:
      - coordination
      - coding
```

Configure Hermes' inbound bearer token according to its A2A plugin settings,
then restart both runtimes. The Lemon Agent Card is available at
`http://127.0.0.1:9901/.well-known/agent-card.json`; Hermes exposes the same
well-known path on port 9900.

## Agent usage

The `peer` tool actions are:

- `list`: configured peers and their current default context.
- `discover`: fetch the peer's Agent Card.
- `message`: send a message in the persistent default conversation.
- `new`: start and select a new conversation.
- `history`: read Lemon's durable local transcript for a context.
- `status`: refresh a remote task.
- `cancel`: request remote task cancellation.

For example, an agent can call:

```json
{"action":"message","peer_id":"hermes","text":"Please investigate the failing release and report evidence here."}
```

The next `message` call to `hermes` resumes the same context without the model
having to retain or repeat a context ID.

## Wire surface and safety

Lemon publishes canonical and legacy Agent Card paths and accepts the A2A v1.0
methods `SendMessage`, `SendStreamingMessage`, `GetTask`, `ListTasks`,
`CancelTask`, and `SubscribeToTask`, plus the standard lowercase aliases.
Streaming uses reconnectable server-sent events. Runs continue under a task
supervisor if the initiating HTTP or SSE connection closes.

Every task lookup/list/cancel operation is scoped to the authenticated peer.
Inbound peer text is wrapped as external untrusted content before model use.
Outbound responses are returned to the Lemon model with `trust: :untrusted`.
Inbound runs use a conservative read/coordination tool allowlist by default;
`allow_tools` can broaden it for one explicitly trusted peer.

Push notification callbacks are not advertised in v1 because Lemon does not
currently accept callback URLs. Peers should use synchronous send, streaming,
or `SubscribeToTask`/`GetTask` reattachment.
