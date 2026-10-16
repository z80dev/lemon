defmodule LemonCli.CronCommand do
  @moduledoc "Cron job management through the running control plane."

  alias LemonCli.RunsCommand

  def run([]), do: run(["list"])

  def run(["list" | args]) do
    case OptionParser.parse(args, strict: [failing: :boolean, json: :boolean]) do
      {opts, [], []} -> list(opts)
      _ -> usage()
    end
  end

  def run([action, "--all"]) when action in ~w(pause resume), do: mutate_all(action)

  def run([action | args]) when action in ~w(pause resume run remove) do
    case OptionParser.parse(args, strict: [yes: :boolean]) do
      {opts, [target], []} when target != "" ->
        if action != "remove" and opts != [], do: usage(), else: mutate(action, target, opts)

      _ ->
        usage()
    end
  end

  def run(_), do: usage()

  defp list(opts) do
    case jobs() do
      {:ok, jobs} ->
        jobs = Enum.filter(jobs, &(opts[:failing] != true or (&1["failureStreak"] || 0) > 0))

        if opts[:json] do
          IO.puts(Jason.encode!(%{jobs: jobs, total: length(jobs)}))
        else
          IO.puts("ID | NAME | SCHEDULE | ENABLED | NEXT RUN | FAILURE STREAK | LAST STATUS")

          Enum.each(jobs, fn job ->
            IO.puts(
              Enum.map_join(
                ~w(id name schedule enabled nextRunAtMs failureStreak lastStatus),
                " | ",
                &clean(job[&1])
              )
            )
          end)
        end

        0

      {:error, reason} ->
        RunsCommand.failure(reason, opts[:json] == true)
    end
  end

  defp mutate(action, target, opts) do
    with {:ok, jobs} <- jobs(),
         {:ok, job} <- resolve(jobs, target),
         :ok <- confirm(action, job, opts),
         {:ok, result} <- RunsCommand.request("cron.#{action}", %{"id" => job["id"]}),
         :ok <- validate_receipt(action, result) do
      IO.puts("Cron #{action}: #{clean(job["id"])}#{run_id(result)}")
      0
    else
      {:refused, message} ->
        IO.puts(:stderr, message)
        1

      {:error, _reason} ->
        operation_failed()
    end
  end

  # One durable switch for every job: it never resolves or edits individual jobs.
  defp mutate_all(action) do
    with {:ok, result} <- RunsCommand.request("cron.#{action}", %{"all" => true}),
         {:ok, message} <- all_receipt(action, result) do
      IO.puts(message)
      0
    else
      {:error, _reason} -> operation_failed()
    end
  end

  defp all_receipt("pause", %{"all" => true, "paused" => true}) do
    {:ok,
     "All cron jobs paused. The pause survives restarts; resume with `lemon cron resume --all`."}
  end

  defp all_receipt("resume", %{"all" => true, "resumed" => true} = result) do
    {:ok,
     "All cron jobs resumed; skipped #{count(result["skippedJobCount"])} missed slot(s) " <>
       "and #{count(result["skippedRetryCount"])} retry(ies)."}
  end

  defp all_receipt("resume", %{"all" => true, "resumed" => false}),
    do: {:ok, "Cron jobs were not paused."}

  defp all_receipt(_action, _result), do: {:error, :invalid_response}

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0

  defp operation_failed do
    IO.puts(
      :stderr,
      "Cron operation failed; check runtime health and authentication. Do not retry an uncertain mutation without checking cron status/runs."
    )

    1
  end

  defp jobs do
    case RunsCommand.request("cron.list", %{"includeTargetText" => false}) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> {:ok, jobs}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp resolve(jobs, target) do
    case Enum.find(jobs, &(&1["id"] == target)) do
      nil -> resolve_name(jobs, target)
      job -> {:ok, job}
    end
  end

  defp resolve_name(jobs, target) do
    case Enum.filter(jobs, &(String.downcase(&1["name"] || "") == String.downcase(target))) do
      [job] ->
        {:ok, job}

      [] ->
        {:refused, "Cron job not found: #{clean(target)}"}

      matches ->
        {:refused,
         "Ambiguous cron name; use an ID: " <> Enum.map_join(matches, ", ", &clean(&1["id"]))}
    end
  end

  defp confirm("remove", job, opts) do
    cond do
      opts[:yes] ->
        :ok

      tty?() ->
        case IO.gets("Remove cron #{clean(job["name"])} (#{clean(job["id"])})? [y/N] ") do
          answer when is_binary(answer) ->
            if String.downcase(String.trim(answer)) in ["y", "yes"],
              do: :ok,
              else: {:refused, "Removal cancelled."}

          _ ->
            {:refused, "Removal cancelled."}
        end

      true ->
        {:refused,
         "Removal requires interactive confirmation; use --yes in non-interactive scripts."}
    end
  end

  defp confirm(_, _, _), do: :ok

  defp tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp validate_receipt("run", %{"runId" => id}) when is_binary(id) and id != "", do: :ok
  defp validate_receipt("run", _), do: {:error, :outcome_unknown}
  defp validate_receipt(_, _), do: :ok

  defp run_id(%{"runId" => id}), do: " · run #{clean(id)}"
  defp run_id(_), do: ""
  defp clean(nil), do: "-"

  defp clean(value),
    do:
      value
      |> to_string()
      |> LemonCore.Redact.text()
      |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ")

  defp usage do
    IO.puts(
      :stderr,
      "Use lemon cron list [--failing] [--json] | pause|resume|run <id|name> | pause|resume --all | remove <id|name> [--yes]."
    )

    2
  end
end
