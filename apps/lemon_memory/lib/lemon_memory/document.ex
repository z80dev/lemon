defmodule LemonMemory.Document do
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
  Build a `Document` from a finalized run record and its summary.

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

  @doc """
  Build a `Document` directly from its fields, applying the same invariants the
  ingest path relies on.

  Use this when you drive `LemonAgent` yourself and want to record a memory
  without the router's run-record shape that `from_run/4` expects. It differs
  from building the struct by hand in two ways that matter:

    * **Summaries are truncated.** `prompt_summary` and `answer_summary` are
      capped at #{@max_summary_bytes} bytes (on a UTF-8 boundary), exactly as
      `from_run/4` does. Building the struct by hand skips this, silently
      indexing whole transcripts into the FTS table.
    * **Identity is validated.** `session_key` and `agent_id` are required and
      must be non-empty binaries — they are `NOT NULL` in the store and are what
      scope a search, so a missing one is a programming error, not a row the
      store should quietly reject.

  Everything else is defaulted: `doc_id` (a fresh `"mem_"`-prefixed id) and
  `run_id` are generated when absent, `ingested_at_ms` defaults to now,
  `started_at_ms` to `ingested_at_ms`, and `scope` to `:session`.

  Accepts a map or keyword list. Raises `ArgumentError` on a missing or invalid
  required field, or an unknown `scope`.

  ## Examples

      iex> doc = LemonMemory.Document.new(session_key: "agent:demo:main", agent_id: "demo",
      ...>   prompt_summary: "hi", answer_summary: "hello")
      iex> {doc.scope, doc.answer_summary, String.starts_with?(doc.doc_id, "mem_")}
      {:session, "hello", true}
  """
  @spec new(map() | keyword()) :: t()
  def new(fields) when is_list(fields), do: new(Map.new(fields))

  def new(fields) when is_map(fields) do
    now = System.system_time(:millisecond)

    session_key = require_binary(fields, :session_key)
    agent_id = require_binary(fields, :agent_id)
    scope = validate_scope(Map.get(fields, :scope, :session))

    ingested_at_ms = Map.get(fields, :ingested_at_ms) || now

    %__MODULE__{
      doc_id: Map.get(fields, :doc_id) || "mem_#{LemonCore.Id.uuid()}",
      run_id: Map.get(fields, :run_id) || LemonCore.Id.uuid(),
      session_key: session_key,
      agent_id: agent_id,
      workspace_key: str(Map.get(fields, :workspace_key)),
      scope: scope,
      started_at_ms: Map.get(fields, :started_at_ms) || ingested_at_ms,
      ingested_at_ms: ingested_at_ms,
      prompt_summary: truncate(Map.get(fields, :prompt_summary, "")),
      answer_summary: truncate(Map.get(fields, :answer_summary, "")),
      tools_used: Map.get(fields, :tools_used, []),
      provider: str(Map.get(fields, :provider)),
      model: str(Map.get(fields, :model)),
      outcome: Map.get(fields, :outcome, :unknown),
      meta: Map.get(fields, :meta, %{})
    }
  end

  @doc """
  The byte cap `new/1` and `from_run/4` apply to each summary field.
  """
  @spec max_summary_bytes() :: pos_integer()
  def max_summary_bytes, do: @max_summary_bytes

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp require_binary(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "LemonMemory.Document.new/1 requires #{inspect(key)} to be a non-empty " <>
                "string, got: #{inspect(other)}"
    end
  end

  @valid_scopes [:session, :workspace, :agent, :global]

  defp validate_scope(scope) when scope in @valid_scopes, do: scope

  defp validate_scope(other) do
    raise ArgumentError,
          "LemonMemory.Document.new/1 got an unknown scope #{inspect(other)}; " <>
            "expected one of #{inspect(@valid_scopes)}"
  end

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
        {:tool_call, tool} when is_binary(tool) ->
          [tool]

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

  defp truncate(text) when is_binary(text) and byte_size(text) > @max_summary_bytes do
    cut = utf8_safe_boundary(text, @max_summary_bytes)
    binary_part(text, 0, cut) <> "...[truncated]"
  end

  defp truncate(text) when is_binary(text), do: text
  defp truncate(_), do: ""

  # Walk back up to 3 bytes to avoid splitting a multibyte UTF-8 codepoint.
  defp utf8_safe_boundary(binary, pos) when pos > 0 do
    if String.valid?(binary_part(binary, 0, pos)) do
      pos
    else
      utf8_safe_boundary(binary, pos - 1)
    end
  end

  defp utf8_safe_boundary(_, 0), do: 0

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(ref) when is_reference(ref), do: inspect(ref)
  defp normalize_id(id), do: inspect(id)

  defp str(nil), do: nil
  defp str(val) when is_binary(val), do: val
  defp str(val), do: inspect(val)
end
