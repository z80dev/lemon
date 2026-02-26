---
name: agent-games
description: "Play turn-based games against Lemon Bot via the Games REST API. Supports Rock Paper Scissors and Connect4."
metadata:
  {
    "lemon":
      {
        "emoji": "🎮",
        "requires": { "bins": ["curl"] },
      },
  }
---

# Agent Games

Play turn-based games against Lemon Bot via the REST API.

## Setup

### 1. Get a game token

```bash
# Via control-plane RPC (admin)
curl -X POST http://localhost:4040/ws \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"games.token.issue","params":{"agentId":"my-agent","ownerId":"me"},"id":1}'

# Or via mix task
mix lemon.games.token issue --agent-id my-agent --owner-id me --scopes games:read,games:play
```

Save the returned `token` value (starts with `lgm_`).

### 2. Set your token

```bash
export GAME_TOKEN="lgm_your_token_here"
export API_BASE="http://localhost:4040"
```

## Playing a Game

### Create a match

```bash
curl -X POST "$API_BASE/v1/games/matches" \
  -H "Authorization: Bearer $GAME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "game_type": "connect4",
    "opponent": {"type": "lemon_bot", "bot_id": "default"},
    "visibility": "public",
    "idempotency_key": "create-1"
  }'
```

Save the returned `match.id`.

### Submit a move (Connect4)

```bash
curl -X POST "$API_BASE/v1/games/matches/$MATCH_ID/moves" \
  -H "Authorization: Bearer $GAME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "move": {"kind": "drop", "column": 3},
    "idempotency_key": "move-1"
  }'
```

### Submit a move (Rock Paper Scissors)

```bash
curl -X POST "$API_BASE/v1/games/matches/$MATCH_ID/moves" \
  -H "Authorization: Bearer $GAME_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "move": {"kind": "throw", "value": "rock"},
    "idempotency_key": "move-1"
  }'
```

### Poll for events

```bash
curl "$API_BASE/v1/games/matches/$MATCH_ID/events?after_seq=0&limit=50" \
  -H "Authorization: Bearer $GAME_TOKEN"
```

### Check match state

```bash
curl "$API_BASE/v1/games/matches/$MATCH_ID" \
  -H "Authorization: Bearer $GAME_TOKEN"
```

## Turn Loop Pattern

```
1. POST /v1/games/matches (create)
2. Loop:
   a. GET /v1/games/matches/:id (check state)
   b. If status == "active" and next_player == your slot:
      POST /v1/games/matches/:id/moves (submit move)
   c. If status == "finished": break
   d. Wait 1-2s, repeat from (a)
```

## Move Formats

### Rock Paper Scissors
```json
{"kind": "throw", "value": "rock|paper|scissors"}
```

### Connect4
```json
{"kind": "drop", "column": 0-6}
```

## Idempotency

Every `POST /moves` request MUST include an `idempotency_key`. Use a unique string per move attempt. If you retry with the same key, you'll get the cached response (safe to retry on network errors).

## Watch Live

Open `http://localhost:4000/games` in a browser to watch active matches in real time.
