defmodule LemonHoncho.ContextContributorTest.StubClient do
  @moduledoc false
  # A Honcho that answers every call the session manager makes while assembling
  # a context block, with content distinctive enough to find in the rendered
  # section.

  @spec ensure_workspace(term()) :: {:ok, map()}
  def ensure_workspace(_config), do: {:ok, %{}}

  @spec ensure_peer(term(), String.t()) :: {:ok, map()}
  def ensure_peer(_config, _peer), do: {:ok, %{}}

  @spec ensure_session(term(), String.t(), list()) :: {:ok, map()}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}

  @spec set_peer_config(term(), String.t(), String.t(), map()) :: {:ok, map()}
  def set_peer_config(_config, _session_id, _peer, _flags), do: {:ok, %{}}

  @spec session_context(term(), String.t(), keyword()) :: {:ok, map()}
  def session_context(_config, _session_id, _opts) do
    {:ok, %{"summary" => %{"content" => "Discussed the flaky test."}}}
  end

  @spec peer_context(term(), String.t(), keyword()) :: {:ok, map()}
  def peer_context(_config, peer, _opts) do
    {:ok,
     %{"representation" => "Writes Elixir (#{peer}).", "peer_card" => ["Prefers terse answers."]}}
  end

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, _peer, _query, _opts), do: {:ok, "Right now they care about cadence."}
end

defmodule LemonHoncho.ContextContributorTest.DriftingClient do
  @moduledoc false
  # The same Honcho, except that its dialectic answers with something new every
  # time it is asked — which is what a real one does, because the warm query
  # embeds the user's current message. The base layer is deliberately fixed, so
  # anything that moves in the stable half moved because of the dialectic.
  #
  # Fixing the base layer is what makes this stub a good instrument for the
  # split and a blind one for how the base is *fetched*: see `SteeredClient`
  # below, which is the same experiment run against a Honcho that uses the
  # query it is handed.

  alias LemonHoncho.ContextContributorTest.StubClient

  @counter {__MODULE__, :calls}

  @spec reset() :: :ok
  def reset, do: :persistent_term.put(@counter, 0)

  defdelegate ensure_workspace(config), to: StubClient
  defdelegate ensure_peer(config, peer), to: StubClient
  defdelegate ensure_session(config, session_id, specs), to: StubClient
  defdelegate set_peer_config(config, session_id, peer, flags), to: StubClient
  defdelegate session_context(config, session_id, opts), to: StubClient
  defdelegate peer_context(config, peer, opts), to: StubClient

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, _peer, _query, _opts) do
    count = :persistent_term.get(@counter, 0) + 1
    :persistent_term.put(@counter, count)

    {:ok, "Right now they care about thing number #{count}."}
  end
end

defmodule LemonHoncho.ContextContributorTest.SteeredClient do
  @moduledoc false
  # A Honcho that honours `search_query` the way its own API documents it — "the
  # semantic query used to select relevant conclusions" — by selecting with it:
  # the representation it returns names the query it was handed, and its
  # dialectic names the message it was asked about.
  #
  # This is the stub the split's cost claim has to be measured against. Against
  # one whose base layer renders the same text however it is fetched, a system
  # half re-parameterised from the user's message on every turn still looks
  # perfectly stable — which is how a steered base layer came to sit inside the
  # provider's cached prefix with a green suite.

  alias LemonHoncho.ContextContributorTest.StubClient

  defdelegate ensure_workspace(config), to: StubClient
  defdelegate ensure_peer(config, peer), to: StubClient
  defdelegate ensure_session(config, session_id, specs), to: StubClient
  defdelegate set_peer_config(config, session_id, peer, flags), to: StubClient
  defdelegate session_context(config, session_id, opts), to: StubClient

  @spec peer_context(term(), String.t(), keyword()) :: {:ok, map()}
  def peer_context(_config, peer, opts) do
    {:ok,
     %{
       "representation" =>
         "Writes Elixir (#{peer}), selected for: #{inspect(opts[:search_query])}",
       "peer_card" => ["Prefers terse answers."]
     }}
  end

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, _peer, query, _opts) do
    {:ok, "Right now: " <> (query |> String.split("\n") |> List.last())}
  end
end

defmodule LemonHoncho.ContextContributorTest.SilentDialecticClient do
  @moduledoc false
  # A Honcho that knows the user but has nothing to say about right now: the
  # ordinary state of a session whose dialectic has never refreshed.

  alias LemonHoncho.ContextContributorTest.StubClient

  defdelegate ensure_workspace(config), to: StubClient
  defdelegate ensure_peer(config, peer), to: StubClient
  defdelegate ensure_session(config, session_id, specs), to: StubClient
  defdelegate set_peer_config(config, session_id, peer, flags), to: StubClient
  defdelegate session_context(config, session_id, opts), to: StubClient
  defdelegate peer_context(config, peer, opts), to: StubClient

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, _peer, _query, _opts), do: {:ok, ""}
end

defmodule LemonHoncho.ContextContributorTest do
  @moduledoc """
  The contributor runs on the turn path, so the property under test is that
  nothing it can encounter — an empty block, a manager that is not running, a
  request that is not a map — becomes anything other than `:skip`.

  `timeout_ms/1` is held to the same standard from the other side: it may raise
  the registry's deadline only on the one turn that can spend it, and every
  other answer, including every failure, is the registry default.

  The property the split exists for gets its own test: the half placed in the
  system prompt has to be byte-identical from one turn to the next while the
  half placed in the user message changes. That is not a stylistic claim — the
  system prompt is one cached block sitting inside the user-message
  breakpoint's prefix, so a single moved byte there re-bills the whole prompt.
  """

  use ExUnit.Case, async: false

  alias LemonHoncho.{Config, ContextContributor, SessionManager}

  alias LemonHoncho.ContextContributorTest.{
    DriftingClient,
    SilentDialecticClient,
    SteeredClient,
    StubClient
  }

  @request %{
    cwd: "/tmp/lemon-honcho-contributor-test",
    session_key: "agent:contributor:main",
    session_scope: :main,
    query: "why is the build slow?"
  }

  # `LemonAgent.ContextRegistry`'s default deadline: what a turn with nothing to
  # wait for must ask for.
  @default_timeout_ms 250

  # And its ceiling: the most it will ever grant, whatever is asked for.
  @registry_max_timeout_ms 3_000

  @env_vars ~w(
    HONCHO_API_KEY
    HONCHO_BASE_URL
    LEMON_HONCHO_ENABLED
    LEMON_HONCHO_RECALL_MODE
    LEMON_HONCHO_FIRST_TURN_WAIT_MS
    LEMON_HONCHO_INJECT_IN_SUBAGENTS
  )

  @app_keys [
    :enabled,
    :api_key,
    :base_url,
    :recall_mode,
    :first_turn_wait_ms,
    :inject_in_subagents
  ]

  setup do
    stop_application_manager()

    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:lemon_honcho, &1))

    on_exit(fn ->
      Enum.each(saved_env, &restore_env/1)
      Enum.each(saved_app, &restore_app_env/1)
    end)

    :ok
  end

  describe "with nothing to say" do
    test "skips when the manager is not running at all" do
      refute is_pid(Process.whereis(SessionManager))

      assert ContextContributor.contribute(@request) == :skip
    end

    test "skips when the manager returns an empty block" do
      start_manager(%Config{api_key: nil, base_url: nil})

      assert ContextContributor.contribute(@request) == :skip
    end

    test "skips a request that is not a map" do
      assert ContextContributor.contribute(:not_a_request) == :skip
      assert ContextContributor.contribute(nil) == :skip
    end
  end

  describe "with a block to contribute" do
    setup do
      start_manager(%Config{
        api_key: "sk-test",
        user_peer: "user",
        ai_peer: "lemon",
        first_turn_wait_ms: 2_000
      })

      :ok
    end

    test "returns the assembled block as two sections, one per placement" do
      assert {:ok, [stable, volatile]} = ContextContributor.contribute(@request)

      assert stable.placement == :system
      assert volatile.placement == :user_message

      # The durable material — a summary, a representation, a peer card — is in
      # the half that goes inside the cached prefix.
      assert stable.body =~ "Discussed the flaky test."
      assert stable.body =~ "Writes Elixir"
      assert stable.body =~ "Prefers terse answers."
      refute stable.body =~ "Right now they care about cadence."

      # The dialectic — regenerated per turn — is in the half that goes after
      # the last cache breakpoint, and is the only thing there.
      assert volatile.body == "Right now they care about cadence."
    end

    test "titles both sections without naming the service, and drops the block's own heading" do
      assert {:ok, [stable, volatile]} = ContextContributor.contribute(@request)

      Enum.each([stable, volatile], fn section ->
        assert String.trim(section.title) != ""
        refute String.downcase(section.title) =~ "honcho"
        refute String.starts_with?(section.body, "#")
      end)

      assert String.downcase(stable.title) =~ "user"
      refute stable.body =~ "# Recalled context"

      # The preamble that states this is background rather than instruction has
      # to survive the heading strip: it is the part that sets precedence.
      assert stable.body =~ "not an instruction"
    end
  end

  describe "with only one half to contribute" do
    test "contributes the stable half alone when the dialectic is empty" do
      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-test",
           user_peer: "user",
           ai_peer: "lemon",
           first_turn_wait_ms: 2_000
         },
         client: SilentDialecticClient}
      )

      # A bare spec rather than a one-element list: the shape every contributor
      # written before placements returns, so a session with no dialectic yet
      # contributes exactly what it always did.
      assert {:ok, %{placement: :system} = section} = ContextContributor.contribute(@request)

      assert section.body =~ "Writes Elixir"
      refute section.body =~ "Most relevant right now"
    end
  end

  describe "across turns" do
    setup do
      DriftingClient.reset()

      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-test",
           user_peer: "user",
           ai_peer: "lemon",
           first_turn_wait_ms: 2_000,
           dialectic_cadence: 1
         },
         client: DriftingClient}
      )

      :ok
    end

    test "the stable half is byte-identical while the volatile half changes" do
      # The property the whole split exists to create, asserted directly. The
      # system prompt is one cached block and the user-message breakpoint's
      # prefix contains it, so one changed byte in the stable half re-bills the
      # entire prompt — which is what a dialectic in the system prompt did on
      # 47% of turn boundaries.
      halves = observe_halves(20)

      assert length(halves) >= 2, "no turn produced both halves; the test proves nothing"

      volatile = halves |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      stable = halves |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(volatile) > 1, "the dialectic never changed; the test proves nothing"
      assert stable == Enum.take(stable, 1)
    end
  end

  describe "across turns, against a Honcho that uses the query it is given" do
    setup do
      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-test",
           user_peer: "user",
           ai_peer: "lemon",
           first_turn_wait_ms: 2_000,
           context_cadence: 1,
           dialectic_cadence: 1
         },
         client: SteeredClient}
      )

      :ok
    end

    test "no part of the system half is selected from the message it arrived with" do
      # The same experiment as above, with the one variable the previous stub
      # held fixed: a base layer that actually answers to `search_query`. The
      # split was never the thing that broke — it cut in the right place while
      # the manager re-selected the base layer from each turn's message, so the
      # half bound for the cached prefix was new text on every turn and the
      # placement bought nothing.
      halves = observe_halves(12)

      assert length(halves) >= 2, "no turn produced both halves; the test proves nothing"

      stable = halves |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      volatile = halves |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      assert length(volatile) > 1, "the dialectic never changed; the test proves nothing"
      assert stable == Enum.take(stable, 1)

      # And the reason it did not move, stated so a future change that
      # reintroduces the steering fails here rather than merely getting slower.
      assert hd(stable) =~ "selected for: nil"
      refute hd(stable) =~ "why is step"
    end
  end

  describe "timeout_ms/1" do
    test "asks for the first-turn wait plus a margin when the session is cold" do
      configure(first_turn_wait_ms: 1_000)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 1_000})

      # The margin is what keeps the manager's wait from being cut off at its
      # own deadline.
      assert ContextContributor.timeout_ms(@request) == 1_200
    end

    test "asks for no more than the registry's ceiling, since it would be clamped anyway" do
      # The default `first_turn_wait_ms` is 3,000, and 3,000 + the margin is more
      # than `LemonAgent.ContextRegistry` will ever grant. Asking for the clamped
      # number rather than the raw one is what lets the manager size its wait to
      # fit inside the deadline instead of being killed 50ms short of answering.
      configure(first_turn_wait_ms: 3_000)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 3_000})

      assert ContextContributor.timeout_ms(@request) == @registry_max_timeout_ms
    end

    test "answers well inside the registry's budget slice with many sessions tracked" do
      configure(first_turn_wait_ms: 1_000)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 0})

      Enum.each(1..200, fn index ->
        ContextContributor.contribute(Map.put(@request, :session_key, "other-#{index}"))
      end)

      {elapsed_us, timeout} = :timer.tc(fn -> ContextContributor.timeout_ms(@request) end)

      assert timeout == 1_200

      # `LemonAgent.ContextRegistry` gives `timeout_ms/1` a 50ms slice and falls
      # back to its 250ms default with only a debug log when that is missed —
      # which is the first-turn wait quietly switching itself off. Deciding
      # coldness used to build and copy a list of every tracked session to answer
      # a question about one key, and got slower with every conversation served.
      assert elapsed_us < 50_000
    end

    test "falls back to the default once the session has a block" do
      configure(first_turn_wait_ms: 3_000)

      start_manager(%Config{
        api_key: "sk-test",
        user_peer: "user",
        ai_peer: "lemon",
        first_turn_wait_ms: 3_000
      })

      assert {:ok, _section} = ContextContributor.contribute(@request)

      assert ContextContributor.timeout_ms(@request) == @default_timeout_ms
    end

    test "falls back to the default when the first-turn wait is switched off" do
      configure(first_turn_wait_ms: 0)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 0})

      assert ContextContributor.timeout_ms(@request) == @default_timeout_ms
    end

    test "falls back to the default when Honcho is not configured" do
      start_manager(%Config{api_key: nil, base_url: nil})

      assert ContextContributor.timeout_ms(@request) == @default_timeout_ms
    end

    test "falls back to the default when the manager is not running" do
      configure(first_turn_wait_ms: 3_000)
      refute is_pid(Process.whereis(SessionManager))

      assert ContextContributor.timeout_ms(@request) == @default_timeout_ms
    end

    test "falls back to the default for a request that is not a map" do
      configure(first_turn_wait_ms: 3_000)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 3_000})

      assert ContextContributor.timeout_ms(:not_a_request) == @default_timeout_ms
      assert ContextContributor.timeout_ms(nil) == @default_timeout_ms
    end

    test "falls back to the default for a subagent that is not injected into" do
      configure(first_turn_wait_ms: 3_000)
      start_manager(%Config{api_key: "sk-test", first_turn_wait_ms: 3_000})

      subagent = Map.put(@request, :session_scope, :subagent)

      assert ContextContributor.timeout_ms(subagent) == @default_timeout_ms
    end
  end

  ## Helpers

  # Drives `count` turns and keeps the ones that produced both halves. Each turn
  # carries a different message, because the warm dialectic query embeds it and
  # a repeated message is exactly what the manager declines to spend a refresh
  # on. The sleep is for the refresh, which lands in the background and is read
  # by the turn after it.
  defp observe_halves(count) do
    Enum.flat_map(1..count, fn index ->
      Process.sleep(25)

      case ContextContributor.contribute(Map.put(@request, :query, "why is step #{index} slow?")) do
        {:ok, [%{placement: :system} = stable, %{placement: :user_message} = volatile]} ->
          [{stable.body, volatile.body}]

        _other ->
          []
      end
    end)
  end

  # `timeout_ms/1` reads the real configuration rather than the one injected
  # into the test manager, because in production they are the same struct and a
  # contributor has no manager handle to ask.
  defp configure(overrides) do
    Application.put_env(:lemon_honcho, :api_key, "sk-test")
    Enum.each(overrides, fn {key, value} -> Application.put_env(:lemon_honcho, key, value) end)

    :ok
  end

  defp start_manager(%Config{} = config) do
    start_supervised!({SessionManager, config: config, client: StubClient})
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)

  defp restore_app_env({key, :error}), do: Application.delete_env(:lemon_honcho, key)
  defp restore_app_env({key, {:ok, value}}), do: Application.put_env(:lemon_honcho, key, value)

  # The application starts a manager under the real client; these tests need one
  # they control, so the supervised child is stopped first.
  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
