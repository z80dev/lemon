defmodule Mix.Tasks.Lemon.Sim.Ratings do
  @moduledoc """
  Aggregate LemonSim suite leaderboards into cross-suite model ratings.

      mix lemon.sim.ratings --root /tmp/suites --out /tmp/ratings
      mix lemon.sim.ratings --suites /tmp/s1,/tmp/s2 --out /tmp/ratings

  `--root` scans the root directory and its direct children for `suite.json`.
  """

  use Mix.Task

  @switches [
    suites: :string,
    root: :string,
    out: :string,
    help: :boolean
  ]

  @spec run([String.t()]) :: :ok
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.shell().error("Invalid options: #{inspect(invalid)}")
        exit({:shutdown, 1})

      missing_input?(opts) ->
        Mix.shell().error(
          "Usage: mix lemon.sim.ratings --root DIR|--suites DIR1,DIR2 [--out DIR]"
        )

        exit({:shutdown, 1})

      true ->
        ensure_runtime_started!()
        run_ratings(opts)
    end
  end

  defp run_ratings(opts) do
    with {:ok, suite_dirs} <- suite_dirs(opts),
         {:ok, %{leaderboard: leaderboard}} <-
           LemonSim.Bench.Ratings.write(suite_dirs, out_dir(opts)) do
      Mix.shell().info(leaderboard)
    else
      {:error, reason} ->
        Mix.shell().error("Ratings failed: #{format_error(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp suite_dirs(opts) do
    explicit = split_csv(opts[:suites])

    with {:ok, discovered} <- discover(opts[:root]) do
      suite_dirs =
        (explicit ++ discovered)
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> Enum.sort()

      if suite_dirs == [] do
        {:error, :no_suites}
      else
        {:ok, suite_dirs}
      end
    end
  end

  defp discover(nil), do: {:ok, []}
  defp discover(root), do: LemonSim.Bench.Ratings.discover_suites(root)

  defp out_dir(opts), do: opts[:out] || opts[:root] || File.cwd!()

  defp missing_input?(opts), do: is_nil(opts[:root]) and is_nil(opts[:suites])

  defp split_csv(nil), do: []

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp format_error({:read_suite_failed, path, reason}) do
    "could not read #{path}: #{inspect(reason)}"
  end

  defp format_error({:invalid_suite, path, reason}) do
    "invalid suite #{path}: #{inspect(reason)}"
  end

  defp format_error({:root_not_found, root}), do: "root not found: #{root}"
  defp format_error(:no_suites), do: "no suite.json files found"
  defp format_error(reason), do: inspect(reason)

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end
end
