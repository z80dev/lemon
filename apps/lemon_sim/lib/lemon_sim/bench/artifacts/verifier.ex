defmodule LemonSim.Bench.Artifacts.Verifier do
  @moduledoc false

  def verify_run(artifact_dir) when is_binary(artifact_dir) do
    with {:ok, manifest} <- read_json(Path.join(artifact_dir, "manifest.json")),
         {:ok, hashes} <- read_json(Path.join(artifact_dir, "hashes.json")),
         :ok <- verify_schema(manifest),
         :ok <- verify_hashes_schema(hashes),
         :ok <- verify_expected_files(manifest, hashes),
         :ok <- verify_manifest_integrity(manifest, hashes),
         :ok <- verify_hashes(artifact_dir, hashes),
         {:ok, scorecard} <- read_json(Path.join(artifact_dir, "scorecard.json")) do
      {:ok, %{manifest: manifest, hashes: hashes, scorecard: scorecard}}
    end
  end

  defp verify_schema(%{"schema_version" => "lemon_sim.run.v1"}), do: :ok

  defp verify_schema(%{"schema_version" => version}),
    do: {:error, {:invalid_manifest_schema, version}}

  defp verify_schema(_other), do: {:error, :invalid_manifest_schema}

  defp verify_hashes_schema(%{"schema_version" => "lemon_sim.hashes.v1", "files" => files})
       when is_map(files),
       do: :ok

  defp verify_hashes_schema(%{"schema_version" => version}),
    do: {:error, {:invalid_hashes_schema, version}}

  defp verify_hashes_schema(_hashes), do: {:error, :invalid_hashes_file}

  defp verify_expected_files(manifest, %{"files" => files}) do
    required_files(manifest)
    |> Enum.find(fn file -> not Map.has_key?(files, file) end)
    |> case do
      nil -> :ok
      missing -> {:error, {:missing_required_hashed_file, missing}}
    end
  end

  defp required_files(%{"sim" => %{"id" => "vending_bench"}}) do
    [
      "final_world.json",
      "events.jsonl",
      "actions.jsonl",
      "supplier_messages.json",
      "worker_history.json",
      "operator_transcript.json",
      "reminders.json",
      "scorecard.json",
      "config.json",
      "commands.jsonl",
      "facts.jsonl",
      "tool_calls.jsonl",
      "prompts/operator.system.md",
      "prompts/operator.initial.md",
      "report.md",
      "replay.json",
      "replay.html"
    ]
  end

  defp required_files(%{"sim" => %{"id" => "tcg_shop"}}) do
    [
      "final_world.json",
      "events.jsonl",
      "actions.jsonl",
      "scorecard.json",
      "config.json",
      "commands.jsonl",
      "facts.jsonl",
      "market.json",
      "inventory.json",
      "counterparty_transcript.json",
      "replay.json",
      "replay.html",
      "report.md"
    ]
  end

  defp required_files(_manifest), do: []

  defp verify_manifest_integrity(%{"integrity" => integrity}, %{"files" => files}) do
    checks = [
      {"events_sha256", "events.jsonl"},
      {"scorecard_sha256", "scorecard.json"}
    ]

    Enum.reduce_while(checks, :ok, fn {integrity_key, file}, :ok ->
      case {Map.get(integrity, integrity_key), Map.get(files, file)} do
        {hash, hash} when is_binary(hash) -> {:cont, :ok}
        {nil, _} -> {:halt, {:error, {:missing_manifest_integrity, integrity_key}}}
        {_, nil} -> {:halt, {:error, {:missing_required_hashed_file, file}}}
        _ -> {:halt, {:error, {:manifest_integrity_mismatch, integrity_key, file}}}
      end
    end)
  end

  defp verify_manifest_integrity(_manifest, _hashes), do: {:error, :missing_manifest_integrity}

  defp verify_hashes(artifact_dir, %{"files" => files}) when is_map(files) do
    Enum.reduce_while(files, :ok, fn {basename, expected_hash}, :ok ->
      with {:ok, path} <- hashed_file_path(artifact_dir, basename),
           {:ok, body} <- File.read(path),
           actual_hash <- sha256(body),
           true <- actual_hash == expected_hash do
        {:cont, :ok}
      else
        {:error, :unsafe_hashed_file_path} ->
          {:halt, {:error, {:unsafe_hashed_file_path, basename}}}

        {:error, reason} ->
          {:halt, {:error, {:missing_hashed_file, basename, reason}}}

        false ->
          {:halt, {:error, {:hash_mismatch, basename}}}
      end
    end)
  end

  defp verify_hashes(_artifact_dir, _hashes), do: {:error, :invalid_hashes_file}

  defp read_json(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      {:ok, json}
    else
      {:error, reason} -> {:error, {:read_json_failed, path, reason}}
    end
  end

  defp hashed_file_path(artifact_dir, basename) when is_binary(basename) do
    root = Path.expand(artifact_dir)
    path = Path.expand(Path.join(root, basename))

    if String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, :unsafe_hashed_file_path}
    end
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
