defmodule LemonGateway.Voice.StreamToken do
  @moduledoc """
  Expiring, application-signed per-call token for Twilio Media Streams.

  The incoming-call webhook (already authenticated by `X-Twilio-Signature`)
  embeds a token bound to the call's CallSid, From and To as a `<Stream>`
  `<Parameter>`. `LemonGateway.Voice.TwilioWebSocket` verifies it from the
  `start` message's `customParameters` before creating any call resource.

  Format: `v1.<expires_unix>.<base64url HMAC-SHA256>`, keyed by a value derived
  from the Twilio auth token.
  """

  alias LemonGateway.Voice.Config

  @ttl_seconds 300

  @doc "Signs a token for the given call, valid for #{@ttl_seconds} seconds."
  @spec sign(String.t(), String.t(), String.t(), integer()) :: String.t()
  def sign(call_sid, from, to, now \\ System.system_time(:second)) do
    expires = now + @ttl_seconds
    "v1.#{expires}.#{mac(key!(), call_sid, from, to, expires)}"
  end

  @doc "Verifies `token` for the given call. Fails closed without an auth token."
  @spec verify(term(), term(), term(), term(), integer()) :: :ok | {:error, atom()}
  def verify(token, call_sid, from, to, now \\ System.system_time(:second))

  def verify(token, call_sid, from, to, now)
      when is_binary(token) and is_binary(call_sid) and call_sid != "" and is_binary(from) and
             is_binary(to) do
    with {:ok, key} <- key(),
         ["v1", exp_str, provided] <- String.split(token, ".", parts: 3),
         {expires, ""} <- Integer.parse(exp_str),
         true <- expires >= now || {:error, :expired},
         true <-
           Plug.Crypto.secure_compare(mac(key, call_sid, from, to, expires), provided) ||
             {:error, :invalid} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token, _call_sid, _from, _to, _now), do: {:error, :invalid}

  defp key do
    case Config.twilio_auth_token() do
      token when is_binary(token) and token != "" ->
        {:ok, :crypto.mac(:hmac, :sha256, token, "lemon-voice-stream-token")}

      _ ->
        {:error, :no_auth_token}
    end
  end

  defp key! do
    {:ok, key} = key()
    key
  end

  defp mac(key, call_sid, from, to, expires) do
    data = Enum.join([call_sid, from, to, Integer.to_string(expires)], <<0>>)
    :crypto.mac(:hmac, :sha256, key, data) |> Base.url_encode64(padding: false)
  end
end
