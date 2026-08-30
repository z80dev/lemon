defmodule CodingAgent.ExecutionNode.Codec do
  @moduledoc """
  JSON codec for the Lemon control-plane WebSocket protocol.

  The execution-node client keeps this small boundary separate from socket
  lifecycle code so protocol validation can be tested without a live network.
  """

  @type decoded_frame ::
          {:hello, map()}
          | {:event, String.t(), map()}
          | {:response, String.t(), {:ok, term()} | {:error, term()}}

  @spec encode_request(String.t(), String.t(), map()) :: binary()
  def encode_request(id, method, params)
      when is_binary(id) and is_binary(method) and is_map(params) do
    Jason.encode!(%{
      "type" => "req",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  @spec decode(binary()) :: {:ok, decoded_frame()} | {:error, term()}
  def decode(data) when is_binary(data) do
    with {:ok, frame} <- Jason.decode(data) do
      decode_frame(frame)
    end
  end

  defp decode_frame(%{"type" => "hello-ok"} = frame), do: {:ok, {:hello, frame}}

  defp decode_frame(%{"type" => "event", "event" => event} = frame)
       when is_binary(event) do
    payload = Map.get(frame, "payload", %{})
    {:ok, {:event, event, if(is_map(payload), do: payload, else: %{})}}
  end

  defp decode_frame(%{"type" => "res", "id" => id, "ok" => true} = frame)
       when is_binary(id) do
    {:ok, {:response, id, {:ok, Map.get(frame, "payload")}}}
  end

  defp decode_frame(%{"type" => "res", "id" => id, "ok" => false} = frame)
       when is_binary(id) do
    {:ok, {:response, id, {:error, Map.get(frame, "error", "unknown error")}}}
  end

  defp decode_frame(frame), do: {:error, {:invalid_frame, frame_type(frame)}}

  defp frame_type(%{"type" => type}), do: type
  defp frame_type(_), do: :missing_type

  @doc "Converts an executor value into a JSON-safe, bounded protocol value."
  @spec json_safe(term()) :: term()
  def json_safe(%LemonCore.ResumeToken{engine: engine, value: value}) do
    %{"engine" => engine, "value" => value}
  end

  def json_safe(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def json_safe(value) when is_atom(value), do: Atom.to_string(value)
  def json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  def json_safe(%_{} = value) do
    value
    |> Map.from_struct()
    |> json_safe()
  end

  def json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key(key), json_safe(item)} end)
  end

  def json_safe(value), do: value |> inspect(limit: 20, printable_limit: 1_000) |> truncate(2_000)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key, limit: 5, printable_limit: 100)

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp truncate(value, max_bytes), do: binary_part(value, 0, max_bytes) <> "..."
end
