defmodule LemonWeb.ManagementText do
  @moduledoc false

  # Management labels and history are not the private chat transcript. Omit
  # slash-bearing tokens rather than guessing which repository paths are public.
  @path_token ~r{(?<![^\s<>"'`])[^\s<>"'`\\/]*[\\/][^\s<>"'`]*}u
  @max_depth 8
  @max_items 200

  def text(value, opts \\ [])
  def text(nil, _opts), do: nil

  def text(value, opts) when is_binary(value) do
    if String.valid?(value) do
      value
      |> then(&Regex.replace(@path_token, &1, "[PATH HIDDEN]"))
      |> LemonMemory.Safety.redact_for_operator(opts)
      |> elem(0)
    else
      "[Invalid text]"
    end
  rescue
    SystemLimitError -> "[REDACTED]"
  end

  def text(_value, _opts), do: "[Hidden]"

  def term(value), do: project(value, 0)

  defp project(_value, depth) when depth >= @max_depth, do: "[Omitted]"
  defp project(value, _depth) when is_binary(value), do: text(value)

  defp project(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_items)
    |> Map.new(fn {key, nested} ->
      safe_key = if is_binary(key), do: text(key, max_bytes: 100), else: key

      safe_value =
        if (is_binary(key) or is_atom(key)) and LemonCore.Redact.sensitive_key?(to_string(key)),
          do: "[REDACTED]",
          else: project(nested, depth + 1)

      {safe_key, safe_value}
    end)
  end

  defp project(value, depth) when is_list(value) do
    value |> Enum.take(@max_items) |> Enum.map(&project(&1, depth + 1))
  end

  defp project(value, _depth) when is_atom(value) or is_number(value), do: value
  defp project(_value, _depth), do: "[Hidden]"
end
