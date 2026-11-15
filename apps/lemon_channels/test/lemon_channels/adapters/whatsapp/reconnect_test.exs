defmodule LemonChannels.Adapters.WhatsApp.Reconnect581Test do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.Transport
  alias LemonChannels.{PortBridge, Registry}

  @config_key :"Elixir.LemonGateway.Config"

  setup do
    old_config = Application.get_env(:lemon_gateway, @config_key)
    old_mode = Application.get_env(:lemon_core, :config_test_mode)
    registry_state = :sys.get_state(Registry)

    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @config_key, %{
      enable_whatsapp: true,
      whatsapp: %{bridge_script: Path.join(System.tmp_dir!(), "missing-bridge-581.mjs")}
    })

    unless Registry.get_plugin("whatsapp"), do: Registry.register(LemonChannels.Adapters.WhatsApp)

    on_exit(fn ->
      restore(:lemon_gateway, @config_key, old_config)
      restore(:lemon_core, :config_test_mode, old_mode)

      :sys.replace_state(Registry, fn state ->
        %{
          state
          | plugins: restore_entry(state.plugins, registry_state.plugins, "whatsapp"),
            health: restore_entry(state.health, registry_state.health, "whatsapp")
        }
      end)
    end)

    :ok
  end

  test "duplicate socket and port failures share one reconnect timer and one attempt" do
    state = %{connected?: false, own_jid: nil, reconnect_timer: nil, reconnect_attempts: 0}
    disconnected = {:whatsapp_bridge_event, %{"type" => "disconnected", "status_code" => 500}}
    bridge_down = {:whatsapp_bridge_event, %{"type" => "bridge_down"}}

    assert {:noreply, pending} = Transport.handle_info(disconnected, state)
    {timer, _ref} = pending.reconnect_timer
    on_exit(fn -> Process.cancel_timer(timer) end)
    assert pending.reconnect_attempts == 1
    assert {:noreply, ^pending} = Transport.handle_info(disconnected, pending)
    assert {:noreply, ^pending} = Transport.handle_info(bridge_down, pending)
    assert {:noreply, ^pending} = Transport.handle_info({:reconnect, make_ref()}, pending)
  end

  test "manual port failures notify the owner and ignore independent restart messages" do
    bridge = %{
      label: "whatsapp",
      event_tag: :whatsapp_bridge_event,
      script_filename: "whatsapp_bridge.mjs"
    }

    # The fault is injected at the Port exit-status boundary, without Node or a race.
    state = %{
      port: nil,
      os_pid: nil,
      buffer: "partial",
      unavailable_reason: nil,
      bridge: bridge,
      notify_pid: self(),
      restart: :manual
    }

    assert {:noreply, failed} = PortBridge.handle_info({nil, {:exit_status, 1}}, state)
    assert_receive {:whatsapp_bridge_event, %{"type" => "error"}}
    assert_receive {:whatsapp_bridge_event, %{"type" => "bridge_down"}}
    assert failed.port == nil
    assert failed.buffer == ""
    assert {:noreply, ^failed} = PortBridge.handle_info(:restart_port, failed)
  end

  test "exhaustion stops a transient supervised child, closes its bridge and appears in health" do
    supervisor =
      start_supervised!(%{
        id: __MODULE__.Supervisor,
        start: {Supervisor, :start_link, [[{Transport, []}], [strategy: :one_for_one]]},
        type: :supervisor
      })

    [{Transport, transport, :worker, _}] = Supervisor.which_children(supervisor)
    bridge = :sys.get_state(transport).port_server
    assert :sys.get_state(bridge).restart == :manual
    # Drain startup failures before installing the budget boundary fault.
    :sys.get_state(transport)

    :sys.replace_state(transport, fn state ->
      if state.reconnect_timer, do: Process.cancel_timer(elem(state.reconnect_timer, 0))
      %{state | reconnect_attempts: 12, reconnect_timer: nil}
    end)

    transport_monitor = Process.monitor(transport)
    bridge_monitor = Process.monitor(bridge)
    send(transport, {:whatsapp_bridge_event, %{"type" => "disconnected", "status_code" => 500}})

    assert_receive {:DOWN, ^transport_monitor, :process, ^transport,
                    {:shutdown, :reconnect_exhausted}},
                   1_000

    assert_receive {:DOWN, ^bridge_monitor, :process, ^bridge, :normal}, 1_000
    assert [{Transport, :undefined, :worker, _}] = Supervisor.which_children(supervisor)

    assert %{"state" => "error", "lastError" => %{"message" => message}} =
             Enum.find(Registry.status().details, &(&1["id"] == "whatsapp"))

    assert message =~ "reconnect budget exhausted"
    assert Transport.deliver(%{kind: :send_text}) == {:error, :whatsapp_not_running}
  end

  test "logout and replacement cancel retries and stop rather than silently staying healthy" do
    for {event, reason} <- [
          {%{"type" => "disconnected", "is_logged_out" => true}, :logged_out},
          {%{"type" => "disconnected", "status_code" => 440}, :connection_replaced}
        ] do
      timer = Process.send_after(self(), :unexpected_reconnect, 60_000)

      state = %{
        connected?: true,
        own_jid: "bot",
        reconnect_timer: {timer, make_ref()},
        reconnect_attempts: 1
      }

      assert {:stop, {:shutdown, ^reason}, stopped} =
               Transport.handle_info({:whatsapp_bridge_event, event}, state)

      assert stopped.reconnect_timer == nil
      assert Process.read_timer(timer) == false
    end
  end

  test "WhatsApp adapter has no bare process or task starts" do
    root = Path.expand("../../../../lib/lemon_channels/adapters/whatsapp", __DIR__)

    for path <- Path.wildcard(Path.join(root, "**/*.ex")) do
      source = File.read!(path)
      refute source =~ "Task.start("
      refute Regex.match?(~r/\bspawn\(/, source)
    end
  end

  defp restore_entry(current, previous, key) do
    case Map.fetch(previous, key) do
      {:ok, value} -> Map.put(current, key, value)
      :error -> Map.delete(current, key)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
