defmodule LemonHoncho.SessionManagerTest.Recorder do
  @moduledoc false
  # Counts every stub client call and forwards it to the test process, so a test
  # can both assert on payloads as they happen and check totals at the end.

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)

    Agent.start_link(fn -> %{owner: owner, counts: %{}} end, name: __MODULE__)
  end

  @spec record(atom(), term()) :: :ok
  def record(name, payload \\ nil) do
    owner =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.owner, put_in(state.counts[name], Map.get(state.counts, name, 0) + 1)}
      end)

    send(owner, {:honcho_call, name, payload})
    :ok
  end

  @spec counts() :: %{atom() => non_neg_integer()}
  def counts, do: Agent.get(__MODULE__, & &1.counts)

  @spec count(atom()) :: non_neg_integer()
  def count(name), do: Map.get(counts(), name, 0)
end

defmodule LemonHoncho.SessionManagerTest.OkClient do
  @moduledoc false
  # A Honcho that answers everything, with content distinctive enough to assert on.

  alias LemonHoncho.SessionManagerTest.Recorder

  def ensure_workspace(_config), do: ok(:ensure_workspace)
  def ensure_peer(_config, peer), do: ok(:ensure_peer, peer)
  def ensure_session(_config, session_id, _specs), do: ok(:ensure_session, session_id)
  def set_peer_config(_config, _session, peer, flags), do: ok(:set_peer_config, {peer, flags})
  def add_messages(_config, session_id, messages), do: ok(:add_messages, {session_id, messages})

  def session_context(_config, _session_id, opts) do
    Recorder.record(:session_context, opts)
    {:ok, %{"summary" => %{"content" => "Discussed the flaky test."}}}
  end

  def peer_context(_config, peer, opts) do
    Recorder.record(:peer_context, {peer, opts})
    {:ok, %{"representation" => "Knows #{peer}.", "peer_card" => ["card for #{peer}"]}}
  end

  def chat(_config, peer, query, opts) do
    Recorder.record(:chat, {peer, query, opts})
    {:ok, "Right now they care about cadence."}
  end

  defp ok(name, payload \\ nil) do
    Recorder.record(name, payload)
    {:ok, %{}}
  end
end

defmodule LemonHoncho.SessionManagerTest.EchoClient do
  @moduledoc false
  # A Honcho that does what its API documents rather than what is convenient for
  # a test. `search_query` is "the semantic query used to select relevant
  # conclusions", so this stub selects with it: the representation it returns
  # names the query it was handed, and so does the summary.
  #
  # That is the entire difference between a stub that catches a base layer
  # steered by the turn's message and one that cannot. A stub which ignores
  # `search_query` renders identical text however it is called, so it reports a
  # perfectly stable system half while every turn re-parameterises the fetch
  # behind it — which is exactly what shipped, and what the previous suite
  # measured as 0% churn.

  alias LemonHoncho.SessionManagerTest.Recorder

  @spec ensure_workspace(term()) :: {:ok, map()}
  def ensure_workspace(_config), do: {:ok, %{}}

  @spec ensure_peer(term(), String.t()) :: {:ok, map()}
  def ensure_peer(_config, _peer), do: {:ok, %{}}

  @spec ensure_session(term(), String.t(), list()) :: {:ok, map()}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}

  @spec set_peer_config(term(), String.t(), String.t(), map()) :: {:ok, map()}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}

  @spec add_messages(term(), String.t(), list()) :: {:ok, map()}
  def add_messages(_config, _session_id, _messages), do: {:ok, %{}}

  @spec session_context(term(), String.t(), keyword()) :: {:ok, map()}
  def session_context(_config, _session_id, opts) do
    Recorder.record(:session_context, opts)

    {:ok, %{"summary" => %{"content" => "Summary selected for: #{inspect(opts[:search_query])}"}}}
  end

  @spec peer_context(term(), String.t(), keyword()) :: {:ok, map()}
  def peer_context(_config, peer, opts) do
    Recorder.record(:peer_context, {peer, opts})

    {:ok,
     %{
       "representation" => "Knows #{peer}, selected for: #{inspect(opts[:search_query])}",
       "peer_card" => ["card for #{peer}"]
     }}
  end

  # The dialectic names the message it was asked about, which is what a real one
  # does: answering about right now is its whole job. The question's last line is
  # the embedded message when the question is the warm one.
  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, peer, query, opts) do
    Recorder.record(:chat, {peer, query, opts})

    {:ok, "Right now: " <> (query |> String.split("\n") |> List.last())}
  end
end

defmodule LemonHoncho.SessionManagerTest.CardClient do
  @moduledoc false
  # A Honcho that answers with whatever peer card the test asked for. A card is
  # the one field of a response that is a collection rather than a string, so it
  # is the one field whose *contents* — maps, nulls, numbers, nested lists — can
  # be anything a JSON document can hold, and the shape it arrives in has
  # changed across Honcho versions before.

  alias LemonHoncho.SessionManagerTest.Recorder

  @env_key :test_peer_card

  def ensure_workspace(_config), do: {:ok, %{}}
  def ensure_peer(_config, _peer), do: {:ok, %{}}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}
  def add_messages(_config, _session_id, _messages), do: {:ok, %{}}
  def session_context(_config, _session_id, _opts), do: {:ok, %{"summary" => "Carded."}}
  def chat(_config, _peer, _query, _opts), do: {:ok, "Carded dialectic."}

  def peer_context(_config, peer, _opts) do
    Recorder.record(:peer_context, peer)
    card = Application.get_env(:lemon_honcho, @env_key)

    {:ok, %{"representation" => "Knows #{peer}.", "peer_card" => card}}
  end
end

defmodule LemonHoncho.SessionManagerTest.ErrorClient do
  @moduledoc false
  # A Honcho that is unreachable. Every call is recorded so the cooldown can be
  # proved by counting attempts.

  alias LemonHoncho.SessionManagerTest.Recorder

  def ensure_workspace(_config), do: error(:ensure_workspace)
  def ensure_peer(_config, peer), do: error(:ensure_peer, peer)
  def ensure_session(_config, session_id, _specs), do: error(:ensure_session, session_id)
  def set_peer_config(_config, _session, peer, _flags), do: error(:set_peer_config, peer)
  def add_messages(_config, _session_id, messages), do: error(:add_messages, messages)
  def session_context(_config, _session_id, opts), do: error(:session_context, opts)
  def peer_context(_config, peer, _opts), do: error(:peer_context, peer)
  def chat(_config, peer, _query, _opts), do: error(:chat, peer)

  defp error(name, payload \\ nil) do
    Recorder.record(name, payload)
    {:error, {:transport, :nxdomain}}
  end
end

defmodule LemonHoncho.SessionManagerTest.SlowClient do
  @moduledoc false
  # A Honcho that is reachable but far too slow to help this turn. It does not
  # touch the recorder, because it may still be sleeping when the test ends.

  @sleep_ms 600

  def ensure_workspace(_config) do
    Process.sleep(@sleep_ms)
    {:ok, %{}}
  end

  def ensure_peer(_config, _peer), do: {:ok, %{}}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}
  def add_messages(_config, _session_id, _messages), do: {:ok, %{}}
  def session_context(_config, _session_id, _opts), do: {:ok, %{}}
  def peer_context(_config, _peer, _opts), do: {:ok, %{}}
  def chat(_config, _peer, _query, _opts), do: {:ok, nil}
end

defmodule LemonHoncho.SessionManagerTest.GatedClient do
  @moduledoc false
  # A Honcho whose first call blocks until the test releases it, so a test can
  # look at the manager while a refresh is genuinely in flight instead of racing
  # it. The refresh process is the one that blocks, and the test finds its pid in
  # the manager's own guard — which is also the point: the guard has to hold that
  # pid for the manager to be able to kill an overrunning refresh.

  alias LemonHoncho.SessionManagerTest.Recorder

  def ensure_workspace(_config) do
    Recorder.record(:ensure_workspace)

    receive do
      :go -> {:ok, %{}}
    after
      5_000 -> {:ok, %{}}
    end
  end

  def ensure_peer(_config, _peer), do: {:ok, %{}}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}
  def add_messages(_config, _session_id, _messages), do: {:ok, %{}}
  def session_context(_config, _session_id, _opts), do: {:ok, %{"summary" => "Gated."}}
  def peer_context(_config, peer, _opts), do: {:ok, %{"representation" => "Knows #{peer}."}}
  def chat(_config, _peer, _query, _opts), do: {:ok, "Gated dialectic."}
end

defmodule LemonHoncho.SessionManagerTest.OverrunClient do
  @moduledoc false
  # A Honcho whose dialectic answers, but only long after the refresh deadline
  # has passed. Every call is recorded *before* the sleep, so a refresh that is
  # killed mid-call still counts — the number under test is how many dialectic
  # calls were *started*, which is what Honcho bills for.

  alias LemonHoncho.SessionManagerTest.Recorder

  # Comfortably over the manager's refresh deadline, which bottoms out at
  # `timeout_ms * 2 + 5_000ms`, so every dialectic call overruns it.
  @sleep_ms 5_500

  def ensure_workspace(_config), do: {:ok, %{}}
  def ensure_peer(_config, _peer), do: {:ok, %{}}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}
  def set_peer_config(_config, _session, _peer, _flags), do: {:ok, %{}}
  def add_messages(_config, _session_id, _messages), do: {:ok, %{}}
  def session_context(_config, _session_id, _opts), do: {:ok, %{"summary" => "Overrun."}}
  def peer_context(_config, peer, _opts), do: {:ok, %{"representation" => "Knows #{peer}."}}

  def chat(_config, _peer, _query, _opts) do
    Recorder.record(:chat)
    Process.sleep(@sleep_ms)
    {:ok, "Too late to matter."}
  end
end

defmodule LemonHoncho.SessionManagerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonHoncho.Config
  alias LemonHoncho.Context
  alias LemonHoncho.ContextContributor
  alias LemonHoncho.SessionManager
  alias LemonHoncho.SessionManagerTest.CardClient
  alias LemonHoncho.SessionManagerTest.EchoClient
  alias LemonHoncho.SessionManagerTest.ErrorClient
  alias LemonHoncho.SessionManagerTest.GatedClient
  alias LemonHoncho.SessionManagerTest.OkClient
  alias LemonHoncho.SessionManagerTest.OverrunClient
  alias LemonHoncho.SessionManagerTest.Recorder
  alias LemonHoncho.SessionManagerTest.SlowClient
  alias LemonMemory.Document

  doctest LemonHoncho.SessionManager

  @session_key "agent:demo:main"
  @request %{
    cwd: "/tmp/lemon-honcho-test",
    session_key: @session_key,
    session_scope: :main,
    query: "why is the build slow?"
  }

  setup do
    stop_application_manager()
    start_supervised!({Recorder, owner: self()})
    :ok
  end

  describe "context_for/1 gating" do
    test "returns an empty string when Honcho is not configured" do
      start_manager(api_key: nil, base_url: nil)

      assert SessionManager.context_for(@request) == ""
      assert Recorder.counts() == %{}
    end

    test "returns an empty string in :tools recall mode" do
      start_manager(recall_mode: :tools)

      assert SessionManager.context_for(@request) == ""
      assert Recorder.counts() == %{}
    end

    test "returns an empty string for a subagent when injection is switched off" do
      start_manager(inject_in_subagents?: false)

      assert SessionManager.context_for(%{@request | session_scope: :subagent}) == ""
      assert Recorder.counts() == %{}
    end

    test "serves a subagent when injection is switched on" do
      start_manager(inject_in_subagents?: true)

      assert SessionManager.context_for(%{@request | session_scope: :subagent}) =~ "Knows user."
    end
  end

  describe "the first turn" do
    test "waits for the first refresh and returns the assembled block" do
      start_manager()

      block = SessionManager.context_for(@request)

      assert block =~ "Discussed the flaky test."
      assert block =~ "Knows user."
      assert block =~ "card for user"
      assert block =~ "Knows lemon."
      assert block =~ "Right now they care about cadence."
    end

    test "asks the cold dialectic question first, and the warm one afterwards" do
      start_manager(dialectic_cadence: 1)

      SessionManager.context_for(@request)
      assert_receive {:honcho_call, :chat, {"lemon", cold, opts}}, 1_000
      assert cold =~ "Who is this person?"
      assert opts[:target] == "user"

      SessionManager.context_for(@request)
      await_idle(@session_key)
      assert_receive {:honcho_call, :chat, {"lemon", warm, _opts}}, 1_000
      assert warm =~ "why is the build slow?"
    end

    test "returns nothing immediately when the wait is disabled, and lands by turn 2" do
      start_manager(first_turn_wait_ms: 0)

      assert SessionManager.context_for(@request) == ""

      await_idle(@session_key)

      assert SessionManager.context_for(@request) =~ "Discussed the flaky test."
    end

    test "never waits on a later turn even when the block is still empty" do
      start_manager(first_turn_wait_ms: 5_000, client: SlowClient)

      SessionManager.context_for(@request)
      {elapsed_us, block} = :timer.tc(fn -> SessionManager.context_for(@request) end)

      assert block == ""
      assert elapsed_us < 200_000
    end
  end

  describe "cadence" do
    test "counts the base layer and the dialectic independently" do
      start_manager(context_cadence: 3, dialectic_cadence: 2)

      Enum.each(1..6, fn _turn ->
        SessionManager.context_for(@request)
        await_idle(@session_key)
      end)

      # Turns 1 and 4 refresh the base layer (cadence 3, both markers start due);
      # turns 1, 3 and 5 refresh the dialectic (cadence 2). Each base refresh is
      # one session read plus one peer read for each of the two peers.
      assert Recorder.count(:session_context) == 2
      assert Recorder.count(:peer_context) == 4
      assert Recorder.count(:chat) == 3

      # Setup is done once for the session, not once per refresh.
      assert Recorder.count(:ensure_workspace) == 1
      assert Recorder.count(:ensure_peer) == 2
      assert Recorder.count(:ensure_session) == 1
      assert Recorder.count(:set_peer_config) == 2
    end

    test "refreshes both layers every turn at cadence 1" do
      start_manager(context_cadence: 1, dialectic_cadence: 1)

      Enum.each(1..3, fn _turn ->
        SessionManager.context_for(@request)
        await_idle(@session_key)
      end)

      assert Recorder.count(:session_context) == 3
      assert Recorder.count(:chat) == 3
    end
  end

  # The property the two-placement split exists to create, tested where it is
  # actually decided: in the *arguments* the base fetch reaches Honcho with.
  # The split itself was never the bug — it cut in the right place all along,
  # around a base layer that was re-selected from the current message on every
  # turn, so the half bound for the cached prefix was new text every time.
  describe "the half that goes into the system prompt" do
    setup do
      start_manager(client: EchoClient, context_cadence: 1, dialectic_cadence: 1)

      :ok
    end

    test "is byte-identical across turns whose only difference is the message" do
      halves = echo_turns(5)

      stable = halves |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      volatile = halves |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      # Against this stub the pre-fix manager produced five distinct stable
      # halves out of five turns. One is the whole point.
      assert length(volatile) == 5, "the dialectic never moved; the test proves nothing"
      assert length(stable) == 1
      assert hd(stable) =~ "Knows user, selected for: nil"
    end

    test "is fetched without a retrieval query, whatever the turn said" do
      echo_turns(4)

      # Asserted on what the stub *received*, not on what it rendered. A Honcho
      # that ignores `search_query` returns identical text either way, so text
      # alone cannot tell a fetch that is turn-independent from one that is
      # merely answered by a forgiving server.
      peer_reads = recorded(:peer_context)
      summary_reads = recorded(:session_context)

      assert length(peer_reads) == 8
      assert Enum.all?(peer_reads, fn {_peer, opts} -> opts == [] end)

      assert length(summary_reads) == 4
      assert Enum.all?(summary_reads, &(Keyword.get(&1, :search_query) == nil))
    end

    test "the message-steered recall is not lost, it is in the volatile half" do
      # Turn 1 asks the cold question, which embeds nothing; every turn after it
      # asks the warm one, which embeds that turn's own message. Dropping the
      # steering from the base layer moved it here rather than throwing it away.
      [_cold | warm] = echo_turns(4)

      for {{stable, volatile}, index} <- Enum.with_index(warm, 2) do
        assert volatile =~ "why is step #{index} slow?"
        refute stable =~ "why is step"
      end
    end
  end

  describe "the retrieval query" do
    test "clips a long query to 1,500 characters before it goes on the wire" do
      start_manager(dialectic_cadence: 1)

      warm = warm_dialectic_question(String.duplicate("a", 40_000))

      assert warm =~ String.duplicate("a", 1_500)
      refute warm =~ String.duplicate("a", 1_501)
    end

    test "clips on a character boundary rather than mid-grapheme" do
      start_manager(dialectic_cadence: 1)

      # 1,000 two-codepoint graphemes: a byte- or codepoint-wise cut at 1,500
      # would split one of them and put half a character on the wire.
      warm = warm_dialectic_question(String.duplicate("é🇬🇧", 1_000))
      [_question, message] = String.split(warm, "Their current message:\n")

      assert String.length(message) == 1_500
      assert String.valid?(message)
      assert String.last(message) in ["é", "🇬🇧"]
      assert byte_size(message) > 1_500
    end

    test "withholds a query that looks like it carries a secret, and still refreshes" do
      start_manager(dialectic_cadence: 1)

      warm = warm_dialectic_question(secret_query())

      # The refresh still happens — the dialectic is just asked its
      # session-scoped question with no message attached, which costs focus and
      # nothing else.
      refute warm =~ "Their current message:"
      assert warm =~ "Prioritize active context"
      assert SessionManager.context_for(@request) =~ "Knows user."
    end

    test "withholds the same query from the dialectic, the one place it travels" do
      start_manager(dialectic_cadence: 1)

      warm = warm_dialectic_question(secret_query())

      refute warm =~ "sk-live"
      refute warm =~ "api_key"
    end

    test "asks without a query when the turn has no user message" do
      start_manager()

      SessionManager.context_for(Map.delete(@request, :query))

      assert_receive {:honcho_call, :peer_context, {"user", opts}}, 1_000
      assert opts == []
      assert_receive {:honcho_call, :chat, {_peer, query, _opts}}, 1_000
      refute query =~ "Their current message:"
    end
  end

  describe "the one-refresh-in-flight guard" do
    # Slow enough to overrun the deadline every time, driven for long enough to
    # cross two deadlines. The invariant is that a refresh may only start when
    # the previous one has been retired, so with a deadline of `timeout_ms * 2 +
    # 5_000ms` = 5,002ms the window below admits three starts and no more.
    #
    # Before the guard held the worker's pid and matched results by tag, this
    # measured 4: the deadline cleared the guard without killing the worker, and
    # the worker's late result then cleared the guard a *second* time, out from
    # under the refresh that had replaced it. Each extra start is a billed
    # dialectic call.
    @tag timeout: 60_000
    test "starts no more refreshes than the deadline allows, however many turns arrive" do
      start_manager(
        client: OverrunClient,
        context_cadence: 1,
        dialectic_cadence: 1,
        first_turn_wait_ms: 0,
        timeout_ms: 1
      )

      drive_turns(11_000, 200)

      assert Recorder.count(:chat) <= 3
      assert Recorder.count(:chat) >= 2
    end

    test "ignores the late result of an abandoned refresh rather than caching it" do
      start_manager()

      fresh = SessionManager.context_for(@request)
      await_idle(@session_key)
      assert fresh =~ "Discussed the flaky test."

      send(SessionManager, {:refresh_result, @session_key, make_ref(), stale_result()})

      assert SessionManager.context_for(@request) == fresh
      refute SessionManager.context_for(@request) =~ "Stale"
    end

    test "cancels the deadline timer when a refresh finishes normally" do
      start_manager(client: GatedClient, first_turn_wait_ms: 0)

      assert SessionManager.context_for(@request) == ""

      %{pid: refresh, timer: timer} = await_pending(@session_key)
      remaining_ms = Process.read_timer(timer)
      assert is_integer(remaining_ms)

      started_ms = System.monotonic_time(:millisecond)
      send(refresh, :go)
      await_idle(@session_key)
      elapsed_ms = System.monotonic_time(:millisecond) - started_ms

      # `Process.read_timer/1` answers `false` for a cancelled timer and for a
      # fired one alike, so the assertion below cannot tell them apart on its
      # own. The arithmetic is what does: less wall time passed than the timer
      # had left, so it cannot have fired, so something cancelled it.
      assert elapsed_ms < remaining_ms
      assert Process.read_timer(timer) == false

      # And the message it would have sent never arrived: the manager is still
      # holding the settled entry rather than an expired one.
      refute_receive {:refresh_expired, _key, _ref}, 50
      assert SessionManager.context_for(@request) =~ "Knows user."
    end

    test "arms the deadline before the worker exists, so an absurd timeout cannot orphan one" do
      # `timeout_ms * 2 + 5_000` overflows what `Process.send_after/3` accepts,
      # which used to raise *after* `spawn_monitor` had already put a refresh
      # into the world — killing the manager and leaving the worker running.
      start_manager(client: GatedClient, first_turn_wait_ms: 0, timeout_ms: 5_000_000_000)

      assert SessionManager.context_for(@request) == ""

      %{timer: timer} = await_pending(@session_key)

      assert Process.read_timer(timer) <= 600_000
      assert Process.alive?(Process.whereis(SessionManager))
    end

    @tag :capture_log
    test "a refresh worker dies with the manager rather than outliving a restart" do
      # A supervisor restarts the manager with an empty session map, so the next
      # turn starts a fresh refresh. An orphan surviving that restart would be a
      # second concurrent dialectic — and the dialectic is what Honcho bills.
      start_manager(client: GatedClient, first_turn_wait_ms: 0)

      SessionManager.context_for(@request)
      %{pid: worker} = await_pending(@session_key)
      worker_down = Process.monitor(worker)

      Process.exit(Process.whereis(SessionManager), :kill)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, _reason}, 2_000
    end

    # What `LemonAgent.ContextRegistry` does to a contributor that overruns its
    # own budget: it kills the process mid-call. The manager is holding a reply
    # for that process at the time, and must neither crash on it nor keep the
    # waiter around afterwards.
    test "survives a first-turn caller that is killed while waiting" do
      start_manager(client: GatedClient, first_turn_wait_ms: 5_000)

      test_process = self()
      caller = spawn(fn -> send(test_process, {:block, SessionManager.context_for(@request)}) end)

      await_waiter(@session_key)
      Process.exit(caller, :kill)
      refute_receive {:block, _block}, 50

      %{pid: refresh} = await_pending(@session_key)
      send(refresh, :go)
      await_idle(@session_key)

      assert waiters(@session_key) == []
      assert Process.alive?(Process.whereis(SessionManager))
      assert SessionManager.context_for(@request) =~ "Knows user."
    end
  end

  # A card is remote JSON and its entries are whatever that document holds.
  # Rendering used to be `to_string/1` per entry, which raises
  # `Protocol.UndefinedError` on a map — and it raises *here*, in the manager's
  # own `handle_info/2`, outside every rescue in the module. What that costs is
  # not one turn: the manager dies holding every session's cached block, and
  # three deaths inside the supervisor's five-second window take a `:permanent`
  # application, and with it the node.
  describe "a peer card with entries that cannot be rendered" do
    test "keeps the renderable lines, drops the rest, and does not take the manager down" do
      logs =
        capture_log(fn ->
          start_card_manager([
            %{"text" => "a card from a differently-spelled API version"},
            "prefers terse answers",
            nil,
            888,
            [["nested"], 1],
            true,
            "   "
          ])

          block = SessionManager.context_for(@request)

          # The block was assembled at all, which is the assertion that fails if
          # the render raised: a dead manager returns "" to its parked caller.
          assert block =~ "## User profile\n- prefers terse answers\n- 888"
          refute block =~ "differently-spelled"
          refute block =~ "nested"

          # And the same process is still the one holding the session.
          assert SessionManager.cold?(@session_key) == false
          assert SessionManager.honcho_session_id(@session_key) == {:ok, "lemon-honcho-test"}
        end)

      refute logs =~ "Protocol.UndefinedError"
    end

    test "serves the rest of the block when the card is a bare map rather than a list" do
      start_card_manager(%{"lines" => ["favourite colour is green"]})

      block = SessionManager.context_for(@request)

      assert block =~ "Knows user."
      refute block =~ "## User profile"
    end

    test "keeps serving later turns after a malformed card, rather than restarting empty" do
      start_card_manager([%{"text" => "unrenderable"}, "renderable"])

      first = SessionManager.context_for(@request)
      await_idle(@session_key)
      second = SessionManager.context_for(@request)

      assert first =~ "- renderable"
      assert second == first
    end
  end

  # Every other module in this app loads the config per call and passes the
  # struct down. The manager pinned it at `init/1`, which made it the one place
  # a runtime change did not reach — `LemonHoncho.status/0` reported the new
  # value while the injection path acted on the old one.
  describe "runtime configuration" do
    test "acts on the configuration as it is now, not as it was at boot" do
      start_unpinned_manager()

      SessionManager.context_for(@request)
      await_idle(@session_key)
      assert SessionManager.context_for(@request) =~ "Discussed the flaky test."
      await_idle(@session_key)

      System.put_env("LEMON_HONCHO_RECALL_MODE", "tools")
      before = Recorder.counts()

      assert SessionManager.context_for(@request) == ""
      assert Recorder.counts() == before
    end

    test "stops uploading when message saving is switched off at runtime" do
      start_unpinned_manager()

      SessionManager.sync_document(document())
      assert_receive {:honcho_call, :add_messages, _payload}, 1_000

      System.put_env("LEMON_HONCHO_SAVE_MESSAGES", "false")

      SessionManager.sync_document(document())
      refute_receive {:honcho_call, :add_messages, _payload}, 150
    end

    # The divergence that mattered: `ContextContributor.timeout_ms/1` asked the
    # registry for a budget computed from a fresh config while the manager sized
    # its wait against a pinned one. Disagree, and the contributor is killed
    # while parked in `{:await, key}` — on the one turn that was waiting for
    # anything.
    test "sizes the first-turn wait from the same live config as the contributor's deadline" do
      start_unpinned_manager(GatedClient, %{"LEMON_HONCHO_FIRST_TURN_WAIT_MS" => "0"})

      {no_wait_us, ""} = :timer.tc(fn -> SessionManager.context_for(request_for("cold-a")) end)
      assert no_wait_us < 200_000

      System.put_env("LEMON_HONCHO_FIRST_TURN_WAIT_MS", "500")

      # The two numbers that used to be able to disagree: what the contributor
      # asks the registry for, and what the manager waits against inside it.
      assert ContextContributor.timeout_ms(@request) ==
               SessionManager.first_turn_budget_ms(Config.load())

      {waited_us, ""} = :timer.tc(fn -> SessionManager.context_for(request_for("cold-b")) end)
      assert waited_us > 400_000
      assert waited_us < 900_000
    end
  end

  describe "the trivial-prompt gate" do
    test "serves the cached block and calls nothing for a turn that says nothing" do
      start_manager(context_cadence: 1, dialectic_cadence: 1)

      warm = SessionManager.context_for(@request)
      await_idle(@session_key)
      assert warm =~ "Discussed the flaky test."

      before = Recorder.counts()

      for query <- ["ok", "yes", "Thanks!", "thank you", "/compact", "", "   ", "👍", "lgtm"] do
        assert SessionManager.context_for(%{@request | query: query}) == warm
      end

      assert Recorder.counts() == before
    end

    test "does not advance the cadence counters, because nothing was said" do
      start_manager(context_cadence: 3, dialectic_cadence: 3, first_turn_wait_ms: 0)

      # Turn 1 refreshes: both markers start unset, so both are due.
      real_turn()
      assert Recorder.count(:session_context) == 1

      Enum.each(1..5, fn _ack -> SessionManager.context_for(%{@request | query: "ok"}) end)

      # Had those five counted, the cadence-3 window would be long spent. They
      # did not, so the next two real turns are still inside it...
      real_turn()
      real_turn()
      assert Recorder.count(:session_context) == 1

      # ...and the third is the one that spends it.
      real_turn()
      assert Recorder.count(:session_context) == 2
    end

    test "an ordinary message that merely starts with an acknowledgement still refreshes" do
      start_manager(context_cadence: 1, first_turn_wait_ms: 0)

      real_turn()
      assert Recorder.count(:session_context) == 1

      SessionManager.context_for(%{@request | query: "no, revert that"})
      await_idle(@session_key)

      assert Recorder.count(:session_context) == 2
    end

    # The one exception, and the reason it is one: a session with no block has
    # nothing to serve, the cold dialectic question does not embed the message
    # at all, and a caller whose first message is "hi" — or one that never
    # populates `:query` — would otherwise never recall anything at all.
    test "still loads a session that has never had context, and waits for that one load" do
      start_manager(first_turn_wait_ms: 2_000)

      block = SessionManager.context_for(%{@request | query: "ok"})

      # The cold load is the one fetch a session cannot do without, and a caller
      # that never populates `:query` — the memory provider is one — would
      # otherwise spend a whole turn discovering its own session id.
      assert block =~ "Discussed the flaky test."
      assert SessionManager.honcho_session_id(@session_key) == {:ok, "lemon-honcho-test"}
    end

    test "the cold load happens once, not on every trivial turn afterwards" do
      start_manager(context_cadence: 1, dialectic_cadence: 1, first_turn_wait_ms: 0)

      SessionManager.context_for(%{@request | query: "ok"})
      await_idle(@session_key)

      before = Recorder.counts()
      Enum.each(1..3, fn _ack -> SessionManager.context_for(%{@request | query: "ok"}) end)

      assert Recorder.counts() == before
    end
  end

  describe "trivial_query?/1" do
    test "is true for nothing to say" do
      for query <- [nil, "", "   ", "\n\t ", "/compact", "/model opus", "?", "...", "🙏"] do
        assert SessionManager.trivial_query?(query), "expected #{inspect(query)} to be trivial"
      end
    end

    test "is true for a bare acknowledgement, whatever its case and punctuation" do
      for query <- [
            "ok",
            "OK!",
            "Okay.",
            "yes",
            "Yep",
            "nope",
            "thanks :)",
            "Thank you!!",
            "go ahead",
            "got it",
            "k",
            "lgtm",
            "done",
            "next",
            "hey"
          ] do
        assert SessionManager.trivial_query?(query), "expected #{inspect(query)} to be trivial"
      end
    end

    test "is false for a message that merely begins with one" do
      for query <- [
            "no, revert that",
            "done — now ship it",
            "ok but why is the build slow?",
            "k8s is misbehaving",
            "yolo",
            "next steps for the release?"
          ] do
        refute SessionManager.trivial_query?(query), "expected #{inspect(query)} to be real"
      end
    end

    test "is false for an ordinary message, and does not scan a long one" do
      assert SessionManager.trivial_query?("why is the build slow?") == false
      assert SessionManager.trivial_query?(String.duplicate("ok ", 20_000)) == false
    end

    test "is true for anything that is not a string, because there is no message in it" do
      for query <- [%{}, [], 42, :ok, {:ok, "ok"}] do
        assert SessionManager.trivial_query?(query)
      end
    end
  end

  describe "an unreachable Honcho" do
    test "degrades to an empty block, stays alive, and does not re-dial within the cooldown" do
      logs =
        capture_log(fn ->
          start_manager(client: ErrorClient, first_turn_wait_ms: 1_000)

          Enum.each(1..3, fn _turn ->
            assert SessionManager.context_for(@request) == ""
            await_idle(@session_key)
          end)
        end)

      assert Recorder.count(:ensure_workspace) == 1
      assert Recorder.count(:session_context) == 0
      assert Recorder.count(:chat) == 0
      assert Process.alive?(Process.whereis(SessionManager))
      assert logs =~ "session setup failed"
    end
  end

  describe "a slow Honcho" do
    test "returns within the bounded first-turn wait without exiting the caller" do
      start_manager(client: SlowClient, first_turn_wait_ms: 100)

      {elapsed_us, block} = :timer.tc(fn -> SessionManager.context_for(@request) end)

      assert block == ""
      assert elapsed_us < 500_000
      assert Process.alive?(self())
      assert Process.alive?(Process.whereis(SessionManager))
    end
  end

  describe "sync_document/1" do
    test "makes no calls when message saving is switched off" do
      start_manager(save_messages?: false)

      assert SessionManager.sync_document(document()) == :ok
      refute_receive {:honcho_call, _name, _payload}, 150
    end

    test "makes no calls when Honcho is not configured" do
      start_manager(api_key: nil)

      assert SessionManager.sync_document(document()) == :ok
      refute_receive {:honcho_call, _name, _payload}, 150
    end

    test "sends both halves of the turn, each attributed to its own peer" do
      start_manager()

      SessionManager.sync_document(document())

      assert_receive {:honcho_call, :add_messages, {_session_id, messages}}, 1_000

      assert messages == [
               %{content: "why is the build slow?", peer_id: "user"},
               %{content: "Because the cache was cold.", peer_id: "lemon"}
             ]
    end

    test "skips a blank half rather than sending an empty message" do
      start_manager()

      SessionManager.sync_document(document(answer_summary: ""))

      assert_receive {:honcho_call, :add_messages, {_session_id, messages}}, 1_000
      assert messages == [%{content: "why is the build slow?", peer_id: "user"}]
    end

    test "clips content to message_max_chars" do
      start_manager(message_max_chars: 10)

      SessionManager.sync_document(document(prompt_summary: String.duplicate("ab", 40)))

      assert_receive {:honcho_call, :add_messages, {_session_id, messages}}, 1_000
      assert [%{content: "ababababab"} | _rest] = messages
    end

    test "logs rather than raises when the upload fails" do
      start_manager(client: ErrorClient)

      logs =
        capture_log(fn ->
          SessionManager.sync_document(document())
          assert_receive {:honcho_call, :ensure_workspace, _payload}, 1_000
          Process.sleep(50)
        end)

      assert Process.alive?(Process.whereis(SessionManager))
      assert logs =~ "session setup failed"
    end
  end

  describe "bounded session state" do
    # Nothing in the suite used to exercise more than two keys, which is exactly
    # why an unbounded map went unnoticed: a manager that has served a hundred
    # conversations retains a rendered block and both halves it was assembled
    # from for every one of them, and walks the lot on every worker death.
    test "evicts the least recently used session once the cap is reached" do
      start_manager(max_sessions: 2, first_turn_wait_ms: 0)

      serve("session-a")
      serve("session-b")
      # Touching a again makes b the least recently used, so the eviction has to
      # be about recency rather than about insertion order.
      serve("session-a")
      serve("session-c")

      assert tracked_keys() == ["session-a", "session-c"]
    end

    test "sheds a session nobody has touched within the idle TTL" do
      start_manager(max_sessions: 100, idle_ttl_ms: 30, first_turn_wait_ms: 0)

      serve("session-idle")
      Process.sleep(60)
      serve("session-fresh")

      assert tracked_keys() == ["session-fresh"]
    end

    test "skips a session with a refresh in flight, and takes it once the refresh retires" do
      start_manager(client: GatedClient, max_sessions: 1, first_turn_wait_ms: 0)

      SessionManager.context_for(request_for("session-busy"))
      %{pid: busy} = await_pending("session-busy")

      SessionManager.context_for(request_for("session-next"))

      # Evicting the busy one would orphan a worker whose result has nowhere to
      # land, so the cap is exceeded rather than honoured — briefly.
      assert "session-busy" in tracked_keys()

      send(busy, :go)
      await_idle("session-busy")
      Process.sleep(2)

      %{pid: next} = await_pending("session-next")
      send(next, :go)
      await_idle("session-next")
      Process.sleep(2)

      # The skip is temporary, not an exemption: both are evictable now, and the
      # next new key takes them. Eviction happens inside the call, so there is
      # nothing to wait for after it returns.
      SessionManager.context_for(request_for("session-later"))

      refute "session-busy" in tracked_keys()
    end

    test "counts a session created only by sync_document/1 toward the cap" do
      # `recall_mode: :tools` gates context injection off entirely, so no turn
      # ever serves a block — and uploads were still creating an entry per
      # finished run. A deployment that injects nothing grew the map anyway.
      start_manager(recall_mode: :tools, max_sessions: 3)

      Enum.each(1..12, fn index ->
        SessionManager.sync_document(document(session_key: "sync-#{index}"))
        Process.sleep(2)
      end)

      assert SessionManager.context_for(@request) == ""
      assert length(tracked_keys()) <= 3
      assert "sync-12" in tracked_keys()
      refute "sync-1" in tracked_keys()
    end

    test "re-initialises an evicted key on its next turn, exactly as a cold one" do
      start_manager(max_sessions: 1, first_turn_wait_ms: 0)

      serve("session-evicted")
      serve("session-other")

      refute "session-evicted" in tracked_keys()
      assert SessionManager.honcho_session_id("session-evicted") == {:error, :unknown_session}

      serve("session-evicted")

      assert SessionManager.context_for(request_for("session-evicted")) =~
               "Discussed the flaky test."

      assert SessionManager.honcho_session_id("session-evicted") == {:ok, "lemon-honcho-test"}
    end
  end

  describe "cold?/1" do
    test "is true for a key this manager has never served" do
      start_manager()

      assert SessionManager.cold?("never-seen") == true
    end

    test "is true for a key that exists but has served no turn" do
      start_manager()

      SessionManager.sync_document(document(session_key: "upload-only"))
      assert_receive {:honcho_call, :add_messages, _payload}, 1_000

      assert SessionManager.cold?("upload-only") == true
    end

    test "is false once the session has served a turn and cached a block" do
      start_manager()

      SessionManager.context_for(@request)
      await_idle(@session_key)

      assert SessionManager.cold?(@session_key) == false
    end

    test "is false when the manager is not running, rather than raising" do
      assert SessionManager.cold?(@session_key) == false
    end
  end

  describe "first_turn_budget_ms/1" do
    test "adds the contributor's margin to the configured wait" do
      assert SessionManager.first_turn_budget_ms(%Config{first_turn_wait_ms: 1_000}) == 1_200
    end

    test "clamps to the registry's ceiling, which is what the contributor is granted" do
      assert SessionManager.first_turn_budget_ms(%Config{first_turn_wait_ms: 2_800}) == 3_000
      assert SessionManager.first_turn_budget_ms(%Config{first_turn_wait_ms: 60_000}) == 3_000
    end

    test "is zero when the wait is switched off" do
      assert SessionManager.first_turn_budget_ms(%Config{first_turn_wait_ms: 0}) == 0
    end

    test "the first turn gives up strictly inside the budget it asked for" do
      # The registry kills the contributor at the budget. A wait that ran to the
      # budget would be killed holding a block the manager had already cached —
      # which is the turn that paid for the wait getting nothing for it.
      start_manager(client: GatedClient, first_turn_wait_ms: 1_000)

      budget_ms = SessionManager.first_turn_budget_ms(%Config{first_turn_wait_ms: 1_000})
      {elapsed_us, block} = :timer.tc(fn -> SessionManager.context_for(@request) end)

      assert block == ""
      assert elapsed_us < budget_ms * 1_000
      assert elapsed_us > 900_000
    end
  end

  describe "introspection" do
    test "sessions/0 reflects the mapped sessions and answers immediately" do
      start_manager()
      SessionManager.context_for(@request)

      {elapsed_us, sessions} = :timer.tc(&SessionManager.sessions/0)

      assert [%{session_key: @session_key, turns: 1} = session] = sessions
      assert session.honcho_session_id == "lemon-honcho-test"
      assert is_integer(session.last_context_at_ms)
      assert elapsed_us < 200_000
    end

    test "sessions/0 is empty when the manager is not running" do
      assert SessionManager.sessions() == []
    end

    test "honcho_session_id/1 and peers/1 answer for a mapped session" do
      start_manager()
      SessionManager.context_for(@request)

      assert SessionManager.honcho_session_id(@session_key) == {:ok, "lemon-honcho-test"}
      assert SessionManager.peers(@session_key) == {:ok, %{user: "user", ai: "lemon"}}
    end

    test "honcho_session_id/1 and peers/1 report an unknown session rather than guessing" do
      start_manager()

      assert SessionManager.honcho_session_id("never-seen") == {:error, :unknown_session}
      assert SessionManager.peers("never-seen") == {:error, :unknown_session}
    end
  end

  test "every entry point degrades when the manager is not started" do
    assert SessionManager.context_for(@request) == ""
    assert SessionManager.sync_document(document()) == :ok
    assert SessionManager.sessions() == []
    assert SessionManager.honcho_session_id(@session_key) == {:error, :unavailable}
    assert SessionManager.peers(@session_key) == {:error, :unavailable}
  end

  ## Helpers

  # Every test starts the manager with an explicit config and an explicit client,
  # so nothing here depends on the ambient environment. `:client` and the two
  # eviction bounds are popped out first because they are start options rather
  # than config fields; the bounds are how a cap of 500 is exercised with three
  # session keys instead of five hundred.
  defp start_manager(overrides \\ []) do
    {client, overrides} = Keyword.pop(overrides, :client, OkClient)
    {bounds, fields} = Keyword.split(overrides, [:max_sessions, :idle_ttl_ms])
    config = struct!(base_config(), fields)

    start_supervised!({SessionManager, [config: config, client: client] ++ bounds})
  end

  # The card lives in application env rather than in a stub module, so one stub
  # can be driven through every shape a JSON card can arrive in — including the
  # ones that used to kill the manager.
  defp start_card_manager(card) do
    Application.put_env(:lemon_honcho, :test_peer_card, card)
    on_exit(fn -> Application.delete_env(:lemon_honcho, :test_peer_card) end)

    start_manager(client: CardClient, first_turn_wait_ms: 2_000)
  end

  # Production starts the manager with no pinned config, which is what makes a
  # runtime change reach it. Every other helper here pins one; these tests
  # deliberately do not, and drive the configuration through the OS environment
  # because `LemonHoncho.Config` resolves that ahead of application env — so a
  # developer's exported HONCHO_* cannot change what these assert.
  defp start_unpinned_manager(client \\ OkClient, overrides \\ %{}) do
    %{
      "HONCHO_API_KEY" => "sk-test",
      "LEMON_HONCHO_ENABLED" => "true",
      "LEMON_HONCHO_RECALL_MODE" => "hybrid",
      "LEMON_HONCHO_SESSION_STRATEGY" => "per_directory",
      "LEMON_HONCHO_INJECT_IN_SUBAGENTS" => "false",
      "LEMON_HONCHO_SAVE_MESSAGES" => "true",
      "LEMON_HONCHO_FIRST_TURN_WAIT_MS" => "0"
    }
    |> Map.merge(overrides)
    |> put_env()

    start_supervised!({SessionManager, client: client})
  end

  # Sets OS environment variables for one test and puts back what was there —
  # including "nothing at all" — however the test ends.
  defp put_env(variables) do
    previous = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(variables, fn {name, value} -> System.put_env(name, value) end)
  end

  # One turn that actually says something, settled.
  defp real_turn do
    block = SessionManager.context_for(@request)
    await_idle(@session_key)

    block
  end

  # `count` settled turns, each saying something different, as the halves the
  # refresh each one started produced. The block is read from the manager after
  # the refresh has landed rather than taken from what the turn was served: a
  # refresh lands after the turn that started it, so serving alone would show
  # turn N's fetch on turn N+1 and blur the boundary being measured.
  defp echo_turns(count) do
    Enum.map(1..count, fn index ->
      SessionManager.context_for(%{@request | query: "why is step #{index} slow?"})
      await_idle(@session_key)

      @session_key |> settled_block() |> Context.split()
    end)
  end

  defp settled_block(key) do
    SessionManager |> :sys.get_state() |> get_in([:sessions, key]) |> Map.fetch!(:last_context)
  end

  # Every call of one kind the recorder forwarded, drained from the mailbox in
  # arrival order. What a fetch was parameterised with is only knowable here:
  # the text that comes back can be identical for the wrong reason.
  defp recorded(name, payloads \\ []) do
    receive do
      {:honcho_call, ^name, payload} -> recorded(name, [payload | payloads])
    after
      0 -> Enum.reverse(payloads)
    end
  end

  # The user's message reaches Honcho inside the *warm* dialectic question and
  # nowhere else, and a session's first turn asks the cold question — which
  # embeds nothing. So every egress assertion needs two turns, and the second
  # one carries the payload under test.
  defp warm_dialectic_question(query) do
    request = %{@request | query: query}

    SessionManager.context_for(request)
    await_idle(@session_key)
    SessionManager.context_for(request)
    await_idle(@session_key)

    assert_receive {:honcho_call, :chat, {_peer, _cold, _cold_opts}}, 1_000
    assert_receive {:honcho_call, :chat, {_peer, warm, _opts}}, 1_000

    warm
  end

  defp request_for(key), do: %{@request | session_key: key}

  # One settled turn for `key`. The sleep is not padding: LRU eviction orders
  # entries by wall-clock touch time, and two turns inside the same millisecond
  # give it nothing to order by.
  defp serve(key) do
    block = SessionManager.context_for(request_for(key))
    await_idle(key)
    Process.sleep(2)

    block
  end

  defp tracked_keys do
    SessionManager |> :sys.get_state() |> Map.fetch!(:sessions) |> Map.keys() |> Enum.sort()
  end

  defp base_config do
    %Config{
      api_key: "sk-test",
      user_peer: "user",
      ai_peer: "lemon",
      session_strategy: :per_directory,
      first_turn_wait_ms: 2_000
    }
  end

  defp document(overrides \\ []) do
    fields =
      Keyword.merge(
        [
          session_key: @session_key,
          agent_id: "demo",
          workspace_key: "/tmp/lemon-honcho-test",
          prompt_summary: "why is the build slow?",
          answer_summary: "Because the cache was cold."
        ],
        overrides
      )

    Document.new(fields)
  end

  # A query the module's own screen — `LemonMemory.Safety.contains_secret?/1` —
  # matches twice over: on the `api_key:` assignment and on the `sk-` prefix.
  defp secret_query do
    "deploy is failing, my api_key: sk-live-4f9c1e2d8a7b6c5d0e9f8a7b6c5d4e3f2a1b"
  end

  # Shaped like what a refresh task sends back, with content nothing else in the
  # suite produces, so a block that contains it can only have come from here.
  defp stale_result do
    %{
      init: {:ok, "lemon-honcho-test", %{user: "user", ai: "lemon"}},
      base: {:ok, %{summary: "Stale summary.", user_representation: "Stale.", peer_card: nil}},
      dialectic: {:ok, "Stale dialectic."}
    }
  end

  # Turns arrive on a wall clock rather than a count, because what is under test
  # is how many refreshes a *duration* admits.
  defp drive_turns(elapsed_ms, interval_ms) do
    deadline = System.monotonic_time(:millisecond) + elapsed_ms

    Stream.repeatedly(fn ->
      SessionManager.context_for(@request)
      Process.sleep(interval_ms)
      System.monotonic_time(:millisecond) < deadline
    end)
    |> Enum.take_while(& &1)
    |> length()
  end

  # The manager's private state is the only place "is a refresh still in flight"
  # is knowable, and every cadence assertion depends on the previous turn having
  # settled. Polling it is what makes these tests deterministic instead of timed.
  defp await_idle(key, deadline \\ 2_000) do
    await_state(key, &is_nil(&1.pending_refresh), deadline, "refresh did not settle")
  end

  # The other direction: block until a refresh is in flight, so a test can take
  # hold of the guard the manager is keeping for it.
  defp await_pending(key) do
    await_state(key, &(not is_nil(&1.pending_refresh)), 2_000, "no refresh started")

    SessionManager |> :sys.get_state() |> get_in([:sessions, key]) |> Map.fetch!(:pending_refresh)
  end

  defp await_waiter(key) do
    await_state(key, &(&1.waiters != []), 2_000, "no caller waited")
  end

  defp waiters(key) do
    SessionManager |> :sys.get_state() |> get_in([:sessions, key]) |> Map.fetch!(:waiters)
  end

  defp await_state(key, predicate, deadline, failure) do
    cond do
      entry_matches?(key, predicate) ->
        :ok

      deadline <= 0 ->
        flunk("honcho: #{failure} for #{key}")

      true ->
        Process.sleep(10)
        await_state(key, predicate, deadline - 10, failure)
    end
  end

  defp entry_matches?(key, predicate) do
    case SessionManager |> :sys.get_state() |> get_in([:sessions, key]) do
      nil -> false
      entry -> predicate.(entry)
    end
  end

  # The application starts a manager under the real client; these tests need the
  # registered name for their own.
  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end
end
