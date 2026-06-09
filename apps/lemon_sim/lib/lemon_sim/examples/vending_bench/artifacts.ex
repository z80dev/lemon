defmodule LemonSim.Examples.VendingBench.Artifacts do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.{Performance, Replay}

  @default_artifact_root "apps/lemon_sim/priv/game_logs/vending_bench"
  @artifact_registry_path Path.join(
                            System.tmp_dir!(),
                            "lemon_vending_bench_artifact_registry.json"
                          )

  def write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) ||
        Path.join(@default_artifact_root, state.sim_id)

    File.mkdir_p!(artifact_dir)
    write_artifact_registry(state.sim_id, artifact_dir)

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
      report: Path.join(artifact_dir, "report.md"),
      replay_json: Path.join(artifact_dir, "replay.json"),
      replay_html: Path.join(artifact_dir, "replay.html")
    }

    File.write!(paths.final_world, Jason.encode!(jsonable(state.world), pretty: true))
    File.write!(paths.scorecard, Jason.encode!(jsonable(scorecard), pretty: true))
    File.write!(paths.events, jsonl(events))
    File.write!(paths.actions, jsonl(actions))

    File.write!(
      paths.supplier_messages,
      Jason.encode!(supplier_messages_artifact(state.world), pretty: true)
    )

    File.write!(
      paths.worker_history,
      Jason.encode!(worker_history_artifact(state.world), pretty: true)
    )

    File.write!(
      paths.operator_transcript,
      Jason.encode!(operator_transcript_artifact(actions, events), pretty: true)
    )

    File.write!(
      paths.reminders,
      Jason.encode!(jsonable(get(state.world, :reminders, [])), pretty: true)
    )

    {:ok, _replay_paths} = Replay.write_browser(artifact_dir)
    File.write!(paths.report, artifact_report(state, scorecard, paths, opts))

    {:ok, paths}
  end

  defp write_artifact_registry(sim_id, artifact_dir) do
    registry =
      case File.read(@artifact_registry_path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.write!(
      @artifact_registry_path,
      registry
      |> Map.put(sim_id, artifact_dir)
      |> Jason.encode!(pretty: true)
    )
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
    - Spoiled units: #{scorecard.spoiled_units}
    - Spoilage loss: $#{format_price(scorecard.spoilage_loss)}
    - Storage overflow units: #{scorecard.storage_overflow_units}
    - Active failure modes: #{scorecard.active_failure_mode_count}

    ## Artifacts

    - Final world: #{paths.final_world}
    - Events: #{paths.events}
    - Actions: #{paths.actions}
    - Supplier messages: #{paths.supplier_messages}
    - Worker history: #{paths.worker_history}
    - Operator transcript: #{paths.operator_transcript}
    - Reminders: #{paths.reminders}
    - Scorecard: #{paths.scorecard}
    - Replay JSON: #{paths.replay_json}
    - Replay browser: #{paths.replay_html}
    """
  end

  defp supplier_messages_artifact(world) do
    %{
      inbox: get(world, :inbox, []),
      outbox: get(world, :outbox, []),
      research_history: get(world, :supplier_research_history, []),
      reply_history: get(world, :supplier_reply_history, []),
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
