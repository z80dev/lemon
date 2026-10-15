# Retained offline regression smoke. Prepared unexecuted; no ExUnit or provider/browser network.
# Real Session/ExecApprovals owners and production authenticated loopback WS handlers.
# Initial RunStore admission metadata is supplied by this isolated fixture, not the router.
defmodule LemonApprovalRecoverySmoke do
  alias CodingAgent.Session
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall, Usage}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonCore.{Bus, ChatState, ChatStateStore, ExecApprovals, ExecApprovalStore, RunStore}

  @key "agent:default:tui:local:unknown:approval-recovery-smoke"

  def run do
    source = File.cwd!()
    root = System.fetch_env!("LEMON_SMOKE_ROOT")
    cwd = Path.join(root, "workspace")
    for path <- [cwd, Path.join(root, "home"), Path.join(root, "agent")], do: File.mkdir_p!(path)
    File.cd!(cwd)
    Logger.configure(level: :warning)

    Application.put_env(:lemon_core, LemonCore.Store,
      backend: LemonCore.Store.EtsBackend,
      backend_opts: []
    )

    Application.put_env(:lemon_core, :store_runtime_override,
      backend: LemonCore.Store.EtsBackend,
      backend_opts: []
    )

    Application.put_env(:lemon_core, LemonCore.RunHistoryStore, path: Path.join(root, "history"))
    Application.put_env(:lemon_core, :bus_backend, :pubsub)
    Application.put_env(:coding_agent, :primary_session, nil)
    Application.put_env(:coding_agent, :task_store_path, Path.join(root, "tasks.dets"))
    Application.put_env(:coding_agent, :run_graph_path, Path.join(root, "run_graph.dets"))
    Application.put_env(:coding_agent, :process_store_path, Path.join(root, "processes.dets"))
    Application.put_env(:lemon_channels, :adapters, [])
    Application.put_env(:lemon_honcho, :enabled, false)

    for app <- [:crypto, :ssl, :bandit, :coding_agent] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    case Application.load(:lemon_control_plane) do
      :ok -> :ok
      {:error, {:already_loaded, :lemon_control_plane}} -> :ok
      _ -> raise "control-plane application metadata unavailable"
    end

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    credential = Path.join(root, "operator.token")
    private_write(credential, token <> "\n")
    Application.put_env(:lemon_control_plane, :operator_token, token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
    port = free_port()

    {:ok, _} =
      Supervisor.start_link(
        [
          LemonControlPlane.LogRing,
          LemonControlPlane.Methods.Registry,
          LemonControlPlane.Presence,
          LemonControlPlane.EventBridge,
          {DynamicSupervisor,
           strategy: :one_for_one, name: LemonControlPlane.ConnectionSupervisor},
          {Registry, keys: :unique, name: LemonControlPlane.ConnectionRegistry},
          {Task.Supervisor, name: LemonControlPlane.A2A.TaskSupervisor},
          {Bandit, plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: port}
        ],
        strategy: :one_for_one
      )

    :ok = LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)

    owner = self()
    run_id = "approval-smoke-run"
    ids = ["approval-a", "approval-b"]
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    {:ok, slot} = Agent.start_link(fn -> nil end)
    :ok = Bus.subscribe("exec_approvals")

    tool = %AgentTool{
      name: "approval_smoke_gate",
      label: "Isolated approval gate",
      description: "No command or network effects",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      execute: fn _call, _args, _signal, _on_update ->
        native_id = Session.get_state(Agent.get(slot, & &1)).session_manager.header.id

        waiters =
          Enum.map(ids, fn id ->
            Task.async(fn ->
              decision =
                ExecApprovals.request(%{
                  approval_id: id,
                  run_id: run_id,
                  session_id: native_id,
                  session_key: @key,
                  agent_id: "default",
                  tool: "approval_smoke_gate",
                  action: %{title: id, kind: "local_smoke"},
                  rationale: "Isolated explicit decision",
                  expires_in_ms: 120_000
                })

              send(owner, {:approval_smoke_decision, id, decision})
              decision
            end)
          end)

        Enum.each(waiters, &Task.await(&1, 125_000))

        %AgentToolResult{
          content: [%TextContent{text: "Explicit decisions received; no action executed."}],
          details: %{status: "completed"}
        }
      end
    }

    stream_fn = fn _model, _context, _options ->
      call = Agent.get_and_update(calls, &{&1, &1 + 1})

      message =
        if call == 0 do
          assistant(
            [%ToolCall{id: "approval-smoke-call", name: "approval_smoke_gate", arguments: %{}}],
            :tool_use
          )
        else
          check(call == 1, "unexpected scripted inference callback")
          assistant([%TextContent{text: "Approval recovery smoke complete."}], :stop)
        end

      event_stream(message)
    end

    model = %Model{
      id: "offline-approval-smoke",
      name: "Local scripted smoke",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      input: [:text],
      cost: %ModelCost{},
      context_window: 32_000,
      max_tokens: 1024
    }

    {:ok, session} =
      Session.start_link(
        cwd: cwd,
        workspace_dir: Path.join(root, "workspace-state"),
        session_key: @key,
        run_id: run_id,
        agent_id: "default",
        register: true,
        model: model,
        tools: [tool],
        stream_fn: stream_fn,
        system_prompt: "Offline deterministic smoke; no network."
      )

    Agent.update(slot, fn _ -> session end)
    native_id = Session.get_state(session).session_manager.header.id
    :ok = RunStore.create_session_index(@key, "default", :tui)

    :ok =
      LemonCore.Store.put(:runs, run_id, %{
        session_key: @key,
        events: [],
        summary: nil,
        started_at: System.system_time(:millisecond)
      })

    :ok = ChatStateStore.put(@key, %ChatState{last_engine: "lemon", last_resume_token: native_id})

    :ok =
      Session.prompt(session, "Exercise two local approval requests without commands or network.")

    Enum.each(ids, fn id ->
      receive do
        %LemonCore.Event{type: :approval_requested, payload: %{approval_id: ^id}} -> :ok
      after
        10_000 -> raise "real pending owner did not publish"
      end
    end)

    Session.get_state(session)
    :sys.get_state(LemonControlPlane.EventBridge)
    ctx = %{auth: %{role: :operator, scopes: [:read, :write, :approvals]}}

    {:ok, before} =
      LemonControlPlane.Methods.SessionsSnapshot.handle(
        %{"sessionKey" => @key, "cwd" => cwd},
        ctx
      )

    check(before["status"] == "ok", "owner snapshot must be stable")
    rows = before["snapshot"]["approvals"]["items"]
    check(Enum.map(rows, & &1["id"]) == ids, "wire rows must expose two real method IDs")

    check(
      Enum.all?(rows, &(not Map.has_key?(&1, "approvalId"))),
      "method rows must not masquerade as events"
    )

    check(
      before["snapshot"]["approvals"]["truncated"] != true,
      "small approval fixture unexpectedly truncated"
    )

    {:ok, policy} = LemonControlPlane.Methods.ExecApprovalsGet.handle(%{}, ctx)

    check(
      Enum.sort(Enum.map(policy["pending"], & &1["id"])) == ids,
      "public pending contract changed"
    )

    manifest = Path.join(root, "runtime.json")

    private_write(
      manifest,
      Jason.encode!(%{
        url: "ws://127.0.0.1:#{port}/ws",
        credentialFile: credential,
        sessionKey: @key,
        cwd: cwd,
        approvalIds: ids
      })
    )

    script = Path.join(source, "clients/tui/scripts/approval-recovery-smoke.ts")

    {consumer_output, status} =
      System.cmd("bun", [script, manifest], cd: source, stderr_to_stdout: true)

    IO.write(consumer_output)
    check(status == 0, "real AppShell consumer smoke failed")

    receive do
      {:approval_smoke_decision, "approval-a", decision} ->
        check(
          decision in [{:ok, :approved, :approve_once}, {:ok, :approved, :once}],
          "first ID did not receive explicit approve_once"
        )
    after
      5000 -> raise "first owner's decision missing"
    end

    receive do
      {:approval_smoke_decision, "approval-b", {:ok, :denied}} -> :ok
    after
      5000 -> raise "second owner was not explicitly denied"
    end

    check(ExecApprovalStore.list_pending() == [], "approval owner retained resolved requests")

    IO.puts(
      Jason.encode!(%{
        status: "passed",
        owner: "real_native_session_and_exec_approvals",
        recoveredPending: 2,
        providerNetworkCalls: 0,
        browserCalls: 0,
        routerAdmissionExercised: false
      })
    )

    GenServer.stop(session, :normal)
    Bus.unsubscribe("exec_approvals")
  end

  defp assistant(content, reason),
    do: %AssistantMessage{
      role: :assistant,
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "offline-approval-smoke",
      usage: %Usage{},
      stop_reason: reason,
      timestamp: System.system_time(:millisecond)
    }

  defp event_stream(message) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})

      Enum.with_index(message.content)
      |> Enum.each(fn {block, index} ->
        case block do
          %ToolCall{} ->
            LemonAi.EventStream.push(stream, {:tool_call_start, index, message})
            LemonAi.EventStream.push(stream, {:tool_call_end, index, block, message})

          %TextContent{text: text} ->
            LemonAi.EventStream.push(stream, {:text_start, index, message})
            LemonAi.EventStream.push(stream, {:text_delta, index, text, message})
            LemonAi.EventStream.push(stream, {:text_end, index, text, message})
        end
      end)

      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    {:ok, stream}
  end

  defp check(true, _), do: :ok
  defp check(false, message), do: raise(message)

  defp private_write(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o600)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

try do
  LemonApprovalRecoverySmoke.run()
rescue
  _ ->
    IO.puts(
      :stderr,
      "Approval owner smoke failed; no passing evidence claimed. Private credentials were not printed."
    )

    System.halt(1)
end
