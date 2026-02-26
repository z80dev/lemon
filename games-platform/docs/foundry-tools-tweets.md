# Foundry Tools in the WASM Sandbox -- Tweet Thread

---

**1/**

just shipped WASM-sandboxed Foundry tools for Lemon

I tried lots of great agent-wallet integrations but wanted something better for devs

Your agent can call `cast send`, `cast call`, `forge create`, and `forge script` -- and the private key never enters WASM memory.

how it works:

---

**2/**

The problem: AI agents need to sign Ethereum transactions, but giving a tool direct access to your private key is a bad idea. specially a third party tool.

We needed a way to give agents crypto capabilities without giving them keys.

---

**3/**

The solution: secret placeholders.

The WASM tool builds a command like:

```
cast send 0xAbC... --private-key {{SECRET:ETH_PRIVATE_KEY}}
```

The tool literally writes the string `{{SECRET:ETH_PRIVATE_KEY}}`. It has no idea what the actual key is.

---

**4/**

The host runtime -- running outside the sandbox -- intercepts that placeholder, resolves it from the secrets store, and passes the real args to `cast` via direct process exec (no shell).

The WASM tool never sees the resolved value. Not in args. Not in output. Nowhere.

---

**5/**

What about output? If `cast` accidentally prints the key in an error message, the host catches that too.

Before returning stdout/stderr to the WASM sandbox, every resolved secret value is scanned for and replaced with `[REDACTED]`.

---

**6/**

Each tool ships with a capabilities file that acts as its security policy:

- Which programs it can exec (`cast`, `forge`)
- Which subcommands are allowed (`send`, not `bind`)
- Which flags are blocked (`--interactive`)
- Rate limits (10 txns/min)

The tool can't change its own permissions.

---

**7/**

This is the same pattern we already use for HTTP credentials.

When a WASM tool makes an API call, the host injects Bearer tokens into headers. The tool never sees the token. We just extended that pattern to CLI execution.

HTTP credential injection -> CLI secret injection. Same idea, new surface.

---

**8/**

The five tools we shipped:

- `cast_call` -- read-only contract calls (no key needed)
- `cast_send` -- sign and broadcast transactions
- `cast_wallet_sign` -- sign messages and EIP-712 typed data
- `forge_script` -- run deployment scripts
- `forge_create` -- deploy contracts

All WASM-sandboxed. All secret-safe.

---

**9/**

Dynamic key selection: you can store multiple keys and tell the tool which one to use.

```json
{ "to": "0x...", "secret_name": "DEPLOYER_KEY" }
```

The capabilities file allows wildcard patterns (`DEPLOYER_*`) so you don't need to enumerate every key name upfront.

---

**10/**

The broader point: agents are going to need access to secrets. API keys, signing keys, tokens. The question isn't whether -- it's how.

WASM sandboxing with host-mediated secret injection gives you capability-based access control for agent tools. The tool declares what it needs. The host enforces what it gets.

---

**11/**

This is all open and extensible. The `exec-command` host capability is generic -- it's not Foundry-specific. Anyone can write a WASM tool that wraps a CLI program with the same secret isolation pattern.

`gpg sign`, `ssh-keygen`, `aws sts` -- same model applies.

---

**12/**

All five tools compile to `wasm32-unknown-unknown`, run in Wasmtime with fuel metering (10M ops), memory limits (10MB), and epoch-based timeouts.

A buggy tool can't infinite loop. It can't OOM. It can't hang. And it definitely can't read your keys.
