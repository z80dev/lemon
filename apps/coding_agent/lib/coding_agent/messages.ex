defmodule CodingAgent.Messages do
  @moduledoc """
  Coding-agent message types and their conversion to `LemonAi.Types` messages.

  User, assistant and tool-result messages are the `LemonAi.Types` structs. The
  coding agent adds two of its own:

  - `CustomMessage` - Extension-defined custom messages (async followups, plan
    notices, recalled context carriers)
  - `BranchSummaryMessage` - Summary of an abandoned branch or collapsed checkpoint

  Journal maps (string keys) are turned into these structs only by
  `CodingAgent.Session.MessageSerialization.deserialize_message/1`.
  """

  alias CodingAgent.Session.MessageSerialization

  defmodule CustomMessage do
    @moduledoc "Extension-defined custom message"
    @type content ::
            String.t() | [LemonAi.Types.TextContent.t() | LemonAi.Types.ImageContent.t()]
    @type t :: %__MODULE__{
            role: :custom,
            id: String.t() | nil,
            custom_type: String.t(),
            content: content(),
            display: boolean(),
            details: any(),
            timestamp: integer()
          }
    defstruct role: :custom,
              id: nil,
              custom_type: "",
              content: "",
              display: true,
              details: nil,
              timestamp: 0
  end

  defmodule BranchSummaryMessage do
    @moduledoc "Summary of git branch context"
    @type t :: %__MODULE__{
            role: :branch_summary,
            summary: String.t(),
            timestamp: integer()
          }
    defstruct role: :branch_summary,
              summary: "",
              timestamp: 0
  end

  @type message :: LemonAi.Types.message() | CustomMessage.t() | BranchSummaryMessage.t()

  # ============================================================================
  # Conversion Functions
  # ============================================================================

  @doc """
  Convert a list of agent messages to `LemonAi.Types` messages for a provider.

  ## Conversion Rules

  - `LemonAi.Types` user/assistant/tool-result messages pass through unchanged
  - `CustomMessage` becomes a user message
  - `CustomMessage{custom_type: "async_followup"}` becomes a user message with a provenance wrapper
  - `BranchSummaryMessage` becomes a user message with the fenced summary in `<branch_summary>` tags
  - Journal maps (string keys) go through `MessageSerialization.deserialize_message/1`;
    roles it does not know are dropped, as they are on session restore
  - Atom-keyed user/assistant/tool-result maps become their `LemonAi.Types` equivalents
  """
  @spec to_llm([message() | map()]) :: [LemonAi.Types.message()]
  def to_llm(messages) when is_list(messages) do
    Enum.flat_map(messages, fn message ->
      case convert_to_llm(message) do
        nil -> []
        converted -> [converted]
      end
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp convert_to_llm(nil), do: nil

  # Pass through LemonAi.Types messages unchanged - they're already in LLM format
  defp convert_to_llm(%LemonAi.Types.UserMessage{} = msg), do: msg
  defp convert_to_llm(%LemonAi.Types.AssistantMessage{} = msg), do: msg
  defp convert_to_llm(%LemonAi.Types.ToolResultMessage{} = msg), do: msg

  defp convert_to_llm(%CustomMessage{custom_type: "async_followup"} = msg) do
    %LemonAi.Types.UserMessage{
      role: :user,
      content: format_async_followup_for_llm(msg),
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%CustomMessage{} = msg) do
    %LemonAi.Types.UserMessage{
      role: :user,
      content: msg.content,
      timestamp: msg.timestamp
    }
  end

  defp convert_to_llm(%BranchSummaryMessage{} = msg) do
    # The summary is model-written from attacker-reachable tool output, so it is
    # reinserted fenced as untrusted data with its wrapper tags neutralised.
    summary =
      msg.summary
      |> to_string()
      |> String.replace(~r/<\s*\/?\s*branch_summary\b[^>]*>/i, "[branch_summary tag removed]")
      |> LemonAgent.Security.ExternalContent.wrap_external_content(
        source: :agent,
        include_warning: true
      )

    content = "<branch_summary>\n#{summary}\n</branch_summary>"

    %LemonAi.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: msg.timestamp
    }
  end

  # Journal maps have exactly one deserializer.
  defp convert_to_llm(%{"role" => _} = msg) do
    msg
    |> MessageSerialization.deserialize_message()
    |> convert_to_llm()
  end

  # Atom-keyed maps built in memory by hooks and tests
  defp convert_to_llm(%{role: :user, content: content} = msg) do
    %LemonAi.Types.UserMessage{
      role: :user,
      content: content,
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp convert_to_llm(%{role: :assistant, content: content} = msg) do
    %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: content,
      api: Map.get(msg, :api),
      provider: Map.get(msg, :provider),
      model: Map.get(msg, :model, ""),
      usage: Map.get(msg, :usage),
      stop_reason: Map.get(msg, :stop_reason),
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp convert_to_llm(%{role: :tool_result, content: content} = msg) do
    %LemonAi.Types.ToolResultMessage{
      role: :tool_result,
      tool_call_id: Map.get(msg, :tool_call_id) || Map.get(msg, :tool_use_id, ""),
      tool_name: Map.get(msg, :tool_name, ""),
      content: content,
      # Map-shaped (imported/persisted) tool results never carry trust.
      trust: :untrusted,
      is_error: Map.get(msg, :is_error, false),
      timestamp: Map.get(msg, :timestamp, 0)
    }
  end

  defp format_async_followup_for_llm(%CustomMessage{} = msg) do
    content = custom_text(msg.content)
    fence = markdown_code_fence(content)
    provenance = async_followup_provenance_lines(msg.details)

    Enum.join(
      [
        "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]",
        provenance,
        "---",
        fence,
        content,
        fence
      ],
      "\n"
    )
    |> String.replace("\n\n---", "\n---")
  end

  defp async_followup_provenance_lines(details) when is_map(details) do
    entries =
      case get_detail(details, :async_followups) do
        entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
        _ -> []
      end

    case entries do
      [] -> async_followup_entry_lines(details)
      entries -> Enum.map_join(entries, "\n\n", &async_followup_entry_lines/1)
    end
  end

  defp async_followup_provenance_lines(_details), do: ""

  defp async_followup_entry_lines(details) do
    delivery = get_detail(details, :delivery)
    delivery_receipt = get_detail(details, :delivery_receipt)

    fields =
      [
        {"source", get_detail(details, :source)},
        {"task_id", get_detail(details, :task_id)},
        {"run_id", get_detail(details, :run_id)},
        {"agent_id", get_detail(details, :agent_id)},
        {"session_key", get_detail(details, :session_key)},
        {"delivery", delivery},
        {"requested_delivery", receipt_value(delivery_receipt, :requested_mode)},
        {"actual_delivery", receipt_value(delivery_receipt, :actual_mode) || delivery},
        {"delivery_status", receipt_value(delivery_receipt, :status)},
        {"fallback_delivery", receipt_value(delivery_receipt, :fallback_mode)},
        {"active_run_id", receipt_value(delivery_receipt, :active_run_id)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {key, value} -> "#{key}: #{format_provenance_value(value)}" end)

    Enum.join(fields, "\n")
  end

  defp get_detail(details, key) do
    Map.get(details, key) || Map.get(details, Atom.to_string(key))
  end

  defp receipt_value(receipt, key) when is_map(receipt) do
    Map.get(receipt, key) || Map.get(receipt, Atom.to_string(key))
  end

  defp receipt_value(_receipt, _key), do: nil

  defp format_provenance_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_provenance_value(value) when is_binary(value), do: value
  defp format_provenance_value(value), do: inspect(value, limit: 20)

  defp markdown_code_fence(content) when is_binary(content) do
    max_backticks =
      Regex.scan(~r/`+/, content)
      |> Enum.reduce(0, fn [run], longest -> max(longest, String.length(run)) end)

    String.duplicate("`", max(3, max_backticks + 1))
  end

  defp custom_text(content) when is_binary(content), do: content

  defp custom_text(content) when is_list(content) do
    Enum.map_join(content, "", fn
      %{type: :text, text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp custom_text(_content), do: ""
end
