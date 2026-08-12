defmodule LemonHoncho.SessionManager do
  @moduledoc """
  The one process that talks to Honcho, so that no turn ever waits on it.

  Honcho is a remote service that reasons with an LLM. Reading a peer's
  representation is a round trip; asking the dialectic endpoint what matters
  right now is a round trip *plus* inference. Neither belongs on the path of a
  turn, and yet the result of both has to be in the system prompt of that turn.
  This process is how those two facts are reconciled: it keeps a rendered
  context block per session, hands the cached one back immediately when asked,
  and refreshes it in the background on a cadence.

  ## What a caller is promised

  `context_for/1` is called while a run is being assembled. It returns a string
  and it returns quickly — bounded by a short `GenServer.call` timeout, plus (on
  the very first turn of a session only) the first-turn budget described below.
  Every failure mode returns `""`: memory switched off, Honcho unreachable, this
  process busy, this process not even started. Nothing it can do makes a turn
  fail, which is the property that lets the platform call it unconditionally.

  The bounded first-turn wait exists because a cold session would otherwise get
  nothing at all on the turn where context matters most — the one where the
  assistant has no conversation to go on. Later turns never wait: by then there
  is a cached block, and stale memory beats a stalled turn.

  ## What the first turn actually waits for

  The wait is not `first_turn_wait_ms` on its own. `LemonAgent.ContextRegistry`
  runs each contributor under a budget and kills it when that budget is spent,
  and the registry caps any budget at 3,000ms — the platform's number, not this
  app's, restated here as `@registry_max_timeout_ms`. So the real wait is
  `first_turn_budget_ms/1`: `first_turn_wait_ms` plus the margin the contributor
  adds, clamped to the registry's ceiling, and then reduced by a little headroom
  so this process answers *before* the registry gives up rather than racing it.

  The practical consequence, which is worth knowing before setting the knob:
  raising `first_turn_wait_ms` above roughly 2.8 seconds buys nothing. The wait
  saturates at the registry's ceiling, and a refresh that has not landed by then
  is cached for the next turn instead — which is the same outcome a shorter wait
  would have produced, one turn later.

  ## Bounded state

  One entry per session key is kept, and the map they live in is capped (500
  keys, `@max_sessions`) and swept by an idle TTL. Both matter because this
  process can outlive many conversations: a gateway serving a hundred users a
  day would otherwise accumulate an entry — an assembled block plus the halves
  it was assembled from — for every key it ever saw, and the map is walked on
  every worker death. Eviction is safe because an entry is a cache and nothing
  else: the next turn for an evicted key re-initialises it exactly as a key this
  process has never seen is initialised, at the cost of re-running the
  get-or-create setup that key already ran once.

  The sweep runs when a key is *added*, which is the only moment the map can
  grow, so a session pays for it once in its life rather than once per turn. It
  takes the least recently touched entries first, and skips any entry with a
  refresh in flight or a caller parked on it: evicting one of those would orphan
  a worker whose result has nowhere to land and strand a waiter nothing would
  ever reply to. The skip is temporary — such an entry becomes a candidate again
  the moment its refresh retires — so the cap can be exceeded briefly, by at
  most the number of refreshes in flight.

  ## Two cadences, counted independently

  Honcho's two layers cost very different amounts, so they are gated by two
  counters that never interact:

    * The **base layer** — session summary, the user's representation and peer
      card, the assistant's own representation — refreshes when
      `turns - last_base_at_turn >= context_cadence`.
    * The **dialectic** — one `chat` call, the expensive one — refreshes when
      `turns - last_dialectic_at_turn >= dialectic_cadence`.

  Both markers start unset, so both are due on turn 1. A refresh may carry one
  layer, the other, or both; whichever half it did not fetch is reused from the
  cache and re-rendered, so the block is always complete even though its halves
  have different ages.

  The markers advance when a refresh is *started*, not when it succeeds. That is
  the rule that protects the cost knobs: an endpoint that fails every call costs
  one attempt per cadence window rather than one per turn.

  ## The half that must not move

  The two layers differ in one more way, and this one decides how they are
  fetched rather than how often. The block this process assembles is split by
  `LemonHoncho.Context.split/1` and placed in two different parts of the
  request: the base layer goes into the **system prompt**, which is inside the
  provider's cached prefix, and the dialectic goes into the user message, after
  the last cache breakpoint. A byte that changes in the first invalidates the
  cache for the whole turn and the model is billed to re-read the entire prompt;
  a byte that changes in the second costs only itself.

  So the base fetch is made **without a retrieval query**. Honcho's
  `peer_context` accepts a `search_query` and uses it to select which
  conclusions the representation it returns is built from — genuinely useful,
  and exactly the wrong thing to do to this layer. Sending the turn's message
  there made the system half a function of that message, which at
  `context_cadence: 1` meant a fresh system prompt on every substantive turn:
  measured against a stub that echoes the parameter, five turns produced five
  distinct system halves. Unsteered, the same five produce one.

  Nothing about *what* is recalled is thrown away with the parameter, because
  the message-steered read still happens — in `fetch_dialectic/3`, whose warm
  question embeds the same message and whose answer is the half placed after
  the breakpoint. What is given up is the steering on turns where the dialectic
  is not due: those turns see the durable representation rather than one
  re-projected around what was just asked. That is the argument for keeping
  `dialectic_cadence` small relative to `context_cadence` rather than the other
  way round — the cheap layer is the one that may safely go stale, and it is now
  also the one that gains nothing from being refetched more often, since two
  refetches of an unsteered representation return the same text unless Honcho
  has revised it in between.

  ## The turns that are not counted

  Cadence counts turns, and a counter cannot tell that a turn said nothing.
  "ok" satisfies `context_cadence: 1`, fires a base refresh, and every second
  such turn fires the dialectic — whose warm question embeds the message, so
  Honcho is billed for an inference answering what is most relevant to the word
  "ok". `trivial_query?/1` is the content test that catches it: a blank
  message, a slash command, or a bare acknowledgement neither refreshes nor
  advances the counters, and the cached block is served unchanged.

  Not advancing the counters is the deliberate half. Cadence is a statement
  about how much has been *said* since the last refresh, so a turn that said
  nothing should leave the next real turn exactly as due as it already was.

  There is one exception, and it is the turn where being wrong costs most: a
  session that has never produced a block still loads on a trivial turn. It has
  nothing to serve otherwise, the cold dialectic question does not embed the
  message at all, and the alternative — a caller whose first message is "hi", or
  one that never populates `:query` — is a session that never recalls anything.
  That load is still not *counted*, so the first turn that says something is as
  due as it would have been; it is only exempt from the content gate, not from
  the cadence arithmetic.

  Uploads (`sync_document/1`) are deliberately *not* gated on any of this. A
  finished run's summary is written by a summarizer, not typed by the user, and
  dropping it would lose the signal the next session is assembled from.

  ## What leaves the machine

  Three things, and nothing else. Two are the run summaries `sync_document/1`
  uploads as messages: they are written by a summarizer rather than by the user,
  are already capped by `LemonMemory.Document`, and are screened by
  `LemonMemory.Ingest` before they ever reach this process.

  The third is the **retrieval query** — the user's current message, sent so
  that what Honcho reasons about is what is being asked. It is verbatim user
  text, and since the base fetch stopped carrying it (see *The half that must
  not move*) it leaves by exactly one route: embedded in the dialectic question
  that `fetch_dialectic/3` posts. So it goes through
  `LemonHoncho.Egress.screen/2`, which every path in this app that puts
  user-derived text on the wire shares: cut to 1,500 characters (the same cut
  `LemonHoncho.Context` applies to the message it embeds in that question), then
  withheld entirely if the clipped text looks like it carries a secret. A
  withheld query is not replaced or trimmed — the dialectic is simply asked its
  session-scoped question without a message attached, which costs focus and
  nothing else. The screen is applied once, where the plan is built, so no
  layer of a refresh can reach the wire by a route it does not cover.

  ## Initialization, and why failure is sticky

  A session key is initialized lazily on its first refresh: resolve the Honcho
  session id (`LemonHoncho.SessionName`, which may shell out to `git`, which is
  exactly why it happens in a task and not in this process), then
  `ensure_workspace`, `ensure_peer` for both peers, `ensure_session`, and
  `set_peer_config` for each peer. All of those are get-or-create, so doing them
  once per manager lifetime is enough.

  When initialization fails the failure is remembered and no refresh is
  attempted again for 30 seconds. An unreachable Honcho — a laptop offline, a
  self-hosted instance down — must not be re-dialled on every single turn, both
  because it is pointless and because each attempt is six requests that all have
  to time out. The first failure for a session is logged at warning and the rest
  at debug, so the log says what happened once instead of scrolling.

  ## Concurrency

  Refreshes run in a plain linked-and-monitored process rather than under a
  `Task.Supervisor`. This module does not own the application's supervision tree
  (`LemonHoncho.Application` does), and a refresh is a fire-and-forget read whose
  only meaningful failure handling is "stop waiting for it" — a monitor gives
  exactly that, and a supervisor would add a process to the tree that supervises
  nothing worth restarting. A crashed refresh is caught by its `:DOWN`, and a
  refresh that never returns at all is caught by a deadline timer, so a stuck
  request cannot wedge a session permanently.

  The **link** is what stops an orphan. If this process dies, its supervisor
  restarts it with an empty session map and the next turn starts a fresh
  refresh; a worker that survived that restart would be a second concurrent
  dialectic, which nothing will read and Honcho still bills. Linking makes the
  worker die with the manager. It is also why exits are trapped: the deadline
  path deliberately kills an overrunning worker, and an untrapped `:killed`
  travelling back up the link would take the manager down with it. The deadline
  timer is armed *before* the worker is spawned for the same reason — the pair
  has to be atomic from the manager's point of view, and arming second leaves a
  window in which a raise puts a worker into the world with nothing watching it.

  At most one refresh is in flight per session key, and that is enforced rather
  than assumed. The guard holds the refresh's tag, its pid, its monitor and its
  deadline timer, and exactly one of three things retires it: the tagged result
  arrives, the deadline fires, or the worker dies. A result whose tag is not the
  one currently in the guard is discarded — it belongs to a refresh that was
  already abandoned, so applying it would overwrite fresher context with older,
  and clearing the guard on it would let the next turn start a second refresh
  beside the one still running. Abandoning kills the worker, because a refresh
  nobody will read is a request nobody should pay for, and the dialectic is
  billed.

  Message uploads (`sync_document/1`) are not subject to that guard: they are
  independent writes and serializing them behind reads would delay them for no
  benefit.

  ## Configuration, and the testing seam

  What production does is re-read `LemonHoncho.Config.load/0` on every path that
  acts on it — serving a turn, applying a refresh, uploading a document. Loading
  is a read of the environment and the application env with no state behind it,
  which is why every other module in this app does the same, and it is what
  makes `LemonHoncho.status/0` and this process agree about what is switched on:
  a knob changed at runtime takes effect on the next turn rather than at the
  next restart.

  The HTTP client is the exception: it is resolved once at `init/1` from
  `Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)`, because it
  is a module rather than a setting and swapping it under a refresh in flight
  buys nothing.

  `start_link/1` accepts `:client`, `:config`, `:max_sessions` and `:idle_ttl_ms`
  overrides. All four are **test-only**: they exist so the cadence arithmetic,
  the degradation paths and the eviction policy can be driven against a stub
  module without a network and without ten thousand session keys, and nothing in
  production sets them. Passing `:config` *pins* the configuration for this
  process's lifetime, which is a property tests want and production does not
  have.
  """

  use GenServer

  require Logger

  alias LemonHoncho.Config
  alias LemonHoncho.Context
  alias LemonHoncho.Egress
  alias LemonHoncho.SessionName

  @typedoc "One row of `sessions/0`, for operator-facing reporting."
  @type session_info :: %{
          session_key: String.t(),
          honcho_session_id: String.t() | nil,
          turns: non_neg_integer(),
          last_context_at_ms: integer() | nil
        }

  # Long enough to survive a scheduler hiccup, short enough that a wedged
  # manager costs a turn a quarter-second rather than a timeout.
  @call_timeout_ms 500

  # `LemonAgent.ContextRegistry`'s `@max_timeout_ms`: the hard ceiling it puts on
  # any one contributor's budget, whatever that contributor asks for. It is the
  # platform's number rather than this app's, restated here (and in
  # `LemonHoncho.ContextContributor`) rather than imported, because a
  # compile-time coupling to another app's private constant would be the worse
  # of the two mistakes. Everything about the first turn is sized to fit inside
  # it: the registry kills the contributor at this deadline, so a wait that
  # merely raced it would throw away refreshes that had already landed.
  @registry_max_timeout_ms 3_000

  # What `LemonHoncho.ContextContributor` adds to `first_turn_wait_ms` when it
  # asks the registry for a budget. Kept here, next to the arithmetic that
  # consumes it, so the two cannot drift.
  @first_turn_margin_ms 200

  # Subtracted from the granted budget, so the reply is on its way back before
  # the registry's deadline rather than exactly at it. This is the whole
  # difference between "the manager answers" and "the contributor is killed
  # holding an answer the manager has already cached".
  @await_headroom_ms 50

  @init_cooldown_ms 30_000

  # A refresh that neither answers nor crashes would hold `pending_refresh`
  # forever and starve every later refresh for that key. The deadline is
  # generous — it is a wedge-breaker, not a request timeout; the client already
  # enforces `config.timeout_ms` per request.
  @refresh_deadline_slack_ms 5_000

  # ...but not unboundedly generous. `Process.send_after/3` refuses anything over
  # 2^32-1 milliseconds and *raises*, which would kill the manager after the
  # worker exists, and a wedge-breaker that fires in seven weeks would not be one
  # anyway. Ten minutes is far past any plausible `timeout_ms` and still short
  # enough to be a guard, so an operator who sets an absurd timeout gets a
  # degraded deadline instead of a crash loop.
  @max_refresh_deadline_ms 600_000

  # The cap on tracked session keys. Each entry holds the assembled block plus
  # the halves it was assembled from — call it twice the block — and a block is
  # a few kilobytes of refc binary, so the map is measured in megabytes rather
  # than in entries. 500 is chosen from that: it is far more concurrent
  # conversations than a single Lemon node serves inside the window a session
  # stays warm, so no realistic deployment ever evicts a live one, and it is
  # where the retained cost stays small. Measured with 6KB blocks: 500 entries
  # hold 587KB of heap and 7.0MB of refc binaries, against 23MB and 277MB for
  # the 20,000 keys an unbounded map reaches after a day of gateway traffic.
  @max_sessions 500

  # And a session nobody has served in two hours is not coming back on this
  # process's watch: the gateway that owned it has moved on, and holding its
  # block costs memory to save one setup round trip that will never be made.
  # Two hours is long enough to survive a lunch break, which is the longest gap
  # a conversation plausibly resumes across.
  @idle_ttl_ms 7_200_000

  # The retrieval query's ceiling, handed to `LemonHoncho.Egress.screen/2` — the
  # policy lives there, the budget lives here, next to the call that spends it.
  # Deliberately the same 1,500 characters `LemonHoncho.Context` cuts the
  # dialectic's embedded message to: the screen and that cut now apply to the
  # same one piece of text on the same wire, and a screen with the looser budget
  # would be screening bytes that never travel.
  @retrieval_query_max_chars 1_500

  @default_key "default"

  # Messages that carry no signal to recall memory *for*. Kept as a list rather
  # than a regular expression so that adding one is a one-word edit and so that
  # matching is exact: a message merely *starting* with an acknowledgement
  # ("no, revert that", "done — now ship it") is a real turn and must not be
  # swallowed by a prefix match. Comparison is against the normalized message,
  # so case and trailing punctuation are already gone by the time it is made.
  @acknowledgements ~w(
    y n k ok okay yes yeah yep yup no nope nah sure
    hi hey hello yo sup
    thanks thx ty
    cool nice great done next lgtm
    continue proceed
  ) ++ ["thank you", "go ahead", "do it", "got it"]

  # No acknowledgement is longer than this, so anything longer is a real message
  # and is answered without downcasing or scanning it. The point is that the
  # gate stays O(1) on the turn path even when the "message" is a 40KB paste.
  @max_trivial_bytes 24

  # Trailing punctuation, symbols (which is what an emoji is) and whitespace.
  # Stripped before matching so "ok!", "thanks :)" and "done???" all land on
  # their bare word, and so a message that is *only* punctuation or a lone
  # emoji normalizes to "" and counts as trivial in its own right.
  @trailing_noise ~r/[\p{P}\p{S}\p{Z}\s]+$/u

  @doc """
  Starts the manager under its registered name.

  ## Options

    * `:name` — registered name, defaults to this module.
    * `:config` — a `t:LemonHoncho.Config.t/0` to pin for this process's
      lifetime, instead of reloading `Config.load/0` per call as production does.
    * `:client` — the client module to use instead of the configured one.
    * `:max_sessions` — tracked-session cap, defaults to `#{@max_sessions}`.
    * `:idle_ttl_ms` — idle eviction TTL, defaults to `#{@idle_ttl_ms}`.

  All but `:name` are test-only; see the moduledoc.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The context block for this run, or `""`.

  Takes the request map `LemonAgent.ContextRegistry` passes contributors and
  returns text to inject. It answers from cache and schedules a refresh when the
  cadence says one is due *and* the turn's message is worth one — see
  `trivial_query?/1`. Only the first turn of a session waits, and only for what
  is left of `first_turn_budget_ms/1` once this call has been paid for, less the
  headroom the reply needs to beat the registry's deadline.

  Returns `""` — never an error, never a raise — when Honcho is not configured,
  when `recall_mode` is `:tools` (the model asks for memory explicitly in that
  mode, so injecting it would be paying twice), when this is a subagent and
  `inject_in_subagents?` is false, and whenever the manager is unavailable or
  too busy to answer in time.
  """
  @spec context_for(map()) :: String.t()
  def context_for(request) when is_map(request) do
    started_ms = System.monotonic_time(:millisecond)

    case safe_call({:context, request}, @call_timeout_ms) do
      {:ok, block} -> block
      {:wait, key, budget_ms} -> await_first_turn(key, remaining_ms(budget_ms, started_ms))
      _other -> ""
    end
  end

  @doc """
  The budget this turn's first-turn wait is sized against, in milliseconds.

  `LemonHoncho.ContextContributor` asks `LemonAgent.ContextRegistry` for exactly
  this, and this process waits for strictly less than it, so a refresh that
  lands inside the window reaches the turn that paid for it instead of being
  cached for the next one. It is `first_turn_wait_ms` plus the contributor's
  margin, clamped to the registry's own `#{@registry_max_timeout_ms}`ms ceiling
  — which is why a `first_turn_wait_ms` above roughly
  #{@registry_max_timeout_ms - @first_turn_margin_ms} buys nothing.

  Pure, and safe to call from the turn path: it reads the config it is handed
  and touches no process.

  ## Examples

      iex> LemonHoncho.SessionManager.first_turn_budget_ms(%LemonHoncho.Config{
      ...>   first_turn_wait_ms: 1_000
      ...> })
      1200

      iex> LemonHoncho.SessionManager.first_turn_budget_ms(%LemonHoncho.Config{
      ...>   first_turn_wait_ms: 60_000
      ...> })
      3000
  """
  @spec first_turn_budget_ms(Config.t()) :: non_neg_integer()
  def first_turn_budget_ms(%Config{first_turn_wait_ms: 0}), do: 0

  def first_turn_budget_ms(%Config{} = config) do
    min(config.first_turn_wait_ms + @first_turn_margin_ms, @registry_max_timeout_ms)
  end

  @doc """
  Whether this turn's message is too thin to be worth spending a refresh on.

  A turn is trivial when its message is missing or blank, is a slash command,
  or is a bare acknowledgement — "ok", "yes", "thanks", "go ahead" — with any
  amount of trailing punctuation. A message that is *only* punctuation or a
  lone emoji is trivial for the same reason: nothing is left of it once the
  punctuation is stripped. Matching is exact against the normalized message, so
  "no" is trivial and "no, revert that" is not.

  What it is for is cost. A refresh is a network read and, every
  `dialectic_cadence` turns, a *billed* LLM call on Honcho's side, and the warm
  dialectic question embeds the user's message — so an ungated "ok" pays an
  inference to answer "what context is most relevant to `ok`". Gating on
  content is the only thing that catches this: the cadence counters cannot,
  because they count turns and this is a turn.

  Pure, total on any term, and safe to call from the turn path.

  ## Examples

      iex> LemonHoncho.SessionManager.trivial_query?("thanks!")
      true

      iex> LemonHoncho.SessionManager.trivial_query?("/compact")
      true

      iex> LemonHoncho.SessionManager.trivial_query?("no, revert that")
      false
  """
  @spec trivial_query?(term()) :: boolean()
  def trivial_query?(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" -> true
      String.starts_with?(trimmed, "/") -> true
      byte_size(trimmed) > @max_trivial_bytes -> false
      true -> acknowledgement?(normalize(trimmed))
    end
  end

  def trivial_query?(_query), do: true

  @doc """
  Whether the next turn for `session_key` is that session's first.

  One map lookup in this process and nothing else — no list of sessions built,
  no copy of it sent to the caller, no network. That matters because
  `LemonHoncho.ContextContributor` asks this on every turn of a configured
  install to decide whether to ask the registry for the first-turn budget, and a
  question asked that often has to be O(1) in the number of sessions rather than
  O(N).

  A key this process has never served is cold, and so is one whose first refresh
  has not landed. A manager that is not running, or is too busy to answer,
  reports **not** cold: there is no first-turn refresh for a caller to hold a
  turn open for, so the honest answer is the one that asks for less time.
  """
  @spec cold?(String.t()) :: boolean()
  def cold?(session_key) when is_binary(session_key) do
    case safe_call({:cold?, session_key}, @call_timeout_ms) do
      {:ok, cold?} -> cold?
      _other -> false
    end
  end

  @doc """
  Uploads a finished run's summaries to Honcho as two messages.

  Fire-and-forget: returns `:ok` immediately and does the work in a task, and a
  failure is logged rather than returned. A no-op when `save_messages?` is false
  or the integration is unconfigured.

  What Honcho receives is the run's `prompt_summary` and `answer_summary`, each
  attributed to the matching peer and each clipped to `config.message_max_chars`.
  Those fields are already truncated upstream — `LemonMemory.Document` caps each
  at 2,000 bytes, see `LemonMemory.Document.max_summary_bytes/0` — so what Honcho
  models is the *summary* of a turn, not its transcript. That is a deliberate
  limitation worth knowing when reading a representation that seems to have
  missed something: the detail may never have been sent.

  A blank half is skipped rather than sent as an empty message, because an empty
  message from a peer is a fact Honcho would otherwise try to interpret.
  """
  @spec sync_document(LemonMemory.Document.t()) :: :ok
  def sync_document(%LemonMemory.Document{} = document) do
    GenServer.cast(__MODULE__, {:sync_document, document})
  catch
    :exit, reason ->
      Logger.debug("honcho: document not synced: #{inspect(reason)}")
      :ok
  end

  @doc """
  The Honcho session id a Lemon session key maps to, once it has been resolved.

  Returns `{:error, :unknown_session}` for a key this manager has never served
  and `{:error, :not_initialized}` for one whose first refresh has not completed
  — resolution happens off the caller's path, so "not yet" is a normal answer
  rather than a failure.
  """
  @spec honcho_session_id(String.t()) :: {:ok, String.t()} | {:error, term()}
  def honcho_session_id(session_key) when is_binary(session_key) do
    call_or_error({:honcho_session_id, session_key})
  end

  @doc """
  The user and assistant peer ids a session is recorded under.

  Same "not yet" semantics as `honcho_session_id/1`: a key this manager has not
  served yields `{:error, :unknown_session}`.
  """
  @spec peers(String.t()) :: {:ok, %{user: String.t(), ai: String.t()}} | {:error, term()}
  def peers(session_key) when is_binary(session_key) do
    call_or_error({:peers, session_key})
  end

  @doc """
  Every session this manager is tracking, for `mix lemon.honcho` and `status/0`.

  Reads process state only and never touches the network, so it is safe to call
  from a diagnostic path. An unstarted or busy manager yields `[]`.
  `honcho_session_id` is `nil` for a session whose first refresh has not landed.

  What it lists is what is *tracked*, which is bounded — see the moduledoc's
  *Bounded state* — so a session that ended hours ago, or that lost its slot to
  the cap, is absent here even though Honcho still holds its record. Being a
  list built per call, this is also the wrong thing to ask on the turn path;
  `cold?/1` exists for the one question a turn needs to ask.
  """
  @spec sessions() :: [session_info()]
  def sessions do
    case safe_call(:sessions, @call_timeout_ms) do
      {:ok, sessions} -> sessions
      _other -> []
    end
  end

  ## Server

  @impl true
  def init(opts) do
    # Refresh workers are linked so they cannot outlive this process (see
    # `start_refresh/6`). Trapping is the price of that link: the deadline path
    # kills an overrunning worker, and an untrapped exit signal coming back up
    # the link would kill the manager along with it.
    Process.flag(:trap_exit, true)

    state = %{
      # `nil` means "load it per call", which is what production does. See
      # `config/1` and the moduledoc's *Testing seam*.
      config: Keyword.get(opts, :config),
      client: Keyword.get(opts, :client) || configured_client(),
      max_sessions: Keyword.get(opts, :max_sessions, @max_sessions),
      idle_ttl_ms: Keyword.get(opts, :idle_ttl_ms, @idle_ttl_ms),
      sessions: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:context, request}, _from, state) do
    config = config(state)

    if gated?(config, request) do
      {:reply, {:ok, ""}, state}
    else
      serve_context(request, config, state)
    end
  end

  def handle_call({:await, key}, from, state) do
    case Map.get(state.sessions, key) do
      nil -> {:reply, {:ok, ""}, state}
      %{pending_refresh: nil} = entry -> {:reply, {:ok, entry.last_context}, state}
      entry -> {:noreply, put_entry(state, key, add_waiter(entry, from))}
    end
  end

  def handle_call({:honcho_session_id, key}, _from, state) do
    {:reply, with_entry(state, key, &session_id_reply/1), state}
  end

  def handle_call({:peers, key}, _from, state) do
    {:reply, with_entry(state, key, &{:ok, %{user: &1.user_peer, ai: &1.ai_peer}}), state}
  end

  def handle_call(:sessions, _from, state) do
    {:reply, {:ok, Enum.map(state.sessions, &session_info/1)}, state}
  end

  # One lookup, one comparison. Deliberately not answered from `:sessions`: this
  # runs on every turn, and building a list of every session to find one row in
  # it is the difference between an O(1) question and an O(N) one.
  def handle_call({:cold?, key}, _from, state) do
    {:reply, {:ok, cold_entry?(Map.get(state.sessions, key))}, state}
  end

  @impl true
  def handle_cast({:sync_document, document}, state) do
    config = config(state)

    if Config.configured?(config) and config.save_messages? do
      {:noreply, flush_document(document, config, state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:refresh_result, key, ref, result}, state) do
    config = config(state)

    {:noreply, update_entry(state, key, &finish_refresh(&1, ref, result, config))}
  end

  def handle_info({:sync_result, key, init}, state) do
    {:noreply, update_entry(state, key, &apply_init(&1, init))}
  end

  def handle_info({:refresh_expired, key, ref}, state) do
    {:noreply, update_entry(state, key, &expire_refresh(&1, ref))}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    {:noreply, update_all(state, &crashed_refresh(&1, monitor, reason))}
  end

  # A linked refresh worker ended — normally, by crashing, or because the
  # deadline killed it. The monitor is what this process acts on, so the exit
  # signal itself only has to be absorbed; it is here rather than in the
  # catch-all so that trapping exits reads as a decision instead of an accident.
  # An exit from the parent supervisor never reaches here: `:gen_server`'s loop
  # handles that one before `handle_info/2` is reached.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  ## Client-side plumbing

  # What is left of the granted budget once the `{:context, …}` call has been
  # paid for, minus the headroom the reply needs to travel. Measured rather than
  # assumed, because the budget belongs to the whole of `contribute/1` and the
  # first call — a state operation, but still a call — has already spent some of
  # it. A non-positive remainder means the budget is gone, and waiting on a
  # deadline that has already passed would only get the caller killed holding a
  # block this process has cached anyway.
  defp remaining_ms(budget_ms, started_ms) do
    budget_ms - (System.monotonic_time(:millisecond) - started_ms) - @await_headroom_ms
  end

  defp await_first_turn(_key, wait_ms) when wait_ms <= 0, do: ""

  defp await_first_turn(key, wait_ms) do
    case safe_call({:await, key}, wait_ms) do
      {:ok, block} -> block
      _other -> ""
    end
  end

  defp call_or_error(message) do
    case safe_call(message, @call_timeout_ms) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  end

  # Every entry point funnels through here so that a manager which is not
  # running, is shutting down, or cannot answer in time degrades to a value
  # instead of taking the caller's process with it.
  defp safe_call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, reason ->
      Logger.debug("honcho: session manager unavailable: #{inspect(reason)}")
      :unavailable
  end

  defp configured_client do
    Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)
  end

  # The live configuration, re-read on every path that acts on it.
  #
  # `Config.load/0` reads the environment and the application env and holds no
  # state, which is why every other module in this app — the contributor, all
  # five tools, the memory provider — loads it per call and passes the struct
  # down. Pinning it here made this process the one place a runtime change did
  # not reach: `LemonHoncho.status/0` would report the new value while the
  # manager acted on the boot-time one, `LEMON_HONCHO_SAVE_MESSAGES=false` would
  # stop the tool writes but not the uploads, and
  # `LemonHoncho.ContextContributor.timeout_ms/1` would size the registry's
  # deadline from a fresh config while `serve_context/3` sized the wait from a
  # stale one — a disagreement that ends with the contributor killed while
  # parked in `{:await, key}`.
  #
  # A pinned struct is the test seam and nothing else: production passes no
  # `:config`, so this loads.
  defp config(%{config: nil}), do: Config.load()
  defp config(%{config: %Config{} = config}), do: config

  ## Serving context

  defp gated?(%Config{} = config, request) do
    cond do
      not Config.configured?(config) -> true
      config.recall_mode == :tools -> true
      subagent?(request) and not config.inject_in_subagents? -> true
      true -> false
    end
  end

  defp subagent?(request), do: Map.get(request, :session_scope) == :subagent

  defp serve_context(request, config, state) do
    key = state_key(request)
    entry = entry_for(state, key, request, config)
    turn = entry.turns
    kind = turn_kind(entry, request)

    entry = advance(entry, kind, key, turn, request, config, state)
    state = track_entry(state, key, entry)

    if wait_for_first_turn?(entry, turn, config) do
      {:reply, {:wait, key, first_turn_budget_ms(config)}, state}
    else
      {:reply, {:ok, entry.last_context}, state}
    end
  end

  # A substantive turn is counted and may refresh. A cold load refreshes without
  # being counted — a session that has never produced a block has nothing to
  # serve, and the cold dialectic question does not embed the message anyway, so
  # gating that one read on the message's content would trade the whole of the
  # session's memory for nothing. A trivial turn does neither and is served from
  # cache.
  defp advance(entry, :substantive, key, turn, request, config, state) do
    bumped = %{entry | turns: turn + 1}

    maybe_refresh(bumped, key, turn, request, config, state)
  end

  defp advance(entry, :cold_load, key, turn, request, config, state) do
    maybe_refresh(entry, key, turn, request, config, state)
  end

  defp advance(entry, :trivial, _key, _turn, _request, _config, _state), do: entry

  defp turn_kind(entry, request) do
    cond do
      not trivial_query?(Map.get(request, :query)) -> :substantive
      is_nil(entry.last_context_at_ms) -> :cold_load
      true -> :trivial
    end
  end

  # Downcased, stripped of trailing punctuation, and with internal runs of
  # whitespace collapsed, so that "Thank  you!!" and "thank you" are the same
  # message as far as `@acknowledgements` is concerned. Only ever reached for a
  # message shorter than `@max_trivial_bytes`.
  defp normalize(message) do
    message
    |> String.downcase()
    |> String.replace(@trailing_noise, "")
    |> String.replace(~r/\s+/u, " ")
  end

  # Nothing left after the punctuation was stripped: the message was "?", "..."
  # or a lone 👍, which says exactly as much as "ok" does.
  defp acknowledgement?(""), do: true
  defp acknowledgement?(normalized), do: normalized in @acknowledgements

  # Only ever true on a session's first turn, and only while that turn's refresh
  # is actually in flight — there is nothing to wait for otherwise.
  #
  # A cold load reaches this and is waited for, which is deliberate: it is the
  # one fetch a session cannot do without, it happens once, and a caller that
  # never populates `:query` would otherwise have to spend a whole turn
  # discovering its own session id. A turn that is merely trivial cannot reach
  # it — being trivial rather than a cold load means a block has already landed,
  # and a trivial turn starts no refresh of its own to wait on.
  defp wait_for_first_turn?(entry, turn, %Config{} = config) do
    turn == 0 and config.first_turn_wait_ms > 0 and not is_nil(entry.pending_refresh)
  end

  defp maybe_refresh(entry, key, turn, request, config, state) do
    base? = due?(entry.last_base_at_turn, turn, config.context_cadence)
    dialectic? = due?(entry.last_dialectic_at_turn, turn, config.dialectic_cadence)

    if refreshable?(entry) and (base? or dialectic?) do
      entry
      |> start_refresh(key, refresh_plan(entry, request, config, state, base?, dialectic?))
      |> mark_refreshed(turn, base?, dialectic?)
    else
      entry
    end
  end

  # An unset marker means the layer has never been fetched, which is always due.
  defp due?(nil, _turn, _cadence), do: true
  defp due?(last_turn, turn, cadence), do: turn - last_turn >= cadence

  defp refreshable?(entry) do
    is_nil(entry.pending_refresh) and not cooling_down?(entry)
  end

  defp cooling_down?(%{init_state: :failed, init_failed_at_ms: at}) when is_integer(at) do
    now_ms() - at < @init_cooldown_ms
  end

  defp cooling_down?(_entry), do: false

  defp mark_refreshed(entry, turn, base?, dialectic?) do
    %{
      entry
      | last_base_at_turn: if(base?, do: turn, else: entry.last_base_at_turn),
        last_dialectic_at_turn: if(dialectic?, do: turn, else: entry.last_dialectic_at_turn)
    }
  end

  # The guard is everything needed to retire this refresh from any of the three
  # directions it can end from: the tag the worker will stamp its result with,
  # the pid to kill if it overruns, the monitor to drop, and the deadline timer
  # to cancel. The tag is a fresh reference rather than the monitor reference
  # because the worker has to carry it and cannot see its own monitor.
  #
  # Order matters. The timer is armed *before* the worker exists, so that the
  # only thing here which can raise — `Process.send_after/3`, on a nonsense
  # deadline — cannot leave a running refresh behind with nothing watching it.
  # And the worker is spawned linked as well as monitored, in one atomic
  # `spawn_opt/2`, so it dies with this process instead of surviving a restart
  # as a second billed dialectic beside the refresh the next turn will start.
  defp start_refresh(entry, key, plan) do
    manager = self()
    ref = make_ref()
    deadline = refresh_deadline_ms(plan.config)
    timer = Process.send_after(manager, {:refresh_expired, key, ref}, deadline)
    worker = fn -> run_refresh(manager, key, ref, plan) end
    # `:erlang.spawn_opt/2` rather than `spawn_monitor/1` plus `Process.link/1`:
    # linking after the fact races the worker's own exit, and losing that race
    # would take this process down with a `:noproc`.
    {pid, monitor} = :erlang.spawn_opt(worker, [:link, :monitor])

    %{entry | pending_refresh: %{ref: ref, pid: pid, monitor: monitor, timer: timer}}
  end

  defp refresh_plan(entry, request, config, state, base?, dialectic?) do
    %{
      config: config,
      client: state.client,
      entry: readiness(entry),
      resolve_opts: entry.resolve_opts,
      query: Egress.screen(Map.get(request, :query), @retrieval_query_max_chars),
      has_base_context?: entry.last_context != "",
      base?: base?,
      dialectic?: dialectic?
    }
  end

  # Clamped, because this number becomes a `Process.send_after/3` delay and that
  # function raises rather than degrades: an operator who sets `timeout_ms` to
  # something enormous would otherwise take the manager down at the exact moment
  # it has just spawned a worker. See `@max_refresh_deadline_ms`.
  defp refresh_deadline_ms(%Config{} = config) do
    min(config.timeout_ms * 2 + @refresh_deadline_slack_ms, @max_refresh_deadline_ms)
  end

  ## Refresh task

  # Runs in its own process. It must never let an exception escape, because an
  # abandoned refresh leaves the session's waiters hanging until their own
  # deadline instead of getting the cached block immediately.
  # `ref` is the tag the manager matches the answer against; a result that
  # arrives after this refresh was abandoned is recognizable by it and dropped.
  defp run_refresh(manager, key, ref, plan) do
    send(manager, {:refresh_result, key, ref, perform_refresh(plan)})
  rescue
    error -> send(manager, {:refresh_result, key, ref, %{init: {:error, error}}})
  catch
    :exit, reason -> send(manager, {:refresh_result, key, ref, %{init: {:error, reason}}})
  end

  defp perform_refresh(plan) do
    case ensure_ready(plan) do
      {:ok, session_id, peers} = init ->
        %{
          init: init,
          base: if(plan.base?, do: {:ok, fetch_base(plan, session_id, peers)}),
          dialectic: if(plan.dialectic?, do: {:ok, fetch_dialectic(plan, session_id, peers)})
        }

      {:error, reason} ->
        %{init: {:error, reason}}
    end
  end

  # Idempotent by construction: every call here is get-or-create, so re-running
  # it after a manager restart costs six requests and changes nothing.
  defp ensure_ready(%{entry: %{init_state: :ready, honcho_session_id: id, peers: peers}})
       when is_binary(id) do
    {:ok, id, peers}
  end

  defp ensure_ready(plan) do
    %{config: config, client: client} = plan
    peers = %{user: config.user_peer, ai: config.ai_peer}
    flags = Config.observation_flags(config)
    session_id = SessionName.resolve(config, plan.resolve_opts)
    specs = [{peers.user, flags.user}, {peers.ai, flags.ai}]

    with {:ok, _} <- client.ensure_workspace(config),
         {:ok, _} <- client.ensure_peer(config, peers.user),
         {:ok, _} <- client.ensure_peer(config, peers.ai),
         {:ok, _} <- client.ensure_session(config, session_id, specs),
         {:ok, _} <- client.set_peer_config(config, session_id, peers.user, flags.user),
         {:ok, _} <- client.set_peer_config(config, session_id, peers.ai, flags.ai) do
      {:ok, session_id, peers}
    end
  end

  # Deliberately unsteered, and that is the whole of *The half that must not
  # move*. `peer_context/3` accepts a `search_query` that selects which
  # conclusions the returned representation is built from, and passing this
  # turn's message made the base layer a function of that message — new bytes on
  # every turn, in the layer that is placed in the system prompt. The message is
  # not thrown away with it: it still steers `fetch_dialectic/3`, whose answer
  # lands after the cache breakpoint where changing it is free.
  defp fetch_base(plan, session_id, peers) do
    %{config: config, client: client} = plan
    user = client.peer_context(config, peers.user, [])
    ai = client.peer_context(config, peers.ai, [])

    %{
      summary: summary_of(client.session_context(config, session_id, summary_opts(config))),
      user_representation: representation_of(user),
      peer_card: card_of(user),
      ai_representation: representation_of(ai)
    }
  end

  # No `search_query` here either, for the same reason: the summary is part of
  # the base layer, so anything that made it vary with the turn would put moving
  # bytes back inside the cached prefix. Honcho's own summary drifts as the
  # session's messages accumulate, which is drift this module cannot prevent and
  # does not need to — `context_cadence` decides how often it is even looked at.
  defp summary_opts(%Config{} = config), do: [summary: true, tokens: config.context_tokens]

  # Which peer is asked matters: when the assistant peer observes the other side
  # it holds the richer view and is asked *about* the user; otherwise the user
  # peer can only be asked about itself.
  defp fetch_dialectic(plan, session_id, peers) do
    %{config: config, client: client} = plan
    query = Context.dialectic_query(plan.query, plan.has_base_context?)
    opts = [session_id: session_id, reasoning_level: config.reasoning_level]

    if Config.observation_flags(config).ai.observe_others do
      answer_of(client.chat(config, peers.ai, query, [{:target, peers.user} | opts]))
    else
      answer_of(client.chat(config, peers.user, query, opts))
    end
  end

  ## Response shaping

  defp summary_of({:ok, %{"summary" => %{"content" => content}}}) when is_binary(content) do
    content
  end

  defp summary_of({:ok, %{"summary" => summary}}) when is_binary(summary), do: summary
  defp summary_of(_other), do: nil

  defp representation_of({:ok, %{"representation" => value}}) when is_binary(value), do: value

  defp representation_of({:ok, %{"peer_representation" => value}}) when is_binary(value) do
    value
  end

  defp representation_of(_other), do: nil

  # The one field whose shape is a collection rather than a string, and the one
  # that has to be *shaped* rather than merely guarded. It is done here, where
  # the response is first accepted, so that everything downstream of this
  # module holds a list of lines it can render.
  #
  # The rest of this section can guard on `is_binary/1` and stop there, because
  # a value that fails that guard is discarded. A list cannot be: `is_list/1`
  # admits a list of anything, and a well-formed 200 whose card is
  # `[%{"text" => "likes elixir"}]` — the shape a differently-spelled API
  # version would return — used to reach `LemonHoncho.Context`'s `to_string/1`
  # and raise `Protocol.UndefinedError`. That raise happens *in this process*:
  # `handle_info/2` renders the refresh result, so the manager dies, every
  # session on the node loses its cached block, and three of those inside the
  # supervisor's restart window take a `:permanent` app — and the node — down
  # with them.
  #
  # Numbers are kept and rendered, because a card line that is a count or a
  # year is still a fact about the user. Maps, nested lists, booleans and
  # `null`s are dropped: there is no line in them a reader would want, and
  # `to_string/1` on them either raises or invents one.
  defp card_of({:ok, %{"peer_card" => card}}), do: shape_card(card)
  defp card_of(_other), do: nil

  defp shape_card(card) when is_binary(card), do: card
  defp shape_card(card) when is_list(card), do: Enum.flat_map(card, &card_line/1)
  defp shape_card(_card), do: nil

  defp card_line(line) when is_binary(line), do: [line]
  defp card_line(line) when is_number(line), do: [to_string(line)]
  defp card_line(_line), do: []

  defp answer_of({:ok, answer}) when is_binary(answer), do: answer
  defp answer_of(_other), do: nil

  ## Applying a refresh

  defp finish_refresh(%{pending_refresh: %{ref: ref}} = entry, ref, result, config) do
    entry
    |> clear_pending()
    |> apply_init(result[:init])
    |> apply_layers(result, config)
    |> flush_waiters()
  end

  # An answer from a refresh this session has already given up on — it overran
  # its deadline and was killed, or its process died and a later one took its
  # place. It is dropped whole rather than merged: its layers are older than
  # whatever replaced them, and touching the guard here is precisely the bug
  # that let two refreshes run at once (each of which bills a dialectic call).
  defp finish_refresh(entry, _ref, _result, _config), do: entry

  # Retires the guard from whichever direction the refresh ended: the monitor is
  # dropped, the deadline timer is cancelled, and the next turn is free to start
  # a refresh. `[:flush]` matters — the worker's own `:DOWN` may already be in
  # the mailbox, and one that outlives its guard would otherwise be read as the
  # death of whatever refresh came after it. Only ever called from a clause that
  # has already matched the guard it is retiring, which is why there is no
  # `nil` clause here: retiring nothing is a caller bug, not a state to absorb.
  defp clear_pending(%{pending_refresh: pending} = entry) do
    Process.demonitor(pending.monitor, [:flush])
    Process.cancel_timer(pending.timer)

    %{entry | pending_refresh: nil}
  end

  defp apply_init(entry, {:ok, session_id, peers}) do
    %{
      entry
      | honcho_session_id: session_id,
        user_peer: peers.user,
        ai_peer: peers.ai,
        init_state: :ready,
        init_failed_at_ms: nil,
        init_failures: 0
    }
  end

  defp apply_init(entry, {:error, reason}) do
    log_init_failure(entry, reason)

    %{
      entry
      | init_state: :failed,
        init_failed_at_ms: now_ms(),
        init_failures: entry.init_failures + 1
    }
  end

  defp apply_init(entry, _other), do: entry

  # The first failure for a session is the one an operator needs to see; the
  # rest are the same failure on a 30-second timer and belong at debug.
  defp log_init_failure(%{init_failures: 0}, reason) do
    Logger.warning("honcho: session setup failed, retrying later: #{inspect(reason)}")
  end

  defp log_init_failure(_entry, reason) do
    Logger.debug("honcho: session setup still failing: #{inspect(reason)}")
  end

  # Only the layers this refresh actually carried are replaced; the other half is
  # re-rendered from cache so the block is never missing a section it had before.
  defp apply_layers(entry, %{init: {:ok, _id, _peers}} = result, config) do
    base = merge_base(entry.base, result[:base])
    dialectic = merge_dialectic(entry.dialectic, result[:dialectic])

    %{
      entry
      | base: base,
        dialectic: dialectic,
        last_context: Context.assemble(Map.put(base, :dialectic, dialectic), config),
        last_context_at_ms: now_ms()
    }
  end

  defp apply_layers(entry, _result, _config), do: entry

  defp merge_base(_cached, {:ok, base}), do: base
  defp merge_base(cached, _not_refreshed), do: cached

  defp merge_dialectic(_cached, {:ok, dialectic}), do: dialectic
  defp merge_dialectic(cached, _not_refreshed), do: cached

  # The deadline fired. The worker is killed rather than left to finish: nothing
  # will read what it returns, it is holding a socket, and if it is inside the
  # dialectic it is running up a bill for an answer that is already discarded.
  # A tag that is not the current one belongs to a refresh that has already been
  # retired — its timer simply outlived it — and must not clear a live guard.
  defp expire_refresh(%{pending_refresh: %{ref: ref} = pending} = entry, ref) do
    Process.exit(pending.pid, :kill)
    log_abandoned(:deadline)

    entry |> clear_pending() |> flush_waiters()
  end

  defp expire_refresh(entry, _ref), do: entry

  # The worker died on its own. Same matching rule, on the monitor this time,
  # so a `:DOWN` for a refresh that is no longer the pending one is a no-op.
  defp crashed_refresh(%{pending_refresh: %{monitor: monitor}} = entry, monitor, reason) do
    log_abandoned(reason)

    entry |> clear_pending() |> flush_waiters()
  end

  defp crashed_refresh(entry, _monitor, _reason), do: entry

  defp log_abandoned(:normal), do: :ok

  defp log_abandoned(reason) do
    Logger.debug("honcho: context refresh did not complete: #{inspect(reason)}")
  end

  defp add_waiter(entry, from), do: %{entry | waiters: [from | entry.waiters]}

  defp flush_waiters(%{waiters: []} = entry), do: entry

  defp flush_waiters(entry) do
    Enum.each(entry.waiters, &GenServer.reply(&1, {:ok, entry.last_context}))
    %{entry | waiters: []}
  end

  ## Message upload

  defp flush_document(document, config, state) do
    key = document.session_key || @default_key

    case messages_for(document, config) do
      [] -> state
      messages -> upload(key, messages, document, config, state)
    end
  end

  defp upload(key, messages, document, config, state) do
    request = %{session_key: key, cwd: document.workspace_key}
    entry = entry_for(state, key, request, config)

    plan = %{
      config: config,
      client: state.client,
      entry: readiness(entry),
      resolve_opts: entry.resolve_opts
    }

    manager = self()

    spawn(fn -> run_upload(manager, key, plan, messages) end)

    track_entry(state, key, entry)
  end

  # Unmonitored on purpose: nothing waits on an upload and there is no cached
  # value to release, so the only thing a monitor would buy is a log line the
  # rescue clause already writes.
  defp run_upload(manager, key, plan, messages) do
    case ensure_ready(plan) do
      {:ok, session_id, _peers} = init ->
        log_upload(plan.client.add_messages(plan.config, session_id, messages))
        send(manager, {:sync_result, key, init})

      {:error, reason} ->
        send(manager, {:sync_result, key, {:error, reason}})
    end
  rescue
    error -> Logger.debug("honcho: message upload failed: #{inspect(error)}")
  catch
    :exit, reason -> Logger.debug("honcho: message upload exited: #{inspect(reason)}")
  end

  defp log_upload({:ok, _body}), do: :ok

  defp log_upload({:error, reason}) do
    Logger.debug("honcho: messages not stored: #{inspect(reason)}")
  end

  defp messages_for(document, %Config{} = config) do
    [{document.prompt_summary, config.user_peer}, {document.answer_summary, config.ai_peer}]
    |> Enum.map(fn {content, peer} -> {clip(content, config.message_max_chars), peer} end)
    |> Enum.reject(fn {content, _peer} -> content == "" end)
    |> Enum.map(fn {content, peer} -> %{content: content, peer_id: peer} end)
  end

  defp clip(content, max) when is_binary(content) do
    content |> String.trim() |> String.slice(0, max)
  end

  defp clip(_content, _max), do: ""

  ## State helpers

  # Derived without any I/O, because it runs inside the manager: the gateway
  # session key identifies a conversation, and the working directory is the
  # fallback for a run that has none.
  defp state_key(request) do
    [Map.get(request, :session_key), Map.get(request, :session_id), Map.get(request, :cwd)]
    |> Enum.find(@default_key, &present?/1)
  end

  # Both writers go through here, and both count as touching the session: a key
  # that is only ever uploaded to is as alive as one that is served, and the
  # eviction policy has to see it that way or a busy `sync_document/1` deployment
  # would evict the very sessions it is writing for.
  defp entry_for(state, key, request, config) do
    state.sessions
    |> Map.get_lazy(key, fn -> new_entry(config, request) end)
    |> touch()
  end

  defp touch(entry), do: %{entry | last_touched_ms: now_ms()}

  # A key created by `sync_document/1` alone gets the same shape as a served one,
  # and that costs nothing: the upload path never assembles a block and never
  # reaches `apply_layers/3`, so `base`, `dialectic` and `last_context` stay at
  # their empty values for its whole life. What such a key does cost is a slot,
  # which is exactly why it is tracked and capped like any other — in
  # `recall_mode: :tools`, where context is never served at all, uploads are the
  # only thing creating entries and were the only thing growing the map.
  defp new_entry(%Config{} = config, request) do
    %{
      honcho_session_id: nil,
      user_peer: config.user_peer,
      ai_peer: config.ai_peer,
      turns: 0,
      last_context: "",
      last_context_at_ms: nil,
      last_touched_ms: now_ms(),
      last_base_at_turn: nil,
      last_dialectic_at_turn: nil,
      init_state: :pending,
      init_failed_at_ms: nil,
      init_failures: 0,
      pending_refresh: nil,
      waiters: [],
      resolve_opts: resolve_opts(request),
      base: %{summary: nil, user_representation: nil, peer_card: nil, ai_representation: nil},
      dialectic: nil
    }
  end

  defp resolve_opts(request) do
    [
      cwd: Map.get(request, :cwd),
      session_key: Map.get(request, :session_key),
      session_id: Map.get(request, :session_id)
    ]
  end

  # What the refresh task needs to know about init, without shipping it the
  # waiters, the cached block, or anything else it must not read.
  defp readiness(entry) do
    %{
      init_state: entry.init_state,
      honcho_session_id: entry.honcho_session_id,
      peers: %{user: entry.user_peer, ai: entry.ai_peer}
    }
  end

  defp put_entry(state, key, entry), do: %{state | sessions: Map.put(state.sessions, key, entry)}

  # The bounded write. Every path that can introduce a *new* key uses this, and
  # only those paths: the sweep is the one O(N) thing in this module, and hanging
  # it off key creation rather than off every write means a session pays for it
  # once in its life instead of once per turn. It is also the only moment the map
  # can grow, so it is the only moment a bound needs checking.
  defp track_entry(state, key, entry) do
    new_key? = not Map.has_key?(state.sessions, key)
    state = put_entry(state, key, entry)

    if new_key?, do: bound_sessions(state), else: state
  end

  defp bound_sessions(state), do: state |> drop_idle() |> drop_over_cap()

  # Sheds sessions nobody has touched in `idle_ttl_ms` before the cap has to. A
  # long-lived gateway accumulates conversations that ended hours ago, and their
  # blocks are the largest thing in this process; the entry the current turn just
  # touched can never be among them.
  defp drop_idle(state) do
    cutoff = now_ms() - state.idle_ttl_ms

    expired =
      for {key, entry} <- state.sessions,
          evictable?(entry),
          entry.last_touched_ms < cutoff,
          do: key

    drop_sessions(state, expired, :idle)
  end

  # Least-recently-touched first, which for a cache of conversations is the same
  # as "the one least likely to be asked for next".
  defp drop_over_cap(state) do
    over = map_size(state.sessions) - state.max_sessions

    if over > 0 do
      drop_sessions(state, lru_keys(state.sessions, over), :cap)
    else
      state
    end
  end

  defp lru_keys(sessions, count) do
    sessions
    |> Enum.filter(fn {_key, entry} -> evictable?(entry) end)
    |> Enum.sort_by(fn {_key, entry} -> entry.last_touched_ms end)
    |> Enum.take(count)
    |> Enum.map(fn {key, _entry} -> key end)
  end

  # An entry with a refresh in flight or a caller parked on it is skipped rather
  # than evicted, and the next candidate is taken instead. Dropping one would
  # orphan a worker whose result no longer has an entry to land in and strand a
  # waiter that nothing would ever reply to; and it is temporary anyway, since
  # the entry becomes evictable the moment the refresh retires. The cap can
  # therefore be exceeded briefly, by at most the number of concurrent refreshes,
  # which is one per key and only for as long as a refresh takes.
  defp evictable?(entry), do: is_nil(entry.pending_refresh) and entry.waiters == []

  defp drop_sessions(state, [], _reason), do: state

  defp drop_sessions(state, keys, reason) do
    # Debug rather than info: eviction is the policy working, not an incident.
    # An evicted key re-initialises on its next turn exactly as a cold one does.
    Logger.debug("honcho: evicted #{length(keys)} session(s) (#{reason})")

    %{state | sessions: Map.drop(state.sessions, keys)}
  end

  defp cold_entry?(nil), do: true
  defp cold_entry?(entry), do: entry.turns == 0 and is_nil(entry.last_context_at_ms)

  defp update_entry(state, key, fun) do
    case Map.get(state.sessions, key) do
      nil -> state
      entry -> put_entry(state, key, fun.(entry))
    end
  end

  defp update_all(state, fun) do
    %{state | sessions: Map.new(state.sessions, fn {key, entry} -> {key, fun.(entry)} end)}
  end

  defp with_entry(state, key, fun) do
    case Map.get(state.sessions, key) do
      nil -> {:error, :unknown_session}
      entry -> fun.(entry)
    end
  end

  defp session_id_reply(%{honcho_session_id: nil}), do: {:error, :not_initialized}
  defp session_id_reply(%{honcho_session_id: id}), do: {:ok, id}

  defp session_info({key, entry}) do
    %{
      session_key: key,
      honcho_session_id: entry.honcho_session_id,
      turns: entry.turns,
      last_context_at_ms: entry.last_context_at_ms
    }
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # Wall clock rather than monotonic, because `last_context_at_ms` is shown to
  # operators and a monotonic reading means nothing to them. The only other use
  # is the init cooldown, where a clock adjustment can lengthen or shorten a
  # single 30-second window and nothing worse.
  defp now_ms, do: System.system_time(:millisecond)
end
