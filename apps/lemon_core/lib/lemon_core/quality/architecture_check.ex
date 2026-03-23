defmodule LemonCore.Quality.ArchitectureCheck do
  @moduledoc """
  Enforces architecture boundaries for umbrella dependencies and module references.

  The check ensures:
  - each app's direct `in_umbrella: true` dependencies remain a subset of policy
  - each app's source files do not reference forbidden umbrella namespaces
  """

  alias LemonCore.Quality.ArchitecturePolicy

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

  @app_namespaces %{
    agent_core: ["AgentCore"],
    ai: ["Ai"],
    coding_agent: ["CodingAgent"],
    coding_agent_ui: ["CodingAgent.UI", "CodingAgentUi"],
    lemon_automation: ["LemonAutomation"],
    lemon_channels: ["LemonChannels"],
    lemon_control_plane: ["LemonControlPlane"],
    lemon_core: ["LemonCore"],
    lemon_gateway: ["LemonGateway"],
    lemon_mcp: ["LemonMCP"],
    lemon_router: ["LemonRouter"],
    lemon_ai_runtime: ["LemonAiRuntime"],
    lemon_sim: ["LemonSim"],
    lemon_services: ["LemonServices"],
    lemon_skills: ["LemonSkills"],
    lemon_web: ["LemonWeb"],
    market_intel: ["MarketIntel"]
  }

  @exact_module_owners %{
    "CodingAgent.UI" => :coding_agent,
    "CodingAgent.UI.Context" => :coding_agent,
    "CodingAgent.UI.RPC" => :coding_agent_ui,
    "CodingAgent.UI.Headless" => :coding_agent_ui,
    "CodingAgent.UI.DebugRPC" => :coding_agent_ui
  }

  @namespace_prefix_owners @app_namespaces
                           |> Enum.flat_map(fn {owner, prefixes} ->
                             Enum.map(prefixes, &{&1, owner})
                           end)
                           |> Enum.sort_by(fn {prefix, _owner} -> -String.length(prefix) end)

  @doc """
  Runs all architecture boundary checks for the umbrella project.

  Checks include:
    * Unknown app detection - apps in apps/ without policy configuration
    * Missing app detection - expected apps that don't exist in apps/
    * Dependency violations - umbrella deps that exceed allowed boundaries
    * Namespace violations - module references to apps not in deps

  Returns `{:ok, report}` if no issues found, `{:error, report}` otherwise.

  ## Options
    * `:root` - root directory of the umbrella project (defaults to current working directory)
  """
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

  @doc """
  Returns the allowed direct dependencies map for all umbrella apps.

  This map defines which umbrella dependencies each app is allowed to have.
  Used for validating the architecture boundary constraints.
  """
  @spec allowed_direct_deps() :: %{optional(atom()) => [atom()]}
  def allowed_direct_deps, do: ArchitecturePolicy.allowed_direct_deps()

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
    with {:ok, source} <- File.read(mix_file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast
      |> find_deps_asts()
      |> Enum.flat_map(&extract_umbrella_dep_atoms/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      _ -> []
    end
  end

  defp find_deps_asts(ast) do
    {_ast, deps_asts} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [{:deps, _, _args}, [do: body]]} = node, acc ->
          {node, [body | acc]}

        {:defp, _meta, [{:deps, _, _args}, [do: body]]} = node, acc ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    deps_asts
  end

  defp extract_umbrella_dep_atoms(deps_ast) do
    deps_ast
    |> dependency_entries()
    |> Enum.flat_map(&extract_umbrella_dep_atom/1)
  end

  defp dependency_entries(list) when is_list(list), do: list
  defp dependency_entries(_), do: []

  defp extract_umbrella_dep_atom({dep, opts}) when is_atom(dep) and is_list(opts) do
    if keyword_true?(opts, :in_umbrella), do: [dep], else: []
  end

  defp extract_umbrella_dep_atom({dep, _version, opts}) when is_atom(dep) and is_list(opts) do
    if keyword_true?(opts, :in_umbrella), do: [dep], else: []
  end

  defp extract_umbrella_dep_atom({:{}, _meta, [dep | tuple_elements]}) when is_atom(dep) do
    if umbrella_dependency_tuple?(tuple_elements), do: [dep], else: []
  end

  defp extract_umbrella_dep_atom(_entry), do: []

  defp umbrella_dependency_tuple?(tuple_elements) when is_list(tuple_elements) do
    Enum.any?(tuple_elements, &keyword_true?(&1, :in_umbrella))
  end

  defp keyword_true?(value, key) when is_list(value) do
    Enum.any?(value, fn
      {^key, true} -> true
      _ -> false
    end)
  end

  defp keyword_true?(_value, _key), do: false

  @spec check_unknown_apps([issue()], %{optional(atom()) => [atom()]}) :: [issue()]
  defp check_unknown_apps(issues, actual) do
    allowed_direct_deps = allowed_direct_deps()

    Enum.reduce(actual, issues, fn {app, _deps}, acc ->
      if Map.has_key?(allowed_direct_deps, app) do
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
    Enum.reduce(allowed_direct_deps(), issues, fn {app, _deps}, acc ->
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
    allowed_direct_deps = allowed_direct_deps()

    Enum.reduce(actual, issues, fn {app, deps}, acc ->
      allowed = Map.get(allowed_direct_deps, app, [])
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
    allowed_direct_deps = allowed_direct_deps()

    Enum.reduce(actual, issues, fn {app, _deps}, acc ->
      allowed_owners = MapSet.new([app | Map.get(allowed_direct_deps, app, [])])

      app
      |> app_source_files(root)
      |> Enum.reduce(acc, fn file, file_acc ->
        case parse_module_references(file) do
          {:ok, refs} ->
            Enum.reduce(refs, file_acc, fn {module_name, line}, ref_acc ->
              case owner_for_module(module_name) do
                nil ->
                  ref_acc

                owner ->
                  if MapSet.member?(allowed_owners, owner) do
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
              module_name = Enum.map_join(parts, ".", &Atom.to_string/1)
              line = meta[:line] || get_in(meta, [:closing, :line]) || 1
              {node, MapSet.put(acc, {module_name, line})}
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

  defp owner_for_module(full_name) when is_binary(full_name) do
    case Map.get(@exact_module_owners, full_name) do
      nil ->
        @namespace_prefix_owners
        |> Enum.find(fn {prefix, _owner} ->
          full_name == prefix || String.starts_with?(full_name, prefix <> ".")
        end)
        |> case do
          nil -> nil
          {_prefix, owner} -> owner
        end

      owner ->
        owner
    end
  end

  defp allowed_list(app) do
    allowed_direct_deps()
    |> Map.get(app, [])
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end
end
