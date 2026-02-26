defmodule CodingAgent.Wasm.Protocol do
  @moduledoc """
  JSONL protocol helpers for `native/lemon-wasm-runtime`.
  """

  @spec next_id(String.t()) :: String.t()
  def next_id(prefix \\ "req") do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @spec encode_request(String.t(), String.t(), map()) :: iodata()
  def encode_request(type, id, payload \\ %{}) do
    payload
    |> Map.put("type", type)
    |> Map.put("id", id)
    |> Jason.encode_to_iodata!()
    |> then(&[&1, "\n"])
  end

  @spec decode_line(String.t()) :: {:ok, map()} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_message, other}}
      {:error, reason} -> {:error, reason}
    end
  end
end
