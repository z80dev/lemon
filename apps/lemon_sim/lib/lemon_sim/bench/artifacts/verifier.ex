defmodule LemonSim.Bench.Artifacts.Verifier do
  @moduledoc false

  def verify_run(artifact_dir) when is_binary(artifact_dir) do
    with {:ok, manifest} <- read_json(Path.join(artifact_dir, "manifest.json")),
         {:ok, hashes} <- read_json(Path.join(artifact_dir, "hashes.json")),
         :ok <- verify_schema(manifest),
         :ok <- verify_hashes(artifact_dir, hashes),
         {:ok, scorecard} <- read_json(Path.join(artifact_dir, "scorecard.json")) do
      {:ok, %{manifest: manifest, hashes: hashes, scorecard: scorecard}}
    end
  end

  defp verify_schema(%{"schema_version" => "lemon_sim.run.v1"}), do: :ok

  defp verify_schema(%{"schema_version" => version}),
    do: {:error, {:invalid_manifest_schema, version}}

  defp verify_schema(_other), do: {:error, :invalid_manifest_schema}

  defp verify_hashes(artifact_dir, %{"files" => files}) when is_map(files) do
    Enum.reduce_while(files, :ok, fn {basename, expected_hash}, :ok ->
      path = Path.join(artifact_dir, basename)

      with {:ok, body} <- File.read(path),
           actual_hash <- sha256(body),
           true <- actual_hash == expected_hash do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, {:missing_hashed_file, path, reason}}}

        false ->
          {:halt, {:error, {:hash_mismatch, path}}}
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

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
