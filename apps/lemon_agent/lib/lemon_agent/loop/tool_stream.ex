defmodule LemonAgent.Loop.ToolStream do
  @moduledoc false

  # Drives `AgentTool.on_stream` for the loop process. Every call that received
  # an `:args` event is remembered here until `settle/0` sends it `:settle`.
  # The loop settles at the start of each model request (calls from a discarded
  # attempt or an earlier turn are never executed), after a turn's tool calls
  # finish, and when the loop task exits.

  require Logger

  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Types.AgentTool
  alias LemonAi.Types.{AssistantMessage, ToolCall}

  @open {__MODULE__, :open}

  @spec observe(term(), %{optional(non_neg_integer()) => String.t()}, [AgentTool.t()], term()) ::
          :ok
  def observe(
        {:tool_call_delta, index, _delta, %AssistantMessage{content: content}},
        raw_arguments,
        tools,
        signal
      )
      when is_list(content) do
    with [_ | _] = streaming <- Enum.filter(tools, &is_function(&1.on_stream, 1)),
         %ToolCall{id: id, name: name} when is_binary(id) and id != "" <- Enum.at(content, index),
         json when is_binary(json) <- Map.get(raw_arguments, index),
         %AgentTool{on_stream: on_stream} = tool <- find_tool(streaming, name) do
      Process.put(@open, Map.put(Process.get(@open, %{}), id, on_stream))

      notify(
        on_stream,
        {:args,
         %{
           id: id,
           json: json,
           signal: signal,
           prepare: &ToolCalls.prepare_arguments(tool, &1)
         }}
      )
    else
      _ -> :ok
    end
  end

  def observe(_event, _raw_arguments, _tools, _signal), do: :ok

  @spec settle() :: :ok
  def settle do
    case Process.delete(@open) do
      nil -> :ok
      open -> Enum.each(open, fn {id, on_stream} -> notify(on_stream, {:settle, id}) end)
    end
  end

  # Only tools with a callback are matched, so ordinary tool calls cost no
  # name normalization per delta.
  defp find_tool(streaming, name) do
    normalized = ToolCalls.normalize_tool_name(name)

    normalized &&
      Enum.find(streaming, &(ToolCalls.normalize_tool_name(&1.name) == normalized))
  end

  # A failing observer never fails the model request; its own settle still runs.
  defp notify(on_stream, event) do
    on_stream.(event)
    :ok
  rescue
    exception ->
      Logger.warning("Tool stream callback failed: #{inspect(exception.__struct__)}")
      :ok
  catch
    kind, _reason ->
      Logger.warning("Tool stream callback failed: #{inspect(kind)}")
      :ok
  end
end
