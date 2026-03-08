defmodule LemonRouter.RouterTest do
  use ExUnit.Case, async: false

  alias LemonRouter.Router
  alias LemonCore.InboundMessage

  defmodule RunOrchestratorStubRouter do
    def submit(request) do
      if pid = Process.get(:router_test_pid) do
        send(pid, {:orchestrator_submit, request})
      end

      Process.get(:router_submit_result, {:ok, "run_stub"})
    end
  end

  defmodule SessionCoordinatorStubRouter do
    def abort_session(session_key, reason) do
      send(test_pid(), {:abort_session, session_key, reason})
      :ok
    end

    def busy?(session_key) do
      send(test_pid(), {:busy_query, session_key})
      session_key == Process.get(:router_busy_session_key)
    end

    def active_run_for_session(session_key) do
      send(test_pid(), {:active_run_query, session_key})
      Process.get({:active_run, session_key}, :none)
    end

    def list_active_sessions do
      send(test_pid(), :list_active_sessions)
      Process.get(:router_active_sessions, [])
    end

    defp test_pid, do: Process.get(:router_test_pid)
  end

  setup do
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    previous_orchestrator = Application.get_env(:lemon_router, :run_orchestrator)
    previous_session_coordinator = Application.get_env(:lemon_router, :session_coordinator)
    Application.put_env(:lemon_router, :run_orchestrator, RunOrchestratorStubRouter)
    Application.put_env(:lemon_router, :session_coordinator, SessionCoordinatorStubRouter)

    Process.put(:router_test_pid, self())
    Process.delete(:router_submit_result)
    Process.delete(:router_busy_session_key)
    Process.delete(:router_active_sessions)

    on_exit(fn ->
      case previous_orchestrator do
        nil -> Application.delete_env(:lemon_router, :run_orchestrator)
        mod -> Application.put_env(:lemon_router, :run_orchestrator, mod)
      end

      case previous_session_coordinator do
        nil -> Application.delete_env(:lemon_router, :session_coordinator)
        mod -> Application.put_env(:lemon_router, :session_coordinator, mod)
      end

      Process.delete(:router_test_pid)
      Process.delete(:router_submit_result)
      Process.delete(:router_busy_session_key)
      Process.delete(:router_active_sessions)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  test "abort/2 aborts the active run registered for the session" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"

    Router.abort(session_key, :test_abort)

    assert_receive {:abort_session, ^session_key, :test_abort}, 500
  end

  test "abort/2 is a no-op when session has no runs" do
    assert :ok = Router.abort("missing:session", :test_abort)
    assert_receive {:abort_session, "missing:session", :test_abort}, 500
  end

  test "session_busy?/1 delegates to the session coordinator" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    Process.put(:router_busy_session_key, session_key)

    assert Router.session_busy?(session_key)
    assert_receive {:busy_query, ^session_key}, 500

    refute Router.session_busy?("agent:test:main:other")
    assert_receive {:busy_query, "agent:test:main:other"}, 500
  end

  test "active_run/1 delegates to the session coordinator" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    Process.put({:active_run, session_key}, {:ok, "run_active"})

    assert Router.active_run(session_key) == {:ok, "run_active"}
    assert_receive {:active_run_query, ^session_key}, 500
  end

  test "list_active_sessions/0 delegates to the session coordinator" do
    sessions = [%{session_key: "agent:test:main:1", run_id: "run_1"}]
    Process.put(:router_active_sessions, sessions)

    assert Router.list_active_sessions() == sessions
    assert_receive :list_active_sessions, 500
  end

  test "resolve_session_key/1 uses explicit meta.session_key when provided" do
    msg = %InboundMessage{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil},
      sender: nil,
      message: %{id: "1", text: "hi", timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: %{
        agent_id: "default",
        session_key: "agent:default:telegram:default:dm:123:sub:999"
      }
    }

    assert Router.resolve_session_key(msg) == "agent:default:telegram:default:dm:123:sub:999"
  end

  test "resolve_session_key/1 ignores invalid meta.session_key and falls back to computed" do
    msg = %InboundMessage{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil},
      sender: nil,
      message: %{id: "1", text: "hi", timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: %{
        agent_id: "default",
        session_key: "not:a:valid:key"
      }
    }

    assert Router.resolve_session_key(msg) == "agent:default:telegram:default:dm:123"
  end

  test "handle_inbound/1 forwards normalized request to orchestrator" do
    msg = %InboundMessage{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "42", thread_id: "99"},
      sender: %{id: "sender-1"},
      message: %{id: "1", text: "run this", timestamp: nil, reply_to_id: nil},
      raw: %{"raw" => true},
      meta: %{
        "agent_id" => "agent-x",
        "queue_mode" => :interrupt,
        "engine_id" => "codex:gpt-test",
        "custom" => "value"
      }
    }

    assert :ok = Router.handle_inbound(msg)

    assert_receive {:orchestrator_submit, request}, 500
    assert request.origin == :channel
    assert request.agent_id == "agent-x"
    assert request.session_key == "agent:agent-x:telegram:default:dm:42:thread:99"
    assert request.prompt == "run this"
    assert request.queue_mode == :interrupt
    assert request.engine_id == "codex:gpt-test"
    assert request.meta["custom"] == "value"
    assert request.meta[:channel_id] == "telegram"
    assert request.meta[:account_id] == "default"
  end

  test "handle_inbound/1 returns :ok when orchestrator submit fails" do
    Process.put(:router_submit_result, {:error, :submit_failed})

    msg = %InboundMessage{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "43", thread_id: nil},
      sender: nil,
      message: %{id: "1", text: "run", timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: %{"agent_id" => "agent-y"}
    }

    assert :ok = Router.handle_inbound(msg)
    assert_receive {:orchestrator_submit, _request}, 500
  end

  test "handle_control_agent/2 builds control-plane request and default main session key" do
    Process.put(:router_submit_result, {:ok, "run_control_1"})

    params = %{
      "agent_id" => "control-agent",
      "prompt" => "continue",
      "queue_mode" => :collect,
      "engine_id" => "claude:test",
      "cwd" => "/tmp/project",
      "meta" => %{"source" => "ws"}
    }

    ctx = %{request_id: "req-1"}

    assert {:ok, %{run_id: "run_control_1", session_key: "agent:control-agent:main"}} =
             Router.handle_control_agent(params, ctx)

    assert_receive {:orchestrator_submit, request}, 500
    assert request.origin == :control_plane
    assert request.session_key == "agent:control-agent:main"
    assert request.agent_id == "control-agent"
    assert request.prompt == "continue"
    assert request.queue_mode == :collect
    assert request.engine_id == "claude:test"
    assert request.cwd == "/tmp/project"
    assert request.meta["source"] == "ws"
    assert request.meta[:control_plane_ctx] == ctx
  end

  test "handle_control_agent/2 returns submit error payload when orchestrator fails" do
    Process.put(:router_submit_result, {:error, :timeout})

    assert {:error, %{code: "SUBMIT_FAILED", message: "Failed to submit run", details: :timeout}} =
             Router.handle_control_agent(%{agent_id: "err-agent", prompt: "hi"}, %{})
  end
end
