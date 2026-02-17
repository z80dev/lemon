defmodule LemonGateway.Telegram.TransportSharedTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.TransportShared

  test "channels_transport_running?/0 reflects adapter process presence" do
    existing_channels = Process.whereis(LemonChannels.Adapters.Telegram.Transport)

    spawned_channels =
      case existing_channels do
        pid when is_pid(pid) ->
          nil

        nil ->
          pid = spawn(fn -> Process.sleep(:infinity) end)
          true = Process.register(pid, LemonChannels.Adapters.Telegram.Transport)
          pid
      end

    on_exit(fn ->
      if is_pid(spawned_channels) and Process.alive?(spawned_channels) do
        Process.exit(spawned_channels, :kill)
      end
    end)

    assert TransportShared.channels_transport_running?()
  end

  test "channels dedupe marks new then seen" do
    :ok = TransportShared.init_dedupe(:channels)
    key = {"chat-1", "topic-1", "msg-1"}

    assert :new == TransportShared.check_and_mark_dedupe(:channels, key, 60_000)
    assert :seen == TransportShared.check_and_mark_dedupe(:channels, key, 60_000)
  end
end
