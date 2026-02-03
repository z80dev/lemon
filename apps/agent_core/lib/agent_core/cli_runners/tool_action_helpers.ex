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
  def complete_action(factory, pending_actions, id, ok, detail, fallback_kind \\ :tool, fallback_title \\ "tool result") do
    case Map.pop(pending_actions, id) do
      {nil, pending_actions} ->
        {event, factory} =
          EventFactory.action_completed(factory, id, fallback_kind, fallback_title, ok, detail: detail)

        {event, factory, pending_actions}

      {action, pending_actions} ->
        detail = Map.merge(action.detail || %{}, detail)

        {event, factory} =
          EventFactory.action_completed(factory, action.id, action.kind, action.title, ok, detail: detail)

        {event, factory, pending_actions}
    end
  end

  @spec normalize_tool_result(any()) :: String.t()
  def normalize_tool_result(nil), do: ""
  def normalize_tool_result(content) when is_binary(content), do: String.slice(content, 0, 200)

  def normalize_tool_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.join("\n")
    |> String.slice(0, 200)
  end

  def normalize_tool_result(content) when is_map(content) do
    Map.get(content, "text", inspect(content))
    |> String.slice(0, 200)
  end

  def normalize_tool_result(content), do: inspect(content) |> String.slice(0, 200)
end
