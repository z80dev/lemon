defmodule LemonAi.PartialJson do
  @moduledoc false

  # Recovery is only for partial display. The loop validates the original JSON
  # separately before executing a tool, so repaired previews never authorize it.
  def decode(json, fallback \\ %{}) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> recover(String.trim(json), fallback)
    end
  end

  defp recover(json, fallback) do
    [complete(json), json <> "}", json <> "\"}"]
    |> Enum.uniq()
    |> Enum.find_value(fallback, fn attempt ->
      case Jason.decode(attempt) do
        {:ok, value} when is_map(value) -> value
        _ -> nil
      end
    end)
  end

  defp complete(json) do
    {stack, in_string?, escaped?} =
      json
      |> String.graphemes()
      |> Enum.reduce({[], false, false}, fn
        "\\", {stack, true, false} -> {stack, true, true}
        _char, {stack, true, true} -> {stack, true, false}
        "\"", {stack, in_string?, false} -> {stack, not in_string?, false}
        "{", {stack, false, false} -> {["}" | stack], false, false}
        "[", {stack, false, false} -> {["]" | stack], false, false}
        "}", {["}" | rest], false, false} -> {rest, false, false}
        "]", {["]" | rest], false, false} -> {rest, false, false}
        _char, state -> state
      end)

    IO.iodata_to_binary([json, if(in_string? and not escaped?, do: "\"", else: ""), stack])
  end
end
