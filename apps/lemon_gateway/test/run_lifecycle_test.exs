defmodule LemonGateway.RunLifecycleTest do
  @moduledoc """
  Run terminalization that an owner can observe: every exit path publishes one
  durable completion. The test owns the run registry and permit authority, so
  losing the authority is not raced by the execution supervisor's restart.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, RunStore}
  alias LemonGateway.{ExecutionRequest, Run, Runtime, Slots}
  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  defmodule GatedExecutor do
    @moduledoc false
    def start_run(request, _opts, _sink) do
      send(request.meta.test_pid, {:executor_started, request.run_id})
      {:ok, make_ref(), %{}}
    end

    def cancel(_context), do: :ok
    def steer(_context, _text), do: {:error, :unsupported}
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  setup do
    running? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :lemon_gateway))
    previous = Application.fetch_env(:lemon_gateway, :executor)
    Application.stop(:lemon_gateway)
    Application.put_env(:lemon_gateway, :executor, GatedExecutor)

    on_exit(fn ->
      case previous do
        {:ok, executor} -> Application.put_env(:lemon_gateway, :executor, executor)
        :error -> Application.delete_env(:lemon_gateway, :executor)
      end

      if running?, do: Application.ensure_all_started(:lemon_gateway)
    end)

    start_supervised!({Registry, keys: :unique, name: LemonGateway.RunRegistry})
    slots = start_supervised!(Supervisor.child_spec({Slots, max: 1}, restart: :temporary))
    %{slots: slots}
  end

  test "losing the permit authority terminalizes waiting and running Runs once", %{slots: slots} do
    running = request()
    waiting = request()
    Enum.each([running, waiting], &Bus.subscribe(Bus.run_topic(&1.run_id)))

    running_pid = start(running)
    running_id = running.run_id
    assert_receive {:executor_started, ^running_id}

    waiting_pid = start(waiting)
    # Registered before start_link returns, so its owner can monitor it at once.
    assert Runtime.run_pid(waiting.run_id) == waiting_pid
    assert_eventually(fn -> match?({:ok, %{waitq: 1, in_flight: 1}}, Slots.stats()) end)

    monitors = Enum.map([running_pid, waiting_pid], &Process.monitor/1)
    Process.exit(slots, :kill)

    for {request, cancelled?} <- [{waiting, nil}, {running, true}] do
      id = request.run_id

      assert_receive %Event{
                       type: :run_completed,
                       meta: %{run_id: ^id},
                       payload: %{completed: %{ok: false, error: :runtime_unavailable} = done}
                     },
                     1_000

      assert done.meta[:cancelled] == cancelled?
      assert {:ok, %{summary: %{completed: %{error: :runtime_unavailable}}}} = RunStore.fetch(id)
    end

    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 1_000)
    refute_receive %Event{type: :run_completed}, 100
    refute_received {:executor_started, _}
  end

  defp request do
    id = "lifecycle-#{System.unique_integer([:positive])}"

    %ExecutionRequest{
      run_id: id,
      session_key: id,
      conversation_key: {:session, id},
      prompt: "test",
      meta: %{test_pid: self()}
    }
  end

  defp start(request) do
    {:ok, pid} = Run.start_link(%{execution_request: request})
    Process.unlink(pid)
    pid
  end
end
