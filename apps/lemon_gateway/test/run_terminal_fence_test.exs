defmodule LemonGateway.RunTerminalFenceTest do
  @moduledoc """
  Gateway-side proofs for the authoritative run lifecycle (epic #68): once a
  terminal decision is committed for a run ID no executor starts for it, and
  sink messages from an obsolete executor invocation cannot decide the run.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, RunStore}
  alias LemonGateway.Event, as: EngineEvent
  alias LemonGateway.{ExecutionRequest, Runtime, Slots}
  import LemonPlatformTest.Testing.AsyncHelpers, only: [assert_eventually: 1]

  defmodule ObservedExecutor do
    @moduledoc false
    @behaviour LemonGateway.Executor

    def start_run(request, _opts, sink) do
      ref = make_ref()
      send(request.meta.notify_pid, {:executor_started, request.run_id, sink, ref})
      {:ok, ref, %{}}
    end

    def cancel(_context), do: :ok
    def steer(_context, _text), do: {:error, :unsupported}
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([LemonGateway.Config, :executor])
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{max_concurrent_runs: 1})
    Application.put_env(:lemon_gateway, :executor, ObservedExecutor)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  test "an already terminal run ID never starts an executor or publishes a second terminal" do
    request = request()
    id = request.run_id
    committed = %{ok: false, error: :aborted, answer: "", run_id: id}
    summary = %{run_id: id, session_key: request.session_key, completed: committed}
    :ok = RunStore.finalize(id, summary)
    :ok = Bus.subscribe(Bus.run_topic(id))

    assert :ok = submit(request)

    assert_eventually(fn -> Runtime.run_pid(id) == nil end)
    assert {:ok, %{in_flight: 0, waitq: 0}} = Slots.stats()
    refute_receive {:executor_started, ^id, _, _}, 50
    refute_received %Event{type: :run_completed, meta: %{run_id: ^id}}
    refute_received {:lemon_gateway_run_completed, _, _}
    assert {:ok, %{summary: ^summary}} = RunStore.fetch(id)
  end

  test "a terminal decision committed while waiting for a permit prevents execution" do
    holder = request()
    {holder_sink, holder_ref} = start(holder)

    waiting = request()
    id = waiting.run_id
    :ok = Bus.subscribe(Bus.run_topic(id))
    assert :ok = submit(waiting)
    assert_eventually(fn -> match?({:ok, %{in_flight: 1, waitq: 1}}, Slots.stats()) end)

    # Another owner (for example a router synthetic completion) commits first.
    committed = %{ok: false, error: :runtime_submission_failed, answer: "", run_id: id}
    summary = %{run_id: id, session_key: waiting.session_key, completed: committed}
    :ok = RunStore.finalize(id, summary)

    complete(holder_sink, holder_ref, "holder done")
    assert_receive {:lemon_gateway_run_completed, ^holder, %{ok: true}}, 1_000

    assert_eventually(fn -> Runtime.run_pid(id) == nil end)
    assert_eventually(fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats()) end)
    refute_receive {:executor_started, ^id, _, _}, 50
    refute_received %Event{type: :run_completed, meta: %{run_id: ^id}}
    assert {:ok, %{summary: ^summary}} = RunStore.fetch(id)
  end

  test "a completion from an obsolete executor invocation cannot decide the run" do
    request = request()
    id = request.run_id
    :ok = Bus.subscribe(Bus.run_topic(id))
    {sink, ref} = start(request)

    complete(sink, make_ref(), "obsolete answer")

    refute_receive %Event{type: :run_completed, meta: %{run_id: ^id}}, 100
    assert {:ok, record} = RunStore.fetch(id)
    assert record == nil or record.summary == nil

    complete(sink, ref, "current answer")

    assert_receive %Event{
                     type: :run_completed,
                     meta: %{run_id: ^id},
                     payload: %{completed: %{ok: true, answer: "current answer"}}
                   },
                   1_000

    assert {:ok, %{summary: %{completed: %{ok: true, answer: "current answer"}}}} =
             RunStore.fetch(id)

    refute_receive %Event{type: :run_completed, meta: %{run_id: ^id}}, 50
  end

  defp request do
    id = "terminal-fence-#{System.unique_integer([:positive])}"

    %ExecutionRequest{
      run_id: id,
      session_key: id,
      conversation_key: {:session, id},
      prompt: "test",
      meta: %{notify_pid: self()}
    }
  end

  defp submit(request), do: Runtime.submit_execution(ExecutionRequest.to_command(request))

  defp start(request) do
    assert :ok = submit(request)
    id = request.run_id
    assert_receive {:executor_started, ^id, sink, ref}, 1_000
    {sink, ref}
  end

  defp complete(sink, ref, answer) do
    send(
      sink,
      {:engine_event, ref, EngineEvent.completed(%{engine: "lemon", ok: true, answer: answer})}
    )
  end
end
