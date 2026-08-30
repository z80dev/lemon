defmodule LemonBrowser.SessionProviders.Helpers do
  @moduledoc false

  alias LemonCore.Secrets

  def secret(name), do: normalize(Secrets.fetch_value(name))

  def config(opts, key, default \\ nil) do
    opts
    |> Keyword.get(:provider_config, %{})
    |> get_value(key, default)
  end

  def get_value(map, key, default \\ nil)

  def get_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  def get_value(_map, _key, default), do: default

  def normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize(_), do: nil

  def base_url(value, default) do
    (normalize(value) || default) |> String.trim_trailing("/")
  end

  def positive_integer(value, default, max_value \\ 86_400)

  def positive_integer(value, _default, max_value) when is_integer(value) and value > 0,
    do: min(value, max_value)

  def positive_integer(value, default, max_value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, max_value)
      _ -> default
    end
  end

  def positive_integer(_value, default, _max_value), do: default

  def truthy(value, default \\ false)
  def truthy(value, _default) when value in [true, "true", "1", "yes", "on"], do: true
  def truthy(value, _default) when value in [false, "false", "0", "no", "off"], do: false
  def truthy(_value, default), do: default

  def response_body(%Req.Response{body: body}) when is_map(body), do: body

  def response_body(%Req.Response{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  def response_body(_), do: %{}

  def request_error(provider, action, {:ok, %Req.Response{status: status}}),
    do: {:error, "#{provider} #{action} failed with HTTP #{status}"}

  def request_error(provider, action, {:error, reason}),
    do: {:error, "#{provider} #{action} request failed: #{safe_reason(reason)}"}

  def request_error(provider, action, other),
    do: {:error, "#{provider} #{action} returned an unexpected response: #{safe_reason(other)}"}

  def safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 300)

  def safe_reason(reason),
    do: reason |> inspect(limit: 8, printable_limit: 300) |> String.slice(0, 300)
end
