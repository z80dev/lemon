Application.ensure_all_started(:coding_agent)

defmodule LemonTerminalProcessSmoke do
  alias CodingAgent.ProcessManager

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    output_path =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "terminal-process-latest.json"])

    File.mkdir_p!(Path.dirname(output_path))

    proof =
      try do
        run_smoke()
      rescue
        error ->
          proof(:failed, [
            failed_check("terminal_process_smoke", Exception.message(error))
          ])
      end

    File.write!(output_path, Jason.encode!(proof, pretty: true))
    IO.puts("terminal process smoke wrote #{output_path}")

    IO.puts(
      "completed=#{proof.completed_count} skipped=#{proof.skipped_count} failed=#{proof.failed_count}"
    )

    if proof.failed_count > 0 do
      System.halt(1)
    end
  end

  defp run_smoke do
    command = "printf lemon-terminal-process-smoke"

    with {:ok, initial} <- ProcessManager.exec_sync(command: command, use_lane_queue: false),
         :ok <- assert_completed(initial, "lemon-terminal-process-smoke"),
         {:ok, initial_polled} <- ProcessManager.poll(initial.process_id),
         :ok <- assert_metadata(initial_polled),
         {:ok, restarted_id, restart_metadata} <-
           ProcessManager.restart(initial.process_id, use_lane_queue: false),
         :ok <- assert_restart_metadata(initial.process_id, restarted_id, restart_metadata),
         {:ok, restarted} <- wait_completed(restarted_id),
         :ok <- assert_completed(restarted, "lemon-terminal-process-smoke"),
         :ok <- assert_restart_result(initial.process_id, restarted) do
      cleanup_ids([initial.process_id, restarted_id])

      proof(:completed, [
        completed_check("initial_process_completion"),
        completed_check("process_metadata_visibility"),
        completed_check("manual_process_restart"),
        completed_check("restarted_process_completion"),
        completed_check("process_cleanup")
      ])
      |> Map.put(:details, %{
        initial_process_hash: hash(initial.process_id),
        restarted_process_hash: hash(restarted_id),
        command_hash: hash(command),
        initial_output_hash: output_hash(initial),
        restarted_output_hash: output_hash(restarted),
        restart_generation: restarted.restart_generation,
        cleanup: cleanup()
      })
    else
      {:error, reason} ->
        proof(:failed, [failed_check("terminal_process_smoke", inspect(reason))])
    end
  end

  defp assert_completed(%{status: :completed, exit_code: 0} = result, expected) do
    if result.logs |> Enum.join("\n") |> String.contains?(expected) do
      :ok
    else
      {:error, :missing_expected_output}
    end
  end

  defp assert_completed(result, _expected), do: {:error, {:unexpected_result, summarize(result)}}

  defp assert_metadata(result) do
    cond do
      result.backend != :local ->
        {:error, {:unexpected_backend, result.backend}}

      :shell not in result.terminal_capabilities ->
        {:error, :missing_shell_capability}

      not is_integer(result.log_line_count) or result.log_line_count < 1 ->
        {:error, {:bad_log_line_count, result.log_line_count}}

      not is_integer(result.max_log_lines) ->
        {:error, {:bad_max_log_lines, result.max_log_lines}}

      not is_integer(result.started_at) ->
        {:error, {:bad_started_at, result.started_at}}

      true ->
        :ok
    end
  end

  defp assert_restart_metadata(initial_id, restarted_id, metadata) do
    cond do
      restarted_id == initial_id ->
        {:error, :restart_reused_process_id}

      metadata.restarted_from != initial_id ->
        {:error, :restart_metadata_missing_origin}

      metadata.restart_generation != 1 ->
        {:error, {:bad_restart_generation, metadata.restart_generation}}

      true ->
        :ok
    end
  end

  defp assert_restart_result(initial_id, result) do
    cond do
      result.restarted_from != initial_id ->
        {:error, :restarted_result_missing_origin}

      result.restart_generation != 1 ->
        {:error, {:bad_restarted_result_generation, result.restart_generation}}

      result.status != :completed ->
        {:error, {:bad_restarted_status, result.status}}

      true ->
        :ok
    end
  end

  defp wait_completed(process_id) do
    Enum.reduce_while(1..40, {:error, :timeout}, fn _, _ ->
      case ProcessManager.poll(process_id) do
        {:ok, %{status: status} = result} when status in [:completed, :error, :killed] ->
          {:halt, {:ok, result}}

        {:ok, _result} ->
          Process.sleep(100)
          {:cont, {:error, :timeout}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_ids(process_ids) do
    Enum.each(process_ids, fn process_id ->
      _ = ProcessManager.clear(process_id)
    end)

    :ok
  end

  defp proof(:completed, checks) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "completed",
      proof_object: "lemon.terminal_process_smoke",
      proof_scope: "terminal_process",
      checks: checks,
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      skipped_count: Enum.count(checks, &(&1.status == "skipped")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      cleanup: cleanup()
    }
  end

  defp proof(:failed, checks) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: "failed",
      proof_object: "lemon.terminal_process_smoke",
      proof_scope: "terminal_process",
      checks: checks,
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      skipped_count: Enum.count(checks, &(&1.status == "skipped")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      cleanup: cleanup()
    }
  end

  defp completed_check(name), do: %{name: name, status: "completed"}
  defp failed_check(name, reason), do: %{name: name, status: "failed", reason: reason}

  defp summarize(result) when is_map(result), do: Map.take(result, [:status, :exit_code])
  defp summarize(result), do: result

  defp output_hash(result), do: result.logs |> Enum.join("\n") |> hash()

  defp cleanup do
    %{
      includes_raw_commands: false,
      includes_raw_logs: false,
      includes_raw_process_ids: false
    }
  end

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonTerminalProcessSmoke.main(System.argv())
