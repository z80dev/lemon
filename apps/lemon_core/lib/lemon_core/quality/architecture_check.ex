defmodule LemonCore.Quality.ArchitectureCheck do
  @moduledoc """
  Enforces architecture boundaries for umbrella dependencies and module references.

  The check ensures:
  - each app's direct `in_umbrella: true` dependencies remain a subset of policy
  - each app's source files do not reference forbidden umbrella namespaces
  """

  @type issue :: %{
          code: atom(),
          message: String.t(),
          app: atom() | nil,
          path: String.t() | nil
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
    lemon_channels: [:lemon_core],
    lemon_control_plane: [
      :ai,
      :coding_agent,
      :lemon_automation,
      :lemon_channels,
      :lemon_core,
      :lemon_router,
      :lemon_skills
    ],
    lemon_core: [],
    lemon_gateway: [
      :agent_core,
      :ai,
      :coding_agent,
      :lemon_automation,
      :lemon_channels,
      :lemon_core
    ],
    lemon_router: [:agent_core, :ai, :coding_agent, :lemon_channels, :lemon_core, :lemon_gateway],
    lemon_skills: [:agent_core, :ai, :lemon_channels, :lemon_core]
  }

  @app_namespaces %{
    agent_core: ["AgentCore"],
    ai: ["Ai"],
    coding_agent: ["CodingAgent"],
    coding_agent_ui: ["CodingAgentUI"],
    lemon_automation: ["LemonAutomation"],
    lemon_channels: ["LemonChannels"],
    lemon_control_plane: ["LemonControlPlane"],
    lemon_core: ["LemonCore"],
    lemon_gateway: ["LemonGateway"],
    lemon_router: ["LemonRouter"],
    lemon_skills: ["LemonSkills"]
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
      |> check_namespace_violations(root, actual)

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
            app: app,
            path: nil
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
            app: app,
            path: nil
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
            app: app,
            path: nil
          }
          | inner_acc
        ]
      end)
    end)
  end

  @spec check_namespace_violations([issue()], String.t(), %{optional(atom()) => [atom()]}) ::
          [issue()]
  defp check_namespace_violations(issues, root, actual) do
    namespace_owners = namespace_owners()

    Enum.reduce(actual, issues, fn {app, _deps}, acc ->
      allowed_prefixes = allowed_namespace_prefixes(app)

      app
      |> app_source_files(root)
      |> Enum.reduce(acc, fn file, file_acc ->
        case parse_module_references(file) do
          {:ok, refs} ->
            Enum.reduce(refs, file_acc, fn {prefix, module_name, line}, ref_acc ->
              case Map.get(namespace_owners, prefix) do
                nil ->
                  ref_acc

                ^app ->
                  ref_acc

                owner ->
                  if MapSet.member?(allowed_prefixes, prefix) do
                    ref_acc
                  else
                    issue = %{
                      code: :forbidden_namespace_reference,
                      message:
                        "App #{app} references #{module_name} (owned by #{owner}) outside allowed deps: #{allowed_list(app)}",
                      app: app,
                      path: "#{Path.relative_to(file, root)}:#{line || 1}"
                    }

                    [issue | ref_acc]
                  end
              end
            end)

          {:error, reason} ->
            [
              %{
                code: :source_parse_error,
                message: "Failed to parse #{Path.relative_to(file, root)}: #{inspect(reason)}",
                app: app,
                path: Path.relative_to(file, root)
              }
              | file_acc
            ]
        end
      end)
    end)
  end

  defp app_source_files(app, root) when is_atom(app) and is_binary(root) do
    root
    |> Path.join("apps/#{app}/lib/**/*.ex")
    |> Path.wildcard()
  end

  defp parse_module_references(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, token_metadata: true) do
      {_ast, refs} =
        Macro.prewalk(ast, MapSet.new(), fn
          {:__aliases__, meta, parts} = node, acc when is_list(parts) ->
            if Enum.all?(parts, &is_atom/1) and parts != [] do
              prefix = parts |> hd() |> Atom.to_string()
              module_name = Enum.map_join(parts, ".", &Atom.to_string/1)
              line = meta[:line] || get_in(meta, [:closing, :line]) || 1
              {node, MapSet.put(acc, {prefix, module_name, line})}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      {:ok, MapSet.to_list(refs)}
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  defp namespace_owners do
    Enum.reduce(@app_namespaces, %{}, fn {app, prefixes}, acc ->
      Enum.reduce(prefixes, acc, fn prefix, inner -> Map.put(inner, prefix, app) end)
    end)
  end

  defp allowed_namespace_prefixes(app) do
    allowed_apps = [app | Map.get(@allowed_direct_deps, app, [])]

    allowed_apps
    |> Enum.flat_map(fn dep -> Map.get(@app_namespaces, dep, []) end)
    |> MapSet.new()
  end

  defp allowed_list(app) do
    @allowed_direct_deps
    |> Map.get(app, [])
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end
end
