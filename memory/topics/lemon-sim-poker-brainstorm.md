# NLHE Poker in LemonSim — Design Brainstorm

## 1. Architecture Fit

Poker maps to lemon_sim's contracts naturally. The framework was designed for exactly this kind of game: sequential decisions, hidden information, well-defined action spaces, and deterministic state updates.

### Contract Mapping

| Contract | Poker Mapping | Fit |
|----------|--------------|-----|
| **State** | Table state: stacks, cards, pots, blinds, positions, hand history | Natural. `world` map holds all of this. |
| **Event** | `deal_hole_cards`, `post_blind`, `bet`, `call`, `raise`, `fold`, `check`, `deal_community`, `showdown`, `hand_result`, `pot_awarded` | Natural. Each discrete game action → one event. |
| **Updater** | Validates bet sizing, enforces action order, computes pots/side pots, resolves showdowns | Natural. Most complex module — all rules live here. Deterministic. |
| **ActionSpace** | Exposes `take_action` tool with legal actions (fold/check/call/raise/all-in). Changes per street and per player context. | Natural. Dynamic tool parameterization per turn. |
| **Projector** | Player sees: own hole cards, community cards, pot, stack sizes, betting history. Does NOT see opponents' hole cards. | Natural. Werewolf pattern — same state, role-filtered views. |
| **Decider** | ToolLoopDecider with `get_game_state` (read) + `take_action` (terminal). Optionally `note` for private journaling. | Natural. Matches existing tool-loop pattern. |
| **DecisionAdapter** | `take_action` returns event payload directly. | Trivial — direct event extraction from tool result. |
| **Runner** | `run_until_terminal` with `terminal?` checking hand/tournament completion. | Natural. Outer loop = hands in a session. Inner loop = betting rounds within a hand. |

### What's Natural

- One player acts per decision turn — poker is inherently sequential within a betting round
- Hidden information (hole cards) → Projector filters, identical to Werewolf's role hiding
- Bounded action space (fold/check/call/raise with specific sizing) → clean ActionSpace
- Deterministic resolution (pot math, hand rankings) → clean Updater
- `active_actor_id` rotation through positions — existing pattern in Stock Market

### What's Tricky

1. **Multi-street hands within a single "game"**: A poker session is many hands. Each hand has 4 streets. Each street has a full betting round. The Runner's `step` = one player decision. A single hand might require 20+ steps. A 100-hand session = 500-2000+ steps. This is fine — Werewolf and Stock Market already handle 300-500 turn games.

2. **Nested phase machine**: Session → Hand → Street → Betting Round → Individual Action. Deeper than most games (Werewolf has Night → Day, two levels). Need a clear phase hierarchy in `world`.

3. **Dealer rotation between hands**: Unlike most games where turn order is fixed, poker rotates the button each hand, which changes blind posting and action order. Tracked as `dealer_seat` in world state, advanced in `hand_result` event handling.

4. **Side pot computation**: Multiple all-in scenarios create layered pots. This is pure algorithmic complexity in the Updater, not a framework mismatch. (See §5.)

---

## 2. Game Structure

### Phase Hierarchy

```
Session (tournament or cash game)
  └─ Hand (one deal → showdown cycle)
       ├─ preflop    (2 hole cards dealt, blinds posted)
       ├─ flop       (3 community cards)
       ├─ turn       (1 community card)
       ├─ river      (1 community card)
       └─ showdown   (hand evaluation, pot distribution)
```

### World State Shape

```elixir
%{
  # Session-level
  status: "in_progress" | "completed",
  game_type: "nlhe_ring" | "nlhe_tournament",
  hand_number: 1,
  max_hands: 100,           # for cash-game-length eval
  small_blind: 25,
  big_blind: 50,
  blind_schedule: [...],    # for tournaments: [{level, sb, bb, ante}, ...]
  blind_level: 1,
  hands_per_level: 10,      # for tournaments

  # Table-level
  seats: %{
    "seat_1" => %{player_id: "player_1", stack: 10_000, status: "active", ...},
    "seat_2" => %{player_id: "player_2", stack: 8_500, status: "active", ...},
    ...
  },
  dealer_seat: "seat_1",

  # Hand-level (reset each hand)
  street: "preflop" | "flop" | "turn" | "river" | "showdown",
  community_cards: [],
  deck: [...],               # remaining deck (hidden from all players)
  hole_cards: %{             # per-player (hidden from opponents)
    "player_1" => ["Ah", "Ks"],
    "player_2" => ["7d", "7c"],
    ...
  },
  pots: [%{amount: 150, eligible: ["player_1", "player_2", ...]}],
  current_bet: 50,
  min_raise: 50,

  # Betting round tracking
  active_actor_id: "player_3",
  action_order: ["player_3", "player_4", "player_1", "player_2"],
  actions_this_street: [],    # [{player_id, action, amount}]
  players_to_act: ["player_3", "player_4"],  # who still needs to act
  last_raiser: nil,

  # History (rolling window, not full — full history in events)
  hand_results: [],           # last N hands summary
  player_stats: %{            # running stats for projection
    "player_1" => %{hands_played: 0, vpip_count: 0, pfr_count: 0, ...},
    ...
  }
}
```

### How the Runner Handles It

**Outer loop**: `run_until_terminal/3` with `terminal?` checking `world.status == "completed"` (session over when max_hands reached or tournament has winner).

**Inner mechanics**: All hand progression lives in the Updater. When a player folds/calls/raises:

1. Updater processes the action event
2. Updater checks: is the betting round complete? (all remaining players have acted, bets are equalized)
3. If round complete → Updater generates derived events: `street_complete`, then `deal_community` (for next street) or `showdown_triggered`
4. Updater sets `active_actor_id` to next player in action
5. Returns `{:decide, next_player_id}` to signal Runner

**Hand boundaries**: When a hand ends (showdown or all fold), the Updater:
1. Distributes pots → `pot_awarded` events
2. Logs `hand_result` event
3. Checks if session should continue
4. If yes → starts new hand: rotates dealer, posts blinds, deals cards → `deal_hole_cards` events
5. Sets `active_actor_id` to first-to-act preflop (UTG)
6. Returns `{:decide, "player_X"}` for first decision of new hand

This is the same pattern as Werewolf's night→day transitions: the Updater handles all phase mechanics internally and just tells the Runner "ok, now this player needs to decide."

### Street Transitions (Updater Logic)

```
Player action (bet/call/raise/check/fold)
  → validate action legality
  → update pots, stacks, betting state
  → check: betting round complete?
    → NO: advance to next player, return {:decide, next_player}
    → YES:
      → check: only one player remaining?
        → YES: award pot, start new hand
        → NO: advance street
          → preflop → flop: deal 3 cards
          → flop → turn: deal 1 card
          → turn → river: deal 1 card
          → river → showdown: evaluate hands, award pots
      → after street advance, return {:decide, first_to_act}
```

---

## 3. Hidden Information

Poker's hidden information is simpler than Werewolf's but more critical to gameplay.

### What's Hidden

| Information | Hidden From | Revealed When |
|-------------|-------------|---------------|
| Hole cards | All other players | Showdown (if player doesn't fold) OR voluntarily shown |
| Deck | Everyone | Never (cards revealed one at a time as community) |
| Opponents' exact hand strength | Everyone | Showdown only |

### Projection Strategy

**Follow the Werewolf pattern exactly:**

1. **All data in world state**: `hole_cards`, `deck`, everything stored in full
2. **Projector filters per-player**: When building `player_1`'s view, only include `hole_cards["player_1"]` — omit all others
3. **Event visibility**: `deal_hole_cards` events are private (each player only sees their own deal). `deal_community` events are public.

```elixir
# In Projector section_builders:
world_state: fn frame, _tools, _opts ->
  actor_id = get(frame.world, :active_actor_id)

  %{
    id: :world_state,
    title: "Table State",
    format: :json,
    content: %{
      your_cards: get_in(frame.world, [:hole_cards, actor_id]),
      community_cards: get(frame.world, :community_cards, []),
      pot: total_pot(frame.world),
      your_stack: get_seat_stack(frame.world, actor_id),
      opponent_stacks: opponent_stacks(frame.world, actor_id),
      current_bet: get(frame.world, :current_bet),
      min_raise: get(frame.world, :min_raise),
      position: get_position_label(frame.world, actor_id),  # "UTG", "CO", "BTN", "SB", "BB"
      street: get(frame.world, :street)
    }
  }
end,

hand_history: fn frame, _tools, _opts ->
  actor_id = get(frame.world, :active_actor_id)

  %{
    id: :hand_history,
    title: "Current Hand Action",
    format: :json,
    content: %{
      actions_this_street: get(frame.world, :actions_this_street),
      # Previous streets' actions (public knowledge)
      preflop_actions: ...,
      flop_actions: ...,
      # Folded players visible, but NOT their cards
      folded_players: folded_player_ids(frame.world)
    }
  }
end
```

### Event Visibility Rules

```elixir
defp event_visible?(event, actor_id, _world) do
  case event.kind do
    :deal_hole_cards ->
      # Only visible to the player being dealt
      get(event.payload, :player_id) == actor_id

    :deal_community -> true   # Public
    :post_blind -> true       # Public
    :bet -> true              # Public
    :call -> true             # Public
    :raise -> true            # Public
    :fold -> true             # Public (but NOT their cards)
    :check -> true            # Public
    :showdown -> true         # Public (reveals cards)
    :pot_awarded -> true      # Public
    :hand_result -> true      # Public
    _ -> true
  end
end
```

### Comparison to Werewolf

| Aspect | Werewolf | Poker |
|--------|----------|-------|
| Hidden info type | Role identity | Hole cards |
| Number of hidden items | 1 per player (role) | 2 per player (cards) |
| Info revealed during play | Via investigations, deaths | Only at showdown |
| Player-to-player private channels | Wolf chat, meetings | None (pure betting signals) |
| Deduction from public actions | Vote patterns → role inference | Bet sizing → hand range inference |

Poker is actually simpler for projection than Werewolf because there's only one type of hidden info (cards) and no private communication channels.

---

## 4. Action Space Design

### Tool Design: Minimal & Clean

Two tools, following the read-then-act pattern from the poker eval research:

#### Tool 1: `get_game_state` (read, non-terminal)

Returns the current game state from the player's perspective. This is technically redundant with the projection (the system prompt already contains this info), but having it as a tool lets the agent "look again" and makes the tool-first pattern consistent.

**Open question**: Is this tool necessary? Stock Market and Werewolf don't have an explicit "read state" tool — the projection IS the state. Including it matches the poker eval research design but adds an extra tool call per turn. **Recommendation: Skip it.** The projection should contain everything. If we want agents to be able to re-examine state, they can do it via the `note` tool which forces them to articulate their reasoning.

#### Tool 2: `take_action` (terminal)

```elixir
%{
  name: "take_action",
  description: "Make your poker action for this betting round.",
  parameters: %{
    type: "object",
    properties: %{
      action: %{
        type: "string",
        enum: legal_actions,  # Dynamic! e.g., ["fold", "check", "call", "raise", "all_in"]
        description: "Your action"
      },
      amount: %{
        type: "integer",
        description: "Bet/raise amount (required for raise, ignored for fold/check/call/all_in)",
        minimum: min_raise,    # Dynamic
        maximum: player_stack  # Dynamic
      },
      thought: %{
        type: "string",
        description: "Private reasoning (not shown to opponents)"
      }
    },
    required: ["action"]
  }
}
```

**Dynamic `enum` based on game state:**
- Can't check if there's a bet to you → no "check" in enum
- Can't raise if you don't have enough chips for min raise → no "raise" in enum (but "all_in" still available)
- Already all-in → no action needed (skip turn in Updater)

#### Tool 3: `note` (optional read tool, non-terminal)

```elixir
%{
  name: "note",
  description: "Write a private note about opponent tendencies, hand ranges, or strategy.",
  parameters: %{
    type: "object",
    properties: %{
      content: %{type: "string", description: "Your note"}
    },
    required: ["content"]
  }
}
```

Stored in `world.journals[player_id]`. Visible only to that player in subsequent hands. Useful for measuring whether agents develop opponent models over multi-hand sessions.

### Legality Validation

ActionSpace provides the broad strokes (which actions are legal, min/max raise). Updater enforces exact rules:
- Raise must be ≥ min raise (2x previous raise or big blind)
- Raise can't exceed player's stack
- Call amount matches current bet minus player's contribution
- Can't act out of turn

If Updater receives an invalid action, it emits `action_rejected` and re-prompts (same as Skirmish's pattern).

---

## 5. Side Pots

This is the most algorithmically complex part. Pure Updater logic, no framework concerns.

### Algorithm

When a player goes all-in for less than the current bet:

1. Create a side pot for the all-in amount
2. Each player who can match the all-in contributes to this pot
3. Remaining bets go into the next pot (which the all-in player is NOT eligible for)
4. Repeat for multiple all-ins at different levels

### Data Structure

```elixir
pots: [
  %{amount: 600, eligible: ["p1", "p2", "p3", "p4"]},   # main pot
  %{amount: 400, eligible: ["p2", "p3", "p4"]},          # side pot 1
  %{amount: 200, eligible: ["p3", "p4"]}                 # side pot 2
]
```

### Resolution at Showdown

1. Evaluate all non-folded players' hands
2. For each pot (main → side pots in order):
   - Find best hand among `eligible` players who haven't folded
   - Award pot to winner (or split on ties)
   - Emit `pot_awarded` event per pot

### Implementation Approach

A `Poker.Pots` helper module (within `examples/poker/`) that handles:
- `recalculate_pots(seats, current_bets)` → updated pots list
- `award_pots(pots, hands, folded)` → list of `{pot_index, winner_ids, amount_each}`

This keeps the Updater clean — it calls into Pots for the math.

---

## 6. Event Design

### Event Catalog

**Hand Lifecycle:**
| Event | Payload | Visibility |
|-------|---------|------------|
| `hand_started` | `{hand_number, dealer_seat, blinds}` | Public |
| `post_blind` | `{player_id, blind_type, amount}` | Public |
| `deal_hole_cards` | `{player_id, cards}` | Private (player only) |
| `deal_community` | `{street, cards}` | Public |
| `showdown` | `{players: [{player_id, cards, hand_rank}]}` | Public |
| `hand_result` | `{winners, pots_awarded, summary}` | Public |

**Player Actions:**
| Event | Payload | Visibility |
|-------|---------|------------|
| `fold` | `{player_id}` | Public |
| `check` | `{player_id}` | Public |
| `call` | `{player_id, amount}` | Public |
| `bet` | `{player_id, amount}` | Public |
| `raise` | `{player_id, amount, raise_to}` | Public |
| `all_in` | `{player_id, amount}` | Public |

**Derived/System:**
| Event | Payload | Visibility |
|-------|---------|------------|
| `street_complete` | `{street}` | Public |
| `pot_awarded` | `{pot_index, winner_ids, amount, hand_description}` | Public |
| `player_eliminated` | `{player_id, finish_position}` | Public (tournament) |
| `blinds_increased` | `{new_sb, new_bb, level}` | Public (tournament) |
| `session_complete` | `{winner, final_standings}` | Public |
| `action_rejected` | `{player_id, reason}` | Private (actor only) |

### Granularity Rationale

- **Separate `bet` vs `raise`**: Semantically different (opening vs re-raising). Makes hand history and stats cleaner.
- **`all_in` as distinct event**: Triggers side pot creation. Clearer than "raise to exactly stack size."
- **`street_complete` as derived event**: Updater emits this when betting round closes, before dealing next street. Useful for projector to show street boundaries.
- **No `think` or `deliberate` events**: Agent reasoning captured via `thought` field on `take_action` tool call, stored in `world.journals` or plan_history. Not a game event.

---

## 7. Agent Tools (Projection Detail)

### What the Agent Sees (System Prompt Sections)

Following SectionedProjector pattern:

**Section: Table State** (JSON)
```json
{
  "hand_number": 42,
  "street": "flop",
  "your_position": "CO",
  "your_cards": ["Ah", "Ks"],
  "community_cards": ["Qh", "Jd", "2c"],
  "pot": 350,
  "your_stack": 8500,
  "current_bet": 150,
  "amount_to_call": 100,
  "min_raise_to": 300,
  "players": [
    {"id": "player_1", "position": "UTG", "stack": 12000, "status": "folded"},
    {"id": "player_2", "position": "MP", "stack": 7500, "status": "active", "bet_this_street": 150},
    {"id": "player_3", "position": "CO", "stack": 8500, "status": "active", "bet_this_street": 50, "you": true},
    {"id": "player_4", "position": "BTN", "stack": 9200, "status": "active", "bet_this_street": 0},
    {"id": "player_5", "position": "SB", "stack": 5000, "status": "active", "bet_this_street": 0},
    {"id": "player_6", "position": "BB", "stack": 10000, "status": "active", "bet_this_street": 0}
  ]
}
```

**Section: Hand Action** (JSON array of actions this hand)
```json
[
  {"street": "preflop", "actions": [
    {"player": "player_1", "position": "UTG", "action": "raise", "amount": 150},
    {"player": "player_2", "position": "MP", "action": "call", "amount": 150},
    {"player": "player_3", "position": "CO", "action": "call", "amount": 150},
    ...
  ]},
  {"street": "flop", "actions": [
    {"player": "player_2", "position": "MP", "action": "bet", "amount": 150}
  ]}
]
```

**Section: Session Stats** (JSON — rolling summary of recent hands)
```json
{
  "hands_played": 41,
  "your_chip_trend": [10000, 9800, 10200, 10500, 8500],
  "opponent_notes": "... (from journal)"
}
```

**Section: Decision Contract** (markdown)
```
You are playing No-Limit Texas Hold'em.
- Use the take_action tool to act.
- Legal actions this turn: fold, call (100), raise (300-8500), all_in
- Think about pot odds, position, opponent tendencies, and hand strength.
- You may use the note tool to record observations about opponents.
- Make exactly one take_action call per turn.
```

### Minimal Toolset Recommendation

1. **`take_action`** (terminal) — the poker action
2. **`note`** (support) — private journal for opponent modeling

Skip `get_game_state` — the projection is the game state. Two tools is clean.

---

## 8. Performance / Evaluation

### `performance.ex` — Poker Metrics

```elixir
defmodule LemonSim.Examples.Poker.Performance do
  def summarize(world) do
    %{
      benchmark_focus: "strategic betting, position awareness, opponent modeling, pot odds calculation",
      session: %{
        hands_played: ...,
        total_pots: ...,
        showdowns: ...,
        average_pot_size: ...
      },
      players: %{
        "player_1" => %{
          name: ...,
          model: ...,
          # Result
          final_stack: ...,
          profit_loss: ...,     # final_stack - starting_stack
          bb_per_hand: ...,     # profit_loss / hands_played / big_blind (key EV metric)

          # Preflop stats
          vpip: ...,            # Voluntarily Put In Pot % (played hands / total hands)
          pfr: ...,             # Pre-Flop Raise % (raised preflop / total hands)
          three_bet: ...,       # 3-bet % (re-raised preflop)

          # Postflop stats
          af: ...,              # Aggression Factor (bets+raises) / calls
          cbet: ...,            # Continuation Bet % (bet flop after raising preflop)
          wtsd: ...,            # Went To Showdown % (of hands that saw flop)
          wsd: ...,             # Won at Showdown % (won / went to showdown)

          # Behavioral
          fold_to_cbet: ...,    # Folded to continuation bet %
          steal_attempt: ...,   # Attempted steal from CO/BTN/SB %
          fold_to_steal: ...,   # Folded BB to steal attempt %

          # Quality signals
          showdown_win_rate: ...,  # How often agent wins when showing down
          bluff_success: ...,      # Won pot without showdown when estimated behind
          value_extraction: ...,   # Average pot won at showdown vs average pot lost
          position_awareness: ..., # Profit from late position vs early position

          # Activity
          hands_played: ...,
          hands_won: ...,
          biggest_pot_won: ...,
          all_in_count: ...,
          notes_written: ...
        }
      },
      models: %{
        "model_name" => %{
          seats: ...,
          avg_bb_per_hand: ...,
          avg_vpip: ...,
          avg_pfr: ...,
          avg_af: ...,
          total_profit_loss: ...
        }
      }
    }
  end
end
```

### Key Metric Definitions

- **bb/hand (bb/100)**: The gold standard for poker agent evaluation. Measures chip expectation per hand in big blind units. Normalizes across different blind levels.
- **VPIP**: How loose/tight the agent plays. Good range: 20-30% for 6-max.
- **PFR**: How aggressive preflop. Should be ~70-80% of VPIP.
- **AF**: Aggression factor. (bets + raises) / calls. Good agents are >2.0.
- **WTSD**: Went to showdown. Too high = calling station. Too low = too tight postflop.
- **C-bet**: Continuation bet frequency. Measures follow-through on preflop initiative.

### TrueSkill Integration (Open Question)

The poker eval research mentions TrueSkill ratings. This would require running multiple sessions and tracking ratings across games. This is a **session-level** concern, not a single-game concern. Options:
1. **Performance module returns raw metrics** (per-game), and a separate `eval_harness.ex` script aggregates across sessions and computes TrueSkill
2. **Performance module tracks cumulative stats** if the same world state persists across a multi-game session

**Recommendation**: Option 1. Keep Performance focused on single-session metrics. Build a separate eval runner that orchestrates multiple sessions.

---

## 9. Seating & Variance

### Position Randomization

```elixir
def initial_world(opts) do
  player_ids = Keyword.get(opts, :player_ids, default_player_ids(6))
  seed = Keyword.get(opts, :seed, :erlang.monotonic_time())

  # Shuffle seating
  :rand.seed(:exsss, {seed, seed, seed})
  shuffled = Enum.shuffle(player_ids)

  seats = shuffled
    |> Enum.with_index(1)
    |> Enum.into(%{}, fn {pid, idx} -> {"seat_#{idx}", %{player_id: pid, ...}} end)

  ...
end
```

### Fixed Seeds for Reproducibility

Critical for benchmarking. Two sources of randomness:
1. **Seating order**: Controlled by `seed` option
2. **Card dealing**: Controlled by a separate `deck_seed` or using the same seed

```elixir
# In Updater, when dealing:
defp shuffle_deck(seed) do
  :rand.seed(:exsss, {seed, seed + 1, seed + 2})
  Enum.shuffle(standard_52_card_deck())
end
```

**Variance reduction strategy** (from poker eval research):
- Run the same hand sequence (fixed deck seeds) across multiple seating arrangements
- Each model plays each position the same number of times
- Compare chip results controlling for card distribution

### Multi-Session Tournament Structure

```elixir
# Eval harness (outside lemon_sim core)
for trial <- 1..num_trials do
  seed = base_seed + trial

  for rotation <- 0..(num_players - 1) do
    rotated_assignments = rotate_seats(model_assignments, rotation)

    Poker.run(
      seed: seed,
      model_assignments: rotated_assignments,
      max_hands: 100
    )
  end
end
```

This gives each model equal exposure to each position with the same card sequence, controlling for both positional and card-luck variance.

---

## 10. Comparison to Existing Games

### Patterns to Reuse

| Pattern | Source Game | Application in Poker |
|---------|-----------|---------------------|
| **Hidden info projection** | Werewolf | Hole card filtering, event visibility |
| **SectionedProjector** | All games | Table state, hand history, decision contract sections |
| **Phase machine in Updater** | Werewolf (night/day), Stock Market (discussion/trading) | Street progression (preflop→flop→turn→river→showdown) |
| **Sequential turn order** | Stock Market (discussion_order), Tic Tac Toe (alternating) | Betting order rotation |
| **Economic state tracking** | Stock Market (portfolio, cash, trade history) | Stack management, pot tracking |
| **`action_rejected` pattern** | Skirmish, Stock Market | Invalid bet sizing → rejection event → re-prompt |
| **Private journals** | Werewolf (thought parameter), Stock Market (journals) | `note` tool for opponent modeling |
| **Performance module** | Stock Market, Werewolf, Survivor | Per-player poker stats + model aggregation |
| **`run_multi_model`** | GameHelpers.Runner | Different LLM per seat |
| **Provider throttling** | GameHelpers.Runner | Rate-limit API calls per provider |
| **Transcript logging** | GameHelpers.Transcript | Hand-by-hand game log |

### Patterns That Don't Apply

| Pattern | Source | Why Not |
|---------|-------|---------|
| **Multi-player simultaneous action** | Diplomacy (order submission) | Poker is strictly sequential |
| **Social deduction** | Werewolf (accusations, voting) | No social/discussion phase |
| **RNG combat resolution** | Skirmish (hit/miss rolls) | Poker's randomness is only in card dealing |
| **Private meetings** | Werewolf (pair chats) | No private communication |
| **Reputation/influence** | Stock Market (call accuracy → rep) | No meta-reputation system |

### Closest Analogue

**Stock Market** is the closest existing game because:
- Economic tracking (stacks = portfolios)
- Sequential turns with dynamic action spaces
- Information asymmetry (tips = hole cards, news = community cards)
- Position matters (speaking order = betting position)
- Performance module with financial metrics (return % = bb/hand)

However, poker is simpler in some ways (no social signaling, no whispers, no multi-round discussion) and more complex in others (side pots, hand evaluation, 4-street structure, dealer rotation).

---

## 11. Edge Cases

### Split Pots / Ties

When two+ players have identical hand strength at showdown:
- Split the pot equally among winners
- Handle odd chips by awarding to the player closest to the left of the dealer (standard rule)
- `pot_awarded` event includes `split: true` flag and all winner IDs

### Disconnects / Timeouts

The Decider handles this via `decision_max_turns`. If the LLM fails to produce a valid action:
1. First retry: re-prompt with clearer instructions
2. After max retries: auto-fold (safest default — doesn't invest more chips)

```elixir
# In Updater, handle timeout:
defp handle_decision_timeout(state, player_id) do
  # Force fold
  apply_event(state, Events.fold(player_id), [])
end
```

**Open question**: Should timeout be fold or check (when check is legal)? Fold is always safe. Check preserves equity when free. **Recommendation**: Check if legal, else fold.

### Short Stacks

When a player's stack < big blind:
- They can still play but will be forced all-in on any action
- ActionSpace shows only `fold` and `all_in`
- No partial bets — either you're in for your whole stack or you're out

### Heads-Up vs Ring Game

Heads-up (2 players) has different blind posting rules:
- Dealer posts small blind, other player posts big blind
- Dealer acts first preflop, second postflop
- This is a config flag, not a separate game

```elixir
defp post_blinds(world) when length(active_players(world)) == 2 do
  # Heads-up rules
  dealer_posts_sb(world)
end

defp post_blinds(world) do
  # Ring game rules: SB is left of dealer, BB is left of SB
  standard_blind_posting(world)
end
```

### All Players All-In

When all remaining players are all-in, skip the remaining streets and deal out all community cards:
- Emit `deal_community` events for remaining streets
- Go directly to showdown
- No more decision turns needed

### Single Player Remaining

When all but one player folds:
- Award pot to remaining player
- Do NOT reveal their hole cards (they may have been bluffing)
- Skip showdown

### Folded on Earlier Street

A player who folded on the flop does not participate in turn/river/showdown. Their seat shows `status: "folded"` for the rest of the hand.

---

## 12. Run Script

### Single-Model Quick Test

```elixir
# mix run apps/lemon_sim/scripts/poker_run.exs

alias LemonSim.Examples.Poker

# 6-player ring game, 50 hands, single model
Poker.run(
  player_count: 6,
  max_hands: 50,
  small_blind: 25,
  big_blind: 50,
  starting_stack: 10_000,
  seed: 42
)
```

### Multi-Model Tournament

```elixir
# mix run apps/lemon_sim/scripts/poker_multi_model.exs

alias LemonSim.Examples.Poker

config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

# Define model assignments per seat
model_assignments = %{
  "player_1" => {resolve_model(config, "anthropic", "claude-sonnet-4-20250514"), resolve_key(config, :anthropic)},
  "player_2" => {resolve_model(config, "anthropic", "claude-sonnet-4-20250514"), resolve_key(config, :anthropic)},
  "player_3" => {resolve_model(config, "openai", "gpt-4o"), resolve_key(config, :openai)},
  "player_4" => {resolve_model(config, "openai", "gpt-4o"), resolve_key(config, :openai)},
  "player_5" => {resolve_model(config, "google_gemini_cli", "gemini-2.5-pro"), resolve_key(config, :google_gemini_cli)},
  "player_6" => {resolve_model(config, "google_gemini_cli", "gemini-2.5-pro"), resolve_key(config, :google_gemini_cli)},
}

Poker.run_multi_model(
  player_count: 6,
  max_hands: 100,
  small_blind: 25,
  big_blind: 50,
  starting_stack: 10_000,
  seed: 42,
  model_assignments: model_assignments,
  transcript_path: "poker_transcript_#{DateTime.to_iso8601(DateTime.utc_now())}.jsonl",
  provider_min_interval_ms: %{google_gemini_cli: 5_000}
)
```

### Full Eval Harness (Multiple Rotations)

```elixir
# mix run apps/lemon_sim/scripts/poker_eval.exs

# Run N trials × M seat rotations for variance reduction
num_trials = 10
base_seed = 12345

results = for trial <- 1..num_trials, rotation <- 0..5 do
  rotated = rotate_model_assignments(model_assignments, rotation)

  {:ok, final_state} = Poker.run_multi_model(
    max_hands: 100,
    seed: base_seed + trial,
    model_assignments: rotated,
    transcript_path: "eval/trial_#{trial}_rot_#{rotation}.jsonl"
  )

  Performance.summarize(final_state.world)
end

# Aggregate across all trials
EvalAggregator.summarize(results)
# → TrueSkill ratings, confidence intervals, per-model stats
```

---

## Open Questions & Trade-offs

1. **Cash game vs tournament?** Cash games are simpler (fixed blinds, rebuy possible, no eliminations). Tournaments are more dramatic (increasing blinds, eliminations, ICM pressure). **Recommendation**: Start with cash game format (simpler), add tournament mode later.

2. **How many hands per session?** Too few = high variance. Too many = expensive (LLM calls). 100 hands at 6-max ≈ 500-1500 decision turns ≈ 500-1500 LLM calls. At $0.01/call that's $5-15 per session. **Recommendation**: Default 100, configurable.

3. **Hand evaluation library**: Need a fast poker hand evaluator. Options:
   - Write one in Elixir (pure, ~200-300 lines for 5/7-card eval)
   - Use a lookup-table approach (fastest, but needs pre-computed tables)
   - **Recommendation**: Write a clean Elixir evaluator. It only runs at showdown, so speed isn't critical. Keep it in `examples/poker/hand_evaluator.ex`.

4. **Ante support?** Tournaments commonly use antes. Adds complexity to blind posting. **Recommendation**: Support it from the start — it's just an extra forced bet, and blind_schedule can include ante amounts.

5. **Straddle / voluntary blinds?** No. Adds complexity without eval value.

6. **Show cards after winning without showdown?** Optional flavor. Could be a tool (`show_cards`) available after winning a hand. **Recommendation**: Skip for v1.

7. **Table talk?** Some poker formats allow chat. Could add a `chat` tool for table talk (mind games, bluffing verbally). **Recommendation**: Skip for v1 — pure mechanical play is the benchmark focus. Table talk could be a v2 feature.

8. **Multi-table tournament?** Way too complex for v1. Single table only.

9. **Observability**: Should there be a spectator projection that sees all hole cards? **Yes** — same as Werewolf's replay_storyboard pattern. Useful for debugging and content generation.

---

## File Structure

```
apps/lemon_sim/lib/lemon_sim/examples/poker/
├── poker.ex                 # Main module: initial_world, initial_state, modules, run, run_multi_model
├── action_space.ex          # Dynamic tool generation per street/position
├── events.ex                # Event constructors
├── updater.ex               # State machine: action validation, street transitions, pot management
├── hand_evaluator.ex        # 5/7-card hand ranking
├── pots.ex                  # Side pot computation
├── performance.ex           # Poker metrics (VPIP, PFR, AF, bb/hand, etc.)
└── positions.ex             # Position labels, blind posting, action order rotation
```

Estimated size: ~2000-3000 lines total. The Updater will be the largest module (~800-1200 lines) as it handles all game rules, street transitions, and pot resolution.

---

## Summary

Poker fits lemon_sim's architecture well. The key insight is that poker's complexity is in the Updater (rules, pots, hand evaluation), not in the framework integration. The hidden information model is simpler than Werewolf's. The action space is well-bounded. The multi-hand session maps cleanly to the Runner's step loop.

The main implementation effort is:
1. **Updater** — the poker state machine (~1000 lines)
2. **Hand evaluator** — standard poker hand ranking (~300 lines)
3. **Pot calculator** — side pot math (~150 lines)
4. **Performance** — HUD-style stats (~200 lines)

Everything else (ActionSpace, Events, Projector, run scripts) follows established patterns from Stock Market and Werewolf almost directly.
