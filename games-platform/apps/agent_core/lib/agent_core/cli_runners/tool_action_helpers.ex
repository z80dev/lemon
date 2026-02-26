defmodule AgentCore.CliRunners.ToolActionHelpers do
  @moduledoc """
  Shared helpers for translating tool calls and tool results into action events.

  This module provides a small abstraction for managing pending tool actions
  and normalizing tool output across CLI runners (e.g., Claude, Kimi).
  """

  alias AgentCore.CliRunners.Types.EventFactory

  @spec start_action(EventFactory.t(), map(), String.t(), atom(), String.t(), map()) ::
          {AgentCore.CliRunners.Types.ActionEvent.t(), EventFactory.t(), map()}
  def start_action(factory, pending_actions, id, kind, title, detail) do
    {event, factory} = EventFactory.action_started(factory, id, kind, title, detail: detail)

    action = %{
      id: id,
      kind: kind,
      title: title,
      detail: detail
    }

    pending_actions = Map.put(pending_actions, id, action)

    {event, factory, pending_actions}
  end

  @spec complete_action(EventFactory.t(), map(), String.t(), boolean(), map(), atom(), String.t()) ::
          {AgentCore.CliRunners.Types.ActionEvent.t(), EventFactory.t(), map()}
  def complete_action(
        factory,
        pending_actions,
        id,
        ok,
        detail,
        fallback_kind \\ :tool,
        fallback_title \\ "tool result"
      ) do
    case Map.pop(pending_actions, id) do
      {nil, pending_actions} ->
        {event, factory} =
          EventFactory.action_completed(factory, id, fallback_kind, fallback_title, ok,
            detail: detail
          )

        {event, factory, pending_actions}

      {action, pending_actions} ->
        detail = Map.merge(action.detail || %{}, detail)

        {event, factory} =
          EventFactory.action_completed(factory, action.id, action.kind, action.title, ok,
            detail: detail
          )

        {event, factory, pending_actions}
    end
  end

  @spec normalize_tool_result(any()) :: String.t()
  def normalize_tool_result(nil), do: ""
  def normalize_tool_result(content) when is_binary(content), do: String.slice(content, 0, 200)

  # Internal tool result (e.g. Codex tool executor) should display as plain text,
  # not as `%AgentCore.Types.AgentToolResult{...}` / `%Ai.Types.TextContent{...}` structs.
  def normalize_tool_result(%AgentCore.Types.AgentToolResult{} = result) do
    result
    |> AgentCore.get_text()
    |> String.slice(0, 200)
  end

  def normalize_tool_result(%Ai.Types.TextContent{text: text}) when is_binary(text),
    do: String.slice(text, 0, 200)

  def normalize_tool_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %Ai.Types.TextContent{text: text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> String.slice(0, 200)
  end

  def normalize_tool_result(content) when is_map(content) do
    text =
      cond do
        is_binary(Map.get(content, "text")) ->
          Map.get(content, "text")

        is_binary(Map.get(content, :text)) ->
          Map.get(content, :text)

        is_list(Map.get(content, "content")) ->
          normalize_tool_result(Map.get(content, "content"))

        is_list(Map.get(content, :content)) ->
          normalize_tool_result(Map.get(content, :content))

        true ->
          inspect(content)
      end

    String.slice(text, 0, 200)
  end

  def normalize_tool_result(content), do: inspect(content) |> String.slice(0, 200)

  # ============================================================================
  # Shared tool classification helpers
  # ============================================================================

  @typedoc "Kind of action for UI display"
  @type action_kind :: :command | :file_change | :tool | :web_search | :subagent

  @doc """
  Classify a tool call into a kind and human-readable title.

  ## Options

  - `:path_keys` - list of map keys to search for file paths (required)
  - `:cwd` - working directory for relativizing paths
  """
  @spec tool_kind_and_title(String.t(), map(), keyword()) :: {action_kind(), String.t()}
  def tool_kind_and_title(name, input, opts) do
    name_lower = name |> to_string() |> String.downcase()
    cwd = Keyword.get(opts, :cwd)
    path_keys = Keyword.fetch!(opts, :path_keys)

    cond do
      name_lower in ["bash", "shell", "killshell"] ->
        command = Map.get(input, "command") || Map.get(input, "cmd") || name
        {:command, String.slice(to_string(command), 0, 80)}

      name_lower in ["edit", "write", "multiedit", "notebookedit"] ->
        path = tool_input_path(input, path_keys)
        title = if path, do: maybe_relativize_path(path, cwd), else: name
        {:file_change, title}

      name_lower == "read" ->
        path = tool_input_path(input, path_keys)
        if path, do: {:tool, "read: `#{maybe_relativize_path(path, cwd)}`"}, else: {:tool, "read"}

      name_lower == "glob" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "glob: `#{pattern}`"}, else: {:tool, "glob"}

      name_lower == "grep" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "grep: #{pattern}"}, else: {:tool, "grep"}

      name_lower == "find" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "find: #{pattern}"}, else: {:tool, "find"}

      name_lower == "ls" ->
        path = tool_input_path(input, path_keys)
        if path, do: {:tool, "ls: `#{maybe_relativize_path(path, cwd)}`"}, else: {:tool, "ls"}

      name_lower in ["websearch", "web_search"] ->
        query = Map.get(input, "query")
        {:web_search, to_string(query || "search")}

      name_lower in ["webfetch", "web_fetch"] ->
        url = Map.get(input, "url")
        {:web_search, to_string(url || "fetch")}

      name_lower in ["task", "agent"] ->
        desc = Map.get(input, "description") || Map.get(input, "prompt")
        {:subagent, to_string(desc || name)}

      true ->
        {:tool, name}
    end
  end

  @doc "Convert atom keys to string keys in a map (shallow)."
  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc "Find the first non-empty string value for any of the given keys."
  @spec tool_input_path(map(), [String.t()]) :: String.t() | nil
  def tool_input_path(input, keys) when is_map(input) do
    Enum.find_value(keys, fn k ->
      v = Map.get(input, k)
      if is_binary(v) and v != "", do: v, else: nil
    end)
  end

  def tool_input_path(_input, _keys), do: nil

  @doc "Make an absolute path relative to `cwd` when possible."
  @spec maybe_relativize_path(String.t(), String.t() | nil) :: String.t()
  def maybe_relativize_path(path, nil), do: path

  def maybe_relativize_path(path, cwd) when is_binary(path) and is_binary(cwd) do
    expanded_path = Path.expand(path)
    expanded_cwd = Path.expand(cwd)

    try do
      rel = Path.relative_to(expanded_path, expanded_cwd)
      if String.starts_with?(rel, ".."), do: path, else: rel
    rescue
      _ -> path
    end
  end

  def maybe_relativize_path(path, _cwd), do: path
end
