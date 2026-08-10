defmodule LemonSim.Examples.VendingBench.ArtifactRegistry do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile

  @filename "lemon_vending_bench_artifact_registry.json"
  @lock {__MODULE__, :registry}

  @doc """
  Absolute path of the artifact registry.

  Resolved per call rather than frozen in a module attribute: the temp
  directory is environment state, so baking it in at compile time makes a
  release read the build machine's path, and makes readers compiled under a
  different TMPDIR disagree with this writer.
  """
  @spec path() :: Path.t()
  def path, do: Path.join(System.tmp_dir!(), @filename)

  def put(sim_id, artifact_dir) when is_binary(sim_id) and is_binary(artifact_dir) do
    :global.trans(@lock, fn ->
      registry =
        case File.read(path()) do
          {:ok, body} ->
            case Jason.decode(body) do
              {:ok, decoded} when is_map(decoded) -> decoded
              _ -> %{}
            end

          _ ->
            %{}
        end

      AtomicFile.write!(
        path(),
        registry
        |> Map.put(sim_id, artifact_dir)
        |> Jason.encode!(pretty: true)
      )
    end)

    :ok
  end
end
