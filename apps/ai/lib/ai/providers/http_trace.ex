defmodule Ai.Providers.HttpTrace do
  @moduledoc """
  HTTP request/response tracing utilities for AI provider integrations.

  Provides functions for generating trace IDs, logging HTTP interactions,
  inspecting response headers, and producing size-limited previews of
  request and response bodies. Tracing is gated by the `LEMON_AI_HTTP_TRACE`
  environment variable — set it to `"1"` to enable trace-level logging.
  """

  require Logger

  @trace_env "LEMON_AI_HTTP_TRACE"
  @default_preview_bytes 1_200
  @default_printable_limit 12_000

  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env(@trace_env) == "1"
  end

  @spec new_trace_id(String.t() | atom()) :: String.t()
  def new_trace_id(provider) do
    suffix = :erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)
    "#{provider}-#{suffix}"
  end

  @spec log(String.t(), String.t(), map(), Logger.level()) :: :ok
  def log(provider, event, payload, level \\ :info)
      when is_binary(provider) and is_binary(event) and is_map(payload) do
    if enabled?() do
      Logger.log(level, "[ai-http][#{provider}] #{event} #{format_payload(payload)}")
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec log_error(String.t(), String.t(), map(), Logger.level()) :: :ok
  def log_error(provider, event, payload, level \\ :error)
      when is_binary(provider) and is_binary(event) and is_map(payload) do
    Logger.log(level, "[ai-http][#{provider}] #{event} #{format_payload(payload)}")
    :ok
  rescue
    _ -> :ok
  end

  @spec body_bytes(term()) :: non_neg_integer()
  def body_bytes(body) when is_binary(body), do: byte_size(body)

  def body_bytes(body) do
    body
    |> inspect(limit: 80, printable_limit: 20_000)
    |> byte_size()
  end

  @spec body_preview(term(), pos_integer()) :: String.t()
  def body_preview(body, max_bytes \\ @default_preview_bytes)

  def body_preview(body, max_bytes)
      when is_binary(body) and is_integer(max_bytes) and max_bytes > 0 do
    truncate_to_bytes(body, max_bytes)
  end

  def body_preview(body, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    body
    |> inspect(limit: 80, printable_limit: max(2 * max_bytes, 200))
    |> truncate_to_bytes(max_bytes)
  end

  @spec response_header_value(map() | [{term(), term()}] | nil, [String.t()] | String.t()) ::
          String.t() | nil
  def response_header_value(headers, names)

  def response_header_value(headers, name) when is_binary(name) do
    response_header_value(headers, [name])
  end

  def response_header_value(headers, names) when is_list(names) do
    normalized = normalize_headers(headers)

    names
    |> Enum.map(&String.downcase/1)
    |> Enum.find_value(&Map.get(normalized, &1))
  end

  @spec summarize_text_size(String.t() | nil) :: non_neg_integer()
  def summarize_text_size(nil), do: 0
  def summarize_text_size(text) when is_binary(text), do: byte_size(text)
  def summarize_text_size(_), do: 0

  defp format_payload(payload) do
    inspect(payload, limit: 80, printable_limit: @default_printable_limit)
  end

  defp normalize_headers(nil), do: %{}

  defp normalize_headers(headers) when is_map(headers) do
    headers
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case normalize_header_pair(k, v) do
        nil -> acc
        {name, value} -> Map.put(acc, name, value)
      end
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {k, v}, acc ->
        case normalize_header_pair(k, v) do
          nil -> acc
          {name, value} -> Map.put(acc, name, value)
        end

      _, acc ->
        acc
    end)
  end

  defp normalize_headers(_), do: %{}

  defp normalize_header_pair(key, value) do
    with name when is_binary(name) <- normalize_header_name(key),
         normalized_value when is_binary(normalized_value) <- normalize_header_value(value) do
      {name, normalized_value}
    else
      _ -> nil
    end
  end

  defp normalize_header_name(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_name(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_header_name(_), do: nil

  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value([value | _]) when is_binary(value), do: value

  defp normalize_header_value(value) do
    to_string(value)
  rescue
    _ -> nil
  end

  defp truncate_to_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_to_bytes(text, max_bytes) do
    prefix =
      text
      |> binary_part(0, max_bytes)
      |> trim_to_valid_utf8()

    "#{prefix}...[truncated #{byte_size(text) - byte_size(prefix)} bytes]"
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end
end
