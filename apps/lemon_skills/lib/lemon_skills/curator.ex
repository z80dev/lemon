defmodule LemonSkills.Curator do
  @moduledoc """
  Skill curation scheduler and review prompt support.

  The curator only acts on agent-authored skills tracked in the usage sidecar.
  Its automatic pass is intentionally conservative: stale skills are marked
  stale, archive candidates are disabled and marked archived, and recently used
  stale skills are reactivated. It never deletes skills.
  """

  alias LemonSkills.{Config, Usage}

  @default_interval_hours 24 * 7
  @default_stale_after_days 30
  @default_archive_after_days 90

  @review_prompt """
  You are running as Lemon's background skill curator.

  Goal: maintain a useful procedural-memory library. Prefer class-level skills
  with clear sections and supporting files over many one-session micro-skills.

  Hard rules:
  1. Only touch agent-authored skills listed below.
  2. Never delete skills. Use skill_manage action=archive for recoverable removal.
  3. Skip pinned and archived skills.
  4. Judge consolidation by content and reusable workflow class, not just usage counters.
  5. If several narrow skills share a domain, merge their reusable lessons into an umbrella skill,
     then archive the absorbed siblings.

  Use read_skill to inspect candidates before editing. Use skill_manage create, patch,
  write_file, pin, archive, or restore for changes. When done, summarize clusters processed,
  skills patched, skills archived, new umbrellas created, and any clusters intentionally left alone.
  """

  @type scope :: :global | :project
  @type counts :: %{
          checked: non_neg_integer(),
          marked_stale: non_neg_integer(),
          archived: non_neg_integer(),
          reactivated: non_neg_integer()
        }

  @doc "Load persisted curator state for a scope."
  @spec load_state(keyword()) :: map()
  def load_state(opts \\ []) do
    opts
    |> state_file()
    |> read_state()
    |> normalize_state()
  end

  @doc "Persist curator state for a scope."
  @spec save_state(map(), keyword()) :: :ok | {:error, term()}
  def save_state(state, opts \\ []) when is_map(state) do
    with {:ok, path} <- state_file(opts),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Jason.encode(normalize_state(state), pretty: true) do
      atomic_write(path, json)
    end
  end

  @doc "Pause or resume scheduled curator checks for a scope."
  @spec set_paused(boolean(), keyword()) :: :ok | {:error, term()}
  def set_paused(paused?, opts \\ []) when is_boolean(paused?) do
    opts
    |> load_state()
    |> Map.put("paused", paused?)
    |> save_state(opts)
  end

  @doc "Return true when a curator pass should run for the scope."
  @spec should_run_now?(keyword()) :: boolean()
  def should_run_now?(opts \\ []) do
    enabled? = Keyword.get(opts, :enabled, true)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    interval_hours = positive_integer(opts, :interval_hours, @default_interval_hours)
    state = load_state(opts)

    cond do
      not enabled? ->
        false

      state["paused"] ->
        false

      true ->
        case parse_time(state["last_run_at"]) do
          nil -> true
          last -> DateTime.diff(now, last, :hour) >= interval_hours
        end
    end
  end

  @doc """
  Apply conservative lifecycle transitions from the usage report.

  Agent-authored archive candidates are archived through the same disable path
  used by `skill_manage action=archive`; stale candidates are marked stale.
  Pinned and already archived skills are skipped by `Usage.report/1` candidate
  flags and are never auto-deleted.
  """
  @spec apply_automatic_transitions(keyword()) :: counts()
  def apply_automatic_transitions(opts \\ []) do
    stale_after_days = positive_integer(opts, :stale_after_days, @default_stale_after_days)
    usage_opts = usage_opts(opts)

    rows = Usage.report(report_opts(opts))

    Enum.reduce(rows, empty_counts(), fn row, counts ->
      if row.agent_authored do
        counts
        |> increment(:checked)
        |> maybe_transition(row, usage_opts, stale_after_days)
      else
        counts
      end
    end)
  end

  @doc """
  Run a curator pass and persist scheduler state.

  Returns automatic transition counts plus a review prompt. A caller can submit
  the prompt to an agent when `review_required` is true.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    started_at = Keyword.get(opts, :now, DateTime.utc_now())
    counts = apply_automatic_transitions(Keyword.put(opts, :now, started_at))
    rows = candidate_rows(Keyword.put(opts, :now, started_at))
    prompt = review_prompt(rows, opts)

    previous_state = load_state(opts)

    state =
      Map.merge(previous_state, %{
        "last_run_at" => DateTime.to_iso8601(started_at),
        "run_count" => previous_state["run_count"] + 1,
        "last_run_summary" => summarize_counts(counts),
        "last_candidate_count" => length(rows)
      })

    with :ok <- save_state(state, opts) do
      {:ok,
       %{
         started_at: DateTime.to_iso8601(started_at),
         auto_transitions: counts,
         candidates: rows,
         review_required: Enum.any?(rows, &review_candidate?/1),
         review_prompt: prompt,
         summary: summarize_counts(counts)
       }}
    end
  end

  @doc "Render the curator review prompt for candidate rows."
  @spec review_prompt([map()], keyword()) :: String.t()
  def review_prompt(rows, opts \\ []) when is_list(rows) do
    scope = scope(opts)

    candidate_text =
      if rows == [] do
        "No agent-authored #{scope} skills have usage records yet."
      else
        rows
        |> Enum.map(fn row ->
          markers =
            [
              row.lifecycle_state,
              if(row.stale_candidate, do: "stale-candidate"),
              if(row.archive_candidate, do: "archive-candidate")
            ]
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.join(",")

          "- #{row.name} state=#{markers} loads=#{row.load_count} writes=#{row.write_count} idle_days=#{row.idle_days || "unknown"} last_activity=#{row.last_activity_at || "never"}"
        end)
        |> Enum.join("\n")
      end

    @review_prompt <> "\n\nScope: #{scope}\n\nCandidates:\n" <> candidate_text
  end

  @doc "Return report rows eligible for curator review prompts."
  @spec candidate_rows(keyword()) :: [map()]
  def candidate_rows(opts \\ []) do
    opts
    |> report_opts()
    |> Usage.report()
    |> Enum.filter(& &1.agent_authored)
  end

  defp maybe_transition(counts, %{archive_candidate: true} = row, usage_opts, _stale_after_days) do
    case archive_skill(row.name, usage_opts) do
      :ok -> increment(counts, :archived)
      {:error, _reason} -> counts
    end
  end

  defp maybe_transition(counts, %{stale_candidate: true} = row, usage_opts, _stale_after_days) do
    if row.lifecycle_state == "active" do
      case Usage.set_state(row.name, :stale, usage_opts) do
        :ok -> increment(counts, :marked_stale)
        {:error, _reason} -> counts
      end
    else
      counts
    end
  end

  defp maybe_transition(
         counts,
         %{lifecycle_state: "stale", idle_days: idle_days} = row,
         usage_opts,
         stale_after_days
       )
       when is_integer(idle_days) and idle_days < stale_after_days do
    case Usage.set_state(row.name, :active, usage_opts) do
      :ok -> increment(counts, :reactivated)
      {:error, _reason} -> counts
    end
  end

  defp maybe_transition(counts, _row, _usage_opts, _stale_after_days), do: counts

  defp archive_skill(name, usage_opts) do
    with :ok <- disable_skill(name, usage_opts),
         :ok <- Usage.set_state(name, :archived, usage_opts) do
      :ok
    end
  end

  defp disable_skill(name, opts) do
    case Keyword.get(opts, :scope, :global) do
      :project -> Config.disable(name, global: false, cwd: Keyword.get(opts, :cwd))
      _ -> Config.disable(name, global: true)
    end
  end

  defp review_candidate?(row) do
    row.lifecycle_state not in ["pinned", "archived"]
  end

  defp summarize_counts(counts) do
    "checked=#{counts.checked} stale=#{counts.marked_stale} archived=#{counts.archived} reactivated=#{counts.reactivated}"
  end

  defp usage_opts(opts), do: [scope: scope(opts)] ++ cwd_opt(opts)

  defp report_opts(opts) do
    usage_opts(opts) ++
      [
        now: Keyword.get(opts, :now, DateTime.utc_now()),
        stale_after_days: positive_integer(opts, :stale_after_days, @default_stale_after_days),
        archive_after_days:
          positive_integer(opts, :archive_after_days, @default_archive_after_days)
      ]
  end

  defp cwd_opt(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> [cwd: cwd]
      _ -> []
    end
  end

  defp scope(opts), do: normalize_scope(Keyword.get(opts, :scope, :global))
  defp normalize_scope(:project), do: :project
  defp normalize_scope("project"), do: :project
  defp normalize_scope(_), do: :global

  defp state_file(opts) do
    case scope(opts) do
      :project ->
        case Keyword.get(opts, :cwd) do
          cwd when is_binary(cwd) and cwd != "" -> {:ok, Config.project_curator_state_file(cwd)}
          _ -> {:error, :missing_cwd}
        end

      :global ->
        {:ok, Config.global_curator_state_file()}
    end
  end

  defp read_state({:ok, path}) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = state} -> state
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp read_state({:error, _reason}), do: %{}

  defp normalize_state(state) when is_map(state) do
    %{
      "last_run_at" => Map.get(state, "last_run_at"),
      "last_run_summary" => Map.get(state, "last_run_summary"),
      "last_candidate_count" => integer_field(state, "last_candidate_count"),
      "paused" => Map.get(state, "paused") == true,
      "run_count" => integer_field(state, "run_count")
    }
  end

  defp parse_time(nil), do: nil

  defp parse_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp integer_field(state, key) do
    case Map.get(state, key, 0) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp empty_counts, do: %{checked: 0, marked_stale: 0, archived: 0, reactivated: 0}
  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp atomic_write(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp.#{System.unique_integer([:positive])}"
      )

    result =
      with :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end
end
