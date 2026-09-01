defmodule LemonCore.RouterBridgeTest do
  alias Elixir.LemonCore, as: LemonCore
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elixir.LemonCore.{RouterBridge, RunRequest}

  defmodule RouterBridgeTestRunOrchestrator do
    @moduledoc false

    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_test"}
    end
  end

  defmodule RouterBridgeTestRouter do
    use LemonCore.RouterBridge.Router
    @moduledoc false

    def abort(session_key, reason) do
      send(self(), {:aborted, session_key, reason})
      :ok
    end

    def abort_run(run_id, reason) do
      send(self(), {:run_aborted, run_id, reason})
      :ok
    end

    def active_run(session_key) do
      send(self(), {:active_run, session_key})
      {:ok, "run_for_#{session_key}"}
    end

    def list_active_sessions do
      send(self(), :list_active_sessions)
      [%{session_key: "agent:bridge:main", run_id: "run_bridge"}]
    end
  end

  defmodule AlternativeRunOrchestrator do
    @moduledoc false

    def submit(_params), do: {:ok, "run_alt"}
  end

  defmodule BridgeDeadRouter do
    @moduledoc false
    # A router whose *module* is configured but whose *process* is not running.
    # `GenServer.call/3` to a dead named process exits with exactly this shape;
    # an exit is not an exception, so `rescue` alone never saw it.

    defp dead, do: exit({:noproc, {GenServer, :call, [__MODULE__, :anything, 5000]}})

    def handle_inbound(_msg), do: dead()
    def abort(_session_key, _reason), do: dead()
    def abort_run(_run_id, _reason), do: dead()
    def keep_run_alive(_run_id, _decision), do: dead()
    def session_busy?(_session_key), do: dead()
    def active_run(_session_key), do: dead()
    def list_active_sessions, do: dead()
  end

  defmodule BridgeDeadOrchestrator do
    @moduledoc false
    def submit(_params), do: exit({:noproc, {GenServer, :call, [__MODULE__, :submit, 5000]}})
  end

  defmodule BridgeTimingOutRouter do
    @moduledoc false
    use LemonCore.RouterBridge.Router
    # The other exit shape worth pinning: the process is alive but did not
    # answer in time. Same consequence for the caller — the work was not taken.
    def handle_inbound(_msg), do: exit({:timeout, {GenServer, :call, [__MODULE__, :x, 5000]}})
  end

  defmodule BridgeRaisingRouter do
    @moduledoc false
    use LemonCore.RouterBridge.Router
    def handle_inbound(_msg), do: raise("router blew up")
  end

  setup do
    original = Application.get_env(:lemon_core, :router_bridge)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :router_bridge)
      else
        Application.put_env(:lemon_core, :router_bridge, original)
      end
    end)

    :ok
  end

  describe "submit_run/1" do
    test "forwards RunRequest params to orchestrator" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)

      request =
        RunRequest.new(%{
          origin: :control_plane,
          session_key: "agent:bridge:main",
          prompt: "hello"
        })

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)

      assert_receive {:submitted,
                      %RunRequest{
                        origin: :control_plane,
                        session_key: "agent:bridge:main",
                        agent_id: "bridge",
                        prompt: "hello",
                        queue_mode: :collect
                      }}
    end

    test "accepts RunRequest struct directly" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:bridge:main",
          agent_id: "bridge",
          prompt: "hello",
          queue_mode: :interrupt,
          meta: %{channel_id: "demo"}
        }

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)
      assert_receive {:submitted, ^request}
    end

    test "returns unavailable when no orchestrator is configured" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:x:main",
          agent_id: "x",
          prompt: "ping"
        }

      assert {:error, :unavailable} = RouterBridge.submit_run(request)
    end
  end

  describe "abort_session/2" do
    test "delegates to router abort when configured" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      assert :ok = RouterBridge.abort_session("agent:bridge:main", :new_session)
      assert_receive {:aborted, "agent:bridge:main", :new_session}
    end

    test "returns unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)
      assert {:error, :unavailable} = RouterBridge.abort_session("agent:x:main")
    end
  end

  describe "abort_run/2" do
    test "delegates to router abort_run when configured" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      assert :ok = RouterBridge.abort_run("run-123", :user_requested)
      assert_receive {:run_aborted, "run-123", :user_requested}
    end

    test "returns unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)
      assert {:error, :unavailable} = RouterBridge.abort_run("run-x")
    end
  end

  describe "session queries" do
    test "active_run/1 delegates to router when configured" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      assert RouterBridge.active_run("agent:bridge:main") == {:ok, "run_for_agent:bridge:main"}
      assert_receive {:active_run, "agent:bridge:main"}
    end

    test "active_run/1 reports unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)
      assert RouterBridge.active_run("agent:x:main") == {:error, :unavailable}
    end

    test "list_active_sessions/0 delegates to router when configured" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      assert RouterBridge.list_active_sessions() ==
               {:ok, [%{session_key: "agent:bridge:main", run_id: "run_bridge"}]}

      assert_receive :list_active_sessions
    end

    test "list_active_sessions/0 reports unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)
      assert RouterBridge.list_active_sessions() == {:error, :unavailable}
    end
  end

  describe "a configured router whose process is not running" do
    # The gap this suite exists to close: every function below rescued
    # exceptions but not exits, so an exit from `GenServer.call` travelled out
    # of the bridge into callers that had been promised an error tuple. For an
    # HTTP handler that meant an opaque 500; for the email webhook it meant a
    # silently dropped message answered with "accepted".

    test "submit_run/1 reports unavailable instead of exiting" do
      :ok = RouterBridge.configure(run_orchestrator: BridgeDeadOrchestrator)

      request = %RunRequest{
        origin: :channel,
        session_key: "agent:dead:main",
        agent_id: "dead",
        prompt: "ping"
      }

      assert {:error, :unavailable} = RouterBridge.submit_run(request)
    end

    test "handle_inbound/1 reports unavailable instead of exiting" do
      :ok = RouterBridge.configure(router: BridgeDeadRouter)

      assert {:error, :unavailable} = RouterBridge.handle_inbound(%{any: :message})
    end

    test "abort_session/2 reports unavailable instead of exiting" do
      :ok = RouterBridge.configure(router: BridgeDeadRouter)

      assert {:error, :unavailable} = RouterBridge.abort_session("agent:dead:main")
    end

    test "abort_run/2 reports unavailable instead of exiting" do
      :ok = RouterBridge.configure(router: BridgeDeadRouter)

      assert {:error, :unavailable} = RouterBridge.abort_run("run-dead")
    end

    test "keep_run_alive/2 reports unavailable instead of exiting" do
      :ok = RouterBridge.configure(router: BridgeDeadRouter)

      assert {:error, :unavailable} = RouterBridge.keep_run_alive("run-dead", :continue)
    end

    test "the query functions report unavailable instead of a soft answer" do
      # "Not busy" for a router that cannot be reached would let a caller start
      # work it would otherwise have queued; the caller decides what unknown
      # means for it.
      :ok = RouterBridge.configure(router: BridgeDeadRouter)

      assert RouterBridge.session_busy?("agent:dead:main") == {:error, :unavailable}
      assert RouterBridge.active_run("agent:dead:main") == {:error, :unavailable}
      assert RouterBridge.list_active_sessions() == {:error, :unavailable}
    end

    test "a timeout is unavailable too, since the work was not taken either way" do
      :ok = RouterBridge.configure(router: BridgeTimingOutRouter)

      assert {:error, :unavailable} = RouterBridge.handle_inbound(%{any: :message})
    end

    test "matches what an unconfigured bridge answers, because it is the same situation" do
      :ok = RouterBridge.configure(router: BridgeDeadRouter)
      dead = RouterBridge.handle_inbound(%{any: :message})

      :ok = RouterBridge.configure(run_orchestrator: RouterBridgeTestRunOrchestrator)
      unconfigured = RouterBridge.handle_inbound(%{any: :message})

      assert dead == unconfigured
    end
  end

  describe "a router that is reached and raises" do
    test "is reported as itself, not flattened into :unavailable" do
      # The router *was* available; saying otherwise would send a caller into a
      # retry loop over a bug that will fail identically every time.
      :ok = RouterBridge.configure(router: BridgeRaisingRouter)

      log =
        capture_log(fn ->
          assert {:error, %RuntimeError{message: "router blew up"}} =
                   RouterBridge.handle_inbound(%{any: :message})
        end)

      assert log =~ "RouterBridge router handle_inbound/1 raised"
      assert log =~ "router blew up"
    end

    test "a callback the router left at its default is reported as not implemented" do
      :ok = RouterBridge.configure(router: BridgeRaisingRouter)

      assert {:error, %LemonCore.RouterBridge.NotImplementedError{function: :keep_run_alive}} =
               RouterBridge.keep_run_alive("run-1", :continue)
    end
  end

  describe "configure/1 validation" do
    test "rejects an implementation that is not loadable" do
      assert {:error, {:invalid_implementation, :router, {:not_loadable, No.Such.Router}}} =
               RouterBridge.configure(router: No.Such.Router)
    end

    test "rejects an implementation missing callbacks and changes nothing" do
      :ok = RouterBridge.configure(router: RouterBridgeTestRouter)

      assert {:error,
              {:invalid_implementation, :router,
               {:missing_callbacks, RouterBridgeTestRunOrchestrator, missing}}} =
               RouterBridge.configure(router: RouterBridgeTestRunOrchestrator)

      assert Keyword.has_key?(missing, :handle_inbound)
      assert RouterBridge.active_run("agent:bridge:main") == {:ok, "run_for_agent:bridge:main"}

      assert {:error,
              {:invalid_implementation, :run_orchestrator,
               {:missing_callbacks, BridgeRaisingRouter, [submit: 1]}}} =
               RouterBridge.configure(run_orchestrator: BridgeRaisingRouter)
    end
  end

  describe "configure guardrails" do
    test "configure_guarded/1 rejects conflicting non-nil overrides" do
      :ok =
        RouterBridge.configure(
          run_orchestrator: RouterBridgeTestRunOrchestrator,
          router: RouterBridgeTestRouter
        )

      assert {:error,
              {:already_configured, :run_orchestrator, RouterBridgeTestRunOrchestrator,
               AlternativeRunOrchestrator}} =
               RouterBridge.configure_guarded(run_orchestrator: AlternativeRunOrchestrator)
    end

    test "merge mode preserves unspecified keys" do
      :ok =
        RouterBridge.configure(
          run_orchestrator: RouterBridgeTestRunOrchestrator,
          router: RouterBridgeTestRouter
        )

      :ok = RouterBridge.configure([router: RouterBridgeTestRouter], mode: :merge)

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:merge:main",
          agent_id: "merge",
          prompt: "test"
        }

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)
      assert_receive {:submitted, %RunRequest{}}
    end
  end
end
