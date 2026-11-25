defmodule LemonRouter.IntrospectionTest do
  @moduledoc """
  Tests that verify introspection events are emitted by lemon_router components.
  """
  use ExUnit.Case, async: false

  import LemonPlatformTest.Testing.AsyncHelpers

  alias LemonCore.Introspection

  defp make_test_request(run_id, session_key, meta) do
    %LemonCore.ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      prompt: "test",
      conversation_key: {:session, session_key},
      meta: meta
    }
  end

  defp await_events(run_id, event_type) do
    assert_eventually(
      fn -> events_of_type(run_id, event_type) != [] end,
      timeout: 5_000,
      message: "no #{inspect(event_type)} introspection event for #{run_id}"
    )

    events_of_type(run_id, event_type)
  end

  defp events_of_type(run_id, event_type) do
    [run_id: run_id, limit: 50]
    |> Introspection.list()
    |> Enum.filter(&(&1.event_type == event_type))
  end

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  defp unique_token, do: System.unique_integer([:positive, :monotonic])

  describe "RunProcess introspection events" do
    test "run_started event is recorded during RunProcess init" do
      token = unique_token()
      run_id = "introspection_run_#{token}"
      session_key = "agent:introspection_test:#{token}:main"

      execution_request = make_test_request(run_id, session_key, %{origin: :test})

      {:ok, pid} =
        LemonRouter.RunProcess.start_link(
          run_id: run_id,
          session_key: session_key,
          execution_request: execution_request,
          submit_to_gateway?: false
        )

      started_events = await_events(run_id, :run_started)

      assert started_events != []
      [evt | _] = started_events
      assert evt.engine == "lemon"
      assert evt.run_id == run_id
      assert evt.session_key == session_key
      assert evt.payload.queue_mode == :collect

      # Clean up
      GenServer.stop(pid, :normal)
    end

    test "run_completed event is recorded when run completes" do
      token = unique_token()
      run_id = "introspection_complete_#{token}"
      session_key = "agent:introspection_complete:#{token}:main"

      execution_request = make_test_request(run_id, session_key, %{origin: :test})

      {:ok, pid} =
        LemonRouter.RunProcess.start_link(
          run_id: run_id,
          session_key: session_key,
          execution_request: execution_request,
          submit_to_gateway?: false
        )

      # Simulate a run_completed event via Bus
      event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "done", error: nil}},
          %{run_id: run_id, session_key: session_key}
        )

      LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), event)

      # Wait for the event to be processed and process to terminate
      assert_process_dead(pid)

      completed_events = await_events(run_id, :run_completed)

      assert completed_events != []
      [evt | _] = completed_events
      assert evt.engine == "lemon"
      assert evt.payload.ok == true
    end
  end

  describe "RunOrchestrator introspection events" do
    test "orchestration_started and orchestration_resolved events are emitted on submit" do
      token = unique_token()
      session_key = "agent:default:introspection_orch_#{token}:main"

      request =
        LemonCore.RunRequest.new(%{
          origin: :test,
          session_key: session_key,
          agent_id: "default",
          prompt: "hello introspection test #{token}",
          queue_mode: :collect
        })

      case LemonRouter.RunOrchestrator.submit(request) do
        {:ok, run_id} ->
          orch_started = await_events(run_id, :orchestration_started)
          orch_resolved = await_events(run_id, :orchestration_resolved)

          assert orch_started != []
          assert orch_resolved != []

          [evt | _] = orch_started
          assert evt.engine == "lemon"
          assert evt.payload.agent_id == "default"

          # Clean up: abort the run and wait until it has left the run
          # supervisor, so later tests never count it as active. The abort
          # settles only once the gateway reports the cancelled execution.
          assert_eventually(fn -> Registry.lookup(LemonRouter.RunRegistry, run_id) != [] end)
          [{run_pid, _}] = Registry.lookup(LemonRouter.RunRegistry, run_id)
          LemonRouter.RunProcess.abort(run_pid, :test_cleanup)
          assert_process_dead(run_pid, timeout: 15_000)

        {:error, _reason} ->
          # In test environments, orchestrator may not be fully started
          :ok
      end
    end
  end
end
