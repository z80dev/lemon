defmodule LemonCore.Quality.ArchitectureCheck do
  @moduledoc """
  Enforces umbrella app dependency boundaries from `apps/*/mix.exs`.

  The check ensures each app's direct `in_umbrella: true` dependencies remain
  a subset of the declared architecture policy.
  """

  @type issue :: %{
          code: atom(),
          message: String.t(),
          app: atom() | nil
        }

  @type report :: %{
          root: String.t(),
          apps_checked: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()],
          actual_dependencies: %{optional(atom()) => [atom()]}
        }

  @allowed_direct_deps %{
    agent_core: [:ai, :lemon_core],
    ai: [:lemon_core],
    coding_agent: [:agent_core, :ai, :lemon_core, :lemon_skills],
    coding_agent_ui: [:coding_agent],
    lemon_automation: [:lemon_core, :lemon_router],
    lemon_channels: [:lemon_core, :lemon_gateway],
    lemon_control_plane: [:ai, :lemon_automation, :lemon_channels, :lemon_core, :lemon_router, :lemon_skills],
    lemon_core: [],
    lemon_gateway: [:agent_core, :coding_agent, :lemon_core],
    lemon_router: [:agent_core, :coding_agent, :lemon_channels, :lemon_core, :lemon_gateway],
    lemon_skills: [:agent_core, :ai, :lemon_core]
  }

  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    actual = load_actual_dependencies(root)

    issues =
      []
      |> check_unknown_apps(actual)
      |> check_missing_apps(actual)
      |> check_dependency_violations(actual)

    report = %{
      root: root,
      apps_checked: map_size(actual),
      issue_count: length(issues),
      issues: Enum.reverse(issues),
      actual_dependencies: actual
    }

    if report.issue_count == 0 do
      {:ok, report}
    else
      {:error, report}
    end
  end

  @spec allowed_direct_deps() :: %{optional(atom()) => [atom()]}
  def allowed_direct_deps, do: @allowed_direct_deps

  @spec load_actual_dependencies(String.t()) :: %{optional(atom()) => [atom()]}
  defp load_actual_dependencies(root) do
    root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Enum.reduce(%{}, fn mix_file, acc ->
      app = mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
      deps = parse_umbrella_deps(mix_file)
      Map.put(acc, app, deps)
    end)
  end

  @spec parse_umbrella_deps(String.t()) :: [atom()]
  defp parse_umbrella_deps(mix_file) do
    mix_file
    |> File.read!()
    |> then(fn content ->
      Regex.scan(~r/\{\s*:([a-z_]+)\s*,\s*in_umbrella:\s*true\s*\}/, content,
        capture: :all_but_first
      )
    end)
    |> List.flatten()
    |> Enum.map(&String.to_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec check_unknown_apps([issue()], %{optional(atom()) => [atom()]}) :: [issue()]
  defp check_unknown_apps(issues, actual) do
    Enum.reduce(actual, issues, fn {app, _deps}, acc ->
      if Map.has_key?(@allowed_direct_deps, app) do
        acc
      else
        [
          %{
            code: :unknown_app,
            message: "No boundary policy configured for app: #{app}",
            app: app
          }
          | acc
        ]
      end
    end)
  end

  @spec check_missing_apps([issue()], %{optional(atom()) => [atom()]}) :: [issue()]
  defp check_missing_apps(issues, actual) do
    Enum.reduce(@allowed_direct_deps, issues, fn {app, _deps}, acc ->
      if Map.has_key?(actual, app) do
        acc
      else
        [
          %{
            code: :missing_app,
            message: "Expected app is missing from apps/*/mix.exs scan: #{app}",
            app: app
          }
          | acc
        ]
      end
    end)
  end

  @spec check_dependency_violations([issue()], %{optional(atom()) => [atom()]}) :: [issue()]
  defp check_dependency_violations(issues, actual) do
    Enum.reduce(actual, issues, fn {app, deps}, acc ->
      allowed = Map.get(@allowed_direct_deps, app, [])
      forbidden = deps -- allowed

      Enum.reduce(forbidden, acc, fn dep, inner_acc ->
        [
          %{
            code: :forbidden_dependency,
            message:
              "App #{app} has forbidden umbrella dependency #{dep}. Allowed: #{Enum.join(Enum.map(allowed, &to_string/1), ", ")}",
            app: app
          }
          | inner_acc
        ]
      end)
    end)
  end
end
