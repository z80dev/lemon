defmodule LemonSim.Examples.VendingBench.Replay do
  @moduledoc """
  Loads VendingBench artifact directories and builds a compact replay browser.
  """

  alias LemonSim.Artifacts.AtomicFile

  @required_files ~w(final_world.json events.jsonl actions.jsonl scorecard.json)

  @spec build(String.t()) :: {:ok, map()} | {:error, term()}
  def build(artifact_dir) when is_binary(artifact_dir) do
    with :ok <- validate_artifact_dir(artifact_dir),
         {:ok, final_world} <- read_json(Path.join(artifact_dir, "final_world.json")),
         {:ok, scorecard} <- read_json(Path.join(artifact_dir, "scorecard.json")),
         {:ok, events} <- read_jsonl(Path.join(artifact_dir, "events.jsonl")),
         {:ok, actions} <- read_jsonl(Path.join(artifact_dir, "actions.jsonl")),
         {:ok, supplier_messages} <-
           read_optional_json(Path.join(artifact_dir, "supplier_messages.json"), %{}),
         {:ok, worker_history} <-
           read_optional_json(Path.join(artifact_dir, "worker_history.json"), %{}),
         {:ok, operator_transcript} <-
           read_optional_json(Path.join(artifact_dir, "operator_transcript.json"), %{}),
         {:ok, reminders} <- read_optional_json(Path.join(artifact_dir, "reminders.json"), []) do
      replay = %{
        artifact_dir: artifact_dir,
        sim_id: Map.get(scorecard, "sim_id", "unknown"),
        status: Map.get(scorecard, "status", Map.get(final_world, "status", "unknown")),
        day_number: Map.get(scorecard, "day_number", Map.get(final_world, "day_number")),
        scorecard: scorecard,
        final_world: final_world,
        timeline: timeline(events),
        action_summaries: actions,
        supplier_messages: supplier_messages,
        worker_history: worker_history,
        operator_transcript: operator_transcript,
        reminders: reminders,
        machine_fault_reports: Map.get(final_world, "machine_fault_reports", []),
        event_count: length(events),
        action_count: length(actions)
      }

      {:ok, replay}
    end
  end

  @spec write_browser(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_browser(artifact_dir, opts \\ []) do
    with {:ok, replay} <- build(artifact_dir) do
      output_dir = Keyword.get(opts, :output_dir, artifact_dir)
      File.mkdir_p!(output_dir)

      paths = %{
        replay_json: Path.join(output_dir, "replay.json"),
        replay_html: Path.join(output_dir, "replay.html")
      }

      AtomicFile.write!(paths.replay_json, Jason.encode!(replay, pretty: true))
      AtomicFile.write!(paths.replay_html, render_html(replay))

      {:ok, Map.put(paths, :replay, replay)}
    end
  end

  @spec render_html(map()) :: String.t()
  def render_html(replay) do
    scorecard = Map.get(replay, :scorecard, %{})
    scores = Map.get(scorecard, "score_modes", %{})
    timeline = Map.get(replay, :timeline, [])

    timeline_html =
      timeline
      |> Enum.map(fn entry ->
        """
        <li>
          <span class="day">D#{html(get(entry, :day, "?"))}</span>
          <span class="kind">#{html(get(entry, :kind, ""))}</span>
          <span class="summary">#{html(get(entry, :summary, ""))}</span>
        </li>
        """
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>VendingBench Replay #{html(Map.get(replay, :sim_id, ""))}</title>
      <style>
        body { margin: 0; background: #0a0f0d; color: #e8f0ea; font-family: system-ui, sans-serif; }
        main { max-width: 1040px; margin: 0 auto; padding: 28px; }
        h1 { margin: 0 0 8px; font-size: 28px; }
        .muted { color: #80a894; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 20px 0; }
        .metric { border: 1px solid #1a3024; border-radius: 8px; padding: 12px; background: #0f1a14; }
        .metric span { display: block; color: #80a894; font-size: 12px; }
        .metric strong { display: block; margin-top: 4px; color: #6ee7b7; font-size: 20px; }
        ol { list-style: none; padding: 0; margin: 0; border: 1px solid #1a3024; border-radius: 8px; overflow: hidden; }
        li { display: grid; grid-template-columns: 56px 190px 1fr; gap: 12px; padding: 10px 12px; border-bottom: 1px solid #13251b; }
        li:last-child { border-bottom: 0; }
        .day, .kind { color: #10b981; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
        .summary { color: #d8efe4; font-size: 13px; }
      </style>
    </head>
    <body>
      <main>
        <h1>VendingBench Replay</h1>
        <div class="muted">#{html(Map.get(replay, :sim_id, "unknown"))} · #{html(Map.get(replay, :status, "unknown"))} · day #{html(Map.get(replay, :day_number, "?"))}</div>
        <section class="grid">
          <div class="metric"><span>V1 net worth</span><strong>$#{format_money(get(scores, "v1_net_worth", 0))}</strong></div>
          <div class="metric"><span>Money balance</span><strong>$#{format_money(get(scores, "money_balance", 0))}</strong></div>
          <div class="metric"><span>Operational score</span><strong>#{html(get(scores, "lemon_operational_score", 0))}</strong></div>
          <div class="metric"><span>Events</span><strong>#{html(Map.get(replay, :event_count, 0))}</strong></div>
          <div class="metric"><span>Refunds</span><strong>$#{format_money(get(scorecard, "refunds_paid", 0))}</strong></div>
          <div class="metric"><span>Supplier incidents</span><strong>#{html(get(scorecard, "supplier_incident_count", 0))}</strong></div>
        </section>
        <h2>Timeline</h2>
        <ol>
          #{timeline_html}
        </ol>
      </main>
    </body>
    </html>
    """
  end

  defp validate_artifact_dir(artifact_dir) do
    missing =
      @required_files
      |> Enum.map(&Path.join(artifact_dir, &1))
      |> Enum.reject(&File.exists?/1)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_artifacts, missing}}
    end
  end

  defp read_json(path) do
    path
    |> File.read()
    |> case do
      {:ok, content} -> Jason.decode(content)
      {:error, reason} -> {:error, {reason, path}}
    end
  end

  defp read_optional_json(path, default) do
    if File.exists?(path) do
      read_json(path)
    else
      {:ok, default}
    end
  end

  defp read_jsonl(path) do
    path
    |> File.read()
    |> case do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case Jason.decode(line) do
            {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
            {:error, reason} -> {:halt, {:error, {:invalid_jsonl, path, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {reason, path}}
    end
  end

  defp timeline(events) do
    events
    |> Enum.map(&timeline_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp timeline_entry(%{"kind" => kind, "payload" => payload}) do
    %{
      kind: kind,
      day: event_day(kind, payload),
      summary: event_summary(kind, payload)
    }
  end

  defp timeline_entry(_event), do: nil

  defp event_day(_kind, payload), do: get(payload, "day", get(payload, "delivery_day", "?"))

  defp event_summary("supplier_email_sent", payload) do
    "Ordered #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} from #{get(payload, "supplier_id", "?")} for $#{format_money(get(payload, "cost", 0))}; delivery day #{get(payload, "delivery_day", "?")}"
  end

  defp event_summary("place_supplier_order", payload) do
    "Requested #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} from #{get(payload, "supplier_id", "?")}"
  end

  defp event_summary("supplier_order_placed", payload) do
    "Placed #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} from #{get(payload, "supplier_id", "?")} for $#{format_money(get(payload, "cost", 0))}; delivery day #{get(payload, "delivery_day", "?")}"
  end

  defp event_summary("supplier_reply_received", payload) do
    "#{get(payload, "supplier_id", "supplier")}: #{get(payload, "message", "")}"
  end

  defp event_summary("delivery_arrived", payload) do
    "Delivered #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} from #{get(payload, "supplier_id", "?")}"
  end

  defp event_summary("sale_realized", payload) do
    "Sold #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} from #{get(payload, "slot_id", "?")} for $#{format_money(get(payload, "revenue", 0))}"
  end

  defp event_summary("customer_refund_paid", payload) do
    "Refunded $#{format_money(get(payload, "amount", 0))} for #{get(payload, "quantity", 0)}x #{get(payload, "item_id", "?")} (#{get(payload, "reason", "refund")})"
  end

  defp event_summary("expired_inventory_removed", payload) do
    "Worker discarded #{get(payload, "quantity", 0)} expired #{get(payload, "item_id", "?")} unit(s); loss $#{format_money(get(payload, "loss", 0))}"
  end

  defp event_summary("machine_fault_reported", payload) do
    "Worker reported #{get(payload, "severity", "low")} machine fault: #{get(payload, "description", "")}"
  end

  defp event_summary("physical_worker_finished", payload) do
    "Worker finished: #{get(payload, "summary", "")}"
  end

  defp event_summary("day_advanced", payload) do
    "Advanced from day #{get(payload, "from_day", "?")} to day #{get(payload, "to_day", "?")}"
  end

  defp event_summary("game_over", payload) do
    "Game over: #{get(payload, "reason", "completed")}"
  end

  defp event_summary(kind, payload), do: "#{kind}: #{inspect(payload)}"

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default

  defp html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp format_money(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp format_money(value) when is_integer(value),
    do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp format_money(value) do
    case Float.parse(to_string(value)) do
      {number, _} -> :erlang.float_to_binary(number, decimals: 2)
      :error -> to_string(value)
    end
  end
end
