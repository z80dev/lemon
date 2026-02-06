defmodule LemonRouter.ToolPreview do
  @moduledoc false

  # A small normalization layer for rendering tool results into human-readable text.
  #
  # Rationale:
  # Tool/action events can carry rich Elixir structs (e.g. AgentToolResult, TextContent),
  # and some paths end up converting them to inspected strings. For user-facing
  # transports like Telegram, we want to show the underlying text, not the struct.

  @spec to_text(term()) :: String.t() | nil
  def to_text(nil), do: nil

  def to_text(text) when is_binary(text) do
    # Best-effort cleanup when we already have an inspected struct string.
    cleaned = extract_text_from_inspected_struct(text)

    cond do
      is_binary(cleaned) and cleaned != "" -> cleaned
      true -> text
    end
  end

  def to_text(%AgentCore.Types.AgentToolResult{} = result) do
    if Code.ensure_loaded?(AgentCore) do
      AgentCore.get_text(result)
    else
      inspect(result)
    end
  rescue
    _ -> inspect(result)
  end

  def to_text(%Ai.Types.TextContent{text: text}) when is_binary(text), do: text

  def to_text(content) when is_list(content) do
    content
    |> Enum.map(&to_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  def to_text(content) when is_map(content) do
    cond do
      is_binary(Map.get(content, :text)) ->
        Map.get(content, :text)

      is_binary(Map.get(content, "text")) ->
        Map.get(content, "text")

      Map.has_key?(content, :content) ->
        to_text(Map.get(content, :content))

      Map.has_key?(content, "content") ->
        to_text(Map.get(content, "content"))

      true ->
        inspect(content)
    end
  end

  def to_text(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # If `text` is an `inspect/1` output of AgentToolResult/TextContent, extract the
  # nested `text: "..."` fields without evaluating Elixir code.
  defp extract_text_from_inspected_struct(text) when is_binary(text) do
    if String.contains?(text, "%AgentCore.Types.AgentToolResult{") or
         String.contains?(text, "%Ai.Types.TextContent{") do
      texts =
        Regex.scan(~r/\btext:\s*"((?:\\.|[^"\\])*)"/s, text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&unescape_elixir_inspect_string/1)
        |> Enum.reject(&(&1 == ""))

      case texts do
        [] -> nil
        list -> Enum.join(list, "\n")
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  # Elixir's inspect escapes common sequences inside quotes (e.g. \n, \t, \").
  # This is a minimal unescaper to get readable output.
  defp unescape_elixir_inspect_string(str) when is_binary(str) do
    str
    |> String.replace("\\\\", "\\")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
  end
end

