defmodule LemonHoncho.ContextContributor do
  @moduledoc """
  Puts what Honcho remembers about the user into a turn, in two halves.

  This is the `LemonAgent.ContextRegistry` half of the integration:
  `LemonHoncho.Application` registers it under `:honcho` at boot, the session
  calls `contribute/1` while assembling every turn, and whatever comes back is
  rendered as labelled sections. The module itself holds nothing — it is a
  thin, total adapter over `LemonHoncho.SessionManager.context_for/1`, which
  already keeps a rendered block per session and refreshes it in the
  background.

  ## Why two halves

  The block the manager caches is not uniform in one respect that costs real
  money: part of it is the same bytes turn after turn, and part of it is
  different every turn. The base layer — the peer card, the durable
  representation, the session summary — changes only when a background refresh
  lands, and only when Honcho's own view of the person has moved: the fetch
  behind it is deliberately not steered by the current message. The dialectic
  supplement is LLM-generated prose answering a question that embeds that
  message, so it is new text on essentially every turn that fires one.

  A provider caches a request by its prefix, and the system prompt is inside
  that prefix. Putting text that changes every turn into the system prompt
  therefore invalidates the cache on every turn — for the whole prompt, not
  just for the changed section — and the model is billed to re-read all of it.
  Measured on this integration's shipped defaults the block changed on 47% of
  turn boundaries, which on a 60-turn Sonnet session came to roughly eleven
  extra dollars.

  So the two halves are contributed with different placements:

    * the stable half at `:system`, inside the cached prefix where it is nearly
      free to keep and where it will still be the same bytes next turn;
    * the volatile half at `:user_message`, after the last cache breakpoint,
      where changing it costs only itself.

  `LemonHoncho.Context.split/1` draws the line, because it is the module that
  drew the block.

  Nothing about *what* is recalled changes here: a turn still gets the whole of
  what the manager assembled, and the volatile half is as fresh as it ever was.
  The only thing that changes is where in the request each half is placed.

  ## What the saving is conditional on

  The eleven dollars is what the placement is worth **while the stable half is
  actually stable**, and that is not a property of this module. It is a property
  of how `LemonHoncho.SessionManager` fetches the base layer: without a
  retrieval query, so that no part of it is derived from the message this turn
  brought. Steer that fetch by the message — Honcho's `peer_context` takes a
  `search_query` for exactly that purpose, and it used to be given one — and the
  split still cuts in the right place while the system half is new text on every
  turn, invalidating the prefix precisely as it did before placements existed.
  The saving would then be zero and the code would look correct, which is why
  the manager's test suite asserts on the *arguments* that fetch reaches Honcho
  with rather than only on the text that comes back.

  ## Why this does no work

  `contribute/1` runs between the user pressing enter and the first token going
  out, and the registry kills a contributor that overruns its deadline. That is
  why every decision about *what* to inject — cadences, budgets, the dialectic,
  the bounded first-turn wait — lives in the session manager and not here. The
  only thing this module decides is whether the manager's answer is worth a
  section at all, which it can do without any I/O.

  Anything other than a non-empty binary is `:skip`, and so is a block whose
  two halves are both empty: memory switched off,
  Honcho unreachable, `recall_mode` set to `:tools`, a subagent whose config
  says not to inject, a manager that is not running, or a manager too busy to
  answer in time. All of those are ordinary states rather than failures, and a
  turn without recalled context is a working turn.

  ## Totality

  The manager's own API already degrades instead of raising, so the `rescue`
  and `catch` below are for the case this module cannot see: a build where the
  manager module is absent, or a `:persistent_term` registration that outlived
  the application it pointed at. The registry would isolate such a failure
  anyway; catching it here keeps the warning it would log out of a user's face
  for something that is not a bug.

  ## The titles

  A section is rendered as `## <title>` followed by the body, so the title is a
  heading the model reads as a claim about what follows. The stable half is
  deliberately **"Recalled background about this user"** rather than something
  naming the service:

    * *Background* rather than *instructions* or *rules*, because a
      representation that says "prefers terse answers" must not outrank what the
      user is asking for right now.
    * *Recalled* because the material may be months old and may be wrong; the
      word invites the model to prefer the live conversation, which is exactly
      the precedence `LemonHoncho.Context`'s preamble states in prose.
    * No mention of Honcho, because the model has no concept of it and a
      branded heading reads like a source with authority rather than a note.

  The volatile half is **"Recalled context most relevant to this message"**,
  which keeps *recalled* for the same reason and adds the one thing that
  distinguishes it: it was selected against the message it is arriving with,
  and is the older half's answer to "of everything known, what matters here".
  It carries no preamble of its own — it lands inside the user's turn, and
  whatever places it there is responsible for saying so; see
  `CodingAgent.Session.attach_recalled_context/2`.

  For the same reason as the titles, the stable body's own top-level heading is
  dropped when one is present: a heading has already been supplied, and a
  second one nested under it is a level inversion that makes the section look
  like two.

  ## The deadline this asks for

  `contribute/1` is instant on every turn but one. On the *first* turn of a
  session there is no cached block yet, and the session manager will hold the
  call while the first refresh lands — which is the one turn where recalled
  context is worth waiting for, since the assistant has no conversation to go
  on. The registry's default deadline is 250ms, so that wait would be cut off
  before it could ever pay off.

  `timeout_ms/1` is how this asks for more, and it asks *only* on that turn.
  Anything else — a session with a block already cached, a build with the wait
  turned off, a mode or a configuration in which the manager would not wait at
  all — gets the registry default back, because a contributor that raises the
  deadline on every turn has effectively raised it for every other contributor
  too.

  What it asks for is `LemonHoncho.SessionManager.first_turn_budget_ms/1`:
  `first_turn_wait_ms` plus a 200ms margin, already clamped to the registry's
  own 3,000ms ceiling. Both halves of that matter. The margin
  is what keeps the manager's wait from being cut off at exactly its own
  deadline. The clamp is why the manager derives its wait from this number
  rather than from `first_turn_wait_ms` directly: the registry would clamp
  silently, and a manager waiting past a deadline it cannot see would have its
  caller killed 50ms before answering — with the refresh cached, and the turn
  that paid for the wait getting nothing. The practical consequence is worth
  stating plainly: a `first_turn_wait_ms` above roughly 2.8 seconds does not
  make the first turn wait any longer.

  ## The question this asks per turn

  Deciding whether a turn is that first turn is one call to
  `LemonHoncho.SessionManager.cold?/1`, which is a single map lookup inside the
  manager. It used to be `sessions/0` plus an `Enum.find/2`, which built a list
  of every tracked session inside that one process and copied it here to answer
  a question about one key — milliseconds of shared-process time per turn on a
  busy node, for an O(1) fact.
  """

  require Logger

  alias LemonAgent.ContextRegistry
  alias LemonHoncho.{Config, Context, SessionManager}

  @stable_title "Recalled background about this user"
  @volatile_title "Recalled context most relevant to this message"

  # `LemonAgent.ContextRegistry`'s own default, restated rather than imported:
  # this is the value to fall back to when nothing special is happening, and a
  # compile-time coupling to another app's private constant would be worse than
  # a number that is wrong by 250ms at most.
  @registry_default_timeout_ms 250

  # The key the session manager derives from a request, mirroring its private
  # `state_key/1`. Restated here for the same reason the tools restate it: the
  # alternative is a call that tells us the key, which is a round trip to learn
  # something already in the request.
  @key_fields [:session_key, :session_id, :cwd]
  @default_key "default"

  # Matches a single leading markdown heading line and the blank lines after it.
  # Written against the *shape* of a heading rather than against
  # `LemonHoncho.Context`'s wording, so a change to that module's heading text
  # cannot silently reintroduce the duplicate.
  @leading_heading ~r/\A\s*\#{1,6}[ \t]+[^\n]*\r?\n+/

  @doc """
  Returns this turn's recalled context, split by placement, or `:skip`.

  Takes the request map described by `t:LemonAgent.ContextRegistry.request/0`
  and asks the session manager for the block it has already assembled for that
  session, then splits it: the durable material is contributed at `:system` and
  the dialectic supplement at `:user_message`. See *Why two halves* in the
  moduledoc for what that placement buys.

  Both halves are usually present, and then this returns a two-element list.
  Either may be absent on its own — a session whose dialectic has never
  refreshed has only the stable half, and a `context_tokens` budget too small
  to hold the base layer can leave only the volatile one — and then this
  returns that half alone, as a single spec.

  Returns `:skip` — never an error, never a raise — whenever both halves are
  empty or the manager cannot answer, which is the normal state of an
  unconfigured, unreachable, or still-warming integration.

  ## Examples

      iex> LemonHoncho.ContextContributor.contribute(:not_a_request)
      :skip
  """
  @spec contribute(ContextRegistry.request()) ::
          {:ok, ContextRegistry.section_spec() | [ContextRegistry.section_spec()]} | :skip
  def contribute(request) when is_map(request) do
    request
    |> SessionManager.context_for()
    |> section()
  rescue
    error ->
      Logger.debug("honcho: context section skipped: #{inspect(error)}")
      :skip
  catch
    kind, reason ->
      Logger.debug("honcho: context section skipped: #{inspect({kind, reason})}")
      :skip
  end

  def contribute(_request), do: :skip

  @doc """
  How long this turn's `contribute/1` may take, in milliseconds.

  Returns `#{@registry_default_timeout_ms}` — the registry's own default — for
  every turn that will be answered from cache, and
  `LemonHoncho.SessionManager.first_turn_budget_ms/1` for a genuinely cold
  session that is about to wait for its first refresh. That budget is already
  inside the registry's ceiling, so what is asked for here is what the manager
  sizes its wait against rather than something the registry will quietly cut
  down.

  Total by construction: an unconfigured integration, a manager that is not
  running, a request that is not a map, and any exception at all yield the
  default. This runs on the turn path, so it does no I/O beyond
  `LemonHoncho.SessionManager.cold?/1`, which is one map lookup in the manager
  and is documented never to touch the network.

  ## Examples

      iex> LemonHoncho.ContextContributor.timeout_ms(:not_a_request)
      #{@registry_default_timeout_ms}
  """
  @spec timeout_ms(ContextRegistry.request()) :: pos_integer()
  def timeout_ms(request) when is_map(request) do
    config = Config.load()

    if first_turn_wait?(config, request) do
      SessionManager.first_turn_budget_ms(config)
    else
      @registry_default_timeout_ms
    end
  rescue
    error ->
      Logger.debug("honcho: context timeout defaulted: #{inspect(error)}")
      @registry_default_timeout_ms
  catch
    kind, reason ->
      Logger.debug("honcho: context timeout defaulted: #{inspect({kind, reason})}")
      @registry_default_timeout_ms
  end

  def timeout_ms(_request), do: @registry_default_timeout_ms

  # Every condition here is one the session manager itself checks before it can
  # wait: it must be configured to have anything to fetch, it must be injecting
  # into this kind of run at all, the wait must be switched on, and the session
  # must be one it has never served. Mirroring the manager's gate rather than
  # asking it costs nothing and can only ever be wrong in the direction of the
  # default, since a request for more time is not a promise to use it.
  defp first_turn_wait?(%Config{} = config, request) do
    Config.configured?(config) and config.recall_mode != :tools and
      injects?(config, request) and config.first_turn_wait_ms > 0 and cold?(request)
  end

  defp injects?(%Config{} = config, request) do
    config.inject_in_subagents? or Map.get(request, :session_scope) != :subagent
  end

  # `cold?/1` is total in the direction that matters here: a manager that is not
  # running, or is too busy to answer, reports "not cold", because there is no
  # first-turn refresh to hold the turn open for and asking for extra time to
  # wait on a process that cannot answer would spend the deadline for nothing.
  defp cold?(request), do: SessionManager.cold?(state_key(request))

  defp state_key(request) do
    @key_fields
    |> Enum.map(&Map.get(request, &1))
    |> Enum.find(@default_key, &present?/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # `split/1` guarantees both halves are already trimmed, so the only thing left
  # to decide is which of them has anything in it. The leading `# …` heading is
  # stripped from the stable half only: it is the one the assembled block put a
  # heading on, and the volatile half is a bare section body by construction.
  defp section(block) when is_binary(block) do
    {stable, volatile} = Context.split(block)

    [
      spec(@stable_title, :system, strip_heading(stable)),
      spec(@volatile_title, :user_message, volatile)
    ]
    |> Enum.reject(&is_nil/1)
    |> result()
  end

  defp section(_other), do: :skip

  defp spec(_title, _placement, ""), do: nil
  defp spec(title, placement, body), do: %{title: title, body: body, placement: placement}

  # One spec is returned bare rather than wrapped in a one-element list. The
  # registry accepts both, and the bare map is the shape every contributor
  # written before placements returns — keeping it means a Honcho session with
  # no dialectic yet contributes exactly what it always did.
  defp result([]), do: :skip
  defp result([spec]), do: {:ok, spec}
  defp result(specs), do: {:ok, specs}

  defp strip_heading(block) do
    block |> String.replace(@leading_heading, "", global: false) |> String.trim()
  end
end
