defmodule LemonRouter.RouterTest do
  use ExUnit.Case, async: false

  alias LemonRouter.Router
  alias LemonCore.InboundMessage

  defmodule RunOrchestratorStub do
    def submit(request) do
      if pid = Process.get(:router_test_pid) do
        send(pid, {:orchestrator_submit, request})
      end

      Process.get(:router_submit_result, {:ok, "run_stub"})
    end
  end

  setup do
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    previous_orchestrator = Application.get_env(:lemon_router, :run_orchestrator)
    Application.put_env(:lemon_router, :run_orchestrator, RunOrchestratorStub)

    Process.put(:router_test_pid, self())
    Process.delete(:router_submit_result)

    on_exit(fn ->
      case previous_orchestrator do
        nil -> Application.delete_env(:lemon_router, :run_orchestrator)
        mod -> Application.put_env(:lemon_router, :run_orchestrator, mod)
      end

      Process.delete(:router_test_pid)
      Process.delete(:router_submit_result)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  defp start_registered_run(parent, session_key, run_id) do
    pid =
      spawn_link(fn ->
        _ = Registry.register(LemonRouter.RunRegistry, run_id, :ok)
        _ = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
        send(parent, {:registered, run_id, self()})

        receive do
          {:"$gen_cast", {:abort, reason}} ->
            send(parent, {:aborted, run_id, reason})
        after
          5_000 ->
            send(parent, {:abort_timeout, run_id})
        end
      end)

    pid
  end

  test "abort/2 aborts the active run registered for the session" do
    # Avoid flakiness in umbrella runs: other tests may also use SessionRegistry.
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    run_id1 = "run_#{System.unique_integer([:positive])}"

    _pid1 = start_registered_run(self(), session_key, run_id1)

    assert_receive {:registered, ^run_id1, _}, 500

    Router.abort(session_key, :test_abort)

    assert_receive {:aborted, ^run_id1, :test_abort}, 500
  end

  test "abort/2 is a no-op when session has no runs" do
    assert :ok = Router.abort("missing:session", :test_abort)
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
