defmodule LemonGateway.Sms.TwilioSignature do
  @moduledoc false

  # Twilio signature:
  # - data = url + concat(sorted(params), key <> value)
  # - signature = Base64(HMAC-SHA1(auth_token, data))
  #
  # Note: Twilio's request validation is sensitive to the exact URL.
  # When running behind tunnels/proxies, prefer configuring TWILIO_WEBHOOK_URL
  # to the exact public URL set in Twilio.

  def valid?(auth_token, url, params, provided) do
    auth_token = normalize(auth_token)
    url = normalize(url)
    provided = normalize(provided)

    cond do
      not is_binary(auth_token) or auth_token == "" ->
        false

      not is_binary(url) or url == "" ->
        false

      not is_binary(provided) or provided == "" ->
        false

      true ->
        expected = signature(auth_token, url, params || %{})
        secure_compare(expected, provided)
    end
  end

  def signature(auth_token, url, params) when is_map(params) do
    data = url <> canonical_param_string(params)
    mac = :crypto.mac(:hmac, :sha, auth_token, data)
    Base.encode64(mac)
  end

  defp canonical_param_string(params) when is_map(params) do
    params
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) -> [{k, v}]
      {k, v} when is_atom(k) -> [{Atom.to_string(k), v}]
      _ -> []
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("", fn {k, v} ->
      k <> normalize_value(v)
    end)
  end

  defp normalize_value(nil), do: ""

  defp normalize_value(v) when is_binary(v), do: v

  defp normalize_value(v) when is_integer(v), do: Integer.to_string(v)

  defp normalize_value(v) when is_float(v), do: :erlang.float_to_binary(v, [:compact])

  defp normalize_value(v) when is_list(v) do
    # Plug may decode some params as lists; join deterministically.
    Enum.map_join(v, "", &normalize_value/1)
  end

  defp normalize_value(v), do: to_string(v)

  defp normalize(v) when is_binary(v), do: String.trim(v)
  defp normalize(_), do: nil

  # Constant-time compare for binaries.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) and byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  defp secure_compare(_, _), do: false
end
