defmodule LemonChannels.TypingIndicatorTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Outbound, as: DiscordOutbound
  alias LemonChannels.Telegram.FakeAPI
  alias LemonChannels.TypingIndicator
  alias LemonCore.{Bus, Event, RunStore}

  defmodule DiscordAPI do
    def start_typing(channel_id) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:discord_typing, channel_id})
      {:ok}
    end
  end

  setup do
    FakeAPI.reset()
    server = start_supervised!({TypingIndicator, name: nil})
    %{server: server}
  end

  test "Telegram refreshes at the injected cadence and stops after completion", %{server: server} do
    run_id = run_id()
    parent = self()

    opts = [
      target: {:telegram, "default", 123, 456},
      interval_ms: 60,
      send: fn ->
        result = FakeAPI.send_chat_action("token", 123, 456, "typing")
        send(parent, {:typing, System.monotonic_time(:millisecond)})
        result
      end
    ]

    assert :ok = TypingIndicator.start_run(run_id, opts, server)
    assert_receive {:typing, first}
    refute_receive {:typing, _}, 30
    assert_receive {:typing, second}, 200
    assert second - first >= 45
    assert Enum.all?(FakeAPI.sent(), &match?(%{args: [123, 456, "typing"]}, &1))

    complete(run_id)
    await_empty(server)
    flush_typing()
    refute_receive {:typing, _}, 150
  end

  test "Discord refreshes its thread endpoint through the injected API", %{server: server} do
    key = :"Elixir.LemonGateway.Config"
    previous = Application.get_env(:lemon_gateway, key)
    previous_test_mode = Application.get_env(:lemon_core, :config_test_mode)
    :persistent_term.put({DiscordAPI, :test_pid}, self())
    Application.put_env(:lemon_core, :config_test_mode, true)
    Application.put_env(:lemon_gateway, key, %{discord: %{api_mod: DiscordAPI}})

    on_exit(fn ->
      restore_env(:lemon_gateway, key, previous)
      restore_env(:lemon_core, :config_test_mode, previous_test_mode)
      :persistent_term.erase({DiscordAPI, :test_pid})
    end)

    id = run_id()

    opts = [
      target: {:discord, "default", 456},
      interval_ms: 40,
      send: fn -> DiscordOutbound.start_typing(456) end
    ]

    TypingIndicator.start_run(id, opts, server)
    assert_receive {:discord_typing, 456}
    assert_receive {:discord_typing, 456}, 200
    complete(id, false)
    await_empty(server)
    flush_discord_typing()
    refute_receive {:discord_typing, _}, 100
  end

  test "a final delivery stops typing even when rendering fails" do
    id = run_id()
    target = {:telegram, "final-test", 123, nil}
    TypingIndicator.start_run(id, recording_options(target))
    assert_receive {:typing, _}

    intent = %LemonCore.DeliveryIntent{
      intent_id: id,
      run_id: id,
      session_key: "agent:typing:main",
      route: %LemonCore.DeliveryRoute{
        channel_id: "typing-test",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "123"
      },
      kind: :final_text
    }

    assert {:error, :missing_text} = LemonChannels.Dispatcher.dispatch(intent)
    refute Map.has_key?(:sys.get_state(TypingIndicator).targets, target)
    flush_typing()
    refute_receive {:typing, _}, 100
  end

  test "overlapping runs share one refresher until the last run ends", %{server: server} do
    first = run_id()
    second = run_id()
    opts = recording_options({:discord, "default", 123, 456})
    TypingIndicator.start_run(first, opts, server)
    assert_receive {:typing, _}
    TypingIndicator.start_run(second, opts, server)
    assert map_size(:sys.get_state(server).targets) == 1
    refute_receive {:typing, _}, 30

    TypingIndicator.stop_run(first, server)
    assert_receive {:typing, _}, 200
    TypingIndicator.stop_run(second, server)
    flush_typing()
    refute_receive {:typing, _}, 150
  end

  test "topics are independent and unrelated completions do not stop them", %{server: server} do
    first = run_id()
    second = run_id()
    TypingIndicator.start_run(first, recording_options({:telegram, "a", 1, 2}), server)
    TypingIndicator.start_run(second, recording_options({:telegram, "a", 1, 3}), server)
    assert map_size(:sys.get_state(server).targets) == 2
    complete(run_id())
    TypingIndicator.stop_run(first, server)
    assert map_size(:sys.get_state(server).targets) == 1
    assert Map.has_key?(:sys.get_state(server).runs, second)
  end

  test "the hard cap is not extended by another accepted run", %{server: server} do
    opts = Keyword.put(recording_options(:capped), :cap_ms, 150)
    TypingIndicator.start_run(run_id(), opts, server)
    assert_receive {:typing, _}
    assert_receive {:typing, _}, 200
    TypingIndicator.start_run(run_id(), opts, server)
    await_empty(server)
    flush_typing()
    refute_receive {:typing, _}, 150
  end

  test "the hard cap kills a hung typing request", %{server: server} do
    parent = self()

    opts = [
      target: :hung_cap,
      interval_ms: 20,
      cap_ms: 80,
      send: fn ->
        send(parent, {:sending, self()})
        Process.sleep(:infinity)
      end
    ]

    TypingIndicator.start_run(run_id(), opts, server)
    assert_receive {:sending, worker}
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 300
    await_empty(server)
  end

  test "transport death stops refreshes and kills an in-flight API call", %{server: server} do
    parent = self()

    owner =
      spawn(fn ->
        opts = [
          target: :crashing_owner,
          interval_ms: 20,
          send: fn ->
            send(parent, {:sending, self()})
            Process.sleep(:infinity)
          end
        ]

        TypingIndicator.start_run(run_id(), opts, server)
        Process.sleep(:infinity)
      end)

    assert_receive {:sending, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    await_empty(server)
  end

  test "slow requests never overlap and completion kills the in-flight request", %{server: server} do
    parent = self()
    id = run_id()

    opts = [
      target: :slow,
      interval_ms: 20,
      send: fn ->
        send(parent, {:sending, self()})
        Process.sleep(:infinity)
      end
    ]

    TypingIndicator.start_run(id, opts, server)
    assert_receive {:sending, worker}
    refute_receive {:sending, _}, 80
    ref = Process.monitor(worker)
    complete(id, false)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    await_empty(server)
  end

  test "send errors and exceptions do not stop later refreshes", %{server: server} do
    parent = self()
    counter = :counters.new(1, [])

    opts = [
      target: :failing,
      interval_ms: 20,
      send: fn ->
        :counters.add(counter, 1, 1)
        count = :counters.get(counter, 1)
        send(parent, {:attempt, count})

        case count do
          1 -> {:error, :rate_limited}
          2 -> raise "fake API error"
          _ -> :ok
        end
      end
    ]

    TypingIndicator.start_run(run_id(), opts, server)
    assert_receive {:attempt, 1}
    assert_receive {:attempt, 2}
    assert_receive {:attempt, 3}
    assert Process.alive?(server)
  end

  test "a durable completion before subscription never starts typing", %{server: server} do
    id = run_id()
    assert :ok = RunStore.finalize(id, %{completed: %{ok: false}, session_key: "typing-test"})
    on_exit(fn -> LemonCore.Store.delete(:runs, id) end)
    TypingIndicator.start_run(id, recording_options(:already_completed), server)
    assert :sys.get_state(server).targets == %{}
    refute_receive {:typing, _}, 100
  end

  test "session cancellation only releases that session's runs", %{server: server} do
    one = Keyword.put(recording_options(:one), :session_key, "one")
    two = Keyword.put(recording_options(:two), :session_key, "two")
    TypingIndicator.start_run(run_id(), one, server)
    id = run_id()
    TypingIndicator.start_run(id, two, server)
    TypingIndicator.stop_session("one", server)
    assert Map.keys(:sys.get_state(server).runs) == [id]
  end

  defp recording_options(target) do
    parent = self()

    [
      target: target,
      interval_ms: 60,
      send: fn ->
        send(parent, {:typing, System.monotonic_time(:millisecond)})
        :ok
      end
    ]
  end

  defp run_id, do: "typing_#{System.unique_integer([:positive])}"

  defp complete(run_id, ok? \\ true) do
    Bus.broadcast(
      Bus.run_topic(run_id),
      Event.new(:run_completed, %{completed: %{ok: ok?}}, %{run_id: run_id})
    )
  end

  defp await_empty(server, attempts \\ 100)
  defp await_empty(_server, 0), do: flunk("typing refresher did not stop")

  defp await_empty(server, attempts) do
    if :sys.get_state(server).targets != %{} do
      Process.sleep(10)
      await_empty(server, attempts - 1)
    end
  end

  defp flush_typing do
    receive do
      {:typing, _} -> flush_typing()
    after
      0 -> :ok
    end
  end

  defp flush_discord_typing do
    receive do
      {:discord_typing, _} -> flush_discord_typing()
    after
      0 -> :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
