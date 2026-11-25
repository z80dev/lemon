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
    LemonGateway.Test.AppIsolation.isolate_gateway([LemonGateway.Config, :executor])

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

  defp start_run_direct(request) do
    Run.start_link(%{execution_request: request})
  end

  describe "delta event emission" do
    test "emits delta events to bus" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self(), controller_pid: self()})

      # Subscribe to bus to receive events
      run_id = "test_run_#{System.unique_integer()}"
      request = %{request | run_id: run_id}

      LemonCore.Bus.subscribe("run:#{run_id}")

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Each delta reaches the bus, in order.
      for text <- ["Hello", " ", "World"] do
        assert_receive %LemonCore.Event{type: :delta, payload: %{text: ^text}}, 2000
      end

      # Complete the run
      send(sink_pid, :complete)

      # Wait for the run to finish
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed}}, 2000
    end

    test "accumulates delta text into final answer when executor answer is empty" do
      scope = make_scope()
      request = make_request(scope, meta: %{notify_pid: self(), controller_pid: self()})

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Complete the run
      send(sink_pid, :complete)

      # Should receive completion with accumulated answer
      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: answer}},
                     2000

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

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:executor_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Test"]})

      # Complete the run
      send(sink_pid, :complete)

      # Should complete successfully without crashing
      # (Old code would try to call Telegram.Outbox)
      assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: true}},
                     2000
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

      LemonCore.Bus.subscribe("run:#{run_id}")

      {:ok, _pid} = start_run_direct(request)

      assert_receive %LemonCore.Event{type: :run_started, meta: %{run_id: ^run_id}}, 2000
      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000
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

      LemonCore.Bus.subscribe("run:#{run_id}")

      {:ok, _pid} = start_run_direct(request)

      assert_receive {:lemon_gateway_run_completed, ^request, _}, 2000
      assert_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}, 2000
    end
  end
end
