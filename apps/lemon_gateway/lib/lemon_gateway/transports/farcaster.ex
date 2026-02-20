defmodule LemonGateway.Transports.Farcaster do
  @moduledoc false

  use LemonGateway.Transport

  require Logger

  alias LemonGateway.Transports.Farcaster.FrameServer

  @impl LemonGateway.Transport
  def id, do: "farcaster"

  @impl LemonGateway.Transport
  def start_link(opts) do
    cond do
      not enabled?() ->
        Logger.info("farcaster transport disabled")
        :ignore

      true ->
        cfg = config()

        maybe_warn_missing_credentials(cfg)

        FrameServer.start_link(Keyword.put(opts, :config, cfg))
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_farcaster) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      cond do
        is_list(cfg) -> Keyword.get(cfg, :enable_farcaster, false)
        is_map(cfg) -> Map.get(cfg, :enable_farcaster, false)
        true -> false
      end
    end
  rescue
    _ -> false
  end

  @spec config() :: map()
  def config do
    cfg =
      case Process.get({__MODULE__, :config_override}) do
        nil ->
          if is_pid(Process.whereis(LemonGateway.Config)) do
            LemonGateway.Config.get(:farcaster) || %{}
          else
            Application.get_env(:lemon_gateway, :farcaster, %{})
          end

        override ->
          override
      end

    cond do
      is_list(cfg) -> Enum.into(cfg, %{})
      is_map(cfg) -> cfg
      true -> %{}
    end
  rescue
    _ -> %{}
  end

  defp maybe_warn_missing_credentials(cfg) do
    api_key = normalize_blank(cfg[:api_key] || System.get_env("FARCASTER_API_KEY"))
    signer_uuid = normalize_blank(cfg[:signer_uuid] || System.get_env("FARCASTER_SIGNER_UUID"))

    if is_nil(api_key) or is_nil(signer_uuid) do
      Logger.warning(
        "farcaster credentials missing (FARCASTER_API_KEY/FARCASTER_SIGNER_UUID); inbound frames will work, outbound cast posting is disabled"
      )
    end
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil
end
