defmodule CodingAgent.Tools.ParentQuestion do
  @moduledoc """
  Tool for listing and answering open clarification requests from spawned
  subagents.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.ParentQuestions

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "parent_question",
      description:
        "List or answer clarification requests raised by spawned subagents. " <>
          "Use this when a child asks for a decision before it can continue.",
      label: "Parent Questions",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["list", "answer"],
            "description" => "Whether to list open questions or answer one."
          },
          "request_id" => %{
            "type" => "string",
            "description" => "Question request id when action=answer."
          },
          "answer" => %{
            "type" => "string",
            "description" => "Answer text when action=answer."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          keyword()
        ) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case normalize_action(Map.get(params, "action")) do
        "answer" -> answer_question(params, opts)
        _ -> list_questions(opts)
      end
    end
  end

  defp list_questions(opts) do
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)

    requests =
      ParentQuestions.list(
        status: :waiting,
        parent_session_key: session_key,
        parent_agent_id: agent_id
      )

    text =
      case requests do
        [] ->
          "No open subagent questions."

        _ ->
          Enum.map_join(requests, "\n\n", fn {request_id, record} ->
            options_text =
              case record.options do
                [] -> ""
                options -> "\nOptions: " <> Enum.join(options, " | ")
              end

            recommended_text =
              if is_binary(record.recommended_option) and record.recommended_option != "" do
                "\nRecommended: #{record.recommended_option}"
              else
                ""
              end

            "[#{request_id}] #{record.question}\nBlocked because: #{record.why_blocked}#{options_text}#{recommended_text}"
          end)
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        status: "completed",
        requests:
          Enum.map(requests, fn {request_id, record} ->
            %{
              request_id: request_id,
              question: record.question,
              why_blocked: record.why_blocked,
              options: record.options,
              recommended_option: record.recommended_option,
              child_run_id: record.child_run_id,
              task_id: record.task_id
            }
          end)
      }
    }
  end

  defp answer_question(params, opts) do
    request_id = normalize_string(Map.get(params, "request_id"))
    answer = normalize_string(Map.get(params, "answer"))

    cond do
      is_nil(request_id) ->
        {:error, "request_id is required for action=answer"}

      is_nil(answer) ->
        {:error, "answer is required for action=answer"}

      true ->
        with :ok <-
               ParentQuestions.answer(
                 request_id,
                 answer,
                 session_key: Keyword.get(opts, :session_key),
                 agent_id: Keyword.get(opts, :agent_id)
               ),
             {:ok, record, _events} <- ParentQuestions.get(request_id) do
          %AgentToolResult{
            content: [%TextContent{text: "Answered subagent question #{request_id}."}],
            details: %{
              status: "completed",
              request_id: request_id,
              question: record.question,
              child_run_id: record.child_run_id,
              task_id: record.task_id
            }
          }
        else
          {:error, :not_found} ->
            {:error, "Unknown request_id: #{request_id}"}

          {:error, :wrong_session} ->
            {:error, "Request #{request_id} does not belong to this session"}

          {:error, {:invalid_status, status}} ->
            {:error, "Request #{request_id} is already #{status}"}

          {:error, reason} ->
            {:error, "Failed to answer request #{request_id}: #{inspect(reason)}"}
        end
    end
  end

  defp normalize_action(nil), do: "list"

  defp normalize_action(action) when is_binary(action),
    do: action |> String.trim() |> String.downcase()

  defp normalize_action(_), do: "list"

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
