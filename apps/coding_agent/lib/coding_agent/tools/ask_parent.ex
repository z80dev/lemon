defmodule CodingAgent.Tools.AskParent do
  @moduledoc """
  Child-only tool for escalating a clarification request to the parent session.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.ParentQuestions
  alias LemonCore.Bus

  @default_timeout_ms 300_000
  @poll_slice_ms 250

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "ask_parent",
      description:
        "Ask the parent session a focused clarification question when you are blocked on a decision. " <>
          "Use this only for decisions or constraints you cannot safely infer yourself. " <>
          "Do not use it for routine exploration, status updates, or chatter.",
      label: "Ask Parent",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "question" => %{
            "type" => "string",
            "description" => "Concrete question for the parent."
          },
          "why_blocked" => %{
            "type" => "string",
            "description" => "Why you cannot safely proceed without input."
          },
          "options" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional mutually exclusive choices."
          },
          "recommended_option" => %{
            "type" => "string",
            "description" => "Optional recommended option."
          },
          "can_continue_without_answer" => %{
            "type" => "boolean",
            "description" =>
              "Whether you may continue with a fallback if the parent does not answer."
          },
          "fallback" => %{
            "type" => "string",
            "description" => "What you will do if the parent does not answer before timeout."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "How long to wait for an answer before timing out."
          }
        },
        "required" => ["question", "why_blocked"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          keyword()
        ) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, _cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, validated} <- validate_params(params),
           {:ok, context} <- validate_context(opts),
           {:ok, request} <- create_request(validated, context),
           :ok <- notify_parent(request, context) do
        await_and_build_result(request.id, validated, signal)
      end
    end
  end

  defp validate_params(params) do
    question = normalize_string(Map.get(params, "question"))
    why_blocked = normalize_string(Map.get(params, "why_blocked"))
    recommended_option = normalize_string(Map.get(params, "recommended_option"))
    fallback = normalize_string(Map.get(params, "fallback"))
    timeout_ms = Map.get(params, "timeout_ms", @default_timeout_ms)
    options = normalize_options(Map.get(params, "options"))
    can_continue_without_answer = Map.get(params, "can_continue_without_answer", false)

    cond do
      is_nil(question) ->
        {:error, "question is required"}

      is_nil(why_blocked) ->
        {:error, "why_blocked is required"}

      not is_integer(timeout_ms) or timeout_ms < 0 ->
        {:error, "timeout_ms must be a non-negative integer"}

      not is_boolean(can_continue_without_answer) ->
        {:error, "can_continue_without_answer must be a boolean"}

      can_continue_without_answer and is_nil(fallback) ->
        {:error, "fallback is required when can_continue_without_answer is true"}

      true ->
        {:ok,
         %{
           question: question,
           why_blocked: why_blocked,
           options: options,
           recommended_option: recommended_option,
           can_continue_without_answer: can_continue_without_answer,
           fallback: fallback,
           timeout_ms: timeout_ms
         }}
    end
  end

  defp validate_context(opts) do
    parent_session_module = Keyword.get(opts, :parent_session_module, CodingAgent.Session)
    parent_session_pid = Keyword.get(opts, :parent_session_pid)
    parent_session_key = Keyword.get(opts, :parent_session_key)
    parent_agent_id = Keyword.get(opts, :parent_agent_id)
    parent_run_id = Keyword.get(opts, :parent_run_id)
    child_run_id = Keyword.get(opts, :child_run_id)
    child_scope_id = Keyword.get(opts, :child_scope_id)
    task_id = Keyword.get(opts, :task_id)
    description = Keyword.get(opts, :task_description)

    cond do
      not is_binary(child_scope_id) or child_scope_id == "" ->
        {:error, "ask_parent is unavailable outside a spawned child task"}

      not is_pid(parent_session_pid) or not Process.alive?(parent_session_pid) ->
        {:error, "Parent session is unavailable"}

      not function_exported?(parent_session_module, :follow_up, 2) ->
        {:error, "Parent session does not support follow_up/2"}

      true ->
        {:ok,
         %{
           parent_session_module: parent_session_module,
           parent_session_pid: parent_session_pid,
           parent_session_key: parent_session_key,
           parent_agent_id: parent_agent_id,
           parent_run_id: parent_run_id,
           child_run_id: child_run_id,
           child_scope_id: child_scope_id,
           task_id: task_id,
           description: description
         }}
    end
  end

  defp create_request(validated, context) do
    ParentQuestions.request(%{
      description: context.description,
      parent_run_id: context.parent_run_id,
      child_run_id: context.child_run_id,
      child_scope_id: context.child_scope_id,
      task_id: context.task_id,
      parent_session_key: context.parent_session_key,
      parent_agent_id: context.parent_agent_id,
      question: validated.question,
      why_blocked: validated.why_blocked,
      options: validated.options,
      recommended_option: validated.recommended_option,
      can_continue_without_answer: validated.can_continue_without_answer,
      fallback: validated.fallback,
      timeout_ms: validated.timeout_ms,
      meta: %{}
    })
  end

  defp notify_parent(request, context) do
    text = build_parent_follow_up_text(request)

    case context.parent_session_module.follow_up(context.parent_session_pid, text) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = ParentQuestions.fail(request.id, reason)
        {:error, "Failed to send question to parent: #{inspect(reason)}"}

      other ->
        _ = ParentQuestions.fail(request.id, {:unexpected_follow_up_result, other})
        {:error, "Failed to send question to parent"}
    end
  rescue
    error ->
      _ = ParentQuestions.fail(request.id, error)
      {:error, "Failed to send question to parent: #{inspect(error)}"}
  end

  defp await_and_build_result(request_id, validated, signal) do
    case await_resolution(request_id, validated.timeout_ms, signal) do
      {:ok, %{status: :answered} = record} ->
        %AgentToolResult{
          content: [
            %TextContent{
              text: "Parent answer for request #{request_id}:\n\n#{record.answer}"
            }
          ],
          details: %{
            request_id: request_id,
            status: "answered",
            parent_run_id: record.parent_run_id,
            child_run_id: record.child_run_id,
            task_id: record.task_id,
            answered: true,
            timed_out: false
          }
        }

      {:ok, %{status: :timed_out} = record} ->
        if validated.can_continue_without_answer do
          %AgentToolResult{
            content: [
              %TextContent{
                text:
                  "Parent question #{request_id} timed out. Continue with fallback:\n\n#{record.fallback}"
              }
            ],
            details: %{
              request_id: request_id,
              status: "timed_out",
              parent_run_id: record.parent_run_id,
              child_run_id: record.child_run_id,
              task_id: record.task_id,
              answered: false,
              timed_out: true
            }
          }
        else
          {:error, "Parent question #{request_id} timed out before an answer arrived"}
        end

      {:ok, %{status: :error, error: error}} ->
        {:error, "Parent question failed: #{error}"}

      {:ok, %{status: :cancelled, error: error}} ->
        {:error, "Parent question was cancelled: #{error}"}

      {:error, :aborted} ->
        {:error, "Operation aborted"}

      {:error, reason} ->
        {:error, "Failed waiting for parent answer: #{inspect(reason)}"}
    end
  end

  defp await_resolution(request_id, timeout_ms, signal) do
    topic = ParentQuestions.request_topic(request_id)
    :ok = Bus.subscribe(topic)

    try do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      do_await(request_id, deadline, signal)
    after
      _ = Bus.unsubscribe(topic)
    end
  end

  defp do_await(request_id, deadline, signal) do
    cond do
      AbortSignal.aborted?(signal) ->
        _ = ParentQuestions.cancel(request_id, :aborted)
        {:error, :aborted}

      true ->
        case ParentQuestions.get(request_id) do
          {:ok, %{status: status} = record, _events}
          when status in [:answered, :timed_out, :cancelled, :error] ->
            {:ok, record}

          {:ok, _record, _events} ->
            remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

            if remaining_ms == 0 do
              _ = ParentQuestions.timeout(request_id)

              case ParentQuestions.get(request_id) do
                {:ok, record, _events} -> {:ok, record}
                error -> error
              end
            else
              receive do
                %LemonCore.Event{meta: %{request_id: ^request_id}} ->
                  do_await(request_id, deadline, signal)

                _other ->
                  do_await(request_id, deadline, signal)
              after
                min(remaining_ms, @poll_slice_ms) ->
                  do_await(request_id, deadline, signal)
              end
            end

          error ->
            error
        end
    end
  end

  defp build_parent_follow_up_text(request) do
    options_text =
      case request.options do
        [] ->
          ""

        options ->
          "\nOptions:\n" <>
            Enum.map_join(options, "\n", fn option -> "- #{option}" end)
      end

    recommended_text =
      if is_binary(request.recommended_option) and request.recommended_option != "" do
        "\nRecommended: #{request.recommended_option}"
      else
        ""
      end

    description_text =
      if is_binary(request.description) and request.description != "" do
        "Child task: #{request.description}\n"
      else
        ""
      end

    """
    [subagent question #{request.id}]
    #{description_text}Blocked because: #{request.why_blocked}
    Question: #{request.question}#{options_text}#{recommended_text}

    Use the `parent_question` tool with `action=\"answer\"`, `request_id=\"#{request.id}\"`, and your answer text.
    """
    |> String.trim()
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp normalize_options(options) when is_list(options) do
    options
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_options(_), do: []
end
