defmodule LemonControlPlane.Methods.AgentIdempotencyTest do
  # Swaps the default Store's backend and the router's session coordinator.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Agent
  alias LemonCore.Store
  alias LemonCore.Store.EtsBackend

  # Fails or stalls every operation on the idempotency table inside the real
  # Store process; `set_op/3` faults one operation on another table. Every
  # other table keeps working.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def set(fault), do: :persistent_term.put({__MODULE__, :fault}, fault)
    def set_op(op, table, fault), do: :persistent_term.put({__MODULE__, op, table}, fault)

    def clear do
      :persistent_term.erase({__MODULE__, :fault})
      :persistent_term.erase({__MODULE__, :put_new, :router_run_admissions})
    end

    defp faulted(op, table, fun) do
      fault =
        if table == :idempotency,
          do: :persistent_term.get({__MODULE__, :fault}, nil),
          else: :persistent_term.get({__MODULE__, op, table}, nil)

      case fault do
        :error ->
          {:error, :boom}

        {:stall, ms} ->
          Process.sleep(ms)
          fun.()

        nil ->
          fun.()
      end
    end

    defdelegate init(opts), to: EtsBackend
    defdelegate sync(state), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend

    def get(s, t, k), do: faulted(:get, t, fn -> EtsBackend.get(s, t, k) end)
    def put(s, t, k, v), do: faulted(:put, t, fn -> EtsBackend.put(s, t, k, v) end)
    def put_new(s, t, k, v), do: faulted(:put_new, t, fn -> EtsBackend.put_new(s, t, k, v) end)
    def delete(s, t, k), do: faulted(:delete, t, fn -> EtsBackend.delete(s, t, k) end)
    def list(s, t), do: faulted(:list, t, fn -> EtsBackend.list(s, t) end)
  end

  # Stands in for the session coordinator: records each accepted submission
  # and its durable receipt, as the real coordinator does, optionally after a
  # delay that outlasts the caller's router call.
  defmodule RecordingCoordinator do
    def stall(ms), do: :persistent_term.put({__MODULE__, :stall_ms}, ms)

    def submit(_conversation_key, submission, _opts \\ []) do
      Process.sleep(:persistent_term.get({__MODULE__, :stall_ms}, 0))

      :ok =
        LemonRouter.RunReceiptStore.put(%{
          run_id: submission.run_id,
          session_key: submission.session_key,
          state: :accepted,
          effective_mode: :new_run,
          target_run_id: submission.run_id
        })

      send(:persistent_term.get({__MODULE__, :test_pid}), {:submitted, submission.run_id})
      :ok
    end

    def submit_recovered(conversation_key, submission, opts \\ []),
      do: submit(conversation_key, submission, opts)

    def abort_run(_run_id, _reason), do: :ok
  end

  setup do
    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    previous = Application.fetch_env(:lemon_router, :session_coordinator)
    :persistent_term.put({RecordingCoordinator, :test_pid}, self())
    Application.put_env(:lemon_router, :session_coordinator, RecordingCoordinator)

    on_exit(fn ->
      FaultBackend.clear()
      :persistent_term.erase({RecordingCoordinator, :stall_ms})
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})

      case previous do
        {:ok, value} -> Application.put_env(:lemon_router, :session_coordinator, value)
        :error -> Application.delete_env(:lemon_router, :session_coordinator)
      end
    end)

    key = "agent-idem-#{System.unique_integer([:positive])}"
    session_key = "agent:default:main:idem-#{System.unique_integer([:positive])}"
    %{key: key, session_key: session_key}
  end

  defp params(ctx),
    do: %{"prompt" => "hello", "session_key" => ctx.session_key, "idempotency_key" => ctx.key}

  @tag timeout: 60_000
  test "a Store timeout on the idempotency key fails closed and never submits", ctx do
    FaultBackend.set({:stall, 5_500})

    assert {:error, _error} = Agent.handle(params(ctx), %{})
    refute_receive {:submitted, _run_id}, 500
  end

  test "an idempotency read error fails closed and never submits", ctx do
    FaultBackend.set(:error)

    assert {:error, _error} = Agent.handle(params(ctx), %{})
    refute_receive {:submitted, _run_id}, 500
  end

  test "concurrent requests with one idempotency key submit exactly once", ctx do
    results =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Agent.handle(params(ctx), %{}) end) end)
      |> Enum.map(&Task.await(&1, 10_000))

    assert_receive {:submitted, run_id}, 2_000
    refute_receive {:submitted, _other}, 500

    for {:ok, result} <- results, do: assert(result["run_id"] == run_id)

    # A completed key replays the original run without resubmitting.
    assert {:ok, %{"run_id" => ^run_id}} = Agent.handle(params(ctx), %{})
    refute_receive {:submitted, _again}, 200
  end

  @tag timeout: 60_000
  test "delayed router admission returns an unknown-outcome receipt with the fixed run id", ctx do
    RecordingCoordinator.stall(6_000)

    assert {:error,
            {:unavailable, _message,
             %{"code" => "SUBMISSION_OUTCOME_UNKNOWN", "runId" => run_id, "retrySafe" => false}}} =
             Agent.handle(params(ctx), %{})

    # The queued submission still executes under the allocated run ID.
    assert_receive {:submitted, ^run_id}, 15_000
    RecordingCoordinator.stall(0)

    # Reusing the key reconciles to that run and never submits again.
    assert {:ok, %{"run_id" => ^run_id}} = Agent.handle(params(ctx), %{})
    refute_receive {:submitted, _again}, 300
  end

  @tag timeout: 60_000
  test "delayed admission without an idempotency key still reports its run id", ctx do
    RecordingCoordinator.stall(6_000)
    params = Map.delete(params(ctx), "idempotency_key")

    assert {:error,
            {:unavailable, _message, %{"code" => "SUBMISSION_OUTCOME_UNKNOWN", "runId" => run_id}}} =
             Agent.handle(params, %{})

    assert_receive {:submitted, ^run_id}, 15_000
  end

  test "a recorded rejection releases the pending agent claim without resubmitting", ctx do
    run_id = LemonCore.Id.run_id()
    pending = %{"run_id" => run_id, "session_key" => ctx.session_key}
    assert {:new, _} = LemonCore.Idempotency.begin(:agent, ctx.key, pending)
    table = LemonRouter.RunOrchestrator.admission_table()
    assert :ok = Store.put(table, run_id, %{state: "rejected", terminal: true})
    on_exit(fn -> Store.delete(table, run_id) end)

    assert {:error,
            {:conflict, _message,
             %{"code" => "SUBMISSION_REJECTED", "runId" => ^run_id, "retrySafe" => true}}} =
             Agent.handle(params(ctx), %{})

    assert {:new, _} = LemonCore.Idempotency.begin(:agent, ctx.key, pending)
    refute_receive {:submitted, _}, 100
  end

  test "an unknown outcome keeps its run id past the TTL and is never resubmitted", ctx do
    FaultBackend.set_op(:put_new, :router_run_admissions, :error)

    assert {:error, {_code, _message, %{"runId" => run_id}}} = Agent.handle(params(ctx), %{})
    FaultBackend.clear()
    refute_receive {:submitted, _run_id}, 200

    # A day and more later the claim still names the original run.
    store_key = LemonCore.IdempotencyStore.key(:agent, ctx.key)
    {:ok, %{} = entry} = Store.fetch(:idempotency, store_key)

    aged =
      Map.new(entry, fn
        {field, at} when is_binary(field) and is_integer(at) ->
          if String.ends_with?(field, "_at_ms"),
            do: {field, at - 25 * 3_600_000},
            else: {field, at}

        other ->
          other
      end)

    :ok = Store.put(:idempotency, store_key, aged)

    assert {:error,
            {:unavailable, _message,
             %{"code" => "SUBMISSION_OUTCOME_UNKNOWN", "runId" => ^run_id, "retrySafe" => false}}} =
             Agent.handle(params(ctx), %{})

    refute_receive {:submitted, _again}, 300
  end
end
