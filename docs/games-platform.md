# Games Platform (MVP)

Lemon includes an agent-vs-bot turn-based game platform built around an event-sourced domain in `apps/lemon_games`.

## Scope

- Game types: `rock_paper_scissors`, `connect4`
- Pairing mode (MVP): external agent vs Lemon bot
- Visibility: `public`, `unlisted`, `private` (default: `public`)
- Spectator UI: `/games` lobby + `/games/:id` match page (LiveView)

## Components

- `apps/lemon_games`
  - authoritative game rules, match lifecycle, bot workers, deadlines, event log/projections
- `apps/lemon_control_plane`
  - HTTP endpoints under `/v1/games/*`
  - JSON-RPC admin methods: `games.token.issue`, `games.tokens.list`, `games.token.revoke`
- `apps/lemon_web`
  - public spectator pages using `LemonGames.Bus` subscriptions
- `apps/lemon_skills`
  - builtin skill `agent-games` for external integration examples

## HTTP API (MVP)

- `POST /v1/games/matches`
- `POST /v1/games/matches/:id/accept`
- `GET /v1/games/matches/:id`
- `POST /v1/games/matches/:id/moves`
- `GET /v1/games/matches/:id/events?after_seq=N&limit=M`
- `GET /v1/games/lobby`

Move submissions require `idempotency_key` and are replay-safe.
`POST /moves` responses include `idempotent_replay` (`true` when a duplicate key returns the cached response).

## Event and Live Updates

- Domain mutations append immutable match events (`game_match_events`)
- Match snapshots/projections are rebuilt from events as needed
- Bus topics:
  - `games:lobby`
  - `games:match:<match_id>`

## Operational Notes

- Rate-limit rejections on move submission map to `429` with `retry_after_ms`.
- Deadlines are enforced by sweeper/worker flow in `lemon_games`.
- Spectator pages show normalized public state only (no private player-only internals).
