defmodule LemonGateway.Transports.Farcaster.HubClient do
  @moduledoc """
  HTTP client for verifying Farcaster frame message signatures against a
  Farcaster Hub validation endpoint. Returns the verified FID on success.
  """

  @default_timeout_ms 5_000

  @spec verify_message_bytes(String.t(), map() | keyword()) ::
          {:ok, %{fid: pos_integer() | nil}} | {:error, term()}
  def verify_message_bytes(message_bytes, cfg \\ %{})

  def verify_message_bytes(message_bytes, cfg) when is_binary(message_bytes) do
    message_bytes = String.trim(message_bytes)

    if message_bytes == "" do
      {:error, :missing_message_bytes}
    else
      do_verify_message_bytes(message_bytes, cfg)
    end
  end

  def verify_message_bytes(_, _), do: {:error, :missing_message_bytes}

  defp do_verify_message_bytes(message_bytes, cfg) do
    with {:ok, validate_url} <- validate_url(cfg),
         {:ok, body} <- Jason.encode(%{"messageBytes" => message_bytes}) do
      headers = [{~c"content-type", ~c"application/json"}]
      request = {to_charlist(validate_url), headers, ~c"application/json", body}
      timeout = timeout_ms(cfg)
      http_opts = [timeout: timeout, connect_timeout: timeout]

      case LemonCore.Httpc.request(:post, request, http_opts, body_format: :binary) do
        {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
          parse_verify_response(resp_body)

        {:ok, {{_, status, _}, _headers, resp_body}} ->
          {:error, {:http_status, status, truncate_body(resp_body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error ->
      {:error, {:exception, error}}
  end

  defp validate_url(cfg) do
    url =
      fetch(cfg, :hub_validate_url) ||
        System.get_env("FARCASTER_HUB_VALIDATE_URL")

    case normalize_blank(url) do
      nil ->
        {:error, :missing_hub_validate_url}

      value ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host}
          when is_binary(host) and scheme in ["http", "https"] ->
            {:ok, value}

          _ ->
            {:error, :invalid_hub_validate_url}
        end
    end
  rescue
    _ -> {:error, :invalid_hub_validate_url}
  end

  defp parse_verify_response(resp_body) when is_binary(resp_body) do
    case String.trim(resp_body) do
      "" ->
        {:error, :empty_verify_response}

      body ->
        case Jason.decode(body) do
          {:ok, decoded} when is_map(decoded) ->
            case verification_valid?(decoded) do
              true ->
                {:ok, %{fid: verifier_fid(decoded)}}

              false ->
                {:error, :invalid_trusted_data}

              nil ->
                {:error, :missing_valid_flag}
            end

          {:ok, _other} ->
            {:error, :invalid_verify_response}

          {:error, reason} ->
            {:error, {:invalid_verify_response, reason}}
        end
    end
  end

  defp parse_verify_response(_), do: {:error, :invalid_verify_response}

  defp verification_valid?(decoded) when is_map(decoded) do
    cond do
      is_boolean(get_in(decoded, ["valid"])) ->
        get_in(decoded, ["valid"])

      is_boolean(get_in(decoded, ["isValid"])) ->
        get_in(decoded, ["isValid"])

      is_boolean(get_in(decoded, ["result", "valid"])) ->
        get_in(decoded, ["result", "valid"])

      is_boolean(get_in(decoded, ["result", "isValid"])) ->
        get_in(decoded, ["result", "isValid"])

      is_boolean(get_in(decoded, ["data", "valid"])) ->
        get_in(decoded, ["data", "valid"])

      is_boolean(get_in(decoded, ["data", "isValid"])) ->
        get_in(decoded, ["data", "isValid"])

      true ->
        nil
    end
  end

  defp verification_valid?(_), do: nil

  defp verifier_fid(decoded) when is_map(decoded) do
    [
      ["fid"],
      ["result", "fid"],
      ["data", "fid"],
      ["result", "data", "fid"],
      ["message", "fid"],
      ["message", "data", "fid"],
      ["result", "message", "fid"],
      ["result", "message", "data", "fid"]
    ]
    |> Enum.find_value(fn path ->
      decoded
      |> get_in(path)
      |> parse_positive_integer()
    end)
  end

  defp verifier_fid(_), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_positive_integer(_), do: nil

  defp timeout_ms(cfg) do
    case fetch(cfg, :hub_timeout_ms) do
      n when is_integer(n) and n > 0 ->
        n

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n > 0 -> n
          _ -> @default_timeout_ms
        end

      _ ->
        @default_timeout_ms
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end

  defp fetch(_, _), do: nil

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp truncate_body(_), do: nil
end
