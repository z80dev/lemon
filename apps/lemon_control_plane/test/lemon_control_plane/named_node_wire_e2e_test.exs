defmodule LemonControlPlane.NamedNodeWireE2ETest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Worker
  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.Methods.ConnectChallenge
  alias LemonControlPlane.NodeStore
  alias LemonGateway.ExecutionRequest

  defmodule NamedNodeWireExecutor do
    @moduledoc false

    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      owner = Process.whereis(__MODULE__)
      run_ref = make_ref()
      runner_pid = spawn_link(fn -> receive do: (:stop -> :ok) end)
      context = %{runner_pid: runner_pid, run_id: request.run_id}

      send(owner, {:fake_executor_started, request, opts, sink_pid, run_ref, context})
      {:ok, run_ref, context}
    end

    def cancel(context) do
      send(Process.whereis(__MODULE__), {:fake_executor_cancelled, context})
      send(context.runner_pid, :stop)
      :ok
    end

    def steer(context, text) do
      send(Process.whereis(__MODULE__), {:fake_executor_steered, context, text})
      :ok
    end

    def redirect(context, text) do
      send(Process.whereis(__MODULE__), {:fake_executor_redirected, context, text})
      :ok
    end
  end

  defmodule NativeNamedNodeWireExecutor do
    @moduledoc false

    alias CodingAgent.Executor
    alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}
    alias LemonGateway.ExecutionRequest

    @probe_key {__MODULE__, :probe}

    def configure(owner) when is_pid(owner) do
      :persistent_term.put(@probe_key, {owner, :counters.new(1, [:atomics])})
    end

    def clear do
      :persistent_term.erase(@probe_key)
    end

    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      {owner, _counter} = probe()

      request = %{
        request
        | meta: Map.put(request.meta || %{}, :model, mock_model())
      }

      opts =
        opts
        |> Map.new()
        |> Map.put(:stream_fn, &__MODULE__.stream/3)

      case Executor.start_run(request, opts, sink_pid) do
        {:ok, run_ref, context} = result ->
          %{session: session} = :sys.get_state(context.runner_pid)
          send(owner, {:native_executor_started, request, run_ref, context, session})
          result

        other ->
          other
      end
    end

    def cancel(context), do: Executor.cancel(context)

    def steer(context, text) do
      result = Executor.steer(context, text)
      send(owner(), {:native_executor_control, :steer, context, text, result})
      result
    end

    def redirect(context, text) do
      result = Executor.redirect(context, text)
      send(owner(), {:native_executor_control, :redirect, context, text, result})
      result
    end

    @doc false
    def stream(_model, context, _options) do
      {owner, counter} = probe()
      :counters.add(counter, 1, 1)
      call = :counters.get(counter, 1)
      send(owner, {:native_model_context, call, context})

      if call == 1 do
        slow_stream(owner)
      else
        {:ok, response_to_event_stream(assistant_message("native redirect complete"))}
      end
    end

    defp slow_stream(owner) do
      {:ok, stream} = LemonAi.EventStream.start_link()

      {:ok, task} =
        Task.start(fn ->
          response = assistant_message("partial native answer")
          LemonAi.EventStream.push(stream, {:start, response})

          for chunk <- 1..100 do
            send(owner, {:native_stream_chunk, chunk})
            Process.sleep(20)
            LemonAi.EventStream.push(stream, {:text_delta, 0, "native #{chunk} ", response})
          end

          LemonAi.EventStream.push(stream, {:done, :stop, response})
          LemonAi.EventStream.complete(stream, response)
        end)

      LemonAi.EventStream.attach_task(stream, task)

      {:ok, stream}
    end

    defp response_to_event_stream(response) do
      {:ok, stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(stream, {:start, response})

        Enum.with_index(response.content)
        |> Enum.each(fn
          {%TextContent{text: text}, index} ->
            LemonAi.EventStream.push(stream, {:text_start, index, response})
            LemonAi.EventStream.push(stream, {:text_delta, index, text, response})
            LemonAi.EventStream.push(stream, {:text_end, index, response})

          _other ->
            :ok
        end)

        LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
        LemonAi.EventStream.complete(stream, response)
      end)

      stream
    end

    defp mock_model do
      %Model{
        id: "native-wire-model",
        name: "Native Wire Model",
        api: :mock,
        provider: :mock_provider,
        base_url: "https://api.mock.test",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{input: 0.0, output: 0.0},
        context_window: 128_000,
        max_tokens: 4_096,
        headers: %{},
        compat: nil
      }
    end

    defp assistant_message(text) do
      %AssistantMessage{
        role: :assistant,
        content: [%TextContent{type: :text, text: text}],
        api: :mock,
        provider: :mock_provider,
        model: "native-wire-model",
        usage: %Usage{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
        },
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }
    end

    defp owner do
      {owner, _counter} = probe()
      owner
    end

    defp probe, do: :persistent_term.get(@probe_key)
  end

  setup do
    true = Process.register(self(), NamedNodeWireExecutor)
    :ok
  end

  @tag :tmp_dir
  test "named node crosses the real WebSocket boundary for invoke, result, and cancel", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    node_id = "wire-node-#{suffix}"
    node_name = "Wire Node #{suffix}"
    token = "wire-token-#{suffix}"

    put_node(node_id, node_name)
    assert {:ok, _token_info} = TokenStore.store(token, %{"type" => "node", "nodeId" => node_id})

    on_exit(fn ->
      LemonCore.Store.delete(:session_tokens, token)
      LemonCore.Store.delete(:session_token_heads, {"node", node_id})
      LemonCore.Store.delete(:nodes_by_name, node_name)
      LemonCore.Store.delete(:nodes_registry, node_id)
    end)

    bandit_id = {:named_node_wire_bandit, suffix}

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: bandit_id,
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    worker_id = {:named_node_wire_worker, suffix}

    worker =
      start_supervised!(%{
        id: worker_id,
        start:
          {Worker, :start_link,
           [
             [
               node_name: node_name,
               controller: "ws://127.0.0.1:#{port}/ws",
               cwd: tmp_dir,
               token: token,
               notify_pid: self(),
               executor_module: NamedNodeWireExecutor,
               socket_opts: [reconnect_delay_ms: 10]
             ]
           ]},
        restart: :temporary
      })

    assert_receive {:execution_node_worker, ^worker, {:status, :online, ^node_id}}, 3_000

    assert {:ok, %{id: ^node_id, name: ^node_name, pid: connection_pid}} =
             LemonCore.NodeRegistry.resolve(node_name)

    assert is_pid(connection_pid)
    assert connection_pid != worker
    connection_ref = Process.monitor(connection_pid)

    invoke_args = %{
      "version" => 1,
      "runId" => "wire-run-#{suffix}",
      "prompt" => "cross the wire",
      "cwd" => tmp_dir,
      "meta" => %{}
    }

    assert {:ok, invoke_id} =
             LemonCore.NodeRegistry.invoke(node_name, "coding_agent.run", invoke_args,
               recipient: self(),
               timeout_ms: 3_000
             )

    assert NodeStore.get_invocation(invoke_id) == nil

    assert_receive {:fake_executor_started, request, run_opts, ^worker, run_ref, context}, 3_000
    assert request.prompt == "cross the wire"
    assert request.cwd == tmp_dir
    assert run_opts == %{cwd: tmp_dir, run_id: "wire-run-#{suffix}"}

    assert {:ok, control_id} =
             LemonCore.NodeRegistry.control(invoke_id, :steer, "stay on the wire",
               recipient: self(),
               timeout_ms: 3_000
             )

    assert_receive {:fake_executor_steered, ^context, "stay on the wire"}, 3_000

    assert_receive {:lemon_node_control_result, ^control_id, ^invoke_id, :ok}, 3_000

    assert {:ok, redirect_id} =
             LemonCore.NodeRegistry.control(invoke_id, :redirect, "take the safer route",
               recipient: self(),
               timeout_ms: 3_000
             )

    assert_receive {:fake_executor_redirected, ^context, "take the safer route"}, 3_000

    assert_receive {:lemon_node_control_result, ^redirect_id, ^invoke_id, :ok}, 3_000

    send(worker, {:engine_delta, run_ref, "wire "})
    send(worker, {:engine_delta, run_ref, "complete"})

    send(worker, {
      :engine_event,
      run_ref,
      %{
        __event__: :completed,
        ok: true,
        answer: "",
        error: nil,
        usage: %{input_tokens: 3},
        meta: %{provider: "fake-boundary"},
        resume: nil
      }
    })

    assert_receive {:lemon_node_result, ^invoke_id, {:ok, result}}, 3_000
    assert get_in(result, ["completed", "answer"]) == "wire complete"
    assert get_in(result, ["completed", "usage", "input_tokens"]) == 3
    assert NodeStore.get_invocation(invoke_id) == nil

    assert {:error, :terminal} =
             LemonCore.NodeRegistry.control(invoke_id, :steer, "too late")

    send(context.runner_pid, :stop)

    assert {:ok, cancel_id} =
             LemonCore.NodeRegistry.invoke(
               node_name,
               "coding_agent.run",
               Map.put(invoke_args, "runId", "wire-cancel-#{suffix}"),
               recipient: self(),
               timeout_ms: 3_000
             )

    assert_receive {:fake_executor_started, _request, _opts, ^worker, _cancel_run_ref,
                    cancel_context},
                   3_000

    assert :ok = LemonCore.NodeRegistry.cancel(cancel_id, :test_cancelled)
    assert_receive {:fake_executor_cancelled, ^cancel_context}, 3_000
    assert_receive {:lemon_node_result, ^cancel_id, {:error, :test_cancelled}}, 3_000

    rotation_challenge = "wire-rotation-#{suffix}"

    assert :ok =
             NodeStore.put_challenge(rotation_challenge, %{
               node_id: node_id,
               node_name: node_name,
               node_type: "coding_agent",
               expires_at_ms: System.system_time(:millisecond) + 60_000
             })

    assert {:ok, rotated} =
             ConnectChallenge.handle(
               %{"challenge" => rotation_challenge},
               %{conn_id: "wire-rotation-connection"}
             )

    assert rotated["identity"]["sessionGeneration"] == 1
    assert {:error, :invalid_token} = TokenStore.validate(token)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection_pid, close_reason}, 3_000
    assert close_reason in [:normal, {:shutdown, :peer_closed}, {:shutdown, :local_closed}]
    refute LemonCore.NodeRegistry.online?(node_name)

    _ = stop_supervised(worker_id)
    assert_eventually(fn -> not LemonCore.NodeRegistry.online?(node_name) end)
  end

  @tag :tmp_dir
  test "source executor steers and redirects the destination native session over WebSocket", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    node_id = "native-wire-node-#{suffix}"
    node_name = "Native Wire Node #{suffix}"
    token = "native-wire-token-#{suffix}"

    NativeNamedNodeWireExecutor.configure(self())
    put_node(node_id, node_name)
    assert {:ok, _token_info} = TokenStore.store(token, %{"type" => "node", "nodeId" => node_id})

    on_exit(fn ->
      NativeNamedNodeWireExecutor.clear()
      LemonCore.Store.delete(:session_tokens, token)
      LemonCore.Store.delete(:session_token_heads, {"node", node_id})
      LemonCore.Store.delete(:nodes_by_name, node_name)
      LemonCore.Store.delete(:nodes_registry, node_id)
    end)

    bandit_id = {:native_named_node_wire_bandit, suffix}

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: bandit_id,
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    worker =
      start_supervised!(%{
        id: {:native_named_node_wire_worker, suffix},
        start:
          {Worker, :start_link,
           [
             [
               node_name: node_name,
               controller: "ws://127.0.0.1:#{port}/ws",
               cwd: tmp_dir,
               token: token,
               notify_pid: self(),
               executor_module: NativeNamedNodeWireExecutor,
               socket_opts: [reconnect_delay_ms: 10]
             ]
           ]},
        restart: :temporary
      })

    assert_receive {:execution_node_worker, ^worker, {:status, :online, ^node_id}}, 3_000

    run_id = "native-wire-run-#{suffix}"

    request = %ExecutionRequest{
      run_id: run_id,
      session_key: "test:native-wire:#{suffix}",
      prompt: "start the native destination run",
      images: [],
      cwd: tmp_dir,
      meta: %{node: node_name}
    }

    assert {:ok, run_ref, source_context} =
             CodingAgent.Executor.start_run(
               request,
               %{remote_timeout_ms: 10_000, remote_control_timeout_ms: 3_000},
               self()
             )

    assert source_context.runner_module == CodingAgent.Executor.RemoteSessionRunner

    assert_receive {:native_executor_started, destination_request, _destination_run_ref,
                    destination_context, native_session},
                   3_000

    assert destination_request.run_id == run_id
    refute Map.has_key?(destination_request.meta, :node)
    refute Map.has_key?(destination_request.meta, "node")
    assert Process.alive?(native_session)
    assert :sys.get_state(destination_context.runner_pid).session == native_session

    assert_receive {:native_model_context, 1, initial_context}, 3_000
    assert context_contains?(initial_context, "start the native destination run")
    assert_receive {:native_stream_chunk, 2}, 3_000

    steer_text = "keep the native session but verify this constraint"
    assert :ok = CodingAgent.Executor.steer(source_context, steer_text)

    assert_receive {:native_executor_control, :steer, ^destination_context, ^steer_text, :ok},
                   3_000

    assert_eventually(fn -> queued_correction?(native_session, steer_text) end)

    redirect_text = "replace the in-flight model direction now"
    assert :ok = CodingAgent.Executor.redirect(source_context, redirect_text)

    assert_receive {:native_executor_control, :redirect, ^destination_context, ^redirect_text,
                    :ok},
                   3_000

    assert_receive {:native_model_context, steer_call, steer_context}, 3_000
    assert steer_call >= 2
    assert context_contains?(steer_context, steer_text)

    assert_receive {:native_model_context, redirect_call, redirect_context}, 3_000
    assert redirect_call > steer_call
    assert context_contains?(redirect_context, steer_text)
    assert context_contains?(redirect_context, redirect_text)

    assert_receive {:engine_event, ^run_ref,
                    %{
                      __event__: :completed,
                      ok: true,
                      answer: "native redirect complete",
                      meta: %{node: ^node_name}
                    }},
                   5_000

    assert_eventually(fn -> not Process.alive?(source_context.runner_pid) end)
    assert {:error, :terminal} = CodingAgent.Executor.steer(source_context, "too late")
  end

  defp put_node(node_id, name) do
    NodeStore.put_node(node_id, %{
      id: node_id,
      name: name,
      type: "coding_agent",
      capabilities: %{"coding_agent.run" => %{"version" => 1}},
      status: :offline
    })
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp queued_correction?(session, text) do
    session
    |> CodingAgent.Session.get_state()
    |> Map.fetch!(:steering_queue)
    |> :queue.to_list()
    |> Enum.any?(&context_contains?(&1, text))
  catch
    :exit, _reason -> false
  end

  defp context_contains?(context, text) do
    context
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.contains?(text)
  end
end
