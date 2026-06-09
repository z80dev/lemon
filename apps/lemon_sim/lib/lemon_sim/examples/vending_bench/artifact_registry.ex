defmodule LemonSim.Examples.VendingBench.ArtifactRegistry do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile

  @path Path.join(System.tmp_dir!(), "lemon_vending_bench_artifact_registry.json")
  @lock {__MODULE__, :registry}

  def path, do: @path

  def put(sim_id, artifact_dir) when is_binary(sim_id) and is_binary(artifact_dir) do
    :global.trans(@lock, fn ->
      registry =
        case File.read(@path) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, decoded} when is_map(decoded) -> decoded
              _ -> %{}
            end

          _ ->
            %{}
        end

      AtomicFile.write!(
        @path,
        registry
        |> Map.put(sim_id, artifact_dir)
        |> Jason.encode!(pretty: true)
      )
    end)

    :ok
  end
end
