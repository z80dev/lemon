# WASM-Sandboxed Foundry Tools
## Secure Agent Access to Ethereum Signing

---

## The Problem

- AI agents are increasingly autonomous
- They need to interact with blockchains: send transactions, deploy contracts, sign messages
- These operations require **private keys**
- Giving an agent direct access to a private key is an unacceptable security risk
- A single prompt injection or tool vulnerability = key exfiltration

---

## What We Built

Five WASM-sandboxed tools wrapping Foundry's `cast` and `forge` CLI:

| Tool | Operation | Needs Key? |
|------|-----------|------------|
| `cast_call` | Read-only contract call | No |
| `cast_send` | Sign & broadcast transaction | Yes |
| `cast_wallet_sign` | Sign message / EIP-712 data | Yes |
| `forge_script` | Run deployment script | Yes |
| `forge_create` | Deploy a contract | Yes |

---

## The Key Insight: Secret Placeholders

The WASM tool **never sees the private key**.

It builds a command with a placeholder:

```
cast send 0xAbC... --private-key {{SECRET:ETH_PRIVATE_KEY}}
```

The string `{{SECRET:ETH_PRIVATE_KEY}}` is all the tool knows.

The host runtime resolves it **outside the sandbox**.

---

## Execution Flow

```
Agent (LLM)
    |
    |  "Send 1 ETH to 0xAbC..."
    v
WASM Tool (sandboxed)
    |
    |  Validates inputs
    |  Builds args with {{SECRET:...}} placeholder
    |  Calls exec-command("cast", args, env, timeout)
    v
Host Runtime (trusted, outside sandbox)
    |
    |  Validates program against allowlist
    |  Validates subcommand ("send") is permitted
    |  Checks for blocked flags ("--interactive")
    |  Resolves {{SECRET:ETH_PRIVATE_KEY}} from secrets store
    |  Executes cast via direct process spawn (no shell)
    |  Captures stdout/stderr
    |  Scans output for leaked secret values -> [REDACTED]
    v
Sanitized result returned to WASM tool
    |
    v
Formatted output returned to agent
```

---

## Security Layer 1: Capability Allowlists

Each tool declares exactly what it can execute in a capabilities file:

```json
{
  "exec": {
    "allowlist": [
      {
        "program": "cast",
        "allowed_subcommands": ["send"],
        "blocked_flags": ["--interactive"]
      }
    ]
  }
}
```

- Only listed programs can run
- Only listed subcommands within those programs
- Dangerous flags explicitly blocked
- The tool cannot modify its own capabilities

---

## Security Layer 2: Secret Isolation

The WASM sandbox interface provides exactly two secret-related operations:

| Operation | What it does |
|-----------|-------------|
| `secret-exists(name)` | Returns true/false. That's it. |
| `{{SECRET:name}}` in exec args | Host resolves outside sandbox |

There is **no** `secret-read` or `secret-resolve` function. The tool can check if a key exists to give the user a helpful error message, but it cannot retrieve the value.

---

## Security Layer 3: Output Sanitization

After the host executes `cast` with the real private key:

1. Capture stdout and stderr
2. Scan both for every resolved secret value
3. Replace any matches with `[REDACTED]`
4. Return sanitized output to the WASM sandbox

Even if `cast` accidentally prints the key in a verbose error, the WASM tool and the agent never see it.

---

## Security Layer 4: Resource Limits

Every WASM tool execution is constrained:

| Resource | Limit |
|----------|-------|
| Memory | 10 MB |
| CPU (fuel) | 10,000,000 operations |
| Timeout | 60 seconds (epoch-based) |
| Exec rate | 10/minute (configurable per tool) |
| Log entries | 1,000 per execution |

A buggy or malicious tool cannot infinite loop, exhaust memory, or flood the system.

---

## Security Layer 5: User Approval

Tools with `exec` capability require user approval before first invocation.

The Elixir policy layer checks:

```elixir
def capability_requires_approval?(capabilities) do
  get_cap(capabilities, :http) or
    get_cap(capabilities, :tool_invoke) or
    get_cap(capabilities, :exec)
end
```

The agent can discover and describe these tools, but cannot silently invoke them.

---

## Comparison: HTTP vs CLI Secret Injection

This extends an existing pattern. Lemon already injects API tokens into HTTP requests made by WASM tools:

| | HTTP (existing) | CLI Exec (new) |
|---|---|---|
| WASM calls | `http-request(method, url, ...)` | `exec-command(program, args, ...)` |
| Secret injection | Host adds Authorization headers | Host resolves `{{SECRET:name}}` in args/env |
| Allowlist | Host + path patterns | Program + subcommand |
| Output scan | Response body | stdout + stderr |
| Rate limiting | Per-minute / per-hour | Per-minute / per-hour |

Same trust model. Same security boundaries. New capability surface.

---

## Dynamic Key Selection

Users can store multiple keys and select at invocation time:

```json
{
  "to": "0xAbC...",
  "rpc_url": "https://eth.llamarpc.com",
  "secret_name": "DEPLOYER_KEY"
}
```

The tool uses `{{SECRET:DEPLOYER_KEY}}` instead of the default `{{SECRET:ETH_PRIVATE_KEY}}`.

Capabilities files support wildcard patterns:

```json
{ "allowed_names": ["ETH_*", "DEPLOYER_*"] }
```

---

## Architecture: The WIT Interface

The host-guest contract is defined in WebAssembly Interface Types (WIT):

```wit
record exec-result {
    exit-code: s32,
    stdout: string,     // sanitized
    stderr: string,     // sanitized
}

exec-command: func(
    program: string,
    args-json: string,
    env-json: string,
    timeout-ms: option<u32>,
) -> result<exec-result, string>;
```

Args are a JSON array of strings. No shell. No interpolation. Direct process exec.

---

## What a Tool Looks Like (cast_send)

```rust
// Build args with secret placeholder
args.push("--private-key".to_string());
args.push(format!("{{{{SECRET:{secret_name}}}}}"));

// Call host to execute
let result = host::exec_command(
    "cast", &args_json, "{}", Some(60_000)
)?;

// Tool gets sanitized output -- key is [REDACTED] if it appeared
```

The tool is ~200 lines of Rust. Input validation, arg construction, host call, output formatting. That's it.

---

## Not Just Foundry

The `exec-command` capability is generic. Any CLI tool that needs secret injection:

- `gpg --sign` with a passphrase
- `aws sts assume-role` with credentials
- `ssh-keygen` with key material
- `openssl` operations
- Any custom signing tool

Same pattern: declare the program in capabilities, use `{{SECRET:name}}` placeholders, let the host handle resolution and sanitization.

---

## The Broader Vision

Agents will need access to secrets. API keys, signing keys, tokens, credentials.

The question is not whether -- it is **how**.

WASM sandboxing with host-mediated secret injection provides:

- **Capability-based access control**: tools declare what they need
- **Least privilege**: tools get exactly what their capabilities allow, nothing more
- **Defense in depth**: allowlists + isolation + sanitization + rate limits + approval
- **Auditability**: every invocation logged with telemetry
- **Extensibility**: write a WASM tool, ship a capabilities file, done

---

## Summary

| What | How |
|------|-----|
| Private keys stay safe | Secret placeholders, host-side resolution |
| Tools can't go rogue | Program + subcommand allowlists |
| Output can't leak secrets | Post-execution sanitization scan |
| Resources are bounded | Fuel, memory, timeout, rate limits |
| Users stay in control | Exec capability requires approval |
| Multiple keys supported | Dynamic `secret_name` with wildcard patterns |
| Not Foundry-specific | Generic `exec-command` host capability |
