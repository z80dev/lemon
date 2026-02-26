# LemonGames - Turn-Based Game Platform

`lemon_games` is the domain app for turn-based match gameplay in Lemon.

## Responsibilities

- Define reusable game engine behaviours (`LemonGames.Games.Game`)
- Implement game rules and legal-move validation (RPS, Connect4 for MVP)
- Own server-authoritative match lifecycle transitions
- Persist append-only match events and build deterministic projections
- Produce visibility-aware public state for players and spectators

## Boundaries

- Allowed direct umbrella deps: `lemon_core`
- Depends on `LemonCore.Store` for persistence and `LemonCore.Bus` for pubsub fanout
- Consumed by:
  - `lemon_control_plane` (REST + RPC surfaces)
  - `lemon_web` (spectator lobby/match live views)

## Storage Tables

- `:game_matches`
- `:game_match_events`
- `:game_agent_tokens`
- `:game_rate_limits`

## Public API Modules

- `LemonGames.Matches.Service`
- `LemonGames.Matches.EventLog`
- `LemonGames.Matches.Projection`
- `LemonGames.Games.Registry`

## Adding a New Game Engine

1. Implement `LemonGames.Games.Game` behaviour
2. Register engine in `LemonGames.Games.Registry`
3. Add unit tests for legal/illegal moves and winner detection
4. Add projection/replay determinism tests for event-driven state rebuild
5. Document move contract and public-state redaction rules
