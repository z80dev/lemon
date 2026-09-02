defmodule LemonControlPlane.A2A.RunnerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.A2A.{Handler, RateLimiter, Router}
  alias LemonCore.{A2AStore, RunStore, Store}
  alias LemonCore.A2A.Protocol

  defmodule BlockingSubmitter do
    use LemonCore.RouterBridge.RunOrchestrator

    @owner_key {__MODULE__, :owner}

    def set_owner(owner), do: :persistent_term.put(@owner_key, owner)
    def clear_owner, do: :persistent_term.erase(@owner_key)

    @impl true
    def submit(request) do
      send(:persistent_term.get(@owner_key), {:a2a_submit_blocked, request, self()})

      receive do
        {:release_a2a_submit, result} -> result
      after
        5_000 -> {:error, :test_submit_timeout}
      end
    end
  end

  defmodule AbortRouter do
    use LemonCore.RouterBridge.Router

    @owner_key {__MODULE__, :owner}
    @result_key {__MODULE__, :result}

    def set_owner(owner), do: :persistent_term.put(@owner_key, owner)
    def set_result(result), do: :persistent_term.put(@result_key, result)

    def clear do
      :persistent_term.erase(@owner_key)
      :persistent_term.erase(@result_key)
    end

    @impl true
    def abort_run(run_id, reason) do
      send(:persistent_term.get(@owner_key), {:a2a_abort_requested, run_id, reason})

      case :persistent_term.get(@result_key, :ok) do
        {:raise, message} -> raise message
        result -> result
      end
    end
  end

  setup do
    previous_config = Application.get_env(:lemon_control_plane, :a2a_config)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)

    Application.put_env(:lemon_control_plane, :a2a_config, %{
      host: "127.0.0.1",
      port: 9901,
      peers: %{},
      reply_timeout_ms: 1_000,
      rate_limit_per_minute: 100,
      max_context_turns: 100
    })

    BlockingSubmitter.set_owner(self())
    AbortRouter.set_owner(self())
    AbortRouter.set_result(:ok)

    if is_nil(Process.whereis(RateLimiter)) do
      start_supervised!(RateLimiter)
    end

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: BlockingSubmitter,
        router: AbortRouter
      )

    on_exit(fn ->
      restore_env(:lemon_control_plane, :a2a_config, previous_config)
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      BlockingSubmitter.clear_owner()
      AbortRouter.clear()
    end)

    :ok
  end

  test "cancellation remains terminal when a blocked submit later fails" do
    secret = "A2A_SUBMIT_SECRET_#{System.unique_integer([:positive])}"
    context_id = unique_id("blocked-context")
    message_id = unique_id("blocked-message")

    assert {:stream, task_id} = start_message(context_id, message_id)
    assert_receive {:a2a_submit_blocked, request, runner_pid}
    run_id = request.run_id

    runner_ref = Process.monitor(runner_pid)

    assert {:ok, canceled} = Handler.handle("CancelTask", %{"id" => task_id}, "local")
    assert get_in(canceled, ["status", "state"]) == "TASK_STATE_CANCELED"
    assert_receive {:a2a_abort_requested, ^run_id, :a2a_peer_canceled}

    send(
      runner_pid,
      {:release_a2a_submit,
       {:error, {:submission_failed, %{credential: secret, path: "/private/#{secret}"}}}}
    )

    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}

    assert %{state: "TASK_STATE_CANCELED", answer: nil, error: nil} =
             A2AStore.get_task(task_id)

    refute inspect(A2AStore.get_task(task_id)) =~ secret
    cleanup_task(task_id, context_id, message_id, run_id)
  end

  test "cancellation wins a delayed successful completion without recording an agent turn" do
    context_id = unique_id("success-context")
    message_id = unique_id("success-message")

    assert {:stream, task_id} = start_message(context_id, message_id)
    assert_receive {:a2a_submit_blocked, request, runner_pid}
    run_id = request.run_id

    runner_ref = Process.monitor(runner_pid)

    assert {:ok, canceled} = Handler.handle("CancelTask", %{"id" => task_id}, "local")
    assert get_in(canceled, ["status", "state"]) == "TASK_STATE_CANCELED"
    assert_receive {:a2a_abort_requested, ^run_id, :a2a_peer_canceled}

    context = A2AStore.get_context(:inbound, "local", context_id)

    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: context.session_key,
               agent_id: context.agent_id,
               origin: :control_plane,
               prompt: "redacted test prompt",
               completed: %{ok: true, answer: "late successful answer"}
             })

    send(runner_pid, {:release_a2a_submit, {:ok, run_id}})
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}

    assert %{state: "TASK_STATE_CANCELED", answer: nil, error: nil} =
             A2AStore.get_task(task_id)

    assert %{turn_count: 0} = A2AStore.get_context(:inbound, "local", context_id)

    assert [%{id: ^message_id, role: "ROLE_USER"}] =
             A2AStore.history("local", context_id)

    cleanup_task(task_id, context_id, message_id, run_id)
  end

  test "an outcome-unknown submit reconciles the original run without submitting twice" do
    context_id = unique_id("accepted-unknown-context")
    message_id = unique_id("accepted-unknown-message")

    assert {:stream, task_id} = start_message(context_id, message_id)
    assert_receive {:a2a_submit_blocked, request, runner_pid}
    run_id = request.run_id
    runner_ref = Process.monitor(runner_pid)
    context = A2AStore.get_context(:inbound, "local", context_id)

    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: context.session_key,
               agent_id: context.agent_id,
               origin: :control_plane,
               prompt: "redacted test prompt",
               completed: %{ok: true, answer: "accepted before acknowledgement was lost"}
             })

    send(runner_pid, {:release_a2a_submit, {:error, :outcome_unknown}})
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}

    assert %{
             state: "TASK_STATE_COMPLETED",
             answer: "accepted before acknowledgement was lost",
             error: nil
           } = A2AStore.get_task(task_id)

    refute_receive {:a2a_submit_blocked, _request, _runner_pid}, 50
    assert %{turn_count: 1} = context = A2AStore.get_context(:inbound, "local", context_id)
    assert context.session_key == request.session_key
    cleanup_task(task_id, context_id, message_id, run_id)
  end

  test "replaying the same inbound message id returns its original task without resubmission" do
    context_id = unique_id("replay-context")
    message_id = unique_id("replay-message")

    assert {:stream, task_id} = start_message(context_id, message_id)
    assert_receive {:a2a_submit_blocked, request, runner_pid}
    run_id = request.run_id

    assert {:stream, ^task_id} = start_message(context_id, message_id)
    refute_receive {:a2a_submit_blocked, _duplicate_request, _duplicate_runner}, 100

    send(runner_pid, {:release_a2a_submit, {:error, :definite_rejection}})
    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}, 1_000

    assert [%{id: ^message_id, task_id: ^task_id}] = A2AStore.history("local", context_id)
    cleanup_task(task_id, context_id, message_id, run_id)
  end

  test "an unresolved outcome-unknown submit stays reattachable and later reconciles" do
    config = Application.fetch_env!(:lemon_control_plane, :a2a_config)
    Application.put_env(:lemon_control_plane, :a2a_config, Map.put(config, :reply_timeout_ms, 25))

    context_id = unique_id("unresolved-unknown-context")
    message_id = unique_id("unresolved-unknown-message")

    assert {:stream, task_id} = start_message(context_id, message_id)
    assert_receive {:a2a_submit_blocked, request, runner_pid}
    run_id = request.run_id
    runner_ref = Process.monitor(runner_pid)

    send(runner_pid, {:release_a2a_submit, {:error, :outcome_unknown}})
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :normal}, 1_000

    assert %{
             state: "TASK_STATE_WORKING",
             answer: nil,
             error: "Run submission outcome is being reconciled"
           } = A2AStore.get_task(task_id)

    refute_receive {:a2a_submit_blocked, _request, _runner_pid}, 50

    context = A2AStore.get_context(:inbound, "local", context_id)

    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: context.session_key,
               agent_id: context.agent_id,
               origin: :control_plane,
               prompt: "redacted test prompt",
               completed: %{ok: true, answer: "reconciled later"}
             })

    assert {:ok, rendered} = Handler.handle("GetTask", %{"id" => task_id}, "local")
    assert get_in(rendered, ["status", "state"]) == "TASK_STATE_COMPLETED"

    assert {:ok, rendered_again} = Handler.handle("GetTask", %{"id" => task_id}, "local")
    assert get_in(rendered_again, ["status", "state"]) == "TASK_STATE_COMPLETED"

    assert %{state: "TASK_STATE_COMPLETED", answer: "reconciled later", error: nil} =
             A2AStore.get_task(task_id)

    assert %{turn_count: 1} = A2AStore.get_context(:inbound, "local", context_id)

    assert Enum.map(A2AStore.history("local", context_id), & &1.role) == [
             "ROLE_USER",
             "ROLE_AGENT"
           ]

    cleanup_task(task_id, context_id, message_id, run_id)
  end

  test "CancelTask JSON-RPC errors never expose router reasons, paths, or secrets" do
    secret = "A2A_CANCEL_SECRET_#{System.unique_integer([:positive])}"
    private_path = "/private/a2a/#{secret}"
    task_id = unique_id("cancel-error-task")

    :ok =
      A2AStore.put_task(%{
        id: task_id,
        direction: :inbound,
        peer_id: "local",
        context_id: unique_id("cancel-error-context"),
        run_id: unique_id("cancel-error-run"),
        state: "TASK_STATE_WORKING"
      })

    for router_result <- [
          {:error, {:router_bug, %{credential: secret, path: private_path, reason: secret}}},
          {:raise, "router exception #{secret} at #{private_path}"}
        ] do
      AbortRouter.set_result(router_result)

      response = cancel_over_wire(task_id, unique_id("rpc"))

      assert response.status == 200

      expected_message =
        if match?({:raise, _message}, router_result),
          do: "Task cancellation outcome is unknown",
          else: "Task cancellation failed"

      assert response.body["error"] == %{
               "code" => -32_603,
               "message" => expected_message
             }

      refute response.raw_body =~ secret
      refute response.raw_body =~ private_path
      refute response.raw_body =~ "router_bug"
      refute response.raw_body =~ "router exception"
      assert %{state: "TASK_STATE_WORKING"} = A2AStore.get_task(task_id)
    end

    AbortRouter.set_result({:error, :unavailable})
    unavailable = cancel_over_wire(task_id, unique_id("rpc"))

    assert unavailable.body["error"] == %{
             "code" => -32_603,
             "message" => "Task cancellation is temporarily unavailable"
           }

    refute unavailable.raw_body =~ secret

    AbortRouter.set_result({:error, :outcome_unknown})
    uncertain = cancel_over_wire(task_id, unique_id("rpc"))

    assert uncertain.body["error"] == %{
             "code" => -32_603,
             "message" => "Task cancellation outcome is unknown"
           }

    assert %{state: "TASK_STATE_WORKING"} = A2AStore.get_task(task_id)
    Store.delete(:a2a_tasks, task_id)
  end

  defp start_message(context_id, message_id) do
    Handler.handle(
      "SendStreamingMessage",
      %{
        "message" =>
          Protocol.message("ROLE_USER", "please help",
            context_id: context_id,
            message_id: message_id
          )
      },
      "local"
    )
  end

  defp cancel_over_wire(task_id, request_id) do
    body = Protocol.request("CancelTask", %{"id" => task_id}, request_id)

    conn =
      :post
      |> conn("/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    %{status: conn.status, raw_body: conn.resp_body, body: Jason.decode!(conn.resp_body)}
  end

  defp cleanup_task(task_id, context_id, message_id, run_id) do
    case A2AStore.get_context(:inbound, "local", context_id) do
      %{session_key: session_key} -> RunStore.delete_session(session_key)
      _ -> :ok
    end

    Store.delete(:runs, run_id)
    Store.delete(:a2a_tasks, task_id)
    Store.delete(:a2a_messages, message_id)
    Store.delete(:a2a_contexts, {:inbound, "local", context_id})
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
