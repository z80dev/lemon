defmodule LemonSim.Examples.TcgShop.Artifacts do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Examples.TcgShop.{ActionSpace, Performance}

  @default_artifact_root "apps/lemon_sim/priv/game_logs/tcg_shop"
  @sim_version "1.0.0"

  def write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) || Path.join(@default_artifact_root, state.sim_id)

    File.mkdir_p!(artifact_dir)

    scorecard =
      state.world
      |> Performance.scorecard()
      |> Map.put(:sim_id, state.sim_id)
      |> Map.put(:status, get(state.world, :status))
      |> Map.put(:day_number, get(state.world, :day_number))

    paths = %{
      final_world: Path.join(artifact_dir, "final_world.json"),
      events: Path.join(artifact_dir, "events.jsonl"),
      actions: Path.join(artifact_dir, "actions.jsonl"),
      scorecard: Path.join(artifact_dir, "scorecard.json"),
      config: Path.join(artifact_dir, "config.json"),
      commands: Path.join(artifact_dir, "commands.jsonl"),
      facts: Path.join(artifact_dir, "facts.jsonl"),
      market: Path.join(artifact_dir, "market.json"),
      inventory: Path.join(artifact_dir, "inventory.json"),
      replay_json: Path.join(artifact_dir, "replay.json"),
      replay_html: Path.join(artifact_dir, "replay.html"),
      report: Path.join(artifact_dir, "report.md"),
      hashes: Path.join(artifact_dir, "hashes.json"),
      manifest: Path.join(artifact_dir, "manifest.json")
    }

    tool_schemas = tool_schema_artifact(state, opts)
    prompt = get(state.intent, :goal, "")

    replay = replay_artifact(state, events, actions, scorecard)

    contents = %{
      paths.final_world => Jason.encode!(jsonable(state.world), pretty: true),
      paths.events => jsonl(events),
      paths.actions => jsonl(actions),
      paths.commands => jsonl(Enum.filter(events, &command_event?/1)),
      paths.facts => jsonl(Enum.reject(events, &command_event?/1)),
      paths.scorecard => Jason.encode!(jsonable(scorecard), pretty: true),
      paths.config =>
        Jason.encode!(config_artifact(state, opts, tool_schemas, prompt), pretty: true),
      paths.market => Jason.encode!(market_artifact(state.world), pretty: true),
      paths.inventory => Jason.encode!(inventory_artifact(state.world), pretty: true),
      paths.replay_json => Jason.encode!(jsonable(replay), pretty: true),
      paths.replay_html => replay_html(replay),
      paths.report => report(state, scorecard, paths, opts)
    }

    Enum.each(contents, fn {path, content} -> AtomicFile.write!(path, content) end)

    hashes = hashes_artifact(artifact_dir, contents, prompt, tool_schemas)
    AtomicFile.write!(paths.hashes, Jason.encode!(hashes, pretty: true))

    AtomicFile.write!(
      paths.manifest,
      Jason.encode!(manifest_artifact(state, hashes, opts), pretty: true)
    )

    {:ok, paths}
  end

  defp command_event?(event) do
    event_kind(event) in [
      "tcg_order_product_line",
      "tcg_buy_collection",
      "tcg_set_prices",
      "tcg_host_event",
      "tcg_submit_grading",
      "tcg_process_online_orders",
      "tcg_wait_next_day"
    ]
  end

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_event), do: nil

  defp config_artifact(state, opts, tool_schemas, prompt) do
    model = Keyword.get(opts, :model)

    %{
      schema_version: "lemon_sim.config.v1",
      sim_id: state.sim_id,
      seed: get(state.world, :seed),
      max_days: get(state.world, :max_days),
      driver_max_turns: Keyword.get(opts, :driver_max_turns),
      decision_max_turns: Keyword.get(opts, :decision_max_turns),
      offline_strategy: Keyword.get(opts, :offline_strategy),
      model: model_artifact(model),
      prompt_sha256: sha256(prompt),
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

  defp tool_schema_artifact(state, opts) do
    case ActionSpace.tools(state, opts) do
      {:ok, tools} ->
        tools
        |> Enum.map(fn tool ->
          %{name: tool.name, description: tool.description, parameters: tool.parameters}
        end)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  defp market_artifact(world) do
    %{
      market_pulses: get(world, :market_pulses, []),
      release_calendar: get(world, :release_calendar, []),
      research_history: get(world, :research_history, []),
      customer_queue: get(world, :customer_queue, []),
      competitor_snapshot: get(world, :competitor_snapshot, %{})
    }
    |> jsonable()
  end

  defp inventory_artifact(world) do
    %{
      catalog: get(world, :catalog, %{}),
      inventory: get(world, :inventory, %{}),
      singles_case: get(world, :singles_case, %{}),
      pending_deliveries: get(world, :pending_deliveries, []),
      pending_grading: get(world, :pending_grading, []),
      supplier_order_history: get(world, :supplier_order_history, []),
      buylist_history: get(world, :buylist_history, []),
      grading_history: get(world, :grading_history, [])
    }
    |> jsonable()
  end

  defp replay_artifact(state, events, actions, scorecard) do
    %{
      schema_version: "tcg_shop.replay.v1",
      sim_id: state.sim_id,
      status: get(state.world, :status),
      scorecard: scorecard,
      beats: replay_beats(state.world, events),
      action_summaries: actions
    }
  end

  defp replay_beats(world, events) do
    day_events =
      events
      |> Enum.filter(&(event_kind(&1) == "tcg_day_advanced"))
      |> Enum.map(fn event ->
        %{
          day: get(event.payload, "day"),
          title: "Day #{get(event.payload, "day")} close",
          sales: get(event.payload, "sales", 0.0),
          market_pulse: get(event.payload, "market_pulse", %{})
        }
      end)

    business_events =
      (get(world, :tournament_history, []) ++
         get(world, :buylist_history, []) ++ get(world, :grading_history, []))
      |> Enum.map(fn entry ->
        %{
          day: get(entry, :day),
          title: replay_title(entry),
          detail: entry
        }
      end)

    (business_events ++ day_events)
    |> Enum.sort_by(&(get(&1, :day, 0) || 0))
  end

  defp replay_title(entry) do
    cond do
      get(entry, :game) -> "Hosted #{get(entry, :game)} event"
      get(entry, :franchise) -> "Bought #{get(entry, :franchise)} collection"
      get(entry, :service_level) -> "Submitted grading order"
      true -> "Shop action"
    end
  end

  defp replay_html(replay) do
    beats =
      replay.beats
      |> Enum.map(fn beat ->
        "<li><strong>Day #{html(get(beat, :day, "?"))}</strong> #{html(get(beat, :title, ""))}</li>"
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>TCG Shop Replay #{html(replay.sim_id)}</title>
      <style>
        body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; margin: 2rem; }
        main { max-width: 900px; margin: 0 auto; }
        h1 { color: #fbbf24; }
        li { margin: .7rem 0; padding: .7rem; background: #1e293b; border: 1px solid #334155; border-radius: 8px; }
        code { color: #67e8f9; }
      </style>
    </head>
    <body>
      <main>
        <h1>TCG Shop Replay</h1>
        <p>Sim <code>#{html(replay.sim_id)}</code> finished with net worth $#{format_price(replay.scorecard.net_worth)}.</p>
        <ol>
          #{beats}
        </ol>
      </main>
    </body>
    </html>
    """
  end

  defp hashes_artifact(artifact_dir, contents, prompt, tool_schemas) do
    files =
      contents
      |> Enum.map(fn {path, content} ->
        {Path.relative_to(path, artifact_dir), sha256(content)}
      end)
      |> Map.new()

    %{
      schema_version: "lemon_sim.hashes.v1",
      files: files,
      prompt_sha256: sha256(prompt),
      tool_schema_sha256: tool_schemas |> Jason.encode!() |> sha256()
    }
  end

  defp manifest_artifact(state, hashes, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      schema_version: "lemon_sim.run.v1",
      sim: %{
        id: "tcg_shop",
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

  defp ruleset_hash do
    [
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/action_space.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/catalog.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/events.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/performance.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/updater.ex"
    ]
    |> Enum.map(fn path -> File.read!(path) end)
    |> Enum.join("\n")
    |> sha256()
  rescue
    _ -> nil
  end

  defp report(state, scorecard, paths, opts) do
    title = Keyword.get(opts, :artifact_report_title, "TCG Shop Run Report")

    """
    # #{title}

    Sim ID: #{state.sim_id}
    Status: #{get(state.world, :status)}
    Final day: #{get(state.world, :day_number)}

    ## Scores

    - Net worth: $#{format_price(scorecard.net_worth)}
    - Bank balance: $#{format_price(scorecard.bank_balance)}
    - Inventory value: $#{format_price(scorecard.inventory_value)}
    - Singles value: $#{format_price(scorecard.singles_value)}
    - Graded value: $#{format_price(scorecard.graded_value)}
    - ROI: #{format_price(scorecard.roi_pct)}%
    - Reputation: #{scorecard.reputation}
    - Online rating: #{scorecard.online_rating}

    ## Activity

    - Units/events sold: #{scorecard.sell_through_units}
    - Events hosted: #{scorecard.events_hosted}
    - Grading submissions: #{scorecard.grading_submissions}
    - Rejections: #{scorecard.rejections}

    ## Artifacts

    - Final world: #{paths.final_world}
    - Events: #{paths.events}
    - Actions: #{paths.actions}
    - Scorecard: #{paths.scorecard}
    - Market: #{paths.market}
    - Inventory: #{paths.inventory}
    - Replay JSON: #{paths.replay_json}
    - Replay browser: #{paths.replay_html}
    """
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
    entry |> jsonable() |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(%{"ts_ms" => _} = entry, index) do
    entry |> jsonable() |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(entry, _index), do: jsonable(entry)

  defp jsonable(%MapSet{} = value), do: value |> MapSet.to_list() |> jsonable()

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

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp format_price(price) when is_float(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default
end
