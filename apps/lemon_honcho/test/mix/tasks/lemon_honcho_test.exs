defmodule Mix.Tasks.Lemon.HonchoTest do
  @moduledoc """
  The property under test throughout is that this task is safe to run and safe
  to paste: no argument makes it crash in a way an operator cannot read, no code
  path prints `HONCHO_API_KEY`, no probe outlasts the timeout it printed, and
  `context` does not change the session it is asked to explain.

  The formatting helpers are exercised by value rather than through the
  terminal, because the leak-proofing lives in them; the `run/1` tests then
  cover argument handling and each state an operator actually hits — with a
  manager and without one, tracked session and untracked, cached and live.

  Both collaborators are stubbed. The client is stubbed because nothing here may
  touch the network. The session manager is stubbed — `StubManager`, registered
  under the real manager's name — because the real one would need a configured
  install and a stub client of its own to hold a session at all, and because
  these tests are about what the *task* does with what the manager reports:
  driving the real manager would test the manager instead, which its own suite
  already does.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonHoncho.Client
  alias LemonHoncho.Config
  alias Mix.Tasks.Lemon.Honcho

  @api_key "sk-honcho-do-not-print-4f2b9c"

  @env_vars ~w(
    HONCHO_API_KEY
    HONCHO_BASE_URL
    HONCHO_ENVIRONMENT
    HONCHO_WORKSPACE
    HONCHO_PEER
    HONCHO_AI_PEER
    HONCHO_TIMEOUT_MS
    LEMON_HONCHO_ENABLED
    LEMON_HONCHO_RECALL_MODE
    LEMON_HONCHO_SESSION_STRATEGY
  )

  # `:enabled` belongs here for the same reason `LEMON_HONCHO_ENABLED` belongs
  # above: this task's job is to explain whatever install it is pointed at, so
  # its tests have to start from the shipped defaults rather than from whatever
  # the ambient environment happens to say. The suite pins `enabled: false`
  # globally so no test can reach a real workspace, which would otherwise make
  # every "a configured install reports…" case here silently exercise the
  # switched-off branch instead.
  @app_keys [:api_key, :base_url, :client, :enabled]

  defmodule OkClient do
    @moduledoc false

    # The probe runs in the test process, so echoing the bounds back as a
    # message is enough to assert what the task asked the client for.
    def ensure_workspace(_config, opts \\ []) do
      send(self(), {:probe_opts, opts})
      {:ok, %{"id" => "lemon"}}
    end
  end

  defmodule LeakyClient do
    @moduledoc false

    # The worst realistic case: an upstream that quotes the credential it
    # rejected back inside its error body.
    def ensure_workspace(config, _opts \\ []) do
      {:error, {:unauthorized, %{"detail" => "invalid key #{config.api_key}"}}}
    end
  end

  defmodule StubManager do
    @moduledoc false

    use GenServer

    @doc "Starts under `LemonHoncho.SessionManager`'s registered name."
    def start(opts) do
      GenServer.start(__MODULE__, opts, name: LemonHoncho.SessionManager)
    end

    @doc "Every `context_for/1` request this manager was asked to serve."
    def context_requests do
      GenServer.call(LemonHoncho.SessionManager, :context_requests)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         sessions: Keyword.get(opts, :sessions, []),
         block: Keyword.get(opts, :block, ""),
         requests: []
       }}
    end

    @impl true
    def handle_call(:sessions, _from, state), do: {:reply, {:ok, state.sessions}, state}

    def handle_call({:context, request}, _from, state) do
      {:reply, {:ok, state.block}, %{state | requests: [request | state.requests]}}
    end

    def handle_call(:context_requests, _from, state) do
      {:reply, Enum.reverse(state.requests), state}
    end
  end

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each([:api_key, :base_url, :enabled], &Application.delete_env(:lemon_honcho, &1))

    # The client is *replaced* rather than deleted: dropping it would fall back
    # to the real transport, which is the hole `config/test.exs` pins shut.
    Application.put_env(:lemon_honcho, :client, Client.Tripwire)

    on_exit(fn ->
      Enum.each(saved_env, &restore_env/1)
      Enum.each(saved_app, &restore_app_env/1)
    end)

    {:ok, pinned_client: saved_app[:client]}
  end

  describe "argument handling" do
    test "no arguments prints usage covering every subcommand" do
      output = capture_io(fn -> Honcho.run([]) end)

      assert output =~ "mix lemon.honcho status"
      assert output =~ "mix lemon.honcho sessions"
      assert output =~ "mix lemon.honcho ping"
      assert output =~ "mix lemon.honcho context"
    end

    test "--help prints the same usage and does not raise" do
      output = capture_io(fn -> Honcho.run(["--help"]) end)

      assert output =~ "mix lemon.honcho status"
      assert output =~ "mix lemon.honcho ping"
    end

    test "an unknown subcommand fails instead of printing usage" do
      assert_raise Mix.Error, ~r/Unknown subcommand "explode"/, fn ->
        Honcho.run(["explode"])
      end
    end

    test "extra arguments to a known subcommand fail with a specific message" do
      assert_raise Mix.Error, ~r/takes no extra arguments/, fn ->
        Honcho.run(["status", "please"])
      end
    end

    test "an unparseable option fails rather than being ignored" do
      assert_raise Mix.Error, ~r/Invalid options/, fn ->
        Honcho.run(["context", "--session"])
      end
    end

    test "a non-numeric --timeout is rejected by the parser" do
      assert_raise Mix.Error, ~r/Invalid options/, fn ->
        Honcho.run(["ping", "--timeout", "soon"])
      end
    end

    test "a --timeout that cannot bound anything is rejected by name" do
      assert_raise Mix.Error, ~r/--timeout must be a positive number/, fn ->
        capture_io(fn -> Honcho.run(["ping", "--timeout", "0"]) end)
      end
    end
  end

  describe "status_lines/1" do
    test "reports an absent key and an unconfigured install" do
      lines = Honcho.status_lines(%Config{})

      assert field(lines, "Configured") == "no"
      assert field(lines, "API key") == "absent"
      assert field(lines, "Environment") == "production"
    end

    test "reports the key as present and never echoes its value" do
      lines = Honcho.status_lines(%Config{api_key: @api_key})

      assert field(lines, "API key") == "present"
      assert field(lines, "Configured") == "yes"
      refute Enum.any?(lines, &String.contains?(&1, @api_key))
    end

    test "prints every field an operator needs to explain the model's behaviour" do
      config = %Config{
        api_key: @api_key,
        base_url: "https://honcho.internal",
        workspace: "acme",
        user_peer: "z80",
        ai_peer: "lemon",
        recall_mode: :context,
        session_strategy: :per_repo,
        observation_mode: :unified,
        context_cadence: 3,
        dialectic_cadence: 5,
        context_tokens: 1_500
      }

      lines = Honcho.status_lines(config)

      assert field(lines, "Base URL") == "https://honcho.internal"
      assert field(lines, "Workspace") == "acme"
      assert field(lines, "User peer") == "z80"
      assert field(lines, "AI peer") == "lemon"
      assert field(lines, "Recall mode") == "context"
      assert field(lines, "Session strategy") == "per_repo"
      assert field(lines, "Observation mode") == "unified"
      assert field(lines, "Context cadence") == "every 3 turns"
      assert field(lines, "Dialectic cadence") == "every 5 turns"
      assert field(lines, "Context budget") == "1500 tokens (~6000 characters)"
    end

    test "names the deployment when no base URL is set, and unlimited context budget" do
      lines = Honcho.status_lines(%Config{environment: "demo"})

      assert field(lines, "Base URL") == "(none — demo deployment)"
      assert field(lines, "Context budget") == "unlimited"
    end
  end

  describe "session_lines/1" do
    test "renders an empty state line rather than a bare header" do
      assert [line] = Honcho.session_lines([])
      assert line =~ "No sessions tracked yet"
    end

    test "renders one row per session and marks an unresolved id" do
      [header, first, second] = Honcho.session_lines(sessions())

      assert header =~ "SESSION KEY"
      assert header =~ "HONCHO SESSION ID"
      assert header =~ "TURNS"
      assert first =~ "agent:demo:main"
      assert first =~ "lemon-demo-main"
      assert first =~ "UTC"
      assert second =~ "(pending)"
      assert second =~ "(never)"
    end
  end

  describe "redact/2" do
    test "removes the configured key from a rendered reason" do
      config = %Config{api_key: @api_key}
      reason = {:unauthorized, %{"detail" => "invalid key #{@api_key}"}}

      rendered = Honcho.redact(reason, config)

      refute rendered =~ @api_key
      assert rendered =~ "[redacted]"
      assert rendered =~ "unauthorized"
    end

    test "leaves a reason intact when no key is configured" do
      assert Honcho.redact({:transport, :timeout}, %Config{}) == "{:transport, :timeout}"
    end

    # The short-key guard is the difference between a redaction and a corrupted
    # diagnostic: a two-character "key" would be replaced everywhere it happened
    # to occur, including inside words that have nothing to do with it.
    test "leaves a key too short to be a credential alone" do
      rendered = Honcho.redact({:api_error, 500, "backend fell over"}, %Config{api_key: "ac"})

      assert rendered =~ "backend fell over"
      refute rendered =~ "[redacted]"
    end

    test "scrubs a key that is exactly long enough" do
      rendered = Honcho.redact({:api_error, 500, "rejected abcdef"}, %Config{api_key: "abcdef"})

      assert rendered =~ "[redacted]"
      refute rendered =~ "abcdef"
    end
  end

  describe "the test environment's egress pin" do
    test "config/test.exs points the client at a module that cannot reach the network", ctx do
      assert ctx.pinned_client == {:ok, Client.Tripwire}
    end

    test "the pinned client raises instead of making a request" do
      assert_raise RuntimeError, ~r/Tripwire/, fn ->
        Client.Tripwire.ensure_workspace(%Config{api_key: @api_key})
      end

      assert_raise RuntimeError, ~r/Tripwire/, fn ->
        Client.Tripwire.workspace_search(%Config{api_key: @api_key}, "anything")
      end
    end
  end

  describe "status" do
    test "an unconfigured install is explained, not reported as a failure" do
      output = capture_io(fn -> Honcho.run(["status"]) end)

      assert output =~ "Not configured"
      assert output =~ "HONCHO_API_KEY"
      assert output =~ "HONCHO_BASE_URL"
      assert output =~ "not a failure"
      refute output =~ "Reachability"
      refute output =~ @api_key
    end

    test "a configured install reports key presence and a reachable endpoint" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, OkClient)

      output = capture_io(fn -> Honcho.run(["status"]) end)

      assert output =~ "API key"
      assert output =~ "present"
      assert output =~ "Reachability"
      assert output =~ "reachable in"
      refute output =~ @api_key
    end

    test "an unreachable endpoint is reported with the key scrubbed out of the reason" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, LeakyClient)

      output = capture_io(fn -> Honcho.run(["status"]) end)

      assert output =~ "unreachable"
      assert output =~ "[redacted]"
      refute output =~ @api_key
    end

    # `status` is documented as answering in seconds. That is only true if the
    # probe is one attempt inside a stated ceiling: three attempts of the same
    # ceiling plus Req's backoff is eighteen seconds, which is what this asserts
    # against.
    test "probes once, inside the five-second cap, without asking for retries" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, OkClient)

      capture_io(fn -> Honcho.run(["status"]) end)

      assert_received {:probe_opts, opts}
      assert opts[:max_retries] == 0
      assert opts[:total_timeout] == 5_000
    end

    test "--timeout overrides the cap it prints" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, OkClient)

      capture_io(fn -> Honcho.run(["status", "--timeout", "250"]) end)

      assert_received {:probe_opts, opts}
      assert opts[:total_timeout] == 250
    end
  end

  describe "ping" do
    test "reports the latency of a successful round trip" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, OkClient)

      output = capture_io(fn -> Honcho.run(["ping"]) end)

      assert output =~ "Honcho answered in"
      refute output =~ @api_key
    end

    test "fails non-zero on an unreachable endpoint, without leaking the key" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, LeakyClient)

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Honcho.run(["ping"]) end)
        end

      assert error.message =~ "Honcho unreachable"
      assert error.message =~ "[redacted]"
      refute error.message =~ @api_key
    end

    # The real client on purpose: this is the one path where it provably cannot
    # reach anything, because the setup above guarantees neither an API key nor
    # a base URL exists, and `LemonHoncho.Client` refuses before it builds a
    # request. It is also the only way to prove the refusal is what fails ping.
    test "an unconfigured install fails, because ping exists to be scripted" do
      Application.put_env(:lemon_honcho, :client, Client)

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn -> Honcho.run(["ping"]) end)
        end

      assert error.message =~ "Honcho unreachable"
      assert error.message =~ "not_configured"
    end

    # `ping` is documented as usable in a script, which is a promise about how
    # long it can take: one attempt, bounded by the configured request timeout.
    # Three attempts of 30 s plus backoff — the old behaviour — is 93 s.
    test "bounds the round trip by the configured timeout and asks for no retries" do
      System.put_env("HONCHO_API_KEY", @api_key)
      System.put_env("HONCHO_TIMEOUT_MS", "1234")
      Application.put_env(:lemon_honcho, :client, OkClient)

      capture_io(fn -> Honcho.run(["ping"]) end)

      assert_received {:probe_opts, opts}
      assert opts[:max_retries] == 0
      assert opts[:total_timeout] == 1234
    end

    test "--timeout is the bound when it is given" do
      System.put_env("HONCHO_API_KEY", @api_key)
      Application.put_env(:lemon_honcho, :client, OkClient)

      capture_io(fn -> Honcho.run(["ping", "--timeout", "750"]) end)

      assert_received {:probe_opts, opts}
      assert opts[:total_timeout] == 750
    end
  end

  describe "sessions with a manager holding sessions" do
    setup do
      start_stub_manager(sessions: sessions())
    end

    test "prints the table the manager reports" do
      output = capture_io(fn -> Honcho.run(["sessions"]) end)

      assert output =~ "Honcho Sessions"
      assert output =~ "SESSION KEY"
      assert output =~ "agent:demo:main"
      assert output =~ "lemon-demo-main"
      assert output =~ "(pending)"
      refute output =~ "No sessions tracked yet"
      refute output =~ "not running"
    end
  end

  describe "sessions with an empty manager" do
    setup do
      start_stub_manager(sessions: [])
    end

    test "explains that nothing has been tracked yet" do
      output = capture_io(fn -> Honcho.run(["sessions"]) end)

      assert output =~ "No sessions tracked yet"
      refute output =~ "not running"
    end
  end

  describe "sessions with no manager" do
    setup :without_manager

    test "says the manager is down rather than that there is nothing to show" do
      output = capture_io(fn -> Honcho.run(["sessions"]) end)

      assert output =~ "Honcho Sessions"
      assert output =~ "Session manager is not running"
      refute output =~ "No sessions tracked yet"
    end
  end

  describe "context with no manager" do
    setup :without_manager

    test "says nothing would be injected, and does not pretend to have looked" do
      output = capture_io(fn -> Honcho.run(["context", "--query", "why is the build slow?"]) end)

      assert output =~ "Honcho Context"
      assert output =~ "why is the build slow?"
      assert output =~ "Session manager is not running"
      refute output =~ "begin injected block"
    end
  end

  describe "context, read-only by default" do
    setup do
      start_stub_manager(sessions: sessions(), block: "REMEMBERED: prefers green")
    end

    test "reports the tracked session without serving a turn for it" do
      output = capture_io(fn -> Honcho.run(["context", "--session", "agent:demo:main"]) end)

      assert output =~ "read-only"
      assert output =~ "tracking that session"
      assert output =~ "SESSION KEY"
      assert output =~ "lemon-demo-main"
      refute output =~ "begin injected block"
      refute output =~ "REMEMBERED: prefers green"

      assert StubManager.context_requests() == []
    end

    test "says nothing was created for a session this node has never served" do
      output = capture_io(fn -> Honcho.run(["context", "--session", "agent:ghost:main"]) end)

      assert output =~ "no turns for \"agent:ghost:main\""
      assert output =~ "Nothing was created"
      refute output =~ "lemon-demo-main"

      assert StubManager.context_requests() == []
    end

    # `latest_session_key/0` picks the session Honcho answered for last, which is
    # the one an operator asking "why did it say that?" almost always means. The
    # never-refreshed session sorts last rather than being skipped.
    test "defaults to the most recently refreshed session" do
      output = capture_io(fn -> Honcho.run(["context"]) end)

      assert output =~ "agent:demo:main"
      refute output =~ "agent:other:main"
    end
  end

  describe "context --live" do
    setup do
      start_stub_manager(sessions: sessions(), block: "REMEMBERED: prefers green")
    end

    test "assembles the block, says so first, and passes the query through" do
      output = capture_io(fn -> Honcho.run(["context", "--live", "--query", "why?"]) end)

      assert output =~ "live ("
      assert output =~ "counts a turn"
      assert output =~ "begin injected block"
      assert output =~ "REMEMBERED: prefers green"
      assert output =~ "end injected block"

      assert [request] = StubManager.context_requests()
      assert request.query == "why?"
      assert request.session_key == "agent:demo:main"
    end
  end

  describe "context --live with nothing to show" do
    setup do
      start_stub_manager(sessions: sessions(), block: "")
    end

    test "an empty block lists every reason that applies, most likely first" do
      System.put_env("LEMON_HONCHO_RECALL_MODE", "tools")

      output = capture_io(fn -> Honcho.run(["context", "--live"]) end)

      assert output =~ "nothing would be injected"
      assert output =~ "Honcho is not configured."
      assert output =~ "Recall mode is :tools"
      assert output =~ "first refresh runs off the turn path"
      assert output =~ "nothing to recall"

      assert String.match?(output, ~r/not configured.*Recall mode is :tools/s)
    end

    test "a configured install in a recall mode that injects is offered neither reason" do
      System.put_env("HONCHO_API_KEY", @api_key)
      System.put_env("LEMON_HONCHO_RECALL_MODE", "context")

      output = capture_io(fn -> Honcho.run(["context", "--live"]) end)

      assert output =~ "nothing would be injected"
      assert output =~ "first refresh runs off the turn path"
      refute output =~ "Honcho is not configured."
      refute output =~ "Recall mode is :tools"
      refute output =~ @api_key
    end
  end

  ## Helpers

  # Two sessions: one Honcho has answered for, one whose first refresh has not
  # landed. Between them they cover every column `session_lines/1` formats.
  defp sessions do
    [
      %{
        session_key: "agent:demo:main",
        honcho_session_id: "lemon-demo-main",
        turns: 4,
        last_context_at_ms: 1_754_000_000_000
      },
      %{
        session_key: "agent:other:main",
        honcho_session_id: nil,
        turns: 0,
        last_context_at_ms: nil
      }
    ]
  end

  # Registers the stub under the real manager's name, standing the application's
  # own manager down first if this node happens to run one.
  defp start_stub_manager(opts) do
    running? = manager_running?()
    if running?, do: stop_application_manager()

    {:ok, pid} = StubManager.start(opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      if running?, do: start_application_manager()
    end)

    :ok
  end

  defp without_manager(_context) do
    running? = manager_running?()
    if running?, do: stop_application_manager()
    on_exit(fn -> if running?, do: start_application_manager() end)

    :ok
  end

  # Reads one "  Label            : value" line back out of the status report.
  defp field(lines, label) do
    Enum.find_value(lines, fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> if String.trim(key) == label, do: String.trim(value)
        _other -> nil
      end
    end)
  end

  defp manager_running?, do: is_pid(Process.whereis(LemonHoncho.SessionManager))

  defp stop_application_manager do
    Supervisor.terminate_child(LemonHoncho.Supervisor, LemonHoncho.SessionManager)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp start_application_manager do
    Supervisor.restart_child(LemonHoncho.Supervisor, LemonHoncho.SessionManager)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp restore_env({name, nil}), do: System.delete_env(name)
  defp restore_env({name, value}), do: System.put_env(name, value)

  defp restore_app_env({key, :error}), do: Application.delete_env(:lemon_honcho, key)
  defp restore_app_env({key, {:ok, value}}), do: Application.put_env(:lemon_honcho, key, value)
end
