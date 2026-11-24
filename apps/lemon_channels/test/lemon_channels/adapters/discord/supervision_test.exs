defmodule LemonChannels.Adapters.Discord.Supervision581Test do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Transport

  @config_key :"Elixir.LemonGateway.Config"

  defmodule BlockingAPI do
    def create(_channel_id, params) do
      send(:persistent_term.get({__MODULE__, :owner}), {:event_blocked, self(), params.content})

      receive do
        :release -> {:ok, %{id: 581}}
      end
    end
  end

  setup context do
    old_config = Application.get_env(:lemon_gateway, @config_key)
    old_mode = Application.get_env(:lemon_core, :config_test_mode)
    old_health = :sys.get_state(LemonChannels.Registry).health
    :persistent_term.put({BlockingAPI, :owner}, self())
    Application.put_env(:lemon_core, :config_test_mode, true)
    Application.put_env(:lemon_gateway, @config_key, %{discord: %{api_mod: BlockingAPI}})

    on_exit(fn ->
      :persistent_term.erase({BlockingAPI, :owner})
      restore(:lemon_gateway, @config_key, old_config)
      restore(:lemon_core, :config_test_mode, old_mode)

      :sys.replace_state(LemonChannels.Registry, fn state ->
        health =
          case Map.fetch(old_health, "discord") do
            {:ok, health} -> Map.put(state.health, "discord", health)
            :error -> Map.delete(state.health, "discord")
          end

        %{state | health: health}
      end)
    end)

    start_supervised!(
      LemonCore.TaskSupervisor.child_spec(
        name: LemonChannels.Adapters.Discord.AsyncSupervisor,
        max_children: context[:task_limit] || 1024
      )
    )

    :ok
  end

  test "blocked event I/O is supervised and does not block the transport mailbox" do
    transport = start_supervised!({Transport, config: %{unauthorized_dm_behavior: "pair"}})

    message = %{
      "id" => "1503803470493257581",
      "channel_id" => "1475727417372049419",
      "content" => "pair me",
      "author" => %{"id" => "1476753643834183691", "bot" => false}
    }

    assert {:noreply, :consumer_state} =
             Transport.Consumer.handle_info(
               {:event, {:MESSAGE_CREATE, message, nil}},
               :consumer_state
             )

    assert_receive {:event_blocked, worker, pairing_reply}, 1_000
    consume_pairing(pairing_reply)
    assert worker in Task.Supervisor.children(LemonChannels.Adapters.Discord.AsyncSupervisor)
    assert %{task: %{pid: ^worker}} = :sys.get_state(transport, 1_000)
    assert :ok = GenServer.call(transport, {:update_allowlist, :add, 999}, 1_000)

    second_message = %{
      message
      | "id" => "1503803470493257582",
        "channel_id" => "1475727417372049420"
    }

    send(transport, {:discord_event, {:MESSAGE_CREATE, second_message, nil}})
    assert %{queue: queue} = :sys.get_state(transport, 1_000)
    assert :queue.len(queue) == 1

    # Killing an event task does not kill the transport or replay that event.
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert Process.alive?(transport)
    assert_receive {:event_blocked, next_worker, next_pairing_reply}, 1_000
    consume_pairing(next_pairing_reply)
    assert next_worker != worker
    next_monitor = Process.monitor(next_worker)
    send(next_worker, :release)
    assert_receive {:DOWN, ^next_monitor, :process, ^next_worker, :normal}, 1_000
    assert %{task: nil, queue: empty, data: data} = :sys.get_state(transport)
    assert MapSet.member?(data.allowed_channel_ids, 999)
    assert :queue.is_empty(empty)
  end

  @tag task_limit: 1
  test "full and missing supervisors reject events without stopping or replaying the transport" do
    supervisor = Process.whereis(LemonChannels.Adapters.Discord.AsyncSupervisor)
    owner = self()

    assert {:ok, blocker} =
             LemonCore.TaskSupervisor.start_child(supervisor, fn ->
               send(owner, :capacity_occupied)

               receive do
                 :release -> :ok
               end
             end)

    assert_receive :capacity_occupied
    transport = start_supervised!({Transport, config: %{unauthorized_dm_behavior: "pair"}})
    send(transport, {:discord_event, {:MESSAGE_CREATE, %{}, nil}})
    assert %{task: nil, queue: queue} = :sys.get_state(transport)
    assert :queue.is_empty(queue)

    Process.unregister(LemonChannels.Adapters.Discord.AsyncSupervisor)

    try do
      send(transport, {:discord_event, {:MESSAGE_CREATE, %{}, nil}})
      assert %{task: nil, queue: queue} = :sys.get_state(transport)
      assert :queue.is_empty(queue)
    after
      Process.register(supervisor, LemonChannels.Adapters.Discord.AsyncSupervisor)
    end

    monitor = Process.monitor(blocker)
    send(blocker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^blocker, :normal}
    assert %{task: nil, queue: queue} = :sys.get_state(transport)
    assert :queue.is_empty(queue)
    refute_receive {:event_blocked, _, _}, 0
  end

  test "transport contains neither global Nostrum configuration nor bare tasks" do
    source =
      File.read!(
        Path.expand("../../../../lib/lemon_channels/adapters/discord/transport.ex", __DIR__)
      )

    refute source =~ "Application.put_env"
    refute source =~ "Application.ensure_all_started"
    refute source =~ "Task.start("
    refute Regex.match?(~r/\bspawn\(/, source)
  end

  test "Discord boot configures the included Nostrum child, not an application controller startup" do
    old_token = Application.get_env(:nostrum, :token)
    old_intents = Application.get_env(:nostrum, :gateway_intents)

    on_exit(fn ->
      restore(:nostrum, :token, old_token)
      restore(:nostrum, :gateway_intents, old_intents)
    end)

    assert {:ok, {%{strategy: :one_for_all}, children}} =
             LemonChannels.Adapters.Discord.Supervisor.init(
               config: %{bot_token: "boot-token-581"}
             )

    assert Enum.any?(children, &(&1.start == {Nostrum.Application, :start, [:normal, []]}))
    assert Enum.any?(children, &(&1.id == Transport))
    assert Enum.any?(children, &(&1.id == Transport.Consumer))
    assert Application.get_env(:nostrum, :token) == "boot-token-581"
    assert :message_content in Application.get_env(:nostrum, :gateway_intents)
  end

  test "a queued /file get is acknowledged on arrival, well inside Discord's 3 s window" do
    parent = self()

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(
        parent,
        {:interaction_response, interaction.id, payload, System.monotonic_time(:millisecond)}
      )

      :ok
    end)

    on_exit(fn -> Application.delete_env(:lemon_channels, :discord_interaction_responder) end)

    transport = start_supervised!({Transport, config: %{unauthorized_dm_behavior: "pair"}})

    # Occupy the serial event queue with blocked platform I/O.
    message = %{
      "id" => "1503803470493257650",
      "channel_id" => "1475727417372049650",
      "content" => "pair me",
      "author" => %{"id" => "1476753643834183650", "bot" => false}
    }

    send(transport, {:discord_event, {:MESSAGE_CREATE, message, nil}})
    assert_receive {:event_blocked, worker, pairing_reply}, 1_000

    sent_at = System.monotonic_time(:millisecond)

    file_get = %{
      id: "1503803470493257651",
      type: 2,
      token: "token",
      application_id: "1",
      channel_id: "1475727417372049651",
      data: %{
        name: "file",
        options: [%{type: 1, name: "get", options: [%{name: "path", value: "a.txt"}]}]
      },
      user: %{id: "1476753643834183651"}
    }

    send(transport, {:discord_event, {:INTERACTION_CREATE, file_get, nil}})

    assert_receive {:interaction_response, "1503803470493257651", %{type: 5, data: %{flags: 64}},
                    acked_at},
                   1_000

    assert acked_at - sent_at < 3_000
    # The ack did not wait for the blocked event.
    assert Process.alive?(worker)

    consume_pairing(pairing_reply)
    send(worker, :release)

    # The reply arrives later as an edit of the deferred response.
    assert_receive {:interaction_response, "1503803470493257651", %{type: :edit_original}, _at},
                   2_000
  end

  defp consume_pairing(reply) do
    [_, code] = Regex.run(~r/Pairing code: ([A-HJ-NP-Z2-9]{8})/, reply)
    assert {:ok, _} = LemonChannels.Pairing.consume("discord", code)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
