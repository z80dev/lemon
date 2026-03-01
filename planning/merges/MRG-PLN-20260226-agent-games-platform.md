---
id: MRG-PLN-20260226-agent-games-platform
plan_id: PLN-20260226-agent-games-platform
status: ready
---

# Merge: Agent Games Platform

## Plan
- **ID:** PLN-20260226-agent-games-platform
- **Title:** Agent-vs-Agent Game Platform (REST API + Live Spectator Web)
- **Owner:** janitor
- **Reviewer:** janitor
- **Branch:** `feature/pln-20260226-agent-games-platform`

## Changes

### New App: `apps/lemon_games/`
- Domain logic for turn-based games
- Event-sourced match state management
- Game engines (RockPaperScissors, Connect4)
- Auth, rate limiting, bot players

### REST API (`apps/lemon_control_plane/`)
- `POST /v1/games/matches` - Create match
- `GET /v1/games/matches/:id` - Get match state
- `POST /v1/games/matches/:id/accept` - Accept match
- `POST /v1/games/matches/:id/moves` - Submit move
- `GET /v1/games/matches/:id/events` - Poll events
- `GET /v1/games/lobby` - List matches
- JSON-RPC admin methods for token management

### LiveView UI (`apps/lemon_web/`)
- `/games` - Lobby page
- `/games/:id` - Match spectator page
- Bus-driven live updates

### Documentation
- `docs/games-platform.md`
- `apps/lemon_games/AGENTS.md`
- `apps/lemon_games/README.md`

## Test Results

```
apps/lemon_games: 86 tests, 0 failures
apps/lemon_control_plane/test/lemon_control_plane/http/games_api_test.exs: 45 tests, 0 failures
apps/lemon_web/test/lemon_web/live/games_live_test.exs: 5 tests, 0 failures
```

## Pre-Landing Checklist

- [x] Code review completed (RVW-PLN-20260226-agent-games-platform.md)
- [x] All tests pass
- [x] Documentation complete
- [x] Success criteria met
- [x] No breaking changes to existing functionality

## Landing Commands

```bash
# Ensure on main and up to date
git checkout main
git pull origin main

# Merge the feature branch
git merge --no-ff feature/pln-20260226-agent-games-platform -m "feat: agent games platform (REST API + LiveView spectator)

Implements turn-based game platform with:
- Event-sourced match state
- REST API for external agents
- LiveView spectator UI
- RockPaperScissors and Connect4 games
- Lemon Bot players
- Auth, rate limiting, idempotency

Closes: PLN-20260226-agent-games-platform"

# Push to origin
git push origin main
```

## Post-Landing

- [ ] Deploy to staging
- [ ] Run smoke tests
- [ ] Update CHANGELOG
- [ ] Announce in team channel
