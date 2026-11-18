defmodule LemonWeb.WorkProjection do
  @moduledoc """
  Bounded, allowlisted operator projections over the canonical automation services.

  Private records exist only during a service call. Socket state contains safe IDs,
  labels, counters, enums, timestamps, validated session keys and opaque revisions,
  never objectives, prompts, commands, execution options or result bodies. A failed
  lookup is not empty state.

  Writes (`execute/3`, `create_cron/1`, `update_cron/2`, `set_goal/1`) call the same
  shared services the control plane uses. Every control on an existing record is
  bound to the opaque revision the operator previewed and is refused when stale.
  """

  alias LemonAgent.Workspace.{GoalStore, KanbanAuthority, KanbanStore}
  alias LemonAutomation.{CronManager, CronSchedule, GoalLoopManager, KanbanDispatcher}
  alias LemonMemory.Safety
  alias LemonWeb.CronText

  @limits %{boards: 12, goals: 25, cron: 25}
  @card_limit 30
  @run_limit 5
  @prompt_max_bytes 16_000
  @objective_max_bytes 8_000
  @agent_regex ~r/\A[A-Za-z0-9_-]{1,64}\z/

  def snapshot(previous \\ %{}) do
    %{
      boards:
        section(fn ->
          call(KanbanStore, :list_boards, [[limit: 12, strict: true]])
          |> strict_rows(12, &board/1)
        end),
      goals:
        section(fn ->
          call(GoalStore, :list, [[limit: 25, strict: true]]) |> strict_rows(25, &goal/1)
        end),
      cron: section(fn -> call(CronManager, :list, []) |> rows(25, &cron/1) end)
    }
    |> Map.new(fn {kind, current} ->
      old = Map.get(previous, kind, %{items: []})

      items =
        if current.state == :unavailable do
          Enum.map(old.items, &unavailable/1)
        else
          Enum.map(current.items, fn row ->
            if row.runtime == "unavailable" do
              unavailable(Enum.find(old.items, row, &(&1.id == row.id)))
            else
              row
            end
          end)
        end

      {kind, %{current | items: items}}
    end)
  end

  defp unavailable(row) do
    row = Map.put(row, :last_runtime, Map.get(row, :last_runtime) || row.runtime)
    row = %{row | runtime: "unavailable"}

    if row.kind == :cron,
      do: %{row | runs: Enum.map(row.runs, &%{&1 | abortable: false})},
      else: row
  end

  def limit(kind), do: Map.fetch!(@limits, kind)
  def card_limit, do: @card_limit
  def run_limit, do: @run_limit

  def target(snapshot, kind, id) when kind in [:boards, :goals, :cron] do
    case snapshot[kind] do
      %{state: :ready, items: items} -> Enum.find(items, &(&1.id == id))
      _ -> nil
    end
  end

  def actions(%{kind: :boards, authority: "quarantined", runtime: "idle"}), do: ["reauthorize"]

  def actions(%{kind: :boards, status: "active", runtime: "idle"} = row) do
    publish = if Map.get(row, :publication) == "requested", do: ["grant-publish"], else: []
    in_place = if Map.get(row, :in_place) == "granted", do: [], else: ["allow-in-place"]
    ["start", "reauthorize"] ++ publish ++ in_place
  end

  def actions(%{kind: :boards, runtime: "running"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "running"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "stopping"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "scheduled"}), do: ["stop"]
  def actions(%{kind: :goals, runtime: "idle", status: "active"}), do: ["start", "pause"]
  def actions(%{kind: :goals, runtime: "idle", status: "paused"}), do: ["resume"]
  def actions(%{kind: :cron, runtime: "unavailable"}), do: []

  def actions(%{kind: :cron, status: status} = row) do
    schedule = if status == "enabled", do: ["pause"], else: ["resume"]

    if active_run?(row),
      do: schedule,
      else: ["run" | schedule] ++ ["remove"]
  end

  def actions(_), do: []

  @doc "Whether a cron row has a pending, running or reconciling invocation."
  def active_run?(%{kind: :cron, runs: runs}),
    do: Enum.any?(runs, &(&1.status in ["pending", "running", "reconciling"]))

  def active_run?(_), do: false

  def execute(row, action, run_id \\ nil) do
    guarded(fn -> mutate(row, action, run_id) end)
  end

  defp guarded(fun) do
    result =
      try do
        fun.()
      rescue
        _ -> {:error, :outcome_unknown}
      catch
        _, _ -> {:error, :outcome_unknown}
      end

    case result do
      {:ok, value} -> if unknown?(value), do: {:error, :outcome_unknown}, else: :ok
      :ok -> :ok
      {:error, :stale} -> {:error, :stale}
      {:error, :outcome_unknown} -> {:error, :outcome_unknown}
      {:error, _} -> {:error, :refused}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp mutate(%{kind: :boards} = row, "start", _),
    do:
      call(KanbanDispatcher, :start_board, [
        row.id,
        [max_concurrency: 1, expected_revision: row.revision]
      ])

  defp mutate(%{kind: :boards} = row, "stop", _),
    do: call(KanbanDispatcher, :stop_board, [row.id, [expected_revision: row.revision]])

  # Operator-only: the sole path that releases quarantined work or widens a
  # board's recorded authority.
  defp mutate(%{kind: :boards} = row, "reauthorize", _),
    do: call(KanbanDispatcher, :reauthorize_board, [row.id, [expected_revision: row.revision]])

  # Operator-only publication grant, bound to the previewed board revision and
  # to the digest of the exact publish settings shown in the preview.
  defp mutate(%{kind: :boards} = row, "grant-publish", _),
    do:
      call(KanbanDispatcher, :grant_publication, [
        row.id,
        [expected_revision: row.revision, publish_digest: row.publish_digest]
      ])

  # Operator-only: lets workers run directly in the board's workspace
  # (non-Git workspaces), bound to the previewed board revision and to the
  # digest of the workspace that was current when previewed.
  defp mutate(%{kind: :boards} = row, "allow-in-place", _),
    do:
      call(KanbanDispatcher, :grant_in_place, [
        row.id,
        [expected_revision: row.revision, workspace_digest: row.workspace_digest]
      ])

  defp mutate(%{kind: :goals} = row, "start", _),
    do:
      call(GoalLoopManager, :start_loop, [
        row.session,
        [max_ticks: 3, auto: false, expected_revision: row.revision]
      ])

  defp mutate(%{kind: :goals} = row, "stop", _),
    do: call(GoalLoopManager, :stop_loop, [row.session, [expected_revision: row.revision]])

  defp mutate(%{kind: :goals} = row, action, _) when action in ["pause", "resume"],
    do:
      call(GoalLoopManager, :transition_goal, [
        row.session,
        if(action == "pause", do: :pause, else: :resume),
        row.revision
      ])

  defp mutate(%{kind: :cron} = row, "run", _),
    do: call(CronManager, :run_now, [row.id, row.revision])

  defp mutate(%{kind: :cron} = row, action, _) when action in ["pause", "resume"],
    do: call(CronManager, :update, [row.id, %{enabled: action == "resume"}, row.revision])

  defp mutate(%{kind: :cron} = row, "remove", _),
    do: call(CronManager, :remove, [row.id, row.revision])

  defp mutate(%{kind: :cron} = row, "abort", run_id) do
    run = Enum.find(row.runs, &(&1.id == run_id and &1.abortable))
    if run, do: call(CronManager, :abort_run, [run.id, run.revision]), else: {:error, :stale}
  end

  defp mutate(_, _, _), do: {:error, :refused}

  # ── Cron create / edit ────────────────────────────────────────────────────

  @doc """
  Validates a cron schedule draft and previews it: normalized expression,
  human-readable text and the next three run times (ms). Errors are bounded,
  operator-input-derived text.
  """
  def schedule_preview(schedule, timezone) do
    timezone = timezone(timezone)

    with {:ok, expression} <- normalize_schedule(schedule) do
      next =
        expression
        |> CronSchedule.next_runs(timezone, count: 3)
        |> Enum.map(&DateTime.to_unix(&1, :millisecond))

      {:ok,
       %{
         expression: expression,
         text: CronText.describe(expression),
         zone: CronText.zone(timezone),
         next: next
       }}
    end
  end

  defp normalize_schedule(value) when is_binary(value) and byte_size(value) <= 96 do
    with {:ok, expression} <- CronSchedule.normalize(value),
         {:ok, _} <- CronSchedule.parse(expression) do
      {:ok, expression}
    else
      {:error, reason} -> {:error, bounded(reason)}
    end
  rescue
    _ -> {:error, "Schedule is not valid."}
  end

  defp normalize_schedule(_), do: {:error, "Schedule is too long."}

  @doc """
  Validates a create/edit form. Returns `{:ok, attrs}` (prompt included only
  when supplied; callers must not retain it) or `{:error, errors}` keyed by field.
  `mode: :create` requires agent and prompt.
  """
  def validate_cron(params, mode) when mode in [:create, :edit] and is_map(params) do
    name = params |> Map.get("name", "") |> to_string() |> String.trim()
    agent = params |> Map.get("agent", "") |> to_string() |> String.trim()
    prompt = params |> Map.get("prompt", "") |> to_string() |> String.trim()
    timezone = timezone(params["timezone"])

    errors =
      []
      |> check(:name, name == "", "Enter a name.")
      |> check(:name, byte_size(name) > 96, "Use at most 96 characters.")
      |> check(:name, String.contains?(name, ["\n", "\r"]), "Use a single line.")
      |> check(
        :agent,
        mode == :create and not Regex.match?(@agent_regex, agent),
        "Use an agent ID of letters, numbers, - or _."
      )
      |> check(:prompt, mode == :create and prompt == "", "Describe what the agent should do.")
      |> check(:prompt, byte_size(prompt) > @prompt_max_bytes, "Prompt is too long (16 KB max).")

    schedule = schedule_preview(params["schedule"] || "", timezone)

    errors =
      if match?({:error, _}, schedule),
        do: [{:schedule, elem(schedule, 1)} | errors],
        else: errors

    timeout = minutes(params["timeout_minutes"])
    errors = check(errors, :timeout_minutes, is_nil(timeout), "Choose a timeout.")

    case errors do
      [] ->
        {:ok, preview} = schedule

        attrs =
          %{
            name: name,
            schedule: preview.expression,
            timezone: timezone,
            enabled: params["enabled"] in ["true", true],
            timeout_ms: timeout * 60_000
          }
          |> then(&if(prompt != "", do: Map.put(&1, :prompt, prompt), else: &1))
          |> then(
            &if(mode == :create,
              do: Map.merge(&1, %{agent_id: agent, session_key: "agent:#{agent}:main"}),
              else: &1
            )
          )

        {:ok, attrs}

      errors ->
        {:error, errors |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Map.new()}
    end
  end

  defp check(errors, field, true, message), do: [{field, message} | errors]
  defp check(errors, _field, _false, _message), do: errors

  defp minutes(value) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n in 1..240 -> n
      _ -> nil
    end
  end

  @doc "Creates an agent cron job. Returns `{:ok, id}` or a safe error atom/message."
  def create_cron(attrs) do
    case safe_call(fn -> call(CronManager, :add, [attrs]) end) do
      {:ok, %{id: id}} -> {:ok, required_id(id)}
      {:error, reason} -> {:error, write_error(reason)}
      _ -> {:error, :outcome_unknown}
    end
  end

  @doc "Updates the exact previewed job revision. Prompt replaces only when supplied."
  def update_cron(%{kind: :cron, id: id, revision: revision, mode: mode}, attrs) do
    attrs = if mode == "agent", do: attrs, else: Map.delete(attrs, :prompt)

    case safe_call(fn -> call(CronManager, :update, [id, attrs, revision]) end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, write_error(reason)}
      _ -> {:error, :outcome_unknown}
    end
  end

  @doc "Sets a durable goal for a session (write-only objective)."
  def set_goal(params) when is_map(params) do
    session = session(String.trim(to_string(params["session"] || "")))
    objective = params |> Map.get("objective", "") |> to_string() |> String.trim()
    budget = params["max_continuations"] |> to_string() |> String.trim()

    budget =
      case Integer.parse(budget) do
        {n, ""} when n in 1..1000 -> n
        _ when budget == "" -> nil
        _ -> :invalid
      end

    errors =
      []
      |> check(:session, is_nil(session), "Enter a valid session key, e.g. agent:default:main.")
      |> check(:objective, objective == "", "Describe the goal.")
      |> check(
        :objective,
        byte_size(objective) > @objective_max_bytes,
        "Goal is too long (8 KB max)."
      )
      |> check(:max_continuations, budget == :invalid, "Use a number from 1 to 1000.")

    if errors == [] do
      opts = if budget, do: [budget: %{"max_continuations" => budget}], else: []

      case safe_call(fn -> call(GoalLoopManager, :set_goal, [session, objective, opts]) end) do
        {:ok, _} -> {:ok, session}
        {:error, :already_running} -> {:error, :already_running}
        {:error, reason} -> {:error, write_error(reason)}
        _ -> {:error, :outcome_unknown}
      end
    else
      {:error, errors |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Map.new()}
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp write_error(:stale), do: :stale
  defp write_error(:not_found), do: :not_found
  defp write_error(:outcome_unknown), do: :outcome_unknown
  defp write_error({:invalid_schedule, _}), do: :invalid_schedule
  defp write_error({:missing_keys, _}), do: :invalid
  defp write_error({:invalid_target, _}), do: :invalid
  defp write_error({:immutable_fields, _}), do: :invalid
  defp write_error(_), do: :refused

  @doc "Safe agent IDs for the create form (from `agents.list`)."
  def agent_ids(payload) do
    case payload do
      %{"agents" => agents} when is_list(agents) ->
        agents
        |> Enum.map(&(is_map(&1) && (&1["id"] || &1["agentId"])))
        |> Enum.filter(&(is_binary(&1) and Regex.match?(@agent_regex, &1)))
        |> Enum.uniq()
        |> Enum.take(50)

      _ ->
        []
    end
  end

  # ── Projections ───────────────────────────────────────────────────────────

  defp board(raw) do
    id = required_id(raw.id)

    tasks =
      call(KanbanStore, :list_tasks, [id, [limit: @card_limit, strict: true]])
      |> strict_rows(@card_limit, &card/1)

    runtime = runtime(fn -> call(KanbanDispatcher, :status, [id]) end, :dispatcher)
    preview = publication_preview(id, raw)

    %{
      kind: :boards,
      id: id,
      label: label(raw[:name]),
      status: enum(raw[:status], ~w(active archived)),
      authority: authority(raw),
      publication: publication(raw, preview),
      publish_digest: preview && preview.digest,
      publish_summary: publish_summary(publish_settings(raw), preview),
      in_place: in_place(raw),
      workspace_digest: KanbanAuthority.workspace_digest(raw[:workspace]),
      runtime: runtime.status,
      revision: runtime.revision,
      running_count: runtime.count,
      cards: tasks,
      columns:
        Enum.uniq(Enum.map(Enum.take(raw.columns, 30), &label/1) ++ Enum.map(tasks, & &1.status))
    }
  end

  # Boards without recorded authority are quarantined: never dispatched until an
  # operator reauthorizes them here.
  defp authority(raw) do
    case KanbanAuthority.fetch(raw) do
      {:ok, _} -> "authorized"
      {:error, _} -> "quarantined"
    end
  end

  defp in_place(raw) do
    with {:ok, authority} <- KanbanAuthority.fetch(raw),
         true <- KanbanAuthority.in_place_granted?(authority, raw[:workspace]) do
      "granted"
    else
      _ -> "not_granted"
    end
  end

  defp publish_settings(%{meta: %{"codingWorkflow" => %{"publish" => %{} = settings}}}),
    do: settings

  defp publish_settings(_raw), do: nil

  # The destinations a grant would bind now, resolved by the dispatcher from
  # the board workspace's remote configuration; nil when unavailable.
  defp publication_preview(id, raw) do
    if is_map(publish_settings(raw)) do
      try do
        case call(KanbanDispatcher, :publication_preview, [id, []]) do
          {:ok, %{destinations: %{"push" => [_ | _]} = destinations, digest: digest}}
          when is_binary(digest) ->
            %{destinations: destinations, digest: digest}

          _ ->
            nil
        end
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    end
  end

  # "granted": the grant's pinned destinations are still what the workspace
  # resolves to (or cannot be re-resolved); "requested": a (fresh) grant can
  # be confirmed for the previewed destinations; "unresolved": neither.
  defp publication(raw, preview) do
    settings = publish_settings(raw)

    with true <- is_map(settings),
         {:ok, authority} <- KanbanAuthority.fetch(raw) do
      granted = KanbanAuthority.granted_destinations(authority, settings)

      cond do
        preview && granted == {:ok, preview.destinations} -> "granted"
        preview -> "requested"
        match?({:ok, _}, granted) -> "granted"
        true -> "unresolved"
      end
    else
      _ -> nil
    end
  end

  # Bounded labels of the exact settings and destinations an operator grant
  # would authorize.
  defp publish_summary(settings, preview) when is_map(settings) do
    push =
      case preview do
        %{destinations: %{"push" => urls}} -> "push to " <> Enum.map_join(urls, ", ", &push_url/1)
        _ -> "push destination unresolved"
      end

    [
      enum(settings["mode"], ~w(branch pull_request)),
      is_binary(settings["remote"]) && "remote " <> label(settings["remote"]),
      push,
      is_binary(settings["repository"]) && "repository " <> label(settings["repository"]),
      is_binary(settings["base"]) && "base " <> label(settings["base"]),
      if(settings["draft"] == false, do: "ready for review", else: nil)
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(", ")
  end

  defp publish_summary(_settings, _preview), do: nil

  # Remote URLs are shown exactly (the dispatcher already refused embedded
  # credentials and control characters); a local path stays hidden.
  defp push_url(url) do
    if Regex.match?(~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:\/\/|[^\/:@\s]+@[^\/:\s]+:)/, url),
      do: String.slice(url, 0, 512),
      else: LemonWeb.ManagementText.text(url, max_bytes: 512)
  end

  defp outcome(value) when value in ~w(running reconciling completed failed outcome_unknown),
    do: value

  defp outcome(_), do: nil

  defp card(raw) do
    meta = if is_map(raw[:meta]), do: raw[:meta], else: %{}

    %{
      id: required_id(raw.id),
      label: label(raw[:title]),
      status: label(raw[:status]),
      priority: enum(raw[:priority], ~w(low normal high urgent)),
      session: session(raw[:session_key]),
      result: outcome(get_in(meta, ["kanbanRun", "status"])),
      attempt: count(get_in(meta, ["kanbanLease", "attempt"])),
      needs_retry: Map.has_key?(meta, "lastFailure"),
      updated_at_ms: timestamp_ms(raw[:updated_at_ms]),
      workflow: workflow(meta["codingWorkflow"])
    }
  end

  defp workflow(raw) when is_map(raw) do
    commit = raw["commitSha"]
    branch = raw["branch"]

    %{
      phase:
        enum(
          raw["phase"],
          ~w(coding coding_complete review review_rejected commit_pending committed publish_pending completed)
        ),
      approved: get_in(raw, ["review", "approved"]) == true,
      commit:
        if(is_binary(commit) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, commit),
          do: commit
        ),
      branch:
        if(is_binary(branch) and Regex.match?(~r/\Alemon-kanban\/[A-Za-z0-9_-]{1,160}\z/, branch),
          do: branch
        ),
      review_session: session(raw["reviewSessionKey"]),
      pr_url: pull_request_url(raw["prUrl"])
    }
  end

  defp workflow(_), do: nil

  defp pull_request_url(value) when is_binary(value) and byte_size(value) <= 256 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and host != "" and is_binary(path) ->
        if Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path) and
             Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, host),
           do: value

      _ ->
        nil
    end
  end

  defp pull_request_url(_), do: nil

  defp goal(raw) do
    key = session(raw[:session_key])
    meta = if is_map(raw[:meta]), do: raw[:meta], else: %{}
    loop = meta["goalLoop"] || %{}
    loop = if is_map(loop), do: loop, else: %{}
    budget = if is_map(raw[:budget]), do: raw[:budget], else: %{}

    runtime =
      if key,
        do: runtime(fn -> call(GoalLoopManager, :status, [key]) end, :loop),
        else: %{status: "unavailable", revision: nil, count: 0}

    %{
      kind: :goals,
      id: required_id(raw.id),
      label: "Goal",
      session: key,
      agent: agent(raw[:agent_id]),
      status: enum(raw[:status], ~w(active paused completed)),
      runtime: runtime.status,
      revision: runtime.revision,
      continuation_count: count(raw[:continuation_count]),
      max_continuations: positive(budget["max_continuations"] || budget[:max_continuations]),
      loop_status:
        optional_enum(
          loop["status"],
          ~w(running reconciling stopped finished limit_reached error)
        ),
      last_action:
        optional_enum(
          get_in(loop, ["lastVerdict", "action"]),
          ~w(continue done blocked needs_input)
        ),
      verdict_count: count(loop["verdictCount"]),
      auto: get_in(loop, ["auto", "enabled"]) == true,
      updated_at_ms: timestamp_ms(raw[:updated_at_ms]),
      running_count: runtime.count,
      result: outcome(get_in(meta, ["lastResult", "status"]))
    }
  end

  defp cron(raw) do
    id = required_id(raw.id)

    runs =
      section(fn ->
        call(CronManager, :runs, [id, [limit: @run_limit, strict: true]])
        |> strict_rows(@run_limit, &run/1)
      end)

    %{
      kind: :cron,
      id: id,
      label: label(raw.name),
      status: if(raw.enabled, do: "enabled", else: "paused"),
      runtime: if(runs.state == :ready, do: "ready", else: "unavailable"),
      revision: CronManager.control_revision(raw),
      runs: runs.items,
      session: session(raw.session_key),
      mode: if(present?(Map.get(raw, :command)), do: "command", else: "agent"),
      agent: agent(Map.get(raw, :agent_id)),
      schedule: schedule(raw.schedule),
      schedule_text: CronText.describe(schedule(raw.schedule)),
      timezone: timezone(Map.get(raw, :timezone)),
      timeout_ms: timestamp_ms(Map.get(raw, :timeout_ms)),
      model: model(Map.get(raw, :model) || Map.get(raw, :captured_default_model)),
      next_run_at_ms: if(raw.enabled, do: timestamp_ms(Map.get(raw, :next_run_at_ms))),
      last_run_at_ms: timestamp_ms(Map.get(raw, :last_run_at_ms))
    }
  end

  defp run(raw) do
    meta = raw.meta || %{}
    unknown = meta[:outcome_unknown] == true or meta["outcome_unknown"] == true
    active = raw.status in [:pending, :running]

    %{
      id: required_id(raw.id),
      revision: CronManager.control_revision(raw),
      status:
        if(unknown and active,
          do: "reconciling",
          else: enum(raw.status, ~w(pending running completed failed timeout aborted))
        ),
      abortable:
        active and not unknown and meta[:abort_requested] != true and
          meta["abort_requested"] != true,
      triggered_by: optional_enum(Map.get(raw, :triggered_by), ~w(schedule manual wake retry)),
      started_at_ms: timestamp_ms(Map.get(raw, :started_at_ms)),
      duration_ms: count(raw.duration_ms),
      retry_attempt: count(meta[:retry_attempt] || meta["retry_attempt"]),
      session:
        session(
          meta[:router_session_key] || meta["router_session_key"] || meta[:session_key] ||
            meta["session_key"]
        )
    }
  end

  defp runtime(fun, key) do
    case section(fn ->
           case fun.() do
             {:ok, %{running: running, control_revision: revision} = raw}
             when is_boolean(running) ->
               details = raw[key] || %{}

               status =
                 cond do
                   count(raw[:reconciling_count]) > 0 -> "reconciling"
                   running -> enum(details[:status], ~w(running stopping reconciling))
                   key == :loop and get_in(raw, [:auto, "enabled"]) == true -> "scheduled"
                   true -> "idle"
                 end

               %{
                 status: status,
                 revision: required_id(revision),
                 count: count(details[:running_count])
               }

             _ ->
               throw(:unavailable)
           end
         end) do
      %{state: :ready, items: value} -> value
      _ -> %{status: "unavailable", revision: nil, count: 0}
    end
  end

  defp section(fun) do
    %{state: :ready, items: fun.()}
  rescue
    _ -> %{state: :unavailable, items: []}
  catch
    _, _ -> %{state: :unavailable, items: []}
  end

  defp strict_rows({:ok, items}, limit, project), do: rows(items, limit, project)
  defp strict_rows(_, _, _), do: throw(:unavailable)

  defp rows(items, limit, project) when is_list(items),
    do: items |> Enum.take(limit) |> Enum.map(project)

  defp rows(_, _, _), do: throw(:unavailable)

  defp call(module, function, args) do
    case Application.get_env(:lemon_web, :work_service_fun) do
      fun when is_function(fun, 3) -> fun.(module, function, args)
      _ -> apply(module, function, args)
    end
  end

  defp required_id(value) do
    if is_binary(value) and byte_size(value) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value) and safe?(value),
       do: value,
       else: throw(:invalid_projection)
  end

  defp session(value) when is_binary(value) do
    if byte_size(value) <= 256 and Regex.match?(~r/\A[A-Za-z0-9_:-]+\z/, value) and
         LemonCore.SessionKey.valid?(value) and safe?(value), do: value, else: nil
  end

  defp session(_), do: nil

  defp agent(value) when is_binary(value) do
    if Regex.match?(@agent_regex, value) and safe?(value), do: value, else: nil
  end

  defp agent(_), do: nil

  defp safe?(value), do: Safety.redact_for_operator(value, max_bytes: 256) == {value, 0}

  defp label(value) when is_binary(value) do
    value
    |> LemonWeb.ManagementText.text(max_bytes: 96)
    |> String.replace(~r/\s+/u, " ")
  end

  defp label(_), do: "Untitled"

  defp bounded(value) when is_binary(value),
    do: LemonWeb.ManagementText.text(value, max_bytes: 160)

  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)
  defp enum(value, allowed), do: if(value in allowed, do: value, else: "unknown")

  defp optional_enum(nil, _allowed), do: nil

  defp optional_enum(value, allowed) when is_atom(value),
    do: optional_enum(Atom.to_string(value), allowed)

  defp optional_enum(value, allowed), do: if(value in allowed, do: value)

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: 0
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_), do: nil
  defp timestamp_ms(value) when is_integer(value) and value > 0, do: value
  defp timestamp_ms(_), do: nil
  defp timezone("local"), do: "local"
  defp timezone(_), do: "UTC"
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp model(value) when is_binary(value) do
    if byte_size(value) in 1..96 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value) and
         safe?(value),
       do: value,
       else: nil
  end

  defp model(_), do: nil

  defp schedule(value) when is_binary(value) do
    if byte_size(value) <= 96 and Regex.match?(~r/\A[0-9*,\/\-\s]+\z/, value),
      do: value,
      else: "Custom schedule"
  end

  defp schedule(_), do: "Custom schedule"

  defp unknown?(:outcome_unknown), do: true
  defp unknown?("outcome_unknown"), do: true
  defp unknown?(%{router_abort: status}) when status in [:unavailable, :rejected], do: true
  defp unknown?(value) when is_map(value), do: value |> Map.values() |> Enum.any?(&unknown?/1)
  defp unknown?(value) when is_list(value), do: Enum.any?(value, &unknown?/1)
  defp unknown?(_), do: false
end
