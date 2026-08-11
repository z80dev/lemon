# Persist memory

`LemonAgent.Agent` keeps the conversation in process state, which is the right
place for it and the wrong place to keep it: restart the node and the agent has
forgotten everything. `lemon_memory` is the other half — a SQLite-backed store
of compact, searchable summaries, scoped so that "what did we decide last
Tuesday" survives a deploy.

This guide adds it to the project from
[Build your first agent](build-your-first-agent.md).

## Two kinds of memory

It is worth being precise about which problem you have, because they have
different answers:

| Problem | Answer |
|---|---|
| The model should remember what was said five minutes ago | The conversation, already in `AgentState.messages` |
| The conversation is longer than the context window | Compaction — `LemonAi.ContextCompactor`, or a `transform_context` function |
| The agent should remember something from last week | This guide |

A memory document is a *summary* of one exchange, not a transcript. Keep them
small: they are indexed for full-text search, and search quality falls off fast
once documents get long.

## 1. Add the dependency

You can generate the whole thing:

```bash
mix lemon.new my_agent --memory
```

or add it by hand. In `mix.exs`:

```elixir
{:lemon_memory, path: "/path/to/lemon/apps/lemon_memory"},
# {:lemon_memory, "~> 0.1"},
```

`lemon_memory` depends on `exqlite`, which builds a SQLite NIF, so the first
`mix deps.get && mix compile` after adding it takes a minute.

In `config/config.exs`:

```elixir
config :lemon_memory, LemonMemory.Store,
  path: Path.expand("~/.my_agent/store"),
  retention_ms: 30 * 24 * 60 * 60 * 1000,
  max_per_scope: 500

if config_env() == :test do
  config :lemon_memory, LemonMemory.Store, path: Path.expand("../tmp/test_store", __DIR__)
end
```

`path` is a *directory*; `memory.sqlite3` is created inside it on first write.
Point tests somewhere disposable — a suite that writes into your real store will
eventually delete something you wanted.

`retention_ms` and `max_per_scope` are enforced by a periodic sweep, so memory
is bounded without you doing anything. Documents older than the retention
window, and the oldest beyond the per-scope cap, are dropped.

## 2. Scopes

Every document has a scope, which decides what a later search can see:

| Scope | Lifetime | Keyed by |
|---|---|---|
| `:session` | one conversation | `session_key` |
| `:workspace` | one project directory | `workspace_key` |
| `:agent` | this agent, forever | `agent_id` |
| `:global` | the whole installation | nothing |

Default to `:session`. It is the choice that cannot leak one user's context into
another user's conversation, and widening it later is a one-line change; the
reverse is a data-deletion problem.

## 3. Write the wrapper

`lib/my_agent/memory.ex`:

```elixir
defmodule MyAgent.Memory do
  alias LemonMemory.{Document, Store}

  @agent_id "my_agent"

  @doc """
  Records one exchange. Writes are asynchronous; a subsequent read on the same
  store is still consistent, because both go through the same process.
  """
  def remember(session_key, prompt, answer, opts \\ []) do
    # Document.new/1 fills the generated fields (doc_id, run_id, timestamps),
    # validates that session_key and agent_id are present, and — the reason to
    # use it rather than building the struct by hand — truncates the two indexed
    # summary fields so you never index a whole transcript.
    Store.put(
      Document.new(
        session_key: session_key,
        agent_id: @agent_id,
        scope: :session,
        run_id: Keyword.get(opts, :run_id),
        started_at_ms: Keyword.get(opts, :started_at_ms),
        prompt_summary: prompt,
        answer_summary: answer,
        tools_used: Keyword.get(opts, :tools_used, []),
        provider: Keyword.get(opts, :provider),
        model: Keyword.get(opts, :model),
        outcome: Keyword.get(opts, :outcome, :success),
        meta: Keyword.get(opts, :meta, %{})
      )
    )
  end

  @doc "The most recent exchanges in a session, newest first."
  def recall(session_key, opts \\ []) do
    Store.get_by_session(session_key, limit: Keyword.get(opts, :limit, 5))
  end

  @doc "Full-text search within one session."
  def search(query, session_key, opts \\ []) do
    Store.search(
      query,
      opts
      |> Keyword.put_new(:scope, :session)
      |> Keyword.put_new(:scope_key, session_key)
    )
  end

  @doc "Asks the agent, then records the exchange."
  def ask_and_remember(session_key, prompt) do
    case MyAgent.Agent.ask(prompt) do
      {:ok, answer} ->
        remember(session_key, prompt, answer)
        {:ok, answer}

      {:error, reason} ->
        remember(session_key, prompt, "", outcome: :failure, meta: %{error: inspect(reason)})
        {:error, reason}
    end
  end
end
```

`remember/4` uses `Document.new/1`, which applies the invariants the ingest path
relies on — summary truncation and required-field validation — so a direct
`LemonAgent` user gets the same document a finalized run would. The other
constructor, `Document.from_run/4`, expects the run record and summary shapes
the router produces when it finalizes a run: reach for it if you are running the
full Lemon runtime, and for `new/1` if you are calling `LemonAgent` directly.

## 4. Feed memory back into a prompt

Storing memories is half of it. To use them, look them up before the run and put
them where the model will see them:

```elixir
def ask_with_context(session_key, prompt) do
  recalled =
    prompt
    |> MyAgent.Memory.search(session_key, limit: 3)
    |> Enum.map_join("\n", &"- #{&1.prompt_summary} → #{&1.answer_summary}")

  full_prompt =
    case recalled do
      "" -> prompt
      lines -> "Relevant earlier exchanges:\n#{lines}\n\nNow: #{prompt}"
    end

  MyAgent.Memory.ask_and_remember(session_key, full_prompt)
end
```

Prepending to the user message is the simplest thing that works and is easy to
inspect. The alternatives, in rough order of effort: put recalled context in the
system prompt instead (better cache behaviour, but it changes per run); use
`AgentLoopConfig`'s `transform_context` to inject it on every turn rather than
only the first; or expose a `search_memory` tool and let the model decide when
to look — see [Add a tool](add-a-tool.md).

## 5. Test it

`test/my_agent/memory_test.exs`:

```elixir
defmodule MyAgent.MemoryTest do
  # Not async: the memory store is a named, node-global process.
  use ExUnit.Case, async: false

  alias MyAgent.Memory

  setup do
    session = "session_" <> Integer.to_string(System.unique_integer([:positive]))
    on_exit(fn -> LemonMemory.Store.delete_by_session(session) end)
    {:ok, session: session}
  end

  test "an exchange survives being written and read back", %{session: session} do
    Memory.remember(session, "how many words in 'one two three'?", "Three words.")

    assert [document] = Memory.recall(session)
    assert document.answer_summary == "Three words."
    assert document.scope == :session
  end

  test "search finds an exchange by its words", %{session: session} do
    Memory.remember(session, "what is the airspeed of a swallow?", "African or European?")

    assert [found] = Memory.search("airspeed", session)
    assert found.answer_summary =~ "European"
  end

  test "one session cannot see another's memories", %{session: session} do
    other = session <> "_other"
    on_exit(fn -> LemonMemory.Store.delete_by_session(other) end)

    Memory.remember(other, "a secret", "kept")

    assert Memory.recall(session) == []
    assert Memory.search("secret", session) == []
  end
end
```

```bash
mix test
```

## Things that will surprise you

- **Same-millisecond ordering is by `doc_id`, not insertion order.** Documents
  come back newest-first by `ingested_at_ms`, with `doc_id` breaking ties, so two
  writes inside the same millisecond return in a *stable* order — but one keyed
  off a random id, not the order you wrote them. Real exchanges are seconds
  apart; if a test needs strict insertion order it should still space its writes
  out (the generated suite sleeps 2ms between them).
- **Every read degrades to empty rather than raising.** `search/2` catches exits
  and returns `[]`. Good for a chat UI, quietly wrong for a data-integrity
  check — do not build one on top of it without checking `LemonMemory.Store.stats/0`.
- **Deletion is by scope key.** `delete_by_session/1`, `delete_by_agent/1` and
  `delete_by_workspace/1` are the whole erasure API. If you need "forget this one
  fact", model it as a narrow scope up front.
- **Summaries are what gets searched.** `prompt_summary` and `answer_summary`
  are the only indexed fields; anything you want to find later has to be in one
  of them. Both `Document.new/1` and `Document.from_run/4` truncate them at
  2,000 bytes — but if you skip both and build the struct literally, nothing
  caps them and every full transcript you pass in gets indexed in full.

## Next

- [Add a channel](add-a-channel.md) — reach the agent from somewhere other than
  a terminal.
- [Add a tool](add-a-tool.md) — including a `search_memory` tool, so the model
  can look things up itself.
