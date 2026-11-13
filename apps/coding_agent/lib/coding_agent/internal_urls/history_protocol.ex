defmodule CodingAgent.InternalUrls.HistoryProtocol do
  @moduledoc "Concise, bounded visible transcripts of owned child tasks. Never includes hidden reasoning."
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Control, Result}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @max_chars 12_000

  def read("history://" <> task_id, opts) do
    with true <- elem(Control.owner(opts), 0) != nil,
         :ok <- Control.authorize(task_id, opts),
         {:ok, record, events} <- TaskStore.get(task_id) do
      {text, truncated?} = render(task_id, record, events)

      %AgentToolResult{
        content: [%TextContent{text: text}],
        details: %{task_id: task_id, truncated: truncated?}
      }
      |> ToolResultTrust.untrusted(:local_file)
    else
      _ -> {:error, "Unknown or unowned child task"}
    end
  end

  @doc """
  The bounded visible transcript of one task record: status, assignment, the
  last ten distinct visible updates and the final result. Callers authorize the
  task first. Returns `{text, truncated?}`.
  """
  @spec render(String.t(), map(), list()) :: {String.t(), boolean()}
  def render(task_id, record, events) do
    updates =
      events
      |> Enum.filter(&match?(%AgentToolResult{}, &1))
      |> Enum.map(&Result.visible_output_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.dedup()
      |> Enum.take(-10)

    final = visible_result(record[:result])
    sections = Enum.dedup(updates ++ if(final == "", do: [], else: [final]))

    text =
      "# Task #{task_id}\nStatus: #{record[:status]}\nAssignment: #{record[:description]}\n\n" <>
        Enum.join(sections, "\n\n")

    truncated? = String.length(text) > @max_chars

    {String.slice(text, 0, @max_chars) <> if(truncated?, do: "\n[History truncated.]", else: ""),
     truncated?}
  end

  defp visible_result(%AgentToolResult{} = result), do: Result.visible_output_text(result)
  defp visible_result(result) when is_binary(result), do: Result.visible_output_text(result)
  defp visible_result(%{answer: answer}) when is_binary(answer), do: answer
  defp visible_result(%{"answer" => answer}) when is_binary(answer), do: answer
  defp visible_result(_), do: ""
end
