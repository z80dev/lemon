defmodule LemonSkills.TestSupport.LearningNudgeConfig do
  @moduledoc false

  # Writes `[skills.learning_nudge]` into an isolated operator config.toml
  # (and optionally a project `.lemon/config.toml`) and reloads the config
  # cache. The operator path is global app env: use only from `async: false`
  # tests.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec isolate!(Path.t()) :: Path.t()
  def isolate!(dir) do
    previous = Application.get_env(:lemon_core, :paths)
    config = Path.join(dir, "operator-config.toml")
    Application.put_env(:lemon_core, :paths, Keyword.put(previous || [], :global_config, config))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    config
  end

  @spec put_operator!(Path.t() | nil, map()) :: :ok
  def put_operator!(cwd, settings) do
    File.write!(LemonCore.Paths.global_config(), toml(settings))
    LemonCore.Config.reload(cwd)
    :ok
  end

  @spec put_project!(Path.t(), map()) :: :ok
  def put_project!(cwd, settings) do
    path = LemonCore.Paths.project_config(cwd)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, toml(settings))
    LemonCore.Config.reload(cwd)
    :ok
  end

  defp toml(settings) do
    {review, nudge} = Map.pop(settings, "background_review")
    review_table = if review, do: "[skills.learning_nudge.background_review]\n" <> lines(review)
    "[skills.learning_nudge]\n" <> lines(nudge) <> (review_table || "")
  end

  defp lines(table) do
    table
    |> Enum.sort()
    |> Enum.map_join(fn {key, value} -> "#{key} = #{value(value)}\n" end)
  end

  defp value(value) when is_binary(value), do: inspect(value)
  defp value(value), do: to_string(value)
end
