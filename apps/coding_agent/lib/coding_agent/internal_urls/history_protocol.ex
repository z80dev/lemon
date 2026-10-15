defmodule CodingAgent.InternalUrls.HistoryProtocol do
  @moduledoc "Concise, bounded visible transcripts of owned child tasks. Never includes hidden reasoning."
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Control, Result}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  def read("history://" <> task_id, opts) do
    with true <- elem(Control.owner(opts), 0) != nil,
         :ok <- Control.authorize(task_id, opts),
         {:ok, record, events} <- TaskStore.get(task_id) do
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

      truncated? = String.length(text) > 12_000

      text =
        String.slice(text, 0, 12_000) <> if(truncated?, do: "\n[History truncated.]", else: "")

      %AgentToolResult{
        content: [%TextContent{text: text}],
        details: %{task_id: task_id, truncated: truncated?}
      }
      |> ToolResultTrust.untrusted(:local_file)
    else
      _ -> {:error, "Unknown or unowned child task"}
    end
  end

  defp visible_result(%AgentToolResult{} = result), do: Result.visible_output_text(result)
  defp visible_result(result) when is_binary(result), do: Result.visible_output_text(result)
  defp visible_result(%{answer: answer}) when is_binary(answer), do: answer
  defp visible_result(%{"answer" => answer}) when is_binary(answer), do: answer
  defp visible_result(_), do: ""
end
