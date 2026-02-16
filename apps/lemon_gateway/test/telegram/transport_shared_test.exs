defmodule LemonGateway.Telegram.TransportSharedTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.TransportShared

  test "legacy_start_decision/2 keeps legacy as fallback-only ownership" do
    assert :disabled == TransportShared.legacy_start_decision(false, false)
    assert :channels_running == TransportShared.legacy_start_decision(true, true)
    assert :start == TransportShared.legacy_start_decision(true, false)
  end

  test "legacy transport force-start is ignored when channels transport is running" do
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

    assert :channels_running == TransportShared.legacy_start_decision(force: true)
    assert :ignore == LemonGateway.Telegram.Transport.start_link(force: true)
  end
end
