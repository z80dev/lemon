defmodule LemonGateway.CliAdapterTest do
  use ExUnit.Case

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    ResumeToken,
    StartedEvent
  }

  alias LemonGateway.Engines.CliAdapter
  alias LemonCore.ResumeToken, as: GatewayToken

  test "maps started event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = StartedEvent.new("codex", token, title: "Codex")

    result = CliAdapter.to_event_map(ev)

    assert %{__event__: :started, engine: "codex", resume: %GatewayToken{value: "thread_123"}} =
             result
  end

  test "maps action event" do
    action = Action.new("a1", :command, "ls -la", %{})
    ev = ActionEvent.new("codex", action, :started, level: :info)

    result = CliAdapter.to_event_map(ev)

    assert %{
             __event__: :action_event,
             engine: "codex",
             action: %{__event__: :action, id: "a1", kind: "command"},
             phase: :started
           } = result
  end

  test "maps action result metadata" do
    result_meta = %{error_type: :tool_task_timeout, timeout_ms: 123, exit_code: 124}

    action =
      Action.new("tool_1", :tool, "slow_tool", %{name: "slow_tool", result_meta: result_meta})

    ev = ActionEvent.new("lemon", action, :completed, ok: false, level: :error)

    result = CliAdapter.to_event_map(ev)

    assert %{
             __event__: :action_event,
             engine: "lemon",
             action: %{detail: %{result_meta: ^result_meta}},
             phase: :completed,
             ok: false,
             level: :error
           } = result
  end

  test "maps completed event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = CompletedEvent.ok("codex", "done", resume: token)

    result = CliAdapter.to_event_map(ev)

    assert %{
             __event__: :completed,
             ok: true,
             answer: "done",
             resume: %GatewayToken{value: "thread_123"}
           } = result
  end

  test "passes ACP filesystem metadata into runner options" do
    parent = self()

    defmodule CliAdapterMetadataRunner do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      def init(opts) do
        send(opts[:owner], {:cli_adapter_start_opts, opts})
        {:ok, stream} = AgentCore.EventStream.start(owner: self())
        AgentCore.EventStream.complete(stream, [])
        {:ok, %{stream: stream}}
      end

      def stream(pid), do: GenServer.call(pid, :stream)

      def handle_call(:stream, _from, state), do: {:reply, state.stream, state}
    end

    job = %{
      prompt: "use editor fs",
      resume: nil,
      images: [],
      tool_policy: nil,
      session_key: "agent:default:acp-test",
      run_id: "run_acp_meta",
      cwd: nil,
      meta: %{
        acp_session_id: "acp_session",
        acp_client_fs_read_text_file: true,
        acp_client_fs_write_text_file: true
      }
    }

    assert {:ok, _run_ref, _ctx} =
             CliAdapter.start_run(CliAdapterMetadataRunner, "lemon", job, %{}, parent)

    assert_receive {:cli_adapter_start_opts, opts}, 1_000
    assert opts[:acp_session_id] == "acp_session"
    assert opts[:acp_client_fs_read_text_file] == true
    assert opts[:acp_client_fs_write_text_file] == true
  end

  test "cancel uses cancel/2 when runner exports it" do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          {:cancel_reason, reason} -> send(parent, {:cancel_reason_seen, reason})
        end
      end)

    defmodule CliAdapterCancel2Runner do
      def cancel(pid, reason), do: send(pid, {:cancel_reason, reason})
    end

    ctx = %{runner_pid: pid, task_pid: nil, runner_module: CliAdapterCancel2Runner}
    assert :ok = CliAdapter.cancel(ctx)
    assert_receive {:cancel_reason_seen, :user_requested}, 1_000
  end

  test "cancel falls back to cancel/1 when runner only exports arity 1" do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :cancel_called -> send(parent, :cancel_arity_1_seen)
        end
      end)

    defmodule CliAdapterCancel1Runner do
      def cancel(pid), do: send(pid, :cancel_called)
    end

    ctx = %{runner_pid: pid, task_pid: nil, runner_module: CliAdapterCancel1Runner}
    assert :ok = CliAdapter.cancel(ctx)
    assert_receive :cancel_arity_1_seen, 1_000
  end
end
