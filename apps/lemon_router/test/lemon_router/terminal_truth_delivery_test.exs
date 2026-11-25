defmodule LemonRouter.TerminalTruthDeliveryTest do
  @moduledoc """
  Terminal decisions are durable-class events (#87): the `:runs` summary is
  committed before `:run_completed` is published, so any subscriber can re-read
  the authority, and a contradictory late terminal never reaches the bus.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, ExecutionCommand, RunStore}
  alias LemonCore.Events.{Completion, RunCompleted}
  alias LemonRouter.RunCompletion

  test "the terminal summary is durable before subscribers observe run_completed" do
    run_id = "terminal-truth-#{System.unique_integer([:positive])}"
    command = %ExecutionCommand{run_id: run_id, session_key: "terminal-truth", prompt: ""}
    observer = start_observer(run_id)

    assert :ok = RunCompletion.publish(command, completion_event(run_id, ok: false))

    assert_receive {:observed, %Event{type: :run_completed} = event, read}, 1_000
    assert event.payload.completed.ok == false
    assert {:ok, %{summary: %{completed: %{ok: false, run_id: ^run_id}}}} = read

    # A later contradictory terminal reconciles its caller from the durable
    # result and publishes nothing: subscribers see exactly one terminal.
    publisher =
      Task.async(fn ->
        :ok = RunCompletion.publish(command, completion_event(run_id, ok: true))

        receive do
          %Event{type: :run_completed} = reconciled -> reconciled
        after
          1_000 -> :missing
        end
      end)

    assert %Event{payload: %RunCompleted{completed: %{ok: false}}} = Task.await(publisher)

    Bus.broadcast(Bus.run_topic(run_id), :barrier)
    assert_receive {:observed, :barrier, _read}, 1_000
    refute_received {:observed, %Event{type: :run_completed}, _}

    assert {:ok, %{summary: %{completed: %{ok: false}}}} = RunStore.fetch(run_id)
    send(observer, :stop)
  end

  test "a terminal-only waiter sees one durable completion and no start or deltas" do
    run_id = "terminal-topic-#{System.unique_integer([:positive])}"
    session_key = "agent:terminal-topic:main"
    command = %ExecutionCommand{run_id: run_id, session_key: session_key, prompt: ""}
    :ok = Bus.subscribe(Bus.run_done_topic(run_id))

    started = Event.new(:run_started, %{}) |> Event.identify_run(run_id)
    :ok = Bus.publish_run_lifecycle(started)

    for n <- 1..100 do
      Bus.broadcast(Bus.run_topic(run_id), Event.new(:delta, %{text: "x", seq: n}))
    end

    assert :ok = RunCompletion.publish(command, completion_event(run_id, ok: true))
    assert_receive %Event{type: :run_completed, meta: meta}, 1_000
    assert meta.schema_version == 1
    assert meta.seq == 2
    assert meta.event_id != started.meta.event_id
    assert meta.attempt_id == started.meta.attempt_id
    assert {:ok, %{summary: %{attempt_id: attempt_id}}} = RunStore.fetch(run_id)
    assert attempt_id == meta.attempt_id
    refute_receive %Event{}, 30
  end

  defp completion_event(run_id, ok: ok) do
    Event.new(
      :run_completed,
      RunCompleted.new(%{
        completed: Completion.new(%{ok: ok, error: if(ok, do: nil, else: :cancelled)}),
        duration_ms: 0
      }),
      %{run_id: run_id}
    )
  end

  # Reads the authority from inside the subscriber, at the moment the event
  # arrives, rather than after the publisher has returned.
  defp start_observer(run_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = Bus.subscribe(Bus.run_topic(run_id))
        send(parent, {:subscribed, self()})
        observe(parent, run_id)
      end)

    assert_receive {:subscribed, ^pid}, 1_000
    pid
  end

  defp observe(parent, run_id) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {:observed, message, RunStore.fetch(run_id)})
        observe(parent, run_id)
    end
  end
end
