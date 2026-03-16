defmodule LemonCore.TaskFingerprint do
  @moduledoc """
  Coarse task fingerprint derived from a finalized run.

  A fingerprint groups runs by the dimensions that matter for routing decisions:
  what the user was trying to do (`:task_family`), which tools were involved,
  which workspace the run belonged to, and which model/provider served it.

  Fingerprints are intentionally coarse — granular enough to accumulate signal
  across similar runs, but not so specific that each run gets its own bucket.

  ## Fields

  - `:task_family` — broad semantic category of the task (see "Task families" below)
  - `:toolset` — sorted unique list of tool names used during the run
  - `:workspace_key` — workspace identifier, or `nil` for session-scoped runs
  - `:model` — LLM model name, or `nil` if unknown
  - `:provider` — LLM provider name, or `nil` if unknown

  ## Task families

  | Family       | Signals |
  |--------------|---------|
  | `:code`      | Implement, fix, debug, refactor, build, write, test, deploy |
  | `:query`     | Explain, describe, analyze, compare, review, summarize |
  | `:file_ops`  | Read, write, create, delete, move, rename, find |
  | `:chat`      | Short conversational turns (yes/no/thanks/status) |
  | `:unknown`   | Default when no signal is detected |

  ## Fingerprint key

  `key/1` serialises a fingerprint to a stable string suitable for use as a
  SQLite key or map key.  The key is constructed from sorted, lowercased
  dimensions joined by `|` so it remains human-readable in debug output.
  """

  alias LemonCore.MemoryDocument

  @type task_family :: :code | :query | :file_ops | :chat | :unknown

  @type t :: %__MODULE__{
          task_family: task_family(),
          toolset: [String.t()],
          workspace_key: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | nil
        }

  defstruct task_family: :unknown,
            toolset: [],
            workspace_key: nil,
            model: nil,
            provider: nil

  @code_keywords ~w(implement fix debug refactor build write create test deploy rewrite migrate
    architect integrate optimize repair patch upgrade)
  @query_keywords ~w(explain describe analyze analyse compare review summarize summarise
    what how why show list find search)
  @file_ops_keywords ~w(read open save delete remove move rename copy touch mkdir)
  @chat_keywords ~w(yes no thanks thank ok okay hello hi bye help status version)

  @doc """
  Build a `TaskFingerprint` from a `MemoryDocument`.
  """
  @spec from_document(MemoryDocument.t()) :: t()
  def from_document(%MemoryDocument{} = doc) do
    %__MODULE__{
      task_family: classify_prompt(doc.prompt_summary),
      toolset: doc.tools_used |> Kernel.||([])|> Enum.uniq() |> Enum.sort(),
      workspace_key: doc.workspace_key,
      model: doc.model,
      provider: doc.provider
    }
  end

  @doc """
  Serialise a fingerprint to a stable, deterministic string key.

  The format is `family|toolset|workspace|provider|model` where each segment
  is lowercased and missing values are replaced with `"-"`.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = fp) do
    [
      context_key(fp),
      fp.provider || "-",
      fp.model || "-"
    ]
    |> Enum.join("|")
  end

  @doc """
  Returns the 3-segment context key for cross-model comparison.

  Strips the provider and model dimensions so the key can be used to look up
  historical performance across different models serving the same task context.

  Format: `family|toolset|workspace`
  """
  @spec context_key(t()) :: String.t()
  def context_key(%__MODULE__{} = fp) do
    toolset_str =
      case fp.toolset do
        [] -> "-"
        tools -> Enum.join(tools, ",")
      end

    [
      Atom.to_string(fp.task_family),
      toolset_str,
      fp.workspace_key || "-"
    ]
    |> Enum.join("|")
  end

  @doc """
  Returns the valid task family atoms.
  """
  @spec task_families() :: [task_family()]
  def task_families, do: [:code, :query, :file_ops, :chat, :unknown]

  @doc """
  Classify a prompt text into a task family atom.

  Returns one of `:code`, `:query`, `:file_ops`, `:chat`, or `:unknown`.
  """
  @spec classify_prompt(String.t() | nil) :: task_family()
  def classify_prompt(nil), do: :unknown
  def classify_prompt(""), do: :unknown

  def classify_prompt(prompt) when is_binary(prompt) do
    lower = prompt |> String.downcase() |> String.split(~r/\s+/)

    cond do
      matches_any?(lower, @code_keywords) -> :code
      matches_any?(lower, @file_ops_keywords) -> :file_ops
      matches_any?(lower, @query_keywords) -> :query
      matches_any?(lower, @chat_keywords) -> :chat
      true -> :unknown
    end
  end

  defp matches_any?(words, keywords) do
    keyword_set = MapSet.new(keywords)
    Enum.any?(words, &MapSet.member?(keyword_set, &1))
  end
end
