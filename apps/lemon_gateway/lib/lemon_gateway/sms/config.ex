defmodule LemonGateway.Sms.Config do
  require Logger

  @moduledoc """
  Configuration reader for SMS webhook settings.

  Declared environment overrides (`LemonCore.Env`, e.g. `LEMON_SMS_WEBHOOK_PORT`)
  take precedence over the `[gateway.sms]` config map. The Twilio auth token
  comes from the encrypted secrets store (`auth_token_secret`, then
  `TWILIO_AUTH_TOKEN` with its environment fallback) or the config map.

  Inbound webhooks are always signature-checked; there is no opt-out. Without an
  auth token the webhook listener does not start and the router rejects every
  request.
  """

  @default_port 4041
  @default_inbox_ttl_ms 24 * 60 * 60 * 1000
  @default_handoff_grace_ms 10 * 60 * 1000

  def webhook_enabled? do
    LemonCore.Env.get(:lemon_sms_webhook_enabled,
      default: truthy_value?(sms_cfg(:webhook_enabled), false)
    ) == true
  end

  @doc "The SMS webhook is enabled and has an auth token to verify signatures with."
  @spec usable?() :: boolean()
  def usable?, do: webhook_enabled?() and is_binary(auth_token())

  def webhook_port do
    LemonCore.Env.get(:lemon_sms_webhook_port,
      default: int_value(sms_cfg(:webhook_port), @default_port)
    )
    |> int_value(@default_port)
  end

  @doc """
  Returns the bind ip option for Bandit.

  Accepts:
  - "127.0.0.1" / "localhost" => :loopback
  - "0.0.0.0" / "any" => :any
  - explicit IPv4/IPv6 tuple strings => parsed tuple
  """
  def webhook_ip do
    :lemon_sms_webhook_bind
    |> env_string(sms_cfg(:webhook_bind))
    |> LemonGateway.BindAddress.parse()
  end

  def inbox_number, do: env_string(:twilio_inbox_number, sms_cfg(:inbox_number))

  def inbox_ttl_ms do
    LemonCore.Env.get(:lemon_sms_inbox_ttl_ms,
      default: int_value(sms_cfg(:inbox_ttl_ms), @default_inbox_ttl_ms)
    )
    |> int_value(@default_inbox_ttl_ms)
  end

  @doc """
  How long the inbox number stays bound to a session after it releases its
  reservation (`[gateway.sms] handoff_grace_ms`, default ten minutes). Late
  texts in this window go to the releasing session and no other session may
  reserve. Must be a positive integer: zero or invalid values are rejected at
  config load and fall back to the default here.
  """
  @spec handoff_grace_ms() :: pos_integer()
  def handoff_grace_ms do
    case int_value(sms_cfg(:handoff_grace_ms), @default_handoff_grace_ms) do
      ms when ms > 0 -> ms
      _ -> @default_handoff_grace_ms
    end
  end

  def auth_token do
    resolve_auth_token_secret() ||
      normalize_blank(LemonCore.Secrets.fetch_value("TWILIO_AUTH_TOKEN")) ||
      normalize_blank(sms_cfg(:auth_token))
  end

  defp resolve_auth_token_secret do
    secret_name = sms_cfg(:auth_token_secret)

    if is_binary(secret_name) and String.trim(secret_name) != "" do
      normalize_blank(LemonCore.Secrets.fetch_value(secret_name))
    else
      nil
    end
  end

  def webhook_url_override, do: env_string(:twilio_webhook_url, sms_cfg(:webhook_url))

  defp env_string(name, config_value) do
    normalize_blank(LemonCore.Env.get(name)) || normalize_blank(config_value)
  end

  defp sms_cfg(key) when is_atom(key) do
    sms = sms_config()
    Map.get(sms, key)
  end

  defp sms_config do
    try do
      case LemonGateway.Config.get(:sms) do
        %{} = sms -> sms
        _ -> %{}
      end
    rescue
      e ->
        Logger.warning("Failed to load SMS config: #{Exception.message(e)}")
        %{}
    end
  end

  defp truthy_value?(v, _default) when is_boolean(v), do: v
  defp truthy_value?(v, _default) when is_integer(v), do: v != 0

  defp truthy_value?(v, default) when is_binary(v) do
    v = String.trim(v)

    cond do
      v == "" ->
        default

      String.downcase(v) in ["1", "true", "yes", "on"] ->
        true

      true ->
        false
    end
  end

  defp truthy_value?(_v, default), do: default

  defp int_value(v, default) when is_integer(default) do
    cond do
      is_integer(v) and v >= 0 ->
        v

      is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {n, _} when n >= 0 -> n
          _ -> default
        end

      true ->
        default
    end
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(v) when is_binary(v) do
    v = String.trim(v)
    if v == "", do: nil, else: v
  end

  defp normalize_blank(_), do: nil
end
