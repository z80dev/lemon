defmodule LemonGateway.Transports.Xmtp do
  @moduledoc """
  XMTP messaging transport stub. The legacy gateway implementation has been
  removed; this module delegates to the `LemonChannels.Adapters.Xmtp` adapter
  and provides configuration and status helpers.
  """

  use LemonGateway.Transport

  require Logger

  @impl LemonGateway.Transport
  def id, do: "xmtp"

  @impl LemonGateway.Transport
  def start_link(_opts) do
    Logger.warning("Legacy LemonGateway XMTP transport is removed; use lemon_channels adapter")

    :ignore
  end

  @spec status() :: {:ok, map()} | {:error, term()}
  def status do
    mod = LemonChannels.Adapters.Xmtp.Transport

    if Code.ensure_loaded?(mod) and function_exported?(mod, :status, 0) do
      mod.status()
    else
      {:error, :unavailable}
    end
  rescue
    error -> {:error, error}
  end

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_xmtp) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      if is_list(cfg) do
        Keyword.get(cfg, :enable_xmtp, false)
      else
        Map.get(cfg, :enable_xmtp, false)
      end
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:xmtp) || %{}
      else
        Application.get_env(:lemon_gateway, :xmtp, %{})
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
