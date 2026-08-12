defmodule LemonAgent.ContextRegistryTest do
  @moduledoc """
  The registry's one load-bearing promise: a broken contributor costs the turn
  its section and nothing else.

  Every way a third party can fail — raising, exiting, hanging, answering with
  the wrong shape, answering with nothing in it, not implementing the callback
  at all — is exercised here alongside a healthy contributor, because the
  interesting assertion is never that the bad one was dropped but that the good
  one still came back.

  The second thing under test is the published contract itself: that the
  behaviour declares what the moduledoc says it declares, that the cost of
  a `collect/2` is bounded by the largest budget asked for rather than by the
  number of contributors registered, and that a section ends up in the half of
  the prompt it asked for — the half being the difference between a cached
  prefix and a re-billed one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonAgent.ContextRegistry

  defmodule Healthy do
    def contribute(_request), do: {:ok, %{title: "User model", body: "Prefers green."}}
  end

  defmodule Second do
    def contribute(_request), do: {:ok, %{title: "Recent work", body: "Refactored the runner."}}
  end

  defmodule Skipper do
    def contribute(_request), do: :skip
  end

  # What a third-party contributor is supposed to look like. Declaring the
  # behaviour is the point of the module: if either callback's name or arity
  # were wrong, this file would not compile clean.
  defmodule Declared do
    @behaviour ContextRegistry

    @impl ContextRegistry
    def contribute(_request), do: {:ok, %{title: "Declared", body: "Implements the behaviour."}}

    @impl ContextRegistry
    def timeout_ms(_request), do: 300
  end

  # A module in the build that is not a contributor at all — the typo case, or
  # a name registered against the wrong module.
  defmodule NotAContributor do
    def contribute_to_context(_request), do: {:ok, %{title: "Never", body: "Never asked."}}
  end

  # A `timeout_ms/1` that never answers, paired with a `contribute/1` that
  # answers instantly, so a `collect/2` over several of these measures budget
  # resolution and almost nothing else.
  defmodule BlockingBudget do
    def timeout_ms(_request), do: Process.sleep(5_000)

    def contribute(_request), do: {:ok, %{title: "Blocking", body: "Budget never arrived."}}
  end

  defmodule Raiser do
    def contribute(_request), do: raise("contributor is broken")
  end

  defmodule Exiter do
    def contribute(_request), do: exit(:no_thanks)
  end

  defmodule Killer do
    def contribute(_request) do
      Process.exit(self(), :kill)
      {:ok, %{title: "unreachable", body: "unreachable"}}
    end
  end

  defmodule Sleeper do
    def contribute(_request) do
      Process.sleep(5_000)
      {:ok, %{title: "Too late", body: "Too late"}}
    end
  end

  defmodule Middling do
    # No `timeout_ms/1`, so it is held to the 250ms default however long the
    # rest of the call runs.
    def contribute(_request) do
      Process.sleep(500)
      {:ok, %{title: "Middling", body: "Too slow for the default budget."}}
    end
  end

  defmodule Patient do
    # Asks for more than the default and uses less than it asked for.
    def timeout_ms(_request), do: 800

    def contribute(_request) do
      Process.sleep(500)
      {:ok, %{title: "Patient", body: "Worth the wait."}}
    end
  end

  defmodule Greedy do
    def timeout_ms(_request), do: 10_000

    def contribute(_request) do
      Process.sleep(30_000)
      {:ok, %{title: "Greedy", body: "Never arrives."}}
    end
  end

  defmodule BudgetRaiser do
    def timeout_ms(_request), do: raise("budget is broken")

    def contribute(_request) do
      Process.sleep(5_000)
      {:ok, %{title: "Too late", body: "Too late"}}
    end
  end

  defmodule BudgetExiter do
    def timeout_ms(_request), do: exit(:no_thanks)

    def contribute(_request) do
      Process.sleep(5_000)
      {:ok, %{title: "Too late", body: "Too late"}}
    end
  end

  defmodule BudgetString do
    def timeout_ms(_request), do: "abc"

    def contribute(_request) do
      Process.sleep(5_000)
      {:ok, %{title: "Too late", body: "Too late"}}
    end
  end

  defmodule BudgetZero do
    def timeout_ms(_request), do: 0

    def contribute(_request) do
      Process.sleep(5_000)
      {:ok, %{title: "Too late", body: "Too late"}}
    end
  end

  defmodule Blank do
    def contribute(_request), do: {:ok, %{title: "Title", body: "   \n  "}}
  end

  defmodule BlankTitle do
    def contribute(_request), do: {:ok, %{title: "  ", body: "Body"}}
  end

  defmodule Untrimmed do
    def contribute(_request), do: {:ok, %{title: "  Padded  ", body: "\n  Body text \n"}}
  end

  defmodule Echo do
    def contribute(request), do: {:ok, %{title: "Echo", body: inspect(request)}}
  end

  defmodule BareString do
    def contribute(_request), do: "just a string"
  end

  defmodule OkString do
    def contribute(_request), do: {:ok, "just a string"}
  end

  defmodule NumericFields do
    def contribute(_request), do: {:ok, %{title: 1, body: 2}}
  end

  defmodule NilBody do
    def contribute(_request), do: {:ok, %{title: "Title", body: nil}}
  end

  # The shape this whole field exists for: the stable half stays in the cached
  # system prefix, the volatile half rides the user message.
  defmodule Split do
    def contribute(_request) do
      {:ok,
       [
         %{title: "How to use me", body: "Stable across the session.", placement: :system},
         %{title: "What I recall", body: "Regenerated this turn.", placement: :user_message}
       ]}
    end
  end

  defmodule UserMessageOnly do
    def contribute(_request) do
      {:ok, %{title: "Recall", body: "Volatile.", placement: :user_message}}
    end
  end

  defmodule BadPlacement do
    def contribute(_request) do
      {:ok,
       [
         %{title: "Good", body: "Kept.", placement: :system},
         %{title: "Bad", body: "Dropped.", placement: :prompt_suffix}
       ]}
    end
  end

  defmodule EmptyList do
    def contribute(_request), do: {:ok, []}
  end

  # The measured shape: 500 sections of 200 bytes, which put 100 KB into a
  # system prompt and took the prompt it was measured on to 111 KB.
  defmodule Verbose do
    def contribute(_request) do
      {:ok, for(i <- 1..500, do: %{title: "Section #{i}", body: String.duplicate("x", 200)})}
    end
  end

  # Well inside the section count and well outside the byte budget on the third
  # section, so the byte limit is the one that bites.
  defmodule Bulky do
    def contribute(_request) do
      {:ok,
       [
         %{title: "One", body: String.duplicate("a", 8_000)},
         %{title: "Two", body: String.duplicate("b", 8_000)},
         %{title: "Three", body: String.duplicate("c", 500)}
       ]}
    end
  end

  # A single spec, not a list, over the byte budget by itself.
  defmodule Enormous do
    def contribute(_request), do: {:ok, %{title: "Huge", body: String.duplicate("x", 20_000)}}
  end

  defmodule ListWithJunk do
    def contribute(_request) do
      {:ok, [%{title: "Good", body: "Kept."}, "not a spec", %{title: "Blank", body: "  "}]}
    end
  end

  setup do
    original = :persistent_term.get({ContextRegistry, :registered}, [])

    on_exit(fn -> :persistent_term.put({ContextRegistry, :registered}, original) end)

    :persistent_term.put({ContextRegistry, :registered}, [])
    :ok
  end

  describe "registration" do
    test "register/all/unregister round-trip preserves registration order" do
      ContextRegistry.register(:second, Second)
      ContextRegistry.register(:healthy, Healthy)

      assert ContextRegistry.all() == [second: Second, healthy: Healthy]

      ContextRegistry.unregister(:second)

      assert ContextRegistry.all() == [healthy: Healthy]
    end

    test "re-registering a name replaces it in place" do
      ContextRegistry.register(:first, Healthy)
      ContextRegistry.register(:second, Second)
      ContextRegistry.register(:first, Skipper)

      assert ContextRegistry.all() == [first: Skipper, second: Second]
    end

    test "all/0 omits a module that is not in this build" do
      capture_log(fn -> ContextRegistry.register(:ghost, :"Elixir.NoSuchContextModule") end)
      ContextRegistry.register(:healthy, Healthy)

      assert ContextRegistry.all() == [healthy: Healthy]
      assert {:ghost, :"Elixir.NoSuchContextModule"} in stored()
    end

    test "unregistering an unknown name is a no-op" do
      ContextRegistry.register(:healthy, Healthy)

      assert ContextRegistry.unregister(:nobody) == :ok
      assert ContextRegistry.all() == [healthy: Healthy]
    end

    test "a module that cannot contribute is reported once and then never asked" do
      log =
        capture_log([level: :error], fn ->
          ContextRegistry.register(:broken, NotAContributor)
        end)

      assert log =~ "NotAContributor"
      assert log =~ "does not export contribute/1"

      # Stored, so a corrected registration later keeps this name's place in the
      # order, but filtered out of the view the turn path uses.
      assert {:broken, NotAContributor} in stored()
      assert ContextRegistry.all() == []

      ContextRegistry.register(:honcho, Healthy)

      {sections, turn_log} = with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end)

      # The regression this guards: a misregistration used to be spawned, fail
      # with `UndefinedFunctionError`, and be logged at warning on every single
      # turn for the life of the node.
      assert [%{name: :honcho}] = sections
      refute turn_log =~ "broken"
      refute turn_log =~ "NotAContributor"
    end

    test "an identical re-registration does not rewrite the stored table" do
      ContextRegistry.register(:healthy, Healthy)

      before = stored()

      ContextRegistry.register(:healthy, Healthy)

      # Not merely equal: the same term. `:persistent_term.put/2` elides a write
      # whose value equals what is stored, so re-registering an unchanged
      # contributor at boot copies nothing and triggers no global GC — which is
      # why `register/2` documents the property instead of guarding for it.
      assert stored() == before
      assert :erts_debug.same(before, stored())

      # And the assertion has teeth: a registration that does change something
      # stores a new term.
      ContextRegistry.register(:second, Second)

      refute :erts_debug.same(before, stored())
    end
  end

  describe "the behaviour" do
    test "declares contribute/1 as required and timeout_ms/1 as optional" do
      callbacks = ContextRegistry.behaviour_info(:callbacks)

      assert {:contribute, 1} in callbacks
      assert {:timeout_ms, 1} in callbacks
      assert ContextRegistry.behaviour_info(:optional_callbacks) == [timeout_ms: 1]
    end

    test "a module declaring the behaviour contributes end to end" do
      ContextRegistry.register(:declared, Declared)

      assert ContextRegistry.collect(%{}) == [
               %{
                 name: :declared,
                 title: "Declared",
                 body: "Implements the behaviour.",
                 placement: :system
               }
             ]
    end
  end

  describe "collect/2" do
    test "returns nothing when no contributor is registered" do
      assert ContextRegistry.collect(%{}) == []
    end

    test "returns a registered contributor's section, tagged with its name" do
      ContextRegistry.register(:honcho, Healthy)

      assert ContextRegistry.collect(%{cwd: "/tmp"}) == [
               %{
                 name: :honcho,
                 title: "User model",
                 body: "Prefers green.",
                 placement: :system
               }
             ]
    end

    test "returns sections in registration order" do
      ContextRegistry.register(:second, Second)
      ContextRegistry.register(:honcho, Healthy)

      assert [%{name: :second}, %{name: :honcho}] = ContextRegistry.collect(%{})
    end

    test "passes the request through to the contributor" do
      ContextRegistry.register(:echo, Echo)

      request = %{cwd: "/work", session_key: "abc", session_scope: :main, query: "hello"}

      assert [%{body: body}] = ContextRegistry.collect(request)
      assert body == inspect(request)
    end

    test "drops a contributor that skips" do
      ContextRegistry.register(:skipper, Skipper)
      ContextRegistry.register(:honcho, Healthy)

      assert [%{name: :honcho}] = ContextRegistry.collect(%{})
    end

    test "trims titles and bodies" do
      ContextRegistry.register(:untrimmed, Untrimmed)

      assert [%{title: "Padded", body: "Body text"}] = ContextRegistry.collect(%{})
    end
  end

  describe "placement" do
    test "a spec that names no placement is a system-prompt section" do
      ContextRegistry.register(:healthy, Healthy)

      # The default, and the reason every contributor written before placement
      # existed keeps behaving exactly as it did.
      assert [%{placement: :system}] = ContextRegistry.collect(%{})
    end

    test "a contributor may place a single section in the user message" do
      ContextRegistry.register(:volatile, UserMessageOnly)

      assert [%{name: :volatile, placement: :user_message}] = ContextRegistry.collect(%{})
    end

    test "a contributor returning a list gets one section per spec, in its order" do
      ContextRegistry.register(:split, Split)

      assert [
               %{name: :split, title: "How to use me", placement: :system},
               %{name: :split, title: "What I recall", placement: :user_message}
             ] = ContextRegistry.collect(%{})
    end

    test "split/1 puts each half where it asked to go, in order" do
      ContextRegistry.register(:split, Split)
      ContextRegistry.register(:honcho, Healthy)
      ContextRegistry.register(:volatile, UserMessageOnly)

      {system, user_message} = ContextRegistry.split(ContextRegistry.collect(%{}))

      assert [%{title: "How to use me"}, %{name: :honcho}] = system
      assert [%{title: "What I recall"}, %{name: :volatile}] = user_message
    end

    test "split/1 on an empty list is two empty lists" do
      assert ContextRegistry.split([]) == {[], []}
    end

    test "an unrecognised placement drops that spec and leaves its sibling" do
      ContextRegistry.register(:bad_placement, BadPlacement)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      # Not coerced to `:system`. A contributor that believes it is sending
      # volatile text to the user message and is quietly given the cached half
      # instead pays for it on every turn of the session, silently — which is
      # the whole reason the field exists.
      assert [%{title: "Good", placement: :system}] = sections
      assert log =~ "contributor :bad_placement dropped"
      assert log =~ "invalid_placement"
      assert log =~ ":prompt_suffix"
    end

    test "one wrong-shaped spec in a list costs only itself" do
      ContextRegistry.register(:mixed, ListWithJunk)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      assert [%{title: "Good", body: "Kept.", placement: :system}] = sections
      assert log =~ "contributor :mixed dropped"
    end

    test "split/1 treats a section with no placement as a system section" do
      # A hand-built section is entitled to the field's documented default, and
      # `split/1` used to raise a `FunctionClauseError` on one instead.
      sections = [
        %{name: :hand_built, title: "No placement", body: "Body"},
        %{name: :volatile, title: "Placed", body: "Body", placement: :user_message}
      ]

      assert {[%{title: "No placement"}], [%{title: "Placed"}]} = ContextRegistry.split(sections)
    end

    test "split/1 drops a section whose placement is not one of the two" do
      sections = [
        %{name: :good, title: "Good", body: "Kept.", placement: :system},
        %{name: :bad, title: "Bad", body: "Dropped.", placement: :prompt_suffix},
        "not a section at all"
      ]

      {{system, user_message}, log} = with_log(fn -> ContextRegistry.split(sections) end)

      # Not coerced into either half. The first half is the cached prefix, which
      # is the direction that must never be taken on a guess; the second is the
      # user's own message, which a typo should not be able to write into.
      assert [%{title: "Good"}] = system
      assert user_message == []
      assert log =~ "split/1 dropped a section with placement :prompt_suffix"
      assert log =~ "split/1 dropped a section with placement nil"
    end

    test "an empty list is :skip" do
      ContextRegistry.register(:empty, EmptyList)
      ContextRegistry.register(:honcho, Healthy)

      {sections, log} = with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end)

      assert [%{name: :honcho}] = sections

      # Nothing to add is not a fault, however it is spelled.
      refute log =~ "contributor :empty dropped"
    end
  end

  describe "collect/2 isolation" do
    test "drops a contributor that raises and still returns the others" do
      ContextRegistry.register(:raiser, Raiser)
      ContextRegistry.register(:honcho, Healthy)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      assert [%{name: :honcho}] = sections
      assert log =~ "contributor :raiser dropped"
    end

    test "drops a contributor that exits and still returns the others" do
      ContextRegistry.register(:exiter, Exiter)
      ContextRegistry.register(:honcho, Healthy)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      assert [%{name: :honcho}] = sections
      assert log =~ "contributor :exiter dropped"
    end

    test "drops a contributor whose process is killed outright" do
      ContextRegistry.register(:killer, Killer)
      ContextRegistry.register(:honcho, Healthy)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      assert [%{name: :honcho}] = sections
      assert log =~ "contributor :killer dropped"
    end

    test "drops a contributor that overruns the timeout, within the deadline" do
      ContextRegistry.register(:sleeper, Sleeper)
      ContextRegistry.register(:honcho, Healthy)

      {micros, {sections, log}} =
        :timer.tc(fn -> with_log(fn -> ContextRegistry.collect(%{}, timeout_ms: 50) end) end)

      assert [%{name: :honcho}] = sections
      assert log =~ "contributor :sleeper dropped"
      assert micros < 2_000_000
    end

    test "a slow contributor does not delay the ones registered after it" do
      ContextRegistry.register(:sleeper, Sleeper)
      ContextRegistry.register(:second, Second)
      ContextRegistry.register(:honcho, Healthy)

      {micros, {sections, _log}} =
        :timer.tc(fn -> with_log(fn -> ContextRegistry.collect(%{}, timeout_ms: 50) end) end)

      assert [%{name: :second}, %{name: :honcho}] = sections
      assert micros < 2_000_000
    end

    test "falls back to the default timeout for a nonsense :timeout_ms" do
      ContextRegistry.register(:honcho, Healthy)

      assert [%{name: :honcho}] = ContextRegistry.collect(%{}, timeout_ms: 0)
      assert [%{name: :honcho}] = ContextRegistry.collect(%{}, timeout_ms: :soon)
    end
  end

  describe "collect/2 budgets" do
    test "honours a contributor that asks for longer than the default" do
      ContextRegistry.register(:patient, Patient)
      ContextRegistry.register(:honcho, Healthy)

      {micros, sections} = :timer.tc(fn -> ContextRegistry.collect(%{}) end)

      assert [
               %{name: :patient, title: "Patient", body: "Worth the wait."},
               %{name: :honcho, body: "Prefers green."}
             ] = sections

      # It slept 500ms, which the 250ms default would have killed, and the call
      # still ended nowhere near the 3s ceiling.
      assert micros > 400_000
      assert micros < 2_500_000
    end

    test "kills a contributor that asks for more than the ceiling at the ceiling" do
      ContextRegistry.register(:greedy, Greedy)

      {micros, {sections, log}} =
        :timer.tc(fn -> with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end) end)

      assert sections == []
      assert log =~ "contributor :greedy dropped"

      # 10s was asked for; 3s is what the registry allows. The bounds are wide
      # so a loaded machine cannot make this flap.
      assert micros > 2_500_000
      assert micros < 8_000_000
    end

    test ":timeout_ms caps a contributor that asks for more than the caller allows" do
      ContextRegistry.register(:patient, Patient)
      ContextRegistry.register(:honcho, Healthy)

      {micros, {sections, _log}} =
        :timer.tc(fn ->
          with_log([level: :debug], fn -> ContextRegistry.collect(%{}, timeout_ms: 100) end)
        end)

      assert [%{name: :honcho}] = sections
      assert micros < 1_000_000
    end

    test "each contributor is held to its own budget, not the longest one" do
      ContextRegistry.register(:greedy, Greedy)
      ContextRegistry.register(:middling, Middling)
      ContextRegistry.register(:honcho, Healthy)

      {micros, {sections, _log}} =
        :timer.tc(fn -> with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end) end)

      # `:middling` answers in 500ms and has no `timeout_ms/1`, so it is dropped
      # at its own 250ms even though `:greedy` keeps the call open for 3s; the
      # fast contributor is unaffected by either of them.
      assert [%{name: :honcho, body: "Prefers green."}] = sections
      assert micros < 8_000_000
    end

    test "resolving budgets costs one budget slice however many contributors ask" do
      contributors = 10

      for i <- 1..contributors do
        ContextRegistry.register(:"blocking_#{i}", BlockingBudget)
      end

      {micros, {sections, _log}} =
        :timer.tc(fn -> with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end) end)

      assert length(sections) == contributors

      # Ten `timeout_ms/1` callbacks that never answer, each held to the
      # registry's 50ms slice, and a `contribute/1` that returns immediately —
      # so essentially all of this is budget resolution. Resolved one after
      # another it could not finish under 500ms; resolved together it is 50ms
      # once. The bound sits between the two with room on both sides: 150ms
      # under the serial floor, and 300ms of slack over the concurrent cost for
      # a loaded machine.
      assert micros < 350_000
    end

    test "a timeout_ms/1 that misbehaves falls back to the default budget" do
      for {name, module} <- [
            budget_raiser: BudgetRaiser,
            budget_exiter: BudgetExiter,
            budget_string: BudgetString,
            budget_zero: BudgetZero
          ] do
        :persistent_term.put({ContextRegistry, :registered}, [])
        ContextRegistry.register(name, module)
        ContextRegistry.register(:honcho, Healthy)

        {micros, {sections, log}} =
          :timer.tc(fn -> with_log([level: :debug], fn -> ContextRegistry.collect(%{}) end) end)

        assert [%{name: :honcho}] = sections
        assert log =~ "contributor #{inspect(name)} dropped"

        # Dropped at the 250ms default rather than at anything the callback
        # said, and nowhere near the 3s ceiling.
        assert micros < 1_500_000
      end
    end
  end

  describe "collect/2 drop logging" do
    test "a contributor that is merely late is logged at debug, not warning" do
      ContextRegistry.register(:sleeper, Sleeper)

      warnings =
        capture_log([level: :warning], fn -> ContextRegistry.collect(%{}, timeout_ms: 50) end)

      refute warnings =~ "contributor :sleeper dropped"

      debug =
        capture_log([level: :debug], fn -> ContextRegistry.collect(%{}, timeout_ms: 50) end)

      assert debug =~ "contributor :sleeper dropped"
      assert debug =~ ":timeout"
    end

    test "a contributor that raises is still logged at warning" do
      ContextRegistry.register(:raiser, Raiser)

      warnings = capture_log([level: :warning], fn -> ContextRegistry.collect(%{}) end)

      assert warnings =~ "contributor :raiser dropped"
    end
  end

  describe "collect/2 size limits" do
    test "keeps the first eight sections of a contributor that returns hundreds" do
      ContextRegistry.register(:verbose, Verbose)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      # The regression: 500 x 200 bytes reached the system prompt intact, where
      # it is re-sent inside the cached prefix on every turn of the session.
      assert length(sections) == 8
      assert [%{title: "Section 1"} | _] = sections
      assert List.last(sections).title == "Section 8"
      assert log =~ "contributor :verbose exceeded its section budget"
    end

    test "stops at the section that crosses the byte budget, keeping the prefix" do
      ContextRegistry.register(:bulky, Bulky)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      # Three sections, so the count limit is not what bit. What survives is a
      # prefix of what was returned rather than whichever sections happened to
      # fit, so a contributor decides what it keeps by ordering them.
      assert [%{title: "One"}, %{title: "Two"}] = sections
      assert log =~ "contributor :bulky exceeded its section budget"
    end

    test "bounds a single oversized spec, not only a list of them" do
      ContextRegistry.register(:enormous, Enormous)
      ContextRegistry.register(:honcho, Healthy)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      # Dropped whole rather than truncated: the registry does not know where
      # another app's prose can be cut, and a body cut mid-sentence still reads
      # to the model as a finished claim.
      assert [%{name: :honcho}] = sections
      assert log =~ "contributor :enormous exceeded its section budget"
    end

    test "the budget is per contributor, so a greedy one costs its neighbours nothing" do
      ContextRegistry.register(:verbose, Verbose)
      ContextRegistry.register(:second, Second)
      ContextRegistry.register(:honcho, Healthy)

      {sections, _log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      # Ten sections: eight from `:verbose` and one each from its neighbours,
      # both intact. A shared ceiling would have let a registration order decide
      # how much an unrelated satellite was allowed to say.
      assert length(sections) == 10
      assert %{name: :second, title: "Recent work"} = Enum.at(sections, 8)
      assert %{name: :honcho, title: "User model"} = Enum.at(sections, 9)
    end

    test "a contributor inside both limits is returned untouched" do
      ContextRegistry.register(:split, Split)

      {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

      assert length(sections) == 2
      refute log =~ "exceeded its section budget"
    end
  end

  describe "collect/2 shape checking" do
    test "drops every wrong-shaped return and still returns the others" do
      for {name, module} <- [
            bare_string: BareString,
            ok_string: OkString,
            numeric: NumericFields,
            nil_body: NilBody
          ] do
        :persistent_term.put({ContextRegistry, :registered}, [])
        ContextRegistry.register(name, module)
        ContextRegistry.register(:honcho, Healthy)

        {sections, log} = with_log(fn -> ContextRegistry.collect(%{}) end)

        assert [%{name: :honcho}] = sections
        assert log =~ "contributor #{inspect(name)} dropped"
      end
    end

    test "drops a section whose body is blank" do
      ContextRegistry.register(:blank, Blank)
      ContextRegistry.register(:honcho, Healthy)

      assert [%{name: :honcho}] = ContextRegistry.collect(%{})
    end

    test "drops a section whose title is blank" do
      ContextRegistry.register(:blank_title, BlankTitle)
      ContextRegistry.register(:honcho, Healthy)

      assert [%{name: :honcho}] = ContextRegistry.collect(%{})
    end
  end

  defp stored, do: :persistent_term.get({ContextRegistry, :registered}, [])
end
