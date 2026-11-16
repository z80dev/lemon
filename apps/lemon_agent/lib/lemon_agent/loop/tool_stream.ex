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
  alias LemonAi.Types.ToolCall

  @open {__MODULE__, :open}
  @calls {__MODULE__, :calls}

  @spec observe(term(), %{optional(non_neg_integer()) => [binary()]}, [AgentTool.t()], term()) ::
          :ok
  def observe({:tool_call_start, index, %ToolCall{} = call}, _raw_arguments, tools, _signal) do
    streaming = Enum.filter(tools, &is_function(&1.on_stream, 1))

    calls = Process.get(@calls, %{})

    calls =
      case find_tool(streaming, call.name) do
        nil -> Map.delete(calls, index)
        tool -> Map.put(calls, index, {call, tool})
      end

    Process.put(@calls, calls)

    :ok
  end

  def observe(
        {:tool_call_delta, index, _delta},
        raw_arguments,
        _tools,
        signal
      ) do
    with {%ToolCall{id: id}, %AgentTool{on_stream: on_stream} = tool}
         when is_binary(id) and id != "" <- Map.get(Process.get(@calls, %{}), index),
         chunks when is_list(chunks) <- Map.get(raw_arguments, index) do
      json = chunks |> Enum.reverse() |> IO.iodata_to_binary()
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
    Process.delete(@calls)

    case Process.delete(@open) do
      nil -> :ok
      open -> Enum.each(open, fn {id, on_stream} -> notify(on_stream, {:settle, id}) end)
    end
  end

  # Only tools with a callback are matched, so ordinary tool calls cost no
  # name normalization per delta.
  defp find_tool([], _name), do: nil

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
