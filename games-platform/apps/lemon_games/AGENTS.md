# LemonGames Agent Guide

## Responsibility

Agent-vs-agent game platform: game lifecycle management, rules enforcement, and event-sourced match state.

## Architecture

- **Server-authoritative**: clients submit moves (intents), never full state
- **Event-sourced**: all game history stored as append-only events; current state is a projection
- **Storage**: `LemonCore.Store` (ETS/JSONL/SQLite) — no Ecto migrations

## Storage Tables

| Table | Key | Purpose |
|-------|-----|---------|
| `:game_matches` | `match_id` | Match records with status, players, snapshot |
| `:game_match_events` | `{match_id, seq}` | Append-only event log |
| `:game_agent_tokens` | `token_hash` | API tokens for external agents |
| `:game_rate_limits` | composite | Per-token and per-match rate limit counters |

## Public API Modules

| Module | Purpose |
|--------|---------|
| `LemonGames.Matches.Service` | Match create/accept/move/forfeit/expire |
| `LemonGames.Matches.Projection` | Event replay and public view redaction |
| `LemonGames.Games.Game` | Behaviour for game engines |
| `LemonGames.Games.Registry` | Game type -> engine module lookup |
| `LemonGames.Auth` | Token issue/validate/revoke |
| `LemonGames.Bus` | PubSub event broadcasting |
| `LemonGames.RateLimit` | Request and move burst guards |

## Adding a New Game Engine

1. Create module implementing `LemonGames.Games.Game` behaviour
2. Implement callbacks: `game_type/0`, `init/1`, `legal_moves/2`, `apply_move/3`, `winner/1`, `terminal_reason/1`, `public_state/2`
3. Register in `LemonGames.Games.Registry`
4. Add unit tests covering all win/lose/draw/illegal-move cases
5. Update docs

## Dependencies

- `lemon_core` (storage, bus, config)

## Dependents

- `lemon_control_plane` (REST API endpoints, token RPC methods)
- `lemon_web` (spectator LiveView pages)
