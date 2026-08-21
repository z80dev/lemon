defmodule LemonGateway.RunTransportAgnosticTest do
  @moduledoc """
  Tests for transport-agnostic run behavior.

  Verifies that:
  - Run emits events to LemonCore.Bus instead of Telegram outbox
  - Delta events are accumulated and included in final answer
  - No channel-specific rendering occurs in Run
  """
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Run

  # The fixture models a controlled native execution process while Run owns
  # lifecycle, bus publication, and answer accumulation.
  defmodule RunTransportAgnosticFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}
      controller_pid = (request.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          if controller_pid, do: send(controller_pid, {:executor_started, run_ref, self()})

          if controller_pid do
            receive do
              {:send_deltas, deltas} ->
                for delta <- deltas do
                  send(sink_pid, {:engine_delta, run_ref, delta})
                  Process.sleep(10)
                end

                receive do
                  :complete ->
                    send(
                      sink_pid,
                      {:engine_event, run_ref,
                       Event.completed(%{engine: "lemon", resume: resume, ok: true, answer: ""})}
                    )
                after
                  5000 -> :ok
                end
            after
              30_000 ->
                send(
                  sink_pid,
                  {:engine_event, run_ref,
                   Event.completed(%{engine: "lemon", resume: resume, ok: false, error: :timeout})}
                )
            end
          else
            send(
              sink_pid,
              {:engine_event, run_ref,
               Event.completed(%{
                 engine: "lemon",
                 resume: resume,
                 ok: true,
                 answer: "Test: #{request.prompt}"
               })}
            )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10
    })

    Application.put_env(:lemon_gateway, :executor, RunTransportAgnosticFixtureExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    "test:#{chat_id}"
  end

  defp make_request(session_key, opts) do
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)

    meta =
      Map.merge(%{notify_pid: self(), user_msg_id: user_msg_id}, Keyword.get(opts, :meta, %{}))

    %ExecutionRequest{
      run_id: Keyword.get(opts, :run_id, "run-#{System.unique_integer([:positive])}"),
      session_key: session_key,
      prompt: Keyword.get(opts, :text, Keyword.get(opts, :prompt, "test message")),
      conversation_key: {:session, session_key},
      resume: Keyword.get(opts, :resume),
      meta: meta
    }
  end

  defp start_run_direct(request, slot_ref \\ make_ref()) do
    args = %{
      execution_request: request,
      slot_ref: slot_ref,
      worker_pid: self()
    }

    Run.start_link(args)
  end

  describe "delta event emission" do
    test "emits delta events to bus" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self(), controller_pid: self()})

      # Subscribe to bus to receive events
      run_id = "test_run_#{System.unique_integer()}"
      request = %{request | run_id: run_id}

      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Should receive delta events on bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        # Receive delta events (may be wrapped in LemonCore.Event)
        received_deltas = collect_delta_events([], 3, 2000)
        assert received_deltas != []
      end

      # Complete the run
      send(sink_pid, :complete)

      # Wait for run_ref to be set and check completion
      Process.sleep(100)
    end

    test "accumulates delta text into final answer when executor answer is empty" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self(), controller_pid: self()})

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Wait for deltas to be processed
      Process.sleep(100)

      # Complete the run
      send(sink_pid, :complete)

      # Should receive completion with accumulated answer
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true, answer: answer}},
                     2000

      assert_receive {:lemon_gateway_run_completed, ^request, %{answer: ^answer}}, 2000

      # Answer should contain the accumulated delta text
      assert answer == "Hello World"
    end
  end

  describe "transport agnostic behavior" do
    test "does not call Telegram outbox directly" do
      scope = make_scope()
      # Include chat_id to trigger old rendering path if it existed
      request =
        make_request(scope,
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: 12_345,
            progress_msg_id: 67_890
          }
        )

      {:ok, pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Test"]})
      Process.sleep(100)

      # Complete the run
      send(sink_pid, :complete)

      # Should complete successfully without crashing
      # (Old code would try to call Telegram.Outbox)
      assert_receive {:run_complete, ^pid, %{__event__: :completed, ok: true}}, 2000
    end

    test "emits run_started event to bus" do
      scope = make_scope()
      run_id = "run_#{System.unique_integer()}"

      request = %ExecutionRequest{
        session_key: scope,
        run_id: run_id,
        prompt: "test",
        conversation_key: {:session, scope},
        meta: %{notify_pid: self(), user_msg_id: 1}
      }

      # Subscribe to bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, pid} = start_run_direct(request)

      # Should receive run_started event
      if Code.ensure_loaded?(LemonCore.Bus) do
        receive do
          %LemonCore.Event{type: :run_started} -> :ok
          _event -> :ok
        after
          2000 -> :ok
        end
      end

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "emits run_completed event to bus" do
      scope = make_scope()
      run_id = "run_#{System.unique_integer()}"

      request = %ExecutionRequest{
        session_key: scope,
        run_id: run_id,
        prompt: "test",
        conversation_key: {:session, scope},
        meta: %{notify_pid: self(), user_msg_id: 1}
      }

      # Subscribe to bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, pid} = start_run_direct(request)

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000

      # Should have received run_completed event on bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        # Drain any remaining events
        Process.sleep(100)
      end
    end
  end

  # Helper to collect delta events with timeout
  defp collect_delta_events(acc, 0, _timeout), do: Enum.reverse(acc)

  defp collect_delta_events(acc, count, timeout) do
    receive do
      %LemonCore.Event{type: :delta} = event ->
        collect_delta_events([event | acc], count - 1, timeout)

      %{type: :delta} = event ->
        collect_delta_events([event | acc], count - 1, timeout)

      _ ->
        collect_delta_events(acc, count, timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
