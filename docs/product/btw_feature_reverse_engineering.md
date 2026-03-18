# `/btw` Feature — Reverse Engineering Reference

> Reverse engineered from Claude Code v2.1.77 binary (ELF + embedded JS bundle).
> Purpose: serve as implementation reference for building equivalent functionality in Lemon.

---

## 1. Feature Overview

`/btw` is a **side-question system** that spawns an ephemeral, tool-less, single-turn
conversation fork. It lets the user ask a quick question without interrupting the main
agent loop or polluting conversation history.

**Key properties:**

- Forked context: inherits the full parent conversation but writes nothing back to it
- Zero tools: all tool use is denied — pure knowledge-only response
- Single turn: exactly one model response, no follow-ups
- Inline rendering: response appears as a transient overlay, dismissed with Escape/Enter/Space
- Prompt-cache-friendly: reuses the parent's cached system prompt, skips cache writes

---

## 2. Feature Gate

The entire feature is gated behind a Statsig feature flag:

```javascript
function p_H() {
  return DA("tengu_marble_whisper2", false);
}
```

- Gate name: `tengu_marble_whisper2`
- Default: `false` (disabled)
- When off: command is invisible, regex parser returns no matches, UI hints hidden

**Implication for Lemon:** We need an equivalent feature flag mechanism. Could use our
existing config/flags system or a simple env var for the initial rollout.

---

## 3. Slash Command Registration

```javascript
d26 = {
  type: "local-jsx",
  name: "btw",
  description: "Ask a quick side question without interrupting the main conversation",
  isEnabled: () => p_H(),          // gated by tengu_marble_whisper2
  isHidden: false,
  immediate: true,                  // executes immediately, no confirmation step
  argumentHint: "<question>",
  load: () => Promise.resolve().then(() => (Hnf(), elf)),
  userFacingName() { return "btw"; }
};
```

**Registration fields:**

| Field | Value | Notes |
|---|---|---|
| `type` | `"local-jsx"` | Renders a React/Ink component inline |
| `name` | `"btw"` | Slash command name |
| `description` | `"Ask a quick side question..."` | Shown in help/autocomplete |
| `isEnabled` | `() => p_H()` | Dynamic — checks feature gate each time |
| `isHidden` | `false` | Visible in command listings when enabled |
| `immediate` | `true` | No confirmation dialog — fires on enter |
| `argumentHint` | `"<question>"` | Shown in autocomplete/help |

**Regex parser:** `Bt1 = /^\/btw\b/gi`

---

## 4. Command Handler

```javascript
async function g26(H, $, A) {
  let L = A?.trim();
  if (!L)
    return H("Usage: /btw <your question>", { display: "system" }), null;

  // Increment the persistent usage counter
  c$((D) => ({ ...D, btwUseCount: D.btwUseCount + 1 }));

  // Render the side-question component
  return P7.createElement(B26, { question: L, context: $, onDone: H });
}
```

**Behavior:**

1. Trim the argument text
2. If empty, show usage hint with `display: "system"` (not added to conversation)
3. Increment `btwUseCount` in persistent state (used for tip suppression)
4. Create and return the `B26` React component

---

## 5. The API Call — `Lzf` (Side Question)

This is the core of the feature — how the forked conversation is constructed and constrained.

```javascript
async function Lzf({ question, cacheSafeParams }) {
  let prompt = `<system-reminder>This is a side question from the user.
You must answer this question directly in a single response.
Simply answer the question with the information you have.</system-reminder>
${question}`;

  let result = await nE({
    promptMessages: [U$({ content: prompt })],
    cacheSafeParams,
    canUseTool: async () => ({
      behavior: "deny",
      message: "Side questions cannot use tools",
      decisionReason: { type: "other", reason: "side_question" }
    }),
    querySource: "side_question",
    forkLabel: "side_question",
    maxTurns: 1,
    skipCacheWrite: true
  });

  return { response: pt1(result.messages), usage: result.totalUsage };
}
```

### 5.1. System Prompt Injection

The question is wrapped in a `<system-reminder>` block that instructs the model to:

- Answer directly
- Use a single response
- Use only existing information (no tool calls)

### 5.2. Conversation Fork Parameters

| Parameter | Value | Purpose |
|---|---|---|
| `promptMessages` | `[U$({ content: prompt })]` | Single user message containing the wrapped question |
| `cacheSafeParams` | Inherited from parent | Reuses the parent conversation's prompt cache (system prompt, etc.) |
| `canUseTool` | Always returns `{ behavior: "deny" }` | **All tools unconditionally denied** |
| `querySource` | `"side_question"` | Analytics/billing tracking label |
| `forkLabel` | `"side_question"` | Marks this as a forked conversation — does not write back to parent history |
| `maxTurns` | `1` | Hard limit: exactly one model response |
| `skipCacheWrite` | `true` | Do not write this conversation into the prompt cache |

### 5.3. Tool Denial

The `canUseTool` callback is a universal deny:

```javascript
canUseTool: async () => ({
  behavior: "deny",
  message: "Side questions cannot use tools",
  decisionReason: { type: "other", reason: "side_question" }
})
```

This means even if the model attempts a tool call, the harness rejects it. The model
receives the denial message and must answer from its existing context only.

### 5.4. Response Extraction

`pt1(result.messages)` extracts the text content from the model's response messages.
The `usage` field tracks token consumption for the side question separately.

---

## 6. Context Construction — `U26`

Before calling `Lzf`, the handler calls `U26(context)` to build `cacheSafeParams`:

```javascript
let V = await U26(L);  // L = context from slash command handler
```

This function constructs the same system prompt and cache-safe parameters that the main
conversation uses. This is critical for two reasons:

1. **Prompt cache reuse**: The side question piggybacks on the already-cached system prompt,
   making the API call significantly cheaper (cache read hit)
2. **Full context**: The model has access to the same system instructions, CLAUDE.md,
   project context, etc. — it just can't act on them via tools

---

## 7. UI Component — `B26`

```javascript
function B26({ question, context, onDone }) {
  const [response, setResponse] = useState(null);
  const [error, setError] = useState(null);
  const [frame, setFrame] = useState(0);

  // Polling animation at 80ms intervals while loading
  useInterval(() => setFrame(f => f + 1), response || error ? null : 80);

  // Keyboard dismiss handler
  useInput((input, key) => {
    if (key.escape || key.return || input === " ")
      onDone(undefined, { display: "skip" });
  });

  // Fire API call on mount
  useEffect(() => {
    const controller = new AbortController();
    (async () => {
      try {
        const params = await U26(context);
        const result = await Lzf({ question, cacheSafeParams: params });
        if (!controller.signal.aborted) {
          if (result.response) setResponse(result.response);
          else setError("No response received");
        }
      } catch (e) {
        if (!controller.signal.aborted) setError(e.message || "Failed to get response");
      }
    })();
    return () => controller.abort();
  }, [question, context]);

  // Render...
}
```

### 7.1. Loading State

- 80ms polling interval drives a frame counter for animation
- Animation stops when response or error arrives

### 7.2. Keyboard Handling

| Key | Action |
|---|---|
| Escape | Dismiss |
| Enter | Dismiss |
| Space | Dismiss |

All three call `onDone(undefined, { display: "skip" })`, which:
- Returns `undefined` as the command result (no content to add)
- Uses `display: "skip"` to prevent anything from being added to conversation history

### 7.3. Visual Rendering

- `/btw` text rendered in **bold warning color** (yellow)
- Response text rendered in **dim color**
- Error text rendered in red
- The entire component is a transient overlay — once dismissed, it's gone

### 7.4. Abort Handling

The `useEffect` creates an `AbortController`. On unmount (e.g., user navigates away),
the controller aborts the in-flight API request. State updates are guarded by
`!controller.signal.aborted` to prevent setting state on an unmounted component.

---

## 8. Persistent State

### 8.1. `btwUseCount`

```javascript
// Part of the persisted settings schema
$b = {
  // ...
  tipsHistory: {},
  memoryUsageCount: 0,
  promptQueueUseCount: 0,
  btwUseCount: 0,         // <-- tracks total /btw invocations
  // ...
};
```

- **Default:** `0`
- **Incremented:** Every time `/btw` is used (before rendering the component)
- **Persisted:** Across sessions via settings file
- **Synced:** Listed in synced settings keys (survives reinstalls if sync is enabled)
- **Purpose:** Once > 0, the spinner tip promoting `/btw` never shows again

### 8.2. `tipsHistory`

```javascript
{
  "tip-id-1": 42,    // shown at startup number 42
  "tip-id-2": 38,    // shown at startup number 38
  // ...
}
```

Maps tip IDs to the `numStartups` value when they were last displayed.

### 8.3. `numStartups`

A monotonically increasing counter incremented each time Claude Code starts. Used as
the "clock" for tip cooldown calculations.

---

## 9. Spinner Tip Promotion System

This is how users discover `/btw`. It's part of a broader tip rotation system that
displays hints in the spinner while the model is working.

### 9.1. `/btw` Tip Trigger Logic

```javascript
let tipsEnabled   = settings.spinnerTipsEnabled !== false;
let sessionMs     = Date.now() - sessionStart;
let clearTip      = tipsEnabled && sessionMs > 1800000;            // > 30 minutes
let btwTip        = tipsEnabled && sessionMs > 30000               // > 30 seconds
                    && p_H()                                        // feature gate on
                    && !getState().btwUseCount;                     // never used /btw

let activeTip = clearTip && !paused
  ? "Use /clear to start fresh when switching topics and free up context"
  : btwTip && !paused
  ? "Use /btw to ask a quick side question without interrupting Claude's current work"
  : defaultTip;
```

**Trigger conditions for `/btw` tip:**

| Condition | Threshold | Notes |
|---|---|---|
| Tips enabled | `spinnerTipsEnabled !== false` | User hasn't disabled tips in settings |
| Session age | `> 30,000ms` (30 seconds) | Must have been in session for at least 30s |
| Feature gate | `p_H() === true` | `tengu_marble_whisper2` must be enabled |
| Never used | `btwUseCount === 0` | Once used even once, tip never shows again |
| Not paused | `!paused` | Session must be active, not backgrounded |

**Priority:** The `/clear` tip (30-minute threshold) takes precedence over the `/btw` tip.

### 9.2. Tip Selection Algorithm

When multiple tips are eligible, the system picks the one shown **least recently**:

```javascript
// Record that a tip was shown this session
function recordTipShown(tipId) {
  let history = getTipsHistory();
  history[tipId] = getState().numStartups;  // current startup count
  persistTipsHistory(history);
}

// Calculate sessions since tip was last shown
function sessionsSinceShown(tipId) {
  let lastShown = getTipLastShown(tipId);
  if (lastShown === 0) return Infinity;      // never shown → highest priority
  return getState().numStartups - lastShown;
}

// Pick the tip with longest gap since last display
function selectTip(tips) {
  if (tips.length === 0) return undefined;
  if (tips.length === 1) return tips[0];

  let scored = tips.map(tip => ({
    tip,
    sessions: sessionsSinceShown(tip.id)
  }));

  scored.sort((a, b) => b.sessions - a.sessions);  // highest gap first
  return scored[0].tip;
}
```

**Key insight:** Cooldowns are measured in **sessions (startups)**, not wall-clock time.
This means a user who restarts frequently will see tips cycle faster.

### 9.3. Tip Cooldown Values

Each tip has a minimum cooldown in sessions before it can be shown again:

| Cooldown | Example Tips |
|---|---|
| 2 sessions | `opusplan-mode-reminder` |
| 3 sessions | `new-user-warmup`, `frontend-design-plugin`, `guest-passes` |
| 5 sessions | `plan-mode-for-complex-tasks`, `prompt-queue` |
| 10 sessions | `git-worktrees`, `permissions`, `double-esc`, `continue`, `shift-tab` |
| 15 sessions | `memory-command`, `custom-agents`, `feedback-command`, `skills` |
| 20 sessions | `theme-command`, `enter-to-steer-in-realtime`, `todo-list`, `image-paste` |
| 25 sessions | `status-line` |
| 30 sessions | `colorterm-truecolor` |

### 9.4. Tip Eligibility Filters

Each tip has a relevance condition beyond just cooldown:

```
new-user-warmup         → numStartups < 10
git-worktrees           → only 1 worktree, numStartups > 50
memory-command          → memoryUsageCount <= 0
permissions             → numStartups > 10
custom-agents           → numStartups > 5
install-github-app      → no github action setup detected
terminal-setup          → shift+enter not installed
drag-and-drop-images    → not an SSH session
paste-images-mac        → macOS only
desktop-app             → not Linux
```

### 9.5. Top-Level Tip Orchestration

```javascript
async function getSpinnerTip(context) {
  if (getSettings().spinnerTipsEnabled === false) return;

  let eligible = await getEligibleTips(context);  // filter by relevance + cooldown
  if (eligible.length === 0) return;

  return selectTip(eligible);  // pick least recently shown
}
```

### 9.6. User Configuration

```javascript
// Settings schema
{
  spinnerTipsEnabled: boolean,    // master switch — false disables all tips

  spinnerTipsOverride: {
    excludeDefault: boolean,      // if true, only show custom tips
    tips: string[]                // custom tip strings
  },

  spinnerVerbs: {
    mode: "append" | "replace",   // append to or replace default verbs
    verbs: string[]               // custom spinner verb list
  }
}
```

---

## 10. Input Area UI Hint

When the feature gate is on, the input area shows a hint:

```javascript
let btwHint = p_H() && (
  <Text dimColor={isDim}>
    /btw for side question
  </Text>
);
```

This is always visible (when gated on), regardless of `btwUseCount`. It serves as a
permanent affordance indicator, unlike the spinner tip which disappears after first use.

---

## 11. Comparison: `/btw` vs Subagents vs Main Conversation

| Dimension | `/btw` | Subagent (Agent tool) | Main Conversation |
|---|---|---|---|
| **Context source** | Full parent conversation | Fresh/empty or custom prompt | Accumulating history |
| **Tools** | None (all denied) | Full toolset | Full toolset |
| **Turns** | 1 | Multiple | Unlimited |
| **History impact** | None (forked + display:skip) | Results injected back | Full read/write |
| **Cache behavior** | Read-only (skipCacheWrite) | Independent cache | Full read/write |
| **Analytics label** | `side_question` | `subagent` | `main` |
| **Cost** | Minimal (cache hit + small response) | Full request | Full request |
| **Use case** | Quick factual Q&A | Complex delegated tasks | Primary workflow |

---

## 12. Implementation Considerations for Lemon

### 12.1. What We Need

1. **Slash command system** — Lemon needs a way to register and parse `/btw`-style commands
   in whichever channel the user is interacting through (Telegram, WhatsApp, etc.)

2. **Conversation fork mechanism** — Ability to make an API call that:
   - Inherits the current conversation context
   - Does not write back to conversation history
   - Denies all tool use
   - Limits to a single turn

3. **Persistent usage tracking** — Track whether the user has ever used the feature
   (for tip suppression / onboarding)

4. **Inline transient response** — Render the response in a way that's clearly
   differentiated from the main conversation (e.g., different formatting, ephemeral
   message, reply-to-self pattern)

### 12.2. Channel-Specific Challenges

| Channel | Transient Display | Inline Rendering | Command Parsing |
|---|---|---|---|
| Telegram | Edit/delete after timeout | Reply to user's /btw message | Native bot commands |
| WhatsApp | No ephemeral messages | Reply/quote | Prefix parsing |
| CLI (if any) | Same as Claude Code | Same as Claude Code | Same as Claude Code |

### 12.3. Architecture Questions (for planning phase)

- Should `/btw` responses count against the user's message quota?
- Should `/btw` have access to Lemon skills, or be purely knowledge-based like Claude Code's version?
- Should `/btw` responses be stored in conversation history at all (for audit/compliance)?
- How do we handle `/btw` during an active skill execution (Lemon's equivalent of "while Claude is working")?
- What model should `/btw` use? Same as main conversation or a cheaper/faster one?

### 12.4. Minimal Viable Implementation

1. Parse `/btw <question>` from incoming messages
2. Fork a single-turn, tool-less API call with the current conversation context
3. Reply with the response in a visually distinct format (e.g., italic, quoted, or prefixed)
4. Do not add the btw exchange to the main conversation history
5. Track usage count in user state

---

## 13. Appendix: Spinner Verbs (165 total)

The whimsical "Clauding..." spinner text. One is selected at random via `X3()` (random
array element picker). Users can customize via `spinnerVerbs` setting.

<details>
<summary>Full list</summary>

Accomplishing, Actioning, Actualizing, Architecting, Baking, Beaming, Beboppin',
Befuddling, Billowing, Blanching, Bloviating, Boogieing, Boondoggling, Booping,
Bootstrapping, Brewing, Bunning, Burrowing, Calculating, Canoodling, Caramelizing,
Cascading, Catapulting, Cerebrating, Channeling, Channelling, Choreographing, Churning,
Clauding, Coalescing, Cogitating, Combobulating, Composing, Computing, Concocting,
Considering, Contemplating, Cooking, Crafting, Creating, Crunching, Crystallizing,
Cultivating, Deciphering, Deliberating, Determining, Dilly-dallying, Discombobulating,
Doing, Doodling, Drizzling, Ebbing, Effecting, Elucidating, Embellishing, Enchanting,
Envisioning, Evaporating, Fermenting, Fiddle-faddling, Finagling, Flambe-ing,
Flibbertigibbeting, Flowing, Flummoxing, Fluttering, Forging, Forming, Frolicking,
Frosting, Gallivanting, Galloping, Garnishing, Generating, Gesticulating, Germinating,
Gitifying, Grooving, Gusting, Harmonizing, Hashing, Hatching, Herding, Honking,
Hullaballooing, Hyperspacing, Ideating, Imagining, Improvising, Incubating, Inferring,
Infusing, Ionizing, Jitterbugging, Julienning, Kneading, Leavening, Levitating,
Lollygagging, Manifesting, Marinating, Meandering, Metamorphosing, Misting, Moonwalking,
Moseying, Mulling, Mustering, Musing, Nebulizing, Nesting, Newspapering, Noodling,
Nucleating, Orbiting, Orchestrating, Osmosing, Perambulating, Percolating, Perusing,
Philosophising, Photosynthesizing, Pollinating, Pondering, Pontificating, Pouncing,
Precipitating, Prestidigitating, Processing, Proofing, Propagating, Puttering, Puzzling,
Quantumizing, Razzle-dazzling, Razzmatazzing, Recombobulating, Reticulating, Roosting,
Ruminating, Sauteing, Scampering, Schlepping, Scurrying, Seasoning, Shenaniganing,
Shimmying, Simmering, Skedaddling, Sketching, Slithering, Smooshing, Sock-hopping,
Spelunking, Spinning, Sprouting, Stewing, Sublimating, Swirling, Swooping, Symbioting,
Synthesizing, Tempering, Thinking, Thundering, Tinkering, Tomfoolering, Topsy-turvying,
Transfiguring, Transmuting, Twisting, Undulating, Unfurling, Unravelling, Vibing,
Waddling, Wandering, Warping, Whatchamacalliting, Whirlpooling, Whirring, Whisking,
Wibbling, Working, Wrangling, Zesting, Zigzagging

</details>

---

## 14. Appendix: Full Spinner Tip Catalog (~35+ tips)

| ID | Content | Cooldown (sessions) | Condition |
|---|---|---|---|
| `new-user-warmup` | Start with small features or bug fixes... | 3 | `numStartups < 10` |
| `plan-mode-for-complex-tasks` | Use Plan Mode to prepare... | 5 | Has used plan mode |
| `default-permission-mode-config` | Use /config to change default permission mode | 10 | Used plan mode, no default mode |
| `git-worktrees` | Use git worktrees for parallel sessions | 10 | 1 worktree, `numStartups > 50` |
| `color-when-multi-clauding` | Running multiple sessions? Use /color and /rename... | 10 | Multiple sessions detected |
| `terminal-setup` | /terminal-setup for terminal integration | 10 | Shift+Enter not installed |
| `shift-enter` | Press Shift+Enter for multi-line messages | 10 | Shift+Enter installed, `numStartups > 3` |
| `shift-enter-setup` | Run /terminal-setup to enable Shift+Enter | 10 | Shift+Enter not installed |
| `memory-command` | Use /memory to view and manage memory | 15 | `memoryUsageCount <= 0` |
| `theme-command` | Use /theme to change color theme | 20 | Always |
| `colorterm-truecolor` | Set COLORTERM=truecolor for richer colors | 30 | No COLORTERM env |
| `status-line` | Use /statusline for custom status line | 25 | No statusLine configured |
| `prompt-queue` | Hit Enter to queue additional messages... | 5 | `promptQueueUseCount <= 3` |
| `enter-to-steer-in-realtime` | Send messages while Claude works... | 20 | Always |
| `todo-list` | Ask Claude to create a todo list | 20 | Always |
| `vscode-command-install` | Open Command Palette → Install code in PATH | 0 | macOS + VS Code without CLI |
| `ide-upsell-external-terminal` | Connect Claude to your IDE - /ide | 4 | Not in IDE, IDEs detected |
| `install-github-app` | Run /install-github-app to tag @claude... | 10 | No github action |
| `install-slack-app` | Run /install-slack-app for Slack | 10 | No slack app |
| `permissions` | Use /permissions to pre-approve/deny... | 10 | `numStartups > 10` |
| `drag-and-drop-images` | Drag and drop image files... | 10 | Not SSH |
| `paste-images-mac` | Paste images using control+v (not cmd+v!) | 10 | macOS only |
| `double-esc` | Double-tap esc to rewind conversation... | 10 | No checkpointing |
| `double-esc-code-restore` | Double-tap esc to rewind code and/or conversation... | 10 | Checkpointing enabled |
| `continue` | Run claude --continue/--resume to resume | 10 | Always |
| `rename-conversation` | Name conversations with /rename... | — | Always |
| `shift-tab` | Hit Shift+Tab to cycle between modes | 10 | Always |
| `image-paste` | Use Ctrl+V to paste images from clipboard | 20 | Always |
| `custom-agents` | Use /agents to optimize specific tasks... | 15 | `numStartups > 5` |
| `agent-flag` | Use --agent to start with a subagent | 15 | `numStartups > 5` |
| `desktop-app` | Run Claude Code using the Claude desktop app | 15 | Not Linux |
| `web-app` | Run tasks in the cloud - clau.de/web | 15 | Always |
| `mobile-app` | /mobile to use Claude Code from Claude app | 15 | Always |
| `opusplan-mode-reminder` | Your default model is Opus Plan Mode... | 2 | Using opusplan, plan not recent |
| `frontend-design-plugin` | Working with HTML/CSS? Add frontend-design plugin | 3 | Has .html/.css, plugin missing |
| `guest-passes` | You have free guest passes - /passes | 3 | Eligible, hasn't visited |
| `feedback-command` | Use /feedback to help us improve! | 15 | `numStartups > 5` |
| `skills` | Add custom skills to .claude/skills/ | 15 | `numStartups > 10` |
