defmodule LemonSim.Examples.VendingBench.Artifacts do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Examples.VendingBench.{ArtifactRegistry, Performance, Replay}

  @default_artifact_root "apps/lemon_sim/priv/game_logs/vending_bench"
  @sim_version "2.0.0"
  @deterministic_artifact_timestamp "1970-01-01T00:00:00Z"

  def write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) ||
        Path.join(@default_artifact_root, state.sim_id)

    File.mkdir_p!(artifact_dir)
    ArtifactRegistry.put(state.sim_id, artifact_dir)

    performance = Performance.summarize(state.world)

    scorecard =
      performance
      |> Map.put(:sim_id, state.sim_id)
      |> Map.put(:status, get(state.world, :status))
      |> Map.put(:day_number, get(state.world, :day_number))

    paths = %{
      final_world: Path.join(artifact_dir, "final_world.json"),
      events: Path.join(artifact_dir, "events.jsonl"),
      actions: Path.join(artifact_dir, "actions.jsonl"),
      supplier_messages: Path.join(artifact_dir, "supplier_messages.json"),
      worker_history: Path.join(artifact_dir, "worker_history.json"),
      operator_transcript: Path.join(artifact_dir, "operator_transcript.json"),
      reminders: Path.join(artifact_dir, "reminders.json"),
      scorecard: Path.join(artifact_dir, "scorecard.json"),
      manifest: Path.join(artifact_dir, "manifest.json"),
      config: Path.join(artifact_dir, "config.json"),
      commands: Path.join(artifact_dir, "commands.jsonl"),
      facts: Path.join(artifact_dir, "facts.jsonl"),
      tool_calls: Path.join(artifact_dir, "tool_calls.jsonl"),
      hashes: Path.join(artifact_dir, "hashes.json"),
      operator_system_prompt: Path.join([artifact_dir, "prompts", "operator.system.md"]),
      operator_initial_prompt: Path.join([artifact_dir, "prompts", "operator.initial.md"]),
      report: Path.join(artifact_dir, "report.md"),
      replay_json: Path.join(artifact_dir, "replay.json"),
      replay_html: Path.join(artifact_dir, "replay.html")
    }

    prompts = prompt_artifacts(state)
    tool_schemas = tool_schema_artifact(state, opts)
    report = artifact_report(state, scorecard, paths, opts)

    contents = %{
      paths.final_world => Jason.encode!(jsonable(state.world), pretty: true),
      paths.scorecard => Jason.encode!(jsonable(scorecard), pretty: true),
      paths.events => jsonl(events),
      paths.actions => jsonl(actions),
      paths.commands => jsonl(Enum.filter(events, &command_event?/1)),
      paths.facts => jsonl(Enum.reject(events, &command_event?/1)),
      paths.tool_calls => jsonl(tool_call_artifact(actions)),
      paths.config =>
        Jason.encode!(config_artifact(state, opts, tool_schemas, prompts), pretty: true),
      paths.supplier_messages =>
        Jason.encode!(supplier_messages_artifact(state.world), pretty: true),
      paths.worker_history => Jason.encode!(worker_history_artifact(state.world), pretty: true),
      paths.operator_transcript =>
        Jason.encode!(operator_transcript_artifact(actions, events), pretty: true),
      paths.reminders => Jason.encode!(jsonable(get(state.world, :reminders, [])), pretty: true),
      paths.operator_system_prompt => prompts.operator_system,
      paths.operator_initial_prompt => prompts.operator_initial,
      paths.report => report
    }

    Enum.each(contents, fn {path, content} -> AtomicFile.write!(path, content) end)

    {:ok, _replay_paths} =
      Replay.write_browser(artifact_dir,
        deterministic?: Keyword.get(opts, :deterministic_artifacts?, false)
      )

    all_contents =
      contents
      |> Map.put(paths.replay_json, File.read!(paths.replay_json))
      |> Map.put(paths.replay_html, File.read!(paths.replay_html))

    hashes = hashes_artifact(artifact_dir, all_contents, prompts, tool_schemas)

    AtomicFile.write!(paths.hashes, Jason.encode!(hashes, pretty: true))

    AtomicFile.write!(
      paths.manifest,
      Jason.encode!(manifest_artifact(state, hashes, opts), pretty: true)
    )

    {:ok, paths}
  end

  defp command_event?(event), do: event_kind(event) in ["place_supplier_order"]

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_event), do: nil

  defp prompt_artifacts(state) do
    %{
      operator_system: "VendingBench operator prompt\n",
      operator_initial: get(state.intent, :goal, "") <> "\n"
    }
  end

  defp tool_schema_artifact(state, opts) do
    case LemonSim.Examples.VendingBench.ActionSpace.tools(state, opts) do
      {:ok, tools} ->
        tools
        |> Enum.map(fn tool ->
          %{
            name: tool.name,
            description: tool.description,
            parameters: tool.parameters
          }
        end)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  defp config_artifact(state, opts, tool_schemas, prompts) do
    model = Keyword.get(opts, :model)

    %{
      schema_version: "lemon_sim.config.v1",
      sim_id: state.sim_id,
      seed: get(state.world, :seed),
      max_days: get(state.world, :max_days),
      driver_max_turns: Keyword.get(opts, :driver_max_turns),
      decision_max_turns: Keyword.get(opts, :decision_max_turns),
      model: model_artifact(model),
      prompt_sha256: sha256(prompts.operator_system <> prompts.operator_initial),
      tool_schema_sha256: tool_schemas |> Jason.encode!() |> sha256()
    }
    |> jsonable()
  end

  defp model_artifact(nil), do: nil

  defp model_artifact(model) do
    %{
      provider: get(model, :provider),
      id: get(model, :id, get(model, :name)),
      name: get(model, :name)
    }
  end

  defp tool_call_artifact(actions) do
    Enum.flat_map(actions, fn action ->
      action
      |> get(:tool_calls, [])
      |> List.wrap()
    end)
  end

  defp hashes_artifact(artifact_dir, contents, prompts, tool_schemas) do
    file_hashes =
      contents
      |> Enum.map(fn {path, content} ->
        {Path.relative_to(path, artifact_dir), sha256(content)}
      end)
      |> Map.new()

    %{
      schema_version: "lemon_sim.hashes.v1",
      files: file_hashes,
      prompt_sha256: sha256(prompts.operator_system <> prompts.operator_initial),
      tool_schema_sha256: tool_schemas |> Jason.encode!() |> sha256()
    }
  end

  defp manifest_artifact(state, hashes, opts) do
    now = artifact_timestamp(opts)

    %{
      schema_version: "lemon_sim.run.v1",
      sim: %{
        id: "vending_bench",
        version: @sim_version,
        ruleset_hash: ruleset_hash(),
        seed: get(state.world, :seed)
      },
      agent: model_artifact(Keyword.get(opts, :model)),
      runtime: %{
        lemon_commit: git_commit(),
        elixir: System.version(),
        otp: :erlang.system_info(:otp_release) |> to_string(),
        started_at: Keyword.get(opts, :started_at, now),
        finished_at: Keyword.get(opts, :finished_at, now)
      },
      integrity: %{
        events_sha256: get_in(hashes, [:files, "events.jsonl"]),
        scorecard_sha256: get_in(hashes, [:files, "scorecard.json"]),
        prompt_sha256: hashes.prompt_sha256,
        tool_schema_sha256: hashes.tool_schema_sha256
      }
    }
    |> jsonable()
  end

  defp artifact_timestamp(opts) do
    cond do
      is_binary(Keyword.get(opts, :artifact_timestamp)) ->
        Keyword.fetch!(opts, :artifact_timestamp)

      Keyword.get(opts, :deterministic_artifacts?, false) ->
        @deterministic_artifact_timestamp

      true ->
        DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp ruleset_hash do
    files = [
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/world.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/updater.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/action_space.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/suppliers.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/arena.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/vending_bench/demand_model.ex"
    ]

    files
    |> Enum.map(fn path -> File.read(path) |> elem(1) end)
    |> Enum.join("\n")
    |> sha256()
  rescue
    _ -> nil
  end

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp artifact_report(state, scorecard, paths, opts) do
    title = Keyword.get(opts, :artifact_report_title, "VendingBench Run Report")

    """
    # #{title}

    Sim ID: #{state.sim_id}
    Status: #{get(state.world, :status)}
    Final day: #{get(state.world, :day_number)}

    ## Scores

    - V1 net worth: $#{format_price(scorecard.score_modes.v1_net_worth)}
    - Money balance: $#{format_price(scorecard.score_modes.money_balance)}
    - Lemon operational score: #{scorecard.score_modes.lemon_operational_score}

    ## Metrics

    - Units sold: #{scorecard.units_sold}
    - Average margin: #{scorecard.average_margin}%
    - Days without sales: #{scorecard.days_without_sales}
    - Stockout count: #{scorecard.stockout_count}
    - Worker trips: #{scorecard.worker_trip_count}
    - Coordination failures: #{scorecard.coordination_failures}
    - Refunds paid: $#{format_price(scorecard.refunds_paid)}
    - Customer complaints: #{scorecard.customer_complaint_count}
    - Supplier incidents: #{scorecard.supplier_incident_count}
    - Supplier quotes: #{scorecard.supplier_quote_count}
    - Market research searches: #{scorecard.market_research_count}
    - Arena messages: #{scorecard.arena_message_count}
    - Arena payments: #{scorecard.arena_payment_count}
    - Arena trades: #{scorecard.arena_trade_count}
    - Arena supplier leads: #{scorecard.arena_supplier_lead_count}
    - Arena price-war signals: #{scorecard.arena_price_war_count}
    - Arena collusion signals: #{scorecard.arena_collusion_signal_count}
    - Spoiled units: #{scorecard.spoiled_units}
    - Spoilage loss: $#{format_price(scorecard.spoilage_loss)}
    - Storage overflow units: #{scorecard.storage_overflow_units}
    - Active failure modes: #{scorecard.active_failure_mode_count}

    ## Artifacts

    - Final world: #{artifact_path(paths.final_world, paths, opts)}
    - Events: #{artifact_path(paths.events, paths, opts)}
    - Actions: #{artifact_path(paths.actions, paths, opts)}
    - Supplier messages: #{artifact_path(paths.supplier_messages, paths, opts)}
    - Worker history: #{artifact_path(paths.worker_history, paths, opts)}
    - Operator transcript: #{artifact_path(paths.operator_transcript, paths, opts)}
    - Reminders: #{artifact_path(paths.reminders, paths, opts)}
    - Scorecard: #{artifact_path(paths.scorecard, paths, opts)}
    - Replay JSON: #{artifact_path(paths.replay_json, paths, opts)}
    - Replay browser: #{artifact_path(paths.replay_html, paths, opts)}
    """
  end

  defp artifact_path(path, paths, opts) do
    if Keyword.get(opts, :deterministic_artifacts?, false) do
      Path.relative_to(path, Path.dirname(paths.report))
    else
      path
    end
  end

  defp supplier_messages_artifact(world) do
    %{
      inbox: get(world, :inbox, []),
      outbox: get(world, :outbox, []),
      market_research_history: get(world, :market_research_history, []),
      research_history: get(world, :supplier_research_history, []),
      reply_history: get(world, :supplier_reply_history, []),
      quote_history: get(world, :supplier_quote_history, []),
      order_history: get(world, :supplier_order_history, []),
      incident_history: get(world, :supplier_incident_history, [])
    }
    |> jsonable()
  end

  defp worker_history_artifact(world) do
    %{
      run_count: get(world, :physical_worker_run_count, 0),
      last_report: get(world, :physical_worker_last_report),
      history: get(world, :physical_worker_history, [])
    }
    |> jsonable()
  end

  defp operator_transcript_artifact(actions, events) do
    %{
      action_summaries: actions,
      event_kinds: Enum.map(events, & &1.kind),
      support_event_count: Enum.count(events, &support_event?/1),
      turn_count: length(actions),
      event_count: length(events)
    }
    |> jsonable()
  end

  defp support_event?(event) do
    event.kind in [
      "operator_checked_balance",
      "operator_checked_storage",
      "operator_read_inbox",
      "operator_inspected_suppliers",
      "operator_reviewed_sales",
      "operator_researched_suppliers",
      "operator_researched_market",
      "operator_checked_competitors",
      "operator_created_reminder",
      "operator_listed_reminders",
      "operator_completed_reminder"
    ]
  end

  defp jsonl(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> Jason.encode!(jsonable_artifact_entry(entry, index)) end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      content -> content <> "\n"
    end)
  end

  defp jsonable_artifact_entry(%{ts_ms: _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(%{"ts_ms" => _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(entry, _index), do: jsonable(entry)

  defp jsonable(%_{} = value), do: value |> Map.from_struct() |> jsonable()

  defp jsonable(%{} = value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      string_key = to_string(key)

      if is_atom(key) or not Map.has_key?(acc, string_key) do
        Map.put(acc, string_key, jsonable(val))
      else
        acc
      end
    end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value), do: value

  defp format_price(price) when is_float(price),
    do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
