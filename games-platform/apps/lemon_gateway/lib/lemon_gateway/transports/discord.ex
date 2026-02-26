defmodule LemonGateway.Transports.Discord do
  @moduledoc """
  Discord transport stub.

  Discord is implemented by `LemonChannels.Adapters.Discord`. The legacy gateway
  transport is intentionally disabled.
  """

  use LemonGateway.Transport

  require Logger

  @impl LemonGateway.Transport
  def id, do: "discord"

  @impl LemonGateway.Transport
  def start_link(_opts) do
    Logger.warning(
      "Legacy LemonGateway Discord transport is removed; use lemon_channels Discord adapter"
    )

    :ignore
  end

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_discord) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      if is_list(cfg) do
        Keyword.get(cfg, :enable_discord, false)
      else
        Map.get(cfg, :enable_discord, false)
      end
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:discord) || %{}
      else
        Application.get_env(:lemon_gateway, :discord, %{})
      end

    cond do
      is_list(cfg) -> Enum.into(cfg, %{})
      is_map(cfg) -> cfg
      true -> %{}
    end
  rescue
    _ -> %{}
  end
end
