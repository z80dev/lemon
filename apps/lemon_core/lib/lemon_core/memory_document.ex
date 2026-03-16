defmodule LemonCore.MemoryDocument do
  @moduledoc """
  Normalized memory document extracted from a finalized run.

  A memory document captures the key facts about a run in a compact, searchable
  form, separate from the full conversation payload stored in `RunHistoryStore`.

  ## Fields

  - `:doc_id` - Unique document identifier (prefixed `"mem_"`)
  - `:run_id` - Source run ID
  - `:session_key` - Session the run belongs to
  - `:agent_id` - Agent that executed the run
  - `:workspace_key` - Workspace the run was executed in (nil if unknown)
  - `:scope` - Memory scope: `:session`, `:workspace`, `:agent`, or `:global`
  - `:started_at_ms` - Run start timestamp in milliseconds
  - `:ingested_at_ms` - When this document was written to the memory store
  - `:prompt_summary` - Truncated prompt text (for FTS)
  - `:answer_summary` - Truncated answer text (for FTS)
  - `:tools_used` - List of tool name strings used during the run
  - `:provider` - LLM provider name (e.g. `"anthropic"`)
  - `:model` - LLM model name (e.g. `"claude-opus-4-6"`)
  - `:outcome` - Outcome label inferred by `LemonCore.RunOutcome.infer/1`
  - `:meta` - Arbitrary metadata map

  ## Scopes

  The four memory scopes follow `docs/assistant_bootstrap_contract.md`:

  | Scope       | Lifetime              | Key field used          |
  |-------------|-----------------------|-------------------------|
  | `:session`  | Single agent run      | `session_key`           |
  | `:workspace`| Workspace lifetime    | `workspace_key`         |
  | `:agent`    | Agent lifetime        | `agent_id`              |
  | `:global`   | Installation lifetime | none (all documents)    |
  """

  @max_summary_bytes 2_000

  @type scope :: :session | :workspace | :agent | :global
  @type outcome :: :unknown | :success | :partial | :failure | :aborted

  @type t :: %__MODULE__{
          doc_id: binary(),
          run_id: binary(),
          session_key: binary(),
          agent_id: binary(),
          workspace_key: binary() | nil,
          scope: scope(),
          started_at_ms: integer(),
          ingested_at_ms: integer(),
          prompt_summary: binary(),
          answer_summary: binary(),
          tools_used: [binary()],
          provider: binary() | nil,
          model: binary() | nil,
          outcome: outcome(),
          meta: map()
        }

  defstruct doc_id: nil,
            run_id: nil,
            session_key: nil,
            agent_id: nil,
            workspace_key: nil,
            scope: :session,
            started_at_ms: 0,
            ingested_at_ms: 0,
            prompt_summary: "",
            answer_summary: "",
            tools_used: [],
            provider: nil,
            model: nil,
            outcome: :unknown,
            meta: %{}

  @doc """
  Build a `MemoryDocument` from a finalized run record and its summary.

  Extracts normalized fields from the run summary. Unknown or missing fields
  are replaced with safe defaults so ingest never raises.
  """
  @spec from_run(run_id :: term(), record :: map(), summary :: map(), opts :: keyword()) :: t()
  def from_run(run_id, record, summary, opts \\ []) do
    now = System.system_time(:millisecond)
    run_id_str = normalize_id(run_id)
    session_key = str(Map.get(summary, :session_key))
    agent_id = str(Map.get(summary, :agent_id)) || parse_agent_id(session_key)
    workspace_key = str(Map.get(summary, :workspace_key) || Map.get(summary, :cwd))
    scope = opts[:scope] || infer_scope(workspace_key)

    prompt_summary = extract_prompt(summary)
    answer_summary = extract_answer(summary)
    tools_used = extract_tools(record)
    {provider, model} = extract_model(summary)

    %__MODULE__{
      doc_id: "mem_#{LemonCore.Id.uuid()}",
      run_id: run_id_str,
      session_key: session_key,
      agent_id: agent_id,
      workspace_key: workspace_key,
      scope: scope,
      started_at_ms: record[:started_at] || now,
      ingested_at_ms: now,
      prompt_summary: truncate(prompt_summary),
      answer_summary: truncate(answer_summary),
      tools_used: tools_used,
      provider: provider,
      model: model,
      outcome: LemonCore.RunOutcome.infer(summary),
      meta: Map.get(summary, :meta) || %{}
    }
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp extract_prompt(summary) do
    str(Map.get(summary, :prompt)) || ""
  end

  defp extract_answer(summary) do
    completed = Map.get(summary, :completed) || %{}
    str(Map.get(completed, :answer) || Map.get(completed, "answer")) || ""
  end

  defp extract_tools(%{events: events}) when is_list(events) do
    events
    |> Enum.flat_map(fn event ->
      case {Map.get(event, :type), Map.get(event, :tool)} do
        {:tool_call, tool} when is_binary(tool) -> [tool]
        _ ->
          case Map.get(event, "type") do
            "tool_call" -> [str(Map.get(event, "tool")) || "unknown"]
            _ -> []
          end
      end
    end)
    |> Enum.uniq()
  end

  defp extract_tools(_), do: []

  defp extract_model(summary) do
    provider = str(Map.get(summary, :provider) || get_in(summary, [:meta, :provider]))
    model = str(Map.get(summary, :model) || get_in(summary, [:meta, :model]))
    {provider, model}
  end

  defp infer_scope(nil), do: :session
  defp infer_scope(_workspace_key), do: :workspace

  defp parse_agent_id(nil), do: "default"
  defp parse_agent_id(""), do: "default"

  defp parse_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      _ -> "default"
    end
  end

  defp parse_agent_id(_), do: "default"

  defp truncate(text) when is_binary(text) and byte_size(text) > @max_summary_bytes do
    binary_part(text, 0, @max_summary_bytes) <> "...[truncated]"
  end

  defp truncate(text) when is_binary(text), do: text
  defp truncate(_), do: ""

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(ref) when is_reference(ref), do: inspect(ref)
  defp normalize_id(id), do: inspect(id)

  defp str(nil), do: nil
  defp str(val) when is_binary(val), do: val
  defp str(val), do: inspect(val)
end
