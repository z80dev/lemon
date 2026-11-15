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

  setup do
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

    start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Discord.AsyncSupervisor})
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

  defp consume_pairing(reply) do
    [_, code] = Regex.run(~r/Pairing code: ([A-HJ-NP-Z2-9]{8})/, reply)
    assert {:ok, _} = LemonChannels.Pairing.consume("discord", code)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
