defmodule Mix.Tasks.Lemon.Proofs do
  @moduledoc """
  Show redacted local proof artifact status.

  ## Usage

      mix lemon.proofs
      mix lemon.proofs --project-dir /path/to/project --limit 5
      mix lemon.proofs --json

  ## Options

    * `--project-dir` - Project root to scan. Defaults to the current directory.
    * `--limit` - Number of recent proofs and checks to show. Defaults to 20.
    * `--json` - Emit the raw redacted diagnostics JSON.
  """

  use Mix.Task

  alias LemonCore.Doctor.ProofDiagnostics

  @default_limit 20

  @impl true
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project_dir: :string,
          limit: :integer,
          json: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    project_dir = opts[:project_dir] || File.cwd!()
    limit = normalize_limit(opts[:limit])
    status = ProofDiagnostics.status(project_dir: project_dir, limit: limit)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(status, pretty: true))
    else
      print_text(status, limit)
    end
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 1_000)
  defp normalize_limit(_), do: Mix.raise("--limit must be a positive integer")

  defp print_text(status, limit) do
    cleanup = Map.get(status, :cleanup, %{})

    Mix.shell().info("Lemon Proofs")
    Mix.shell().info("Proofs: #{Map.get(status, :proof_count, 0)}")
    Mix.shell().info("Completed: #{Map.get(status, :completed_count, 0)}")
    Mix.shell().info("Failed: #{Map.get(status, :failed_count, 0)}")
    Mix.shell().info("Skipped: #{Map.get(status, :skipped_count, 0)}")
    Mix.shell().info("Invalid: #{Map.get(status, :invalid_count, 0)}")
    Mix.shell().info("Includes raw paths: #{truthy?(cleanup[:includes_raw_paths])}")
    Mix.shell().info("Includes raw filenames: #{truthy?(cleanup[:includes_raw_filenames])}")

    Mix.shell().info(
      "Includes raw proof details: #{truthy?(cleanup[:includes_raw_proof_details])}"
    )

    Mix.shell().info("Includes raw prompts: #{truthy?(cleanup[:includes_raw_prompts])}")

    Mix.shell().info(
      "Includes raw provider responses: #{truthy?(cleanup[:includes_raw_provider_responses])}"
    )

    Mix.shell().info("")

    print_counts("Status Counts", Map.get(status, :status_counts, %{}))
    print_counts("Proof Scopes", Map.get(status, :proof_scope_counts, %{}))
    print_counts("Reason Kinds", Map.get(status, :reason_kind_counts, %{}))
    print_directories(Map.get(status, :directories, []))
    print_recent_proofs(Map.get(status, :recent_proofs, []), limit)
    print_latest_checks(Map.get(status, :latest_checks, []), limit)
  end

  defp print_counts(label, counts) when counts == %{} do
    Mix.shell().info("#{label}: none")
  end

  defp print_counts(label, counts) do
    Mix.shell().info("#{label}:")

    counts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.each(fn {key, value} ->
      Mix.shell().info("  #{key}: #{value}")
    end)
  end

  defp print_directories(directories) do
    Mix.shell().info("Directories:")

    Enum.each(directories, fn directory ->
      Mix.shell().info(
        "  #{directory.label}: exists=#{directory.exists} files=#{directory.file_count} path_hash=#{short_hash(directory.path_hash)}"
      )
    end)
  end

  defp print_recent_proofs([], _limit) do
    Mix.shell().info("Recent Proofs: none")
  end

  defp print_recent_proofs(proofs, limit) do
    Mix.shell().info("Recent Proofs:")

    proofs
    |> Enum.take(limit)
    |> Enum.each(fn proof ->
      scopes =
        proof
        |> Map.get(:proof_scopes, [])
        |> Enum.join(", ")
        |> empty_as("none")

      Mix.shell().info(
        "  #{Map.get(proof, :status, "unknown")} proof_hash=#{short_hash(proof[:proof_hash])} file_hash=#{short_hash(proof[:file_hash])} object=#{Map.get(proof, :proof_object) || "unknown"} scopes=#{scopes}"
      )
    end)
  end

  defp print_latest_checks([], _limit) do
    Mix.shell().info("Latest Checks: none")
  end

  defp print_latest_checks(checks, limit) do
    Mix.shell().info("Latest Checks:")

    checks
    |> Enum.take(limit)
    |> Enum.each(fn check ->
      Mix.shell().info(
        "  #{Map.get(check, :name, "unknown")}: #{Map.get(check, :status, "unknown")} proof_hash=#{short_hash(check[:proof_hash])}"
      )
    end)
  end

  defp short_hash(nil), do: "unknown"
  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp short_hash(_), do: "unknown"

  defp truthy?(value), do: if(value, do: "true", else: "false")

  defp empty_as("", fallback), do: fallback
  defp empty_as(value, _fallback), do: value
end
