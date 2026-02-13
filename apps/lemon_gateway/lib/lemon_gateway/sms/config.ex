defmodule LemonGateway.Sms.Config do
  @moduledoc false

  @default_port 4041

  def webhook_enabled? do
    case normalize_blank(System.get_env("LEMON_SMS_WEBHOOK_ENABLED")) do
      nil -> truthy_value?(sms_cfg(:webhook_enabled), false)
      v -> truthy_value?(v, false)
    end
  end

  def webhook_port do
    case normalize_blank(System.get_env("LEMON_SMS_WEBHOOK_PORT")) do
      nil -> int_value(sms_cfg(:webhook_port), @default_port)
      v -> int_value(v, @default_port)
    end
  end

  @doc """
  Returns the bind ip option for Bandit.

  Accepts:
  - "127.0.0.1" / "localhost" => :loopback
  - "0.0.0.0" / "any" => :any
  - explicit IPv4/IPv6 tuple strings => parsed tuple
  """
  def webhook_ip do
    bind =
      normalize_blank(System.get_env("LEMON_SMS_WEBHOOK_BIND")) ||
        normalize_blank(sms_cfg(:webhook_bind))

    case bind do
      nil ->
        :loopback

      "127.0.0.1" ->
        :loopback

      "localhost" ->
        :loopback

      "0.0.0.0" ->
        :any

      "any" ->
        :any

      other ->
        parse_ip(other) || :loopback
    end
  end

  def inbox_number do
    normalize_blank(System.get_env("TWILIO_INBOX_NUMBER")) ||
      normalize_blank(sms_cfg(:inbox_number))
  end

  def inbox_ttl_ms do
    case normalize_blank(System.get_env("LEMON_SMS_INBOX_TTL_MS")) do
      nil -> int_value(sms_cfg(:inbox_ttl_ms), 24 * 60 * 60 * 1000)
      v -> int_value(v, 24 * 60 * 60 * 1000)
    end
  end

  def validate_webhook? do
    case normalize_blank(System.get_env("TWILIO_VALIDATE_WEBHOOK")) do
      nil -> truthy_value?(sms_cfg(:validate_webhook), false)
      v -> truthy_value?(v, false)
    end
  end

  def auth_token do
    normalize_blank(System.get_env("TWILIO_AUTH_TOKEN")) || normalize_blank(sms_cfg(:auth_token))
  end

  def webhook_url_override do
    normalize_blank(System.get_env("TWILIO_WEBHOOK_URL")) ||
      normalize_blank(sms_cfg(:webhook_url))
  end

  defp sms_cfg(key) when is_atom(key) do
    sms = sms_config()
    Map.get(sms, key)
  end

  defp sms_cfg(_), do: nil

  defp sms_config do
    try do
      case LemonGateway.Config.get(:sms) do
        %{} = sms -> sms
        _ -> %{}
      end
    rescue
      _ -> %{}
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

  defp parse_ip(str) when is_binary(str) do
    # IPv4: "1.2.3.4"
    case String.split(str, ".", parts: 8) do
      [a, b, c, d] ->
        with {a, ""} <- Integer.parse(a),
             {b, ""} <- Integer.parse(b),
             {c, ""} <- Integer.parse(c),
             {d, ""} <- Integer.parse(d),
             true <- Enum.all?([a, b, c, d], &(&1 >= 0 and &1 <= 255)) do
          {a, b, c, d}
        else
          _ -> nil
        end

      _ ->
        # IPv6 is rarely needed here; keep it simple unless demanded.
        nil
    end
  end

  defp parse_ip(_), do: nil
end
