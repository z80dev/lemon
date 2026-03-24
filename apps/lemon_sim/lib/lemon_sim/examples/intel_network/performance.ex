defmodule LemonSim.Examples.IntelNetwork.Performance do
  @moduledoc """
  Objective performance summary for Intelligence Network runs.

  The benchmark emphasis is:
  - Information propagation efficiency (how fast intel reaches loyal nodes)
  - Mole detection accuracy (suspicion correctly pointed at mole vs innocents)
  - Network utilization (messages sent / possible messages)
  - Trust calibration (how well trust scores match ground truth)
  """

  import LemonSim.GameHelpers

  @spec summarize(map()) :: map()
  def summarize(world) do
    players = get(world, :players, %{})
    winner = get(world, :winner)
    mole_id = find_mole_id(players)
    operations_log = get(world, :operations_log, [])
    message_log = get(world, :message_log, %{})
    suspicion_board = get(world, :suspicion_board, %{})
    leaked_intel = get(world, :leaked_intel, [])
    intel_pool = get(world, :intel_pool, [])

    player_metrics =
      players
      |> Enum.into(%{}, fn {player_id, info} ->
        role = get(info, :role, "operative")
        is_mole = player_id == mole_id
        fragments_held = length(get(info, :intel_fragments, []))

        suspicion_against_me = Map.get(suspicion_board, player_id, [])

        {player_id,
         %{
           role: role,
           model: get(info, :model),
           is_mole: is_mole,
           won: won?(winner, is_mole, role),
           messages_sent: 0,
           operations_performed: 0,
           share_intel_count: 0,
           verify_agent_count: 0,
           report_suspicion_count: 0,
           intel_fragments_held: fragments_held,
           times_reported: length(suspicion_against_me)
         }}
      end)
      |> apply_message_log(message_log)
      |> apply_operations_log(operations_log)

    detection_accuracy = compute_detection_accuracy(suspicion_board, mole_id, players)
    propagation_efficiency = compute_propagation_efficiency(players, intel_pool)
    total_messages = count_total_messages(message_log)
    max_possible_messages = compute_max_possible_messages(world)
    network_utilization = safe_div(total_messages, max_possible_messages)

    %{
      benchmark_focus:
        "intel propagation, mole detection accuracy, network utilization, trust calibration",
      mole_id: mole_id,
      winner: winner,
      leaked_intel_count: length(leaked_intel),
      intel_pool_size: length(intel_pool),
      detection_accuracy: detection_accuracy,
      propagation_efficiency: propagation_efficiency,
      network_utilization: network_utilization,
      total_messages: total_messages,
      players: player_metrics,
      models: summarize_models(player_metrics)
    }
  end

  defp apply_message_log(metrics, message_log) do
    Enum.reduce(message_log, metrics, fn {_edge_key, messages}, acc ->
      Enum.reduce(messages, acc, fn msg, inner_acc ->
        sender = get(msg, :from, get(msg, "from"))
        update_player(inner_acc, sender, &Map.update!(&1, :messages_sent, fn c -> c + 1 end))
      end)
    end)
  end

  defp apply_operations_log(metrics, operations_log) do
    Enum.reduce(operations_log, metrics, fn record, acc ->
      player = get(record, :player_id)
      op_type = get(record, :operation_type)

      acc
      |> update_player(player, &Map.update!(&1, :operations_performed, fn c -> c + 1 end))
      |> maybe_increment_op(player, op_type, "share_intel", :share_intel_count)
      |> maybe_increment_op(player, op_type, "verify_agent", :verify_agent_count)
      |> maybe_increment_op(player, op_type, "report_suspicion", :report_suspicion_count)
    end)
  end

  defp maybe_increment_op(metrics, player, op_type, match, key) do
    if op_type == match do
      update_player(metrics, player, &Map.update!(&1, key, fn c -> c + 1 end))
    else
      metrics
    end
  end

  defp compute_detection_accuracy(_suspicion_board, nil, _players), do: 0.0

  defp compute_detection_accuracy(suspicion_board, mole_id, _players) do
    total_reports =
      suspicion_board
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    mole_reports = length(Map.get(suspicion_board, mole_id, []))

    if total_reports == 0, do: 0.0, else: Float.round(mole_reports / total_reports, 3)
  end

  defp compute_propagation_efficiency(_players, intel_pool) when length(intel_pool) == 0, do: 0.0

  defp compute_propagation_efficiency(players, intel_pool) do
    loyal_players =
      Enum.filter(players, fn {_id, p} ->
        get(p, :role, "operative") == "operative"
      end)

    if loyal_players == [] do
      0.0
    else
      # Average unique fragments per loyal player / total pool size
      avg_fragments =
        loyal_players
        |> Enum.map(fn {_id, p} -> length(get(p, :intel_fragments, [])) end)
        |> then(fn counts ->
          if counts == [], do: 0, else: Enum.sum(counts) / length(counts)
        end)

      Float.round(avg_fragments / length(intel_pool), 3)
    end
  end

  defp count_total_messages(message_log) do
    message_log
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
  end

  defp compute_max_possible_messages(world) do
    adjacency = get(world, :adjacency, %{})
    max_rounds = get(world, :max_rounds, 8)
    edge_count = adjacency |> Map.values() |> Enum.map(&length/1) |> Enum.sum() |> div(2)
    # Each player sends up to 2 per round, but topology limits it
    player_count = map_size(get(world, :players, %{}))
    min(player_count * 2 * max_rounds, edge_count * 2 * max_rounds)
  end

  defp safe_div(_a, 0), do: 0.0
  defp safe_div(a, b), do: Float.round(a / b, 3)

  defp won?(winner, _is_mole, "mole"),
    do: winner == "mole" or (is_binary(winner) and String.contains?(winner, "mole"))

  defp won?("loyalists", _is_mole, "operative"), do: true
  defp won?(_winner, _is_mole, _role), do: false

  defp find_mole_id(players) do
    case Enum.find(players, fn {_id, p} -> get(p, :role, "operative") == "mole" end) do
      {id, _} -> id
      nil -> nil
    end
  end

  defp summarize_models(player_metrics) do
    player_metrics
    |> Enum.group_by(fn {_player_id, metrics} -> get(metrics, :model, "unknown") end)
    |> Enum.into(%{}, fn {model, entries} ->
      metrics = Enum.map(entries, fn {_player_id, item} -> item end)

      {model,
       %{
         seats: length(metrics),
         wins: Enum.count(metrics, &get(&1, :won, false)),
         messages_sent: Enum.sum(Enum.map(metrics, &get(&1, :messages_sent, 0))),
         operations_performed: Enum.sum(Enum.map(metrics, &get(&1, :operations_performed, 0))),
         share_intel_count: Enum.sum(Enum.map(metrics, &get(&1, :share_intel_count, 0))),
         verify_agent_count: Enum.sum(Enum.map(metrics, &get(&1, :verify_agent_count, 0))),
         report_suspicion_count: Enum.sum(Enum.map(metrics, &get(&1, :report_suspicion_count, 0)))
       }}
    end)
  end

  defp update_player(metrics, nil, _updater), do: metrics

  defp update_player(metrics, player_id, updater) do
    case Map.fetch(metrics, player_id) do
      {:ok, item} -> Map.put(metrics, player_id, updater.(item))
      :error -> metrics
    end
  end
end
