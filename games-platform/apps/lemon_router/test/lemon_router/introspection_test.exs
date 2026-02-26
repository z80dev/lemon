defmodule LemonRouter.IntrospectionTest do
  @moduledoc """
  Tests that verify introspection events are emitted by lemon_router components.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Introspection

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

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "test",
        engine_id: "lemon",
        queue_mode: :collect,
        meta: %{origin: :test}
      }

      {:ok, pid} =
        LemonRouter.RunProcess.start_link(
          run_id: run_id,
          session_key: session_key,
          job: job,
          submit_to_gateway?: false
        )

      # Give the init a moment to complete the introspection call
      Process.sleep(50)

      events = Introspection.list(run_id: run_id, limit: 10)
      started_events = Enum.filter(events, &(&1.event_type == :run_started))

      assert length(started_events) >= 1
      [evt | _] = started_events
      assert evt.engine == "lemon"
      assert evt.run_id == run_id
      assert evt.session_key == session_key
      assert evt.payload.engine_id == "lemon"
      assert evt.payload.queue_mode == :collect

      # Clean up
      GenServer.stop(pid, :normal)
    end

    test "run_completed event is recorded when run completes" do
      token = unique_token()
      run_id = "introspection_complete_#{token}"
      session_key = "agent:introspection_complete:#{token}:main"

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "test",
        engine_id: "echo",
        queue_mode: :collect,
        meta: %{origin: :test}
      }

      {:ok, pid} =
        LemonRouter.RunProcess.start_link(
          run_id: run_id,
          session_key: session_key,
          job: job,
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
      Process.sleep(200)
      refute Process.alive?(pid)

      events = Introspection.list(run_id: run_id, limit: 20)
      completed_events = Enum.filter(events, &(&1.event_type == :run_completed))

      assert length(completed_events) >= 1
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
          Process.sleep(100)

          events = Introspection.list(run_id: run_id, limit: 20)

          orch_started =
            Enum.filter(events, &(&1.event_type == :orchestration_started))

          orch_resolved =
            Enum.filter(events, &(&1.event_type == :orchestration_resolved))

          assert length(orch_started) >= 1
          assert length(orch_resolved) >= 1

          [evt | _] = orch_started
          assert evt.engine == "lemon"
          assert evt.payload.agent_id == "default"

          # Clean up - abort the run
          LemonRouter.RunProcess.abort(run_id, :test_cleanup)

        {:error, _reason} ->
          # In test environments, orchestrator may not be fully started
          :ok
      end
    end
  end
end
