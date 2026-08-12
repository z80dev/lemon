defmodule LemonAgent.ContextRegistry do
  @moduledoc """
  Runtime registry for prompt sections contributed by apps outside the platform.

  `CodingAgent.SystemPrompt.build/2` assembles the prompt from a fixed list of
  sections it names in source: the runtime banner, skills, the memory and
  learning workflows, the workspace and its bootstrap files. That list is right
  for context the platform owns, but a satellite integration that has something
  to say on every turn — a memory backend carrying a model of the user, say —
  has nowhere to appear in it. It registers here instead, at boot, exactly as a
  satellite tool registers with `LemonAgent.ToolRegistry`:

      LemonAgent.ContextRegistry.register(:my_context, MyIntegration.ContextContributor)

  ## The contract

  This module is a behaviour, and a contributor should say so:

      defmodule MyIntegration.ContextContributor do
        @behaviour LemonAgent.ContextRegistry

        @impl true
        def contribute(_request) do
          {:ok, %{title: "What I know", body: "..."}}
        end
      end

  `contribute/1` is the one required callback. It takes the request map
  described by `t:request/0` and returns either `{:ok, spec}` — one
  `t:section_spec/0`, or a list of them — or `:skip` when it has nothing to add
  for this turn. An empty list means the same thing as `:skip`. `collect/2`
  gathers the answers into `t:section/0` values in registration order, and the
  caller places each one according to its `:placement`.

  `timeout_ms/1` is optional, and asks for a different budget on this particular
  turn. See *Budgets* below.

  ## Placement, and the prompt cache

  Every section carries a `t:placement/0`: `:system` puts it in the system
  prompt, `:user_message` puts it in the user message that opens the turn. A
  spec that does not say is `:system`, which is what every contributor written
  before this field existed already got.

  Choosing between them is not a matter of where the text reads best. It is the
  difference between a section that is nearly free after the first turn and one
  that re-bills the entire prompt on every turn, and the number is large enough
  to be worth stating before anyone writes a contributor.

  The provider caches a prefix of the request. For Anthropic, the whole system
  prompt goes out as one block marked `cache_control: ephemeral` (see
  `build_system_prompt/2` in `LemonAi.Providers.Anthropic`), and a second
  breakpoint is placed on the last user message
  (`add_cache_control_to_last_user_message/1` in the same module). The second
  breakpoint's prefix *contains* the system prompt. A cache entry is matched by
  exact bytes, so changing one character of the system prompt misses both
  breakpoints: the turn pays full input price for the whole conversation so far,
  plus a 1.25x write to re-establish the entry, instead of the tenth of input
  price a cache read costs.

  The rule of thumb, and it is the whole of it:

  > **If the text can differ between two consecutive turns, it belongs in
  > `:user_message`. If it is the same all session, it belongs in `:system`.**

  What that costs when it goes the other way was measured rather than estimated.
  A contributor here regenerated its text on 47% of turn boundaries — it
  embedded the user's current message, so its answer was newly written prose
  each turn. Placed in the system prompt over a 60-turn Sonnet 4 coding session,
  that took the session from $3.40 to $14.58: **$11.18 of pure cache churn**,
  for text whose only defect was being in the wrong half of the prompt.

  ### The trap

  Moving the section *within* the system prompt does not help, and it is the
  first thing everyone tries. The system prompt is a single cached block, so
  there is no "after the breakpoint" inside it; and the user-message breakpoint's
  prefix includes all of it, so that one misses too. Only two placements
  preserve the cache — stable text anywhere in the prefix, or volatile text
  after the last breakpoint. That is what the two values of `t:placement/0` are,
  and it is why a contributor with both stable and volatile material returns a
  *list*: the stable half stays in the cached prefix and the volatile half rides
  the user message, where changing it costs nothing but its own tokens.

  A placement the registry does not recognise is a wrong shape and drops the
  spec, exactly as a missing title would. It is deliberately not coerced to
  `:system`: a contributor that believes it is sending volatile text to the user
  message, and is quietly given the cache-breaking placement instead, is the
  precise bug this field exists to prevent.

  Declaring `@behaviour` is not enforced — `register/2` accepts any module that
  exports `contribute/1` — but it is what turns a typo into a compiler warning
  in the contributor's own build rather than a section that never appears. A
  module that is in the build and does *not* export `contribute/1` is a defect
  the registry can see, and it says so once, loudly, at registration; see
  `register/2`.

  ## This runs on the turn path

  The system prompt is rebuilt for every user message, so `collect/2` sits
  directly between the user pressing enter and the first token going out. A
  contributor that blocks for a second makes every turn a second slower, and a
  contributor that blocks forever hangs the session. That is the whole reason
  for the shape of this module.

  The rule that follows from it, and the one that is easiest to get wrong:
  **`contribute/1` returns a value the contributor already has.** It reads a
  cached string out of its own GenServer or ETS table and returns it. It does
  not call an HTTP API, query a database, or wait on a network round trip while
  the turn is held open. A contributor whose data is not ready yet returns
  `:skip` and appears on the next turn instead; a section arriving one turn late
  is invisible to the user, while a turn that stalls is not.

  ## Budgets

  Every contributor is given 250ms to answer and is killed and dropped when it
  overruns. That is the right number for the rule above — reading a cached value
  takes microseconds — and it is what a contributor gets by exporting
  `contribute/1` alone.

  The exception the default cannot express is a *cold* turn. A cache that is
  populated in the background is empty on the first turn of a new session, and
  only there; on that one turn, waiting a beat is worth more than the section
  arriving a turn late, and on every turn afterwards waiting is pure cost. So a
  contributor may export

      @spec timeout_ms(LemonAgent.ContextRegistry.request()) :: pos_integer()
      def timeout_ms(request)

  and return a larger budget **on exactly the turns where it can use one**, and
  the default on all the others. A contributor that returns a raised constant on
  every turn has not bought itself anything — it has made every steady-state turn
  slower for a section it already had ready, which is the opposite of the point.
  Returning 250 unless there is something concrete to wait for is the correct
  behaviour, and not exporting the callback at all is better still.

  Whatever a contributor asks for, the registry decides. The budget it is
  actually held to is

      min(what it asked for, the caller's `:timeout_ms` if given, 3000)

  floored at 1ms, so no contributor can hang a turn however large a number it
  returns, and a caller that passes `:timeout_ms` keeps an absolute ceiling over
  every contributor regardless of what they ask. Resolving the budget is itself
  defended: a `timeout_ms/1` that raises, exits, blocks, or answers with
  anything that is not a positive integer simply gets the default.

  Budgets are per contributor, not per call. All contributors start together,
  each is dropped when *its own* budget elapses, and the call as a whole ends
  when the largest of them does — so one contributor asking for 3000ms never
  buys a 250ms contributor extra time, and never turns a slow neighbour into a
  section it should not have produced.

  ### What a call costs

  Deciding the budgets is work of its own, and it happens before any contributor
  starts, so it belongs in the bound rather than hidden inside it. Writing
  `asked(i)` for what contributor `i`'s `timeout_ms/1` returned — 250 for one
  that does not export it — a call is bounded by

      budget(i) = max(1, min(asked(i), caller's :timeout_ms, 3000))
      resolve   = 50 if any registered contributor exports timeout_ms/1, else 0
      collect  <= resolve + max(budget(1), ..., budget(N))

  Worst case, therefore, `50 + 3000 = 3050`ms; with no `timeout_ms/1` anywhere,
  250ms flat.

  The property worth relying on is that **no term in that is a sum over `N`**.
  Budgets are resolved concurrently, under one shared 50ms deadline, and the
  contributors then run concurrently under their own. Registering an `N+1`-th
  contributor adds nothing to the bound unless it asks for a longer budget than
  every contributor already registered — which is what makes this a seam a third
  party can join without having to know who else is in it.

  ## Isolation

  Contributors are third-party code, so `collect/2` assumes each one is broken
  and defends against it. Every contributor runs concurrently in its own
  monitored, unlinked process, under its own deadline. A contributor that
  raises, throws, exits, is killed, overruns its budget, or returns something
  that is not a section is dropped while the remaining contributors still
  return. There is no failure mode in which a satellite's bug becomes an error
  the user sees or a turn that never starts — the worst it can do is not appear
  in the prompt.

  Drops are logged at the level their cause deserves. Overrunning a budget is
  routine — a cache that is still warming does exactly that, once, and answers
  on the next turn — so it is logged at debug; warning about a system working as
  designed, once per session, only teaches operators to skim the log. A raise,
  an exit, or a value of the wrong shape is a bug in the contributor and is
  logged at warning.

  Shape checking is deliberately strict, because a section is concatenated
  straight into the prompt. Titles and bodies must be binaries and are trimmed;
  a section whose title or body trims to the empty string is dropped rather than
  emitted as a heading with nothing under it. A `:placement`, when given, must be
  one of the two atoms. Anything else — a bare string, an `{:ok, "text"}`
  without the map, a body that is a number — is a wrong shape and is discarded.

  When a contributor returns a *list*, each spec is checked on its own and one
  bad spec costs only itself. The good ones still reach the prompt, for the same
  reason a broken contributor never costs its neighbours their sections: the two
  halves of a split contribution are independent pieces of work, and a typo in
  the volatile one is no reason to throw away the stable one.

  ## Size

  Time and shape are not the only ways a contributor can be expensive. A section
  is concatenated into a prompt, and a `:system` section is concatenated into the
  cached prefix that goes out again on every turn of the session, so its *length*
  is billed repeatedly whether or not it ever changes. Nothing above bounds that:
  titles and bodies are trimmed, not measured, and a contributor returning 500
  sections of 200 bytes puts 100 KB into the system prompt — measured, and the
  prompt it was measured on grew to 111 KB.

  So a contributor is allowed at most **eight sections totalling 16 KB** of title
  and body per turn, and what it gets is the *prefix* of what it returned that
  fits: sections are taken in the order it listed them until the next one would
  not fit, and that one and everything after it are dropped and logged at
  warning. Taking a prefix rather than whichever subset happens to fit is what
  lets a contributor decide what survives — it orders its sections — instead of
  having to reason about which of them were selected.

  Three things about the shape of that bound are deliberate.

  It **drops whole sections rather than truncating one**. The registry has no
  idea where another app's prose can be cut, and a body cut mid-sentence still
  reads to the model as a complete claim — a recalled note trimmed at the wrong
  clause can assert the opposite of what it said. A contributor that has to fit a
  budget cuts its own text, where the meaning is known and a sentence can be
  dropped whole.

  It is **per contributor rather than per call**, exactly as a budget is. A
  shared ceiling would mean that registering an `N+1`-th contributor silently
  shrank what an existing one was allowed to say, which is precisely the property
  this seam promises a third party it need not think about. How many
  contributors a node has is a small fact fixed at boot by whoever assembled the
  build; what one of them returns on a given turn is neither small nor fixed.

  And it is a **backstop against a bug, not a budget to design against**. The
  motivating contribution is two sections of a few kilobytes. A contributor
  sitting near either limit is contributing something it should be budgeting
  itself, and it will be the first to know.

  ## Registration is a boot-time operation

  Registrations live in `:persistent_term`, so they survive a supervisor restart
  and may be made before the consuming app has started. That durability is
  bought with a write cost that is unusual and worth stating plainly: storing a
  term that does not fit in one machine word triggers a **global garbage
  collection** — every process on the node is made runnable at once to scan its
  heap — and the cost of a write grows with the number of terms already stored.
  It is a read-optimised structure being written to.

  So: `register/2` belongs in an application callback, called once as the node
  boots. It does not belong on a session path, in a config reload, in a
  `setup` block that runs per test, or anywhere else that repeats. Registering
  is idempotent per name — registering the same name twice replaces the module
  in place, keeping its original position in the order — and a re-registration
  that changes nothing is free, because the runtime elides a write whose value
  equals what is already stored (`:persistent_term`'s own documented
  optimisation, which is why this module does not compare the values itself).
  A registration that *does* change something pays the full cost.

  `unregister/1` exists for the case where a contributor must be taken out of
  the prompt for the remaining life of the node — a satellite shutting down, a
  test cleaning up after itself. It is not the other half of a register /
  unregister pair to be run per session; using it that way would put a global GC
  on the turn path twice over. A contributor that has nothing to say on a given
  turn returns `:skip`; that is the mechanism for appearing and disappearing,
  and it costs nothing.
  """

  require Logger

  @key {__MODULE__, :registered}

  @default_timeout_ms 250

  # The two placements a spec may name. A spec that names neither is `:system`;
  # a spec that names anything else is a wrong shape. See *Placement, and the
  # prompt cache* in the moduledoc for why this is not coerced.
  @placements [:system, :user_message]
  @default_placement :system

  # The hard ceiling on any one contributor, whatever it asks for and whatever
  # the caller allows. It is the number a human would notice as a stall on a
  # cold start and forgive once, and it is small enough that a contributor
  # returning nonsense — or a large number on every turn — still cannot make a
  # session unusable.
  @max_timeout_ms 3_000

  # Deciding a budget is a lookup ("is this session's cache cold?"), so the
  # decision itself gets a small fixed slice and nothing more. A `timeout_ms/1`
  # that cannot answer within it is already misbehaving and is held to the
  # default, exactly as one that raises would be.
  @budget_timeout_ms 50

  # What one contributor may put into a turn, in sections and in bytes of title
  # plus body. Both are backstops against a contributor that has gone wrong
  # rather than budgets a healthy one should ever approach — the motivating
  # contribution is two sections of a few kilobytes. See *Size* in the moduledoc
  # for why the bound is per contributor and why it drops whole sections instead
  # of truncating one.
  @max_sections 8
  @max_bytes 16_384

  @typedoc """
  What the turn knows about itself, passed to every contributor.

  Every field is optional: a caller building a prompt outside a session has no
  session key, and a contributor that needs one returns `:skip`. `:query` is the
  user message that triggered this turn, for contributors that rank their
  cached material by relevance.
  """
  @type request :: %{
          optional(:cwd) => String.t(),
          optional(:session_key) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:agent_id) => String.t() | nil,
          optional(:run_id) => String.t() | nil,
          optional(:session_scope) => :main | :subagent,
          optional(:query) => String.t()
        }

  @typedoc """
  Where a section goes: the system prompt, or the user message opening the turn.

  `:system` is the default and is the right answer only for text that is the
  same on every turn of a session. Volatile text belongs in `:user_message`;
  see *Placement, and the prompt cache* in the moduledoc for what the difference
  is worth.
  """
  @type placement :: :system | :user_message

  @typedoc """
  What a contributor returns: a heading, its body, and optionally where it goes.

  `:placement` defaults to `:system`, so a contributor written before that field
  existed keeps behaving exactly as it did.
  """
  @type section_spec :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          optional(:placement) => placement()
        }

  @typedoc """
  One contributed prompt section, tagged with the name it registered under and
  resolved to a placement.

  A contributor that returns several specs gets several sections, all carrying
  its single registered `:name`; `:name` identifies the contributor, not the
  section.
  """
  @type section :: %{
          name: atom(),
          title: String.t(),
          body: String.t(),
          placement: placement()
        }

  @type contributor_name :: atom()
  @type entry :: {contributor_name(), module()}

  @doc """
  This turn's section or sections, or `:skip` when there is nothing to add.

  Called on the turn path, in a process of the contributor's own, under a
  deadline it does not control. It must return a value it already has — see
  *This runs on the turn path* in the moduledoc.

  Return one `t:section_spec/0` for a single section, or a list of them to place
  parts of the contribution differently — typically stable material in the
  system prompt and volatile material in the user message, which is what keeps
  the prompt cache intact. An empty list is `:skip`. Anything else is treated as
  a bug in the contributor: a spec whose title or body is not a non-blank
  binary, or whose `:placement` is not one of the `t:placement/0` atoms, is
  dropped and logged, and in a list the remaining specs still stand.

  What comes back is also bounded in size: at most #{@max_sections} sections
  totalling #{@max_bytes} bytes of title and body, with the overflow dropped from
  the end. See *Size* in the moduledoc — a contributor that can approach that
  should be budgeting its own text.
  """
  @callback contribute(request()) :: {:ok, section_spec() | [section_spec()]} | :skip

  @doc """
  How long this turn's `contribute/1` may take, in milliseconds.

  Optional. Export it only to ask for a *larger* budget on the specific turns
  that can use one — a cold cache, typically — and return
  `#{@default_timeout_ms}` on every other turn. The registry clamps whatever is
  returned; see *Budgets* in the moduledoc. This runs on the turn path too, and
  under a tighter bound than `contribute/1` does, so it must be a lookup rather
  than any kind of work.
  """
  @callback timeout_ms(request()) :: pos_integer()

  @optional_callbacks timeout_ms: 1

  @doc """
  Register `module` under `name`, replacing any previous registration for it.

  Call this once, from an application callback, as the node boots — never per
  session. See *Registration is a boot-time operation* in the moduledoc for
  what the write costs.

  Replacement keeps the name's original position, so re-registering never
  reorders the prompt. `module` need not be loadable yet — the application that
  owns it may not have started — but a module that is still absent when
  `all/0` runs is filtered out there rather than failing at the call site.

  ## Misregistration

  A module that is loadable and does not export `contribute/1` cannot ever
  contribute, and that is a fact available here rather than a suspicion, so it
  is logged at error, once, naming the callback that is missing. The entry is
  still stored, and `all/0` filters it out; the alternative — refusing the
  registration — is rejected for two reasons. It could not be applied
  consistently, because the same call must be accepted when the module has
  simply not been loaded yet (see `all/0`: the filter is a view, not a fact
  about the build), so a registry that sometimes rejects would reject or accept
  the identical call depending on the order applications happened to start. And
  storing keeps the name's slot in the order, so a corrected registration made
  later — a hot reload, a satellite fixing itself on restart — lands where it
  was always meant to.

  What matters is that a misregistration is diagnosed here and stays silent
  afterwards: it is skipped by `all/0` rather than spawned, failed, and warned
  about on every turn for the life of the node.
  """
  @spec register(contributor_name(), module()) :: :ok
  def register(name, module) when is_atom(name) and is_atom(module) do
    check_contract(module)

    put(List.keystore(stored(), name, 0, {name, module}))
  end

  defp check_contract(module) do
    cond do
      contributor?(module) ->
        :ok

      Code.ensure_loaded?(module) ->
        Logger.error(
          "[LemonAgent.ContextRegistry] #{inspect(module)} does not export contribute/1 " <>
            "and will never contribute a section; add " <>
            "`@behaviour LemonAgent.ContextRegistry` to it and implement the callback"
        )

      true ->
        Logger.warning(
          "[LemonAgent.ContextRegistry] #{inspect(module)} is not loadable; " <>
            "registered anyway, and checked again once it is in the build"
        )
    end
  end

  @doc """
  Remove the registration for `name`.

  For a contributor leaving for good — a satellite shutting down, a test
  cleaning up — not for one that has nothing to say this turn, which returns
  `:skip` instead. This writes `:persistent_term`; see `register/2`.
  """
  @spec unregister(contributor_name()) :: :ok
  def unregister(name) when is_atom(name), do: put(List.keydelete(stored(), name, 0))

  @doc """
  Every registration, in registration order, filtered to modules that can
  actually contribute in this build — loadable, and exporting `contribute/1`.

  The filter is a view over the stored table, not a change to it: an entry whose
  module has not been loaded yet is still registered and reappears here once its
  application starts. An entry whose module is loaded but does not implement the
  behaviour was reported at `register/2` and is skipped here, so it costs a
  turn nothing rather than a spawn, a failure and a warning per turn.
  """
  @spec all() :: [entry()]
  def all do
    Enum.filter(stored(), fn {_name, module} -> contributor?(module) end)
  end

  defp contributor?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :contribute, 1)
  end

  @doc """
  Ask every registered contributor for its sections and return the ones that
  answered, in registration order.

  Sections of every placement come back together, interleaved in registration
  order; `split/1` separates them when the caller is ready to place them. A
  contributor that returned a list contributes its sections here in the order it
  listed them.

  Each contributor answers within its own budget — `#{@default_timeout_ms}`ms
  unless it exports `timeout_ms/1` to ask for more, capped at
  `#{@max_timeout_ms}`ms — and the call as a whole returns when the largest of
  those budgets has elapsed, plus the `#{@budget_timeout_ms}`ms it may spend
  resolving those budgets first. The whole bound, as a formula, is in the
  *Budgets* section of the moduledoc; the short version is that it depends on
  the largest budget asked for and not on how many contributors are registered.

  Supported options:

    * `:timeout_ms` — an absolute ceiling on every contributor's budget, over
      and above the registry's own. Given, no contributor may exceed it, whether
      or not it asked for more; omitted, contributors keep whatever the registry
      allows them. A value that is not a positive integer is meaningless rather
      than unlimited, so it falls back to `#{@default_timeout_ms}`.

  Contributors that return `:skip`, an empty list, raise, exit, overrun their
  budget, or return a value that is not a `t:section_spec/0` (or a list of them)
  are dropped; the rest still return. With nothing registered this returns `[]`
  without spawning anything, which is the common case on a turn.

  Each contributor's surviving sections are then bounded: at most
  #{@max_sections} of them, totalling at most #{@max_bytes} bytes of title and
  body, keeping the prefix of what it returned that fits and dropping the rest
  with a warning. `collect/2` therefore returns at most
  #{@max_sections} x N sections for N registered contributors, however
  enthusiastic any one of them is. *Size* in the moduledoc has the reasoning.
  """
  @spec collect(request(), keyword()) :: [section()]
  def collect(request, opts \\ []) when is_map(request) and is_list(opts) do
    case all() do
      [] -> []
      entries -> gather(entries, request, ceiling(opts))
    end
  end

  @doc """
  Partition collected sections into `{system, user_message}`.

  Order within each half is the order `collect/2` returned them in, so each half
  is still in registration order. A caller renders the first half into the
  system prompt and the second into the user message opening the turn; putting
  the second half in the first place is the mistake described under *Placement,
  and the prompt cache* in the moduledoc.

  Collect once per turn and split the result. Collecting twice pays every
  contributor's budget twice, and — since a contributor's whole reason for the
  `:user_message` placement is that its text changes — can return two different
  answers for one turn.

  ## Sections this did not produce

  Everything `collect/2` returns carries one of the two placements, so the rules
  below only ever bite on a list a caller assembled by hand — a test, or a caller
  placing sections it got from somewhere else. They are the rules `collect/2`
  applies to a spec, for the same reasons. A section that names **no** placement
  is a `:system` section, because that is what the field's documented default
  means and a hand-built map is entitled to it. A section naming **something
  else**, or that is not a map at all, is a wrong shape: it is dropped and logged
  rather than coerced into either half, since coercing it into the first half is
  the cache-breaking mistake `t:placement/0` exists to prevent and coercing it
  into the second would put text into the user's own message on the strength of a
  typo.
  """
  @spec split([section()]) :: {[section()], [section()]}
  def split(sections) when is_list(sections) do
    sections
    |> Enum.filter(&placeable?/1)
    |> Enum.split_with(&(placement_of(&1) == :system))
  end

  defp placeable?(section) do
    placement = placement_of(section)

    if placement in @placements do
      true
    else
      Logger.warning(
        "[LemonAgent.ContextRegistry] split/1 dropped a section with placement " <>
          "#{inspect(placement)}; expected one of #{inspect(@placements)}"
      )

      false
    end
  end

  defp placement_of(section) when is_map(section) do
    Map.get(section, :placement, @default_placement)
  end

  defp placement_of(_section), do: nil

  # Budgets are resolved first, for every contributor, and only then is anything
  # started — so the contributors do start together and one contributor's slow
  # answer about its own budget cannot eat into another's. Each then carries its
  # own deadline, measured from that common start.
  #
  # The processes are monitored but deliberately *not* linked. A linked worker
  # that is killed outright takes its caller with it, which would turn a broken
  # satellite into a dead turn; with only a monitor, its death is a `:DOWN`
  # message and nothing more.
  defp gather(entries, request, ceiling) do
    parent = self()

    budgets = resolve_budgets(entries, request, ceiling)

    start = System.monotonic_time(:millisecond)

    workers =
      Enum.map(budgets, fn {name, module, budget} ->
        {name, start_contributor(parent, module, request), start + budget}
      end)

    outcomes = await_all(workers)

    Enum.flat_map(workers, fn {name, _worker, _deadline} ->
      name
      |> section_from(Map.fetch!(outcomes, name))
      |> within_limits(name)
    end)
  end

  # The size bound, applied once per contributor over everything it contributed
  # this turn — a single spec can be a megabyte just as easily as a list can, so
  # this sits above `section_from/2` rather than inside either of its clauses.
  # See *Size* in the moduledoc.
  defp within_limits(sections, name) do
    kept = take_within_limits(sections, 0, 0)

    case length(sections) - length(kept) do
      0 ->
        sections

      dropped ->
        Logger.warning(
          "[LemonAgent.ContextRegistry] contributor #{inspect(name)} exceeded its section " <>
            "budget (#{@max_sections} sections, #{@max_bytes} bytes); kept #{length(kept)}, " <>
            "dropped #{dropped}"
        )

        kept
    end
  end

  # Stops at the first section that does not fit rather than skipping it and
  # trying the next, so what survives is always a prefix of what was returned.
  # A contributor can then decide what it keeps by ordering its sections, which
  # it can reason about; "whichever of my sections happened to fit" is not
  # something anyone can reason about.
  defp take_within_limits([], _count, _bytes), do: []

  defp take_within_limits([section | rest], count, bytes) do
    bytes = bytes + section_bytes(section)

    if count < @max_sections and bytes <= @max_bytes do
      [section | take_within_limits(rest, count + 1, bytes)]
    else
      []
    end
  end

  defp section_bytes(%{title: title, body: body}), do: byte_size(title) + byte_size(body)

  # Waiting on the nearest deadline first is what keeps the budgets independent:
  # the worker being waited on is always the one with the least time left, so a
  # contributor that asked for seconds can never hold a 250ms contributor open
  # past its own deadline. A worker that answered while an earlier one was still
  # being waited on has its reply sitting in the mailbox already and is taken
  # from there immediately, deadline or not — it did answer in time. Results are
  # keyed by name so `gather/3` can put them back into registration order.
  defp await_all(workers) do
    workers
    |> Enum.sort_by(fn {_name, _worker, deadline} -> deadline end)
    |> Enum.map(fn {name, worker, deadline} -> {name, await(worker, remaining(deadline))} end)
    |> Map.new()
  end

  defp start_contributor(parent, module, request) do
    start_worker(parent, fn -> module.contribute(request) end)
  end

  defp start_worker(parent, fun) do
    ref = make_ref()

    {pid, monitor_ref} = spawn_monitor(fn -> send(parent, {ref, invoke(fun)}) end)

    {ref, pid, monitor_ref}
  end

  defp await({ref, pid, monitor_ref}, remaining) do
    receive do
      {^ref, outcome} ->
        Process.demonitor(monitor_ref, [:flush])
        outcome

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:failed, reason}
    after
      remaining ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        discard_late_reply(ref)
        {:failed, :timeout}
    end
  end

  # The worker may have answered in the instant between the deadline expiring
  # and the kill landing. That reply is no longer wanted, but leaving it in the
  # mailbox would leak into whatever this process receives next.
  defp discard_late_reply(ref) do
    receive do
      {^ref, _outcome} -> :ok
    after
      0 -> :ok
    end
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp invoke(fun) do
    {:value, fun.()}
  rescue
    e -> {:failed, Exception.message(e)}
  catch
    kind, reason -> {:failed, {kind, reason}}
  end

  # Every contributor's budget, clamped to what the registry and the caller
  # allow. `timeout_ms/1` is third-party code on the turn path, so it is
  # defended exactly as `contribute/1` is — its own monitored process, its own
  # small bound — and anything other than a positive integer arriving in time is
  # not an error, only a reason to use the default.
  #
  # This step is concurrent for the same reason the contributors are, and it is
  # the reason `collect/2`'s bound has no term that sums over the number of
  # contributors. Resolved one after another, N callbacks that each decline to
  # answer would cost N x @budget_timeout_ms of pure arithmetic *before* the
  # first contributor started. Started together under one shared deadline, they
  # cost @budget_timeout_ms once. Waiting on them in registration order rather
  # than by deadline is fine here where it is not in `await_all/1`, because the
  # deadline is the same for all of them: a callback that already answered has
  # its reply in the mailbox and is taken from there even when the shared
  # deadline has since passed.
  defp resolve_budgets(entries, request, ceiling) do
    parent = self()
    deadline = System.monotonic_time(:millisecond) + @budget_timeout_ms

    entries
    |> Enum.map(fn {name, module} -> {name, module, start_budget(parent, module, request)} end)
    |> Enum.map(fn {name, module, worker} ->
      {name, module, clamp(requested_budget(worker, module, deadline), ceiling)}
    end)
  end

  # `nil` rather than a worker for the common case: a contributor that does not
  # export the callback has nothing to ask and nothing to spawn.
  defp start_budget(parent, module, request) do
    if function_exported?(module, :timeout_ms, 1) do
      start_worker(parent, fn -> module.timeout_ms(request) end)
    end
  end

  defp requested_budget(nil, _module, _deadline), do: @default_timeout_ms

  defp requested_budget(worker, module, deadline) do
    worker
    |> await(remaining(deadline))
    |> budget_or_default(module)
  end

  defp budget_or_default({:value, budget}, _module) when is_integer(budget) and budget > 0 do
    budget
  end

  defp budget_or_default(outcome, module) do
    Logger.debug(
      "[LemonAgent.ContextRegistry] #{inspect(module)}.timeout_ms/1 gave " <>
        "#{inspect(outcome)}; using #{@default_timeout_ms}ms"
    )

    @default_timeout_ms
  end

  defp clamp(budget, ceiling) do
    budget
    |> min(ceiling)
    |> min(@max_timeout_ms)
    |> max(1)
  end

  defp section_from(_name, {:value, :skip}), do: []

  # A list is checked spec by spec, and one bad spec drops only itself. The
  # specs in a list are independent pieces of work — characteristically a stable
  # section and a volatile one, placed differently — so a typo in one is no more
  # a reason to discard the other than one contributor's bug is a reason to
  # discard another's section. An empty list yields nothing, which is `:skip`
  # spelled differently and is not worth logging.
  defp section_from(name, {:value, {:ok, specs}}) when is_list(specs) do
    Enum.flat_map(specs, &section_from_spec(name, &1))
  end

  defp section_from(name, {:value, {:ok, spec}}) when is_map(spec) do
    section_from_spec(name, spec)
  end

  defp section_from(name, {:value, other}) do
    log_dropped(name, {:invalid_section, other})
    []
  end

  defp section_from(name, {:failed, reason}) do
    log_dropped(name, reason)
    []
  end

  defp section_from_spec(name, %{title: title, body: body} = spec)
       when is_binary(title) and is_binary(body) do
    placement = Map.get(spec, :placement, @default_placement)

    build_section(name, placement, String.trim(title), String.trim(body))
  end

  defp section_from_spec(name, other) do
    log_dropped(name, {:invalid_section, other})
    []
  end

  # An unrecognised placement is dropped rather than coerced to the default. The
  # default is the cache-breaking one, so coercing would take a contributor that
  # meant to send volatile text to the user message and silently give it the
  # placement that costs money on every turn — the exact failure the field
  # exists to make impossible. See the moduledoc.
  defp build_section(name, placement, _title, _body) when placement not in @placements do
    log_dropped(name, {:invalid_placement, placement})
    []
  end

  defp build_section(_name, _placement, "", _body), do: []
  defp build_section(_name, _placement, _title, ""), do: []

  defp build_section(name, placement, title, body) do
    [%{name: name, title: title, body: body, placement: placement}]
  end

  # A contributor that was merely late is a routine state rather than a fault: a
  # cache that is still warming answers on the next turn, and a warning per
  # session about a system behaving as designed only teaches operators to skim
  # the log. A raise, an exit, a killed process or a value of the wrong shape is
  # a bug in the contributor, and stays loud.
  defp log_dropped(name, :timeout) do
    Logger.debug(
      "[LemonAgent.ContextRegistry] contributor #{inspect(name)} dropped: " <>
        ":timeout (late; it may appear on a later turn)"
    )
  end

  defp log_dropped(name, reason) do
    Logger.warning(
      "[LemonAgent.ContextRegistry] contributor #{inspect(name)} dropped: #{inspect(reason)}"
    )
  end

  defp ceiling(opts) do
    case Keyword.fetch(opts, :timeout_ms) do
      :error -> @max_timeout_ms
      {:ok, timeout} when is_integer(timeout) and timeout > 0 -> timeout
      {:ok, _other} -> @default_timeout_ms
    end
  end

  # The raw table. Registration reads and writes this rather than `all/0` so
  # that registering one contributor cannot delete another whose application has
  # not started yet — the filter in `all/0` is a view, not a fact about the
  # build.
  defp stored do
    :persistent_term.get(@key, [])
  end

  # No "has this actually changed?" guard, deliberately. `:persistent_term.put/2`
  # already special-cases a write whose value equals what is stored and returns
  # without touching the term or triggering a global GC — its documentation says
  # so explicitly, and adds that there is therefore no need for a caller to
  # compare the values itself. Re-registering an unchanged contributor at boot is
  # free; a comparison here would only duplicate the runtime's in Elixir.
  defp put(entries) do
    :persistent_term.put(@key, entries)
    :ok
  end
end
