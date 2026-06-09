defmodule Mix.Tasks.Lemon.Sim.Score do
  @moduledoc """
  Print the scorecard for a LemonSim run artifact bundle.

      mix lemon.sim.score path/to/run
  """

  use Mix.Task

  @impl true
  def run(args) do
    case args do
      [artifact_dir] ->
        path = Path.join(artifact_dir, "scorecard.json")

        with {:ok, body} <- File.read(path),
             {:ok, scorecard} <- Jason.decode(body) do
          Mix.shell().info(Jason.encode!(scorecard, pretty: true))
        else
          {:error, reason} ->
            Mix.shell().error("Could not read scorecard: #{inspect(reason)}")
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error(@moduledoc)
        exit({:shutdown, 1})
    end
  end
end
