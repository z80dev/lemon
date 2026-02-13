defmodule LemonGateway.Sms.Config do
  @moduledoc false

  @default_port 4041

  def webhook_enabled? do
    truthy_env?("LEMON_SMS_WEBHOOK_ENABLED", false)
  end

  def webhook_port do
    int_env("LEMON_SMS_WEBHOOK_PORT", @default_port)
  end

  @doc """
  Returns the bind ip option for Bandit.

  Accepts:
  - "127.0.0.1" / "localhost" => :loopback
  - "0.0.0.0" / "any" => :any
  - explicit IPv4/IPv6 tuple strings => parsed tuple
  """
  def webhook_ip do
    case normalize_blank(System.get_env("LEMON_SMS_WEBHOOK_BIND")) do
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
    normalize_blank(System.get_env("TWILIO_INBOX_NUMBER"))
  end

  def inbox_ttl_ms do
    int_env("LEMON_SMS_INBOX_TTL_MS", 24 * 60 * 60 * 1000)
  end

  def validate_webhook? do
    truthy_env?("TWILIO_VALIDATE_WEBHOOK", false)
  end

  def auth_token do
    normalize_blank(System.get_env("TWILIO_AUTH_TOKEN"))
  end

  def webhook_url_override do
    normalize_blank(System.get_env("TWILIO_WEBHOOK_URL"))
  end

  defp truthy_env?(name, default) do
    case normalize_blank(System.get_env(name)) do
      nil ->
        default

      v ->
        v in ["1", "true", "yes", "on"]
    end
  end

  defp int_env(name, default) when is_integer(default) do
    case normalize_blank(System.get_env(name)) do
      nil ->
        default

      v ->
        case Integer.parse(v) do
          {n, _} when n >= 0 -> n
          _ -> default
        end
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

