# Lemon — Goals (living)

## North star
Build Lemon into a fully featured **agent harness** (Pi / OpenCode-ish) with an Elixir/BEAM core for:
- coordination
- communication
- cooperation
- modular extensibility (plugins)

## Near-term themes
- Clear modular architecture boundaries (core vs plugins vs clients)
- Plugin system targeting the **Elixir backend** first
- Strong harness primitives: sessions, tools, memory, files, subprocess, streaming
- Good DX: docs, examples, tests, reproducible dev setup

## Stretch goals
- Plugins in multiple languages (defined by a stable RPC/ABI)
- Multi-agent orchestration patterns (plans, roles, delegations, consensus)

## Current big idea: plugin system
- First-class backend plugin API (Elixir behaviours + supervised processes)
- Define plugin capabilities (tools, hooks, providers)
- Consider language-agnostic plugin RPC as a later layer (gRPC/stdio JSON-RPC/etc)
