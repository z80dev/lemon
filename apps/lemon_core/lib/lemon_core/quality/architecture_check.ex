defmodule LemonCore.Quality.ArchitectureCheck do
  @moduledoc """
  Enforces architecture rules over the umbrella dependency graph.

  The declared graph is read from `apps/*/mix.exs` (the only authority) and
  checked against the roles in `LemonCore.Quality.ArchitecturePolicy`:

    * foundations declare no umbrella dependency
    * nothing depends on a satellite
    * test kits are only `only: :test` dependencies
    * the graph of declared edges plus reference-only seams is acyclic
    * every lib edge is referenced from the app's `lib/`, and no `only: :test`
      edge is
    * every reference seam is used and is not also a declared edge

  Cross-app references are discovered statically in `apps/*/lib/**/*.ex` in
  every form that reaches another app: aliases, quoted `:"Elixir.Module"`
  atoms, `Module.concat/1,2` with literal namespace segments (including
  `"Lemon" <> "X"` concatenations) and `Application`/`:application` env access
  naming another umbrella app. Each must resolve to the app itself or one of
  its lib dependencies; seams are allowed for the alias form only. Quoted
  atoms and literal `Module.concat` hide an edge from the compiler and xref,
  so they are rejected even toward a dependency. Modules named in
  `config/*.exs` under `config :app` must likewise belong to `app` or its
  dependencies.
  """

  alias LemonCore.Quality.ArchitecturePolicy

  @type issue :: %{
          code: atom(),
          message: String.t(),
          app: atom() | nil,
          path: String.t() | nil
        }

  @type dependency_map :: %{optional(atom()) => [atom()]}

  @type report :: %{
          root: String.t(),
          apps_checked: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()],
          lib_dependencies: dependency_map(),
          test_dependencies: dependency_map(),
          reference_only_namespace_exceptions: dependency_map()
        }

  @typep dep :: %{app: atom(), test_only?: boolean()}

  @app_env_functions [
    :get_env,
    :fetch_env,
    :fetch_env!,
    :get_all_env,
    :compile_env,
    :compile_env!,
    :put_env,
    :put_all_env,
    :delete_env
  ]

  @doc """
  Runs every architecture rule against the umbrella at `opts[:root]`
  (default: the current directory).

  Returns `{:ok, report}` when no rule is violated, `{:error, report}` otherwise.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    declared = declared_dependencies(root)
    known_apps = Map.keys(declared)
    lib_deps = select_deps(declared, false)
    test_deps = select_deps(declared, true)
    seams = ArchitecturePolicy.reference_only_namespace_exceptions()
    bindings = ArchitecturePolicy.config_bindings()

    runtime_edges =
      Map.merge(seams, bindings, fn _app, left, right -> Enum.uniq(left ++ right) end)

    {references, parse_issues} = lib_references(root, known_apps)

    issues =
      registry_issues(declared) ++
        parse_issues ++
        foundation_issues(declared, seams) ++
        satellite_issues(declared, runtime_edges) ++
        test_kit_issues(declared) ++
        cycle_issues(declared, runtime_edges) ++
        reference_issues(references, lib_deps, test_deps, seams) ++
        unreferenced_dependency_issues(references, lib_deps) ++
        seam_issues(references, declared, seams) ++
        config_issues(root, known_apps, lib_deps, bindings)

    report = %{
      root: root,
      apps_checked: map_size(declared),
      issue_count: length(issues),
      issues: issues,
      lib_dependencies: lib_deps,
      test_dependencies: test_deps,
      reference_only_namespace_exceptions: seams
    }

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  @doc """
  Reads the direct umbrella dependency graph declared by `apps/*/mix.exs`,
  lib and test-only edges together.

  Dependency lists may be returned directly or wrapped by a helper such as the
  published packages' `lemon_deps/1`; the parser walks the complete `deps/0`
  body so both forms produce the same graph.
  """
  @spec actual_direct_deps(String.t()) :: dependency_map()
  def actual_direct_deps(root) do
    root
    |> declared_dependencies()
    |> Map.new(fn {app, deps} -> {app, deps |> Enum.map(& &1.app) |> Enum.sort()} end)
  end

  @doc "Declared `in_umbrella` edges without `only: :test`, per app."
  @spec lib_dependencies(String.t()) :: dependency_map()
  def lib_dependencies(root), do: root |> declared_dependencies() |> select_deps(false)

  @doc "Declared `in_umbrella` edges restricted to `only: :test`, per app."
  @spec test_dependencies(String.t()) :: dependency_map()
  def test_dependencies(root), do: root |> declared_dependencies() |> select_deps(true)

  # ---------------------------------------------------------------------------
  # mix.exs parsing
  # ---------------------------------------------------------------------------

  @spec declared_dependencies(String.t()) :: %{optional(atom()) => [dep()]}
  defp declared_dependencies(root) do
    root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Map.new(fn mix_file ->
      app = mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
      {app, parse_umbrella_deps(mix_file)}
    end)
  end

  defp select_deps(declared, test_only?) do
    Map.new(declared, fn {app, deps} ->
      {app, for(%{app: dep, test_only?: ^test_only?} <- deps, do: dep) |> Enum.sort()}
    end)
  end

  defp parse_umbrella_deps(mix_file) do
    with {:ok, source} <- File.read(mix_file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      ast
      |> find_deps_asts()
      |> Enum.flat_map(&extract_umbrella_deps/1)
      |> Enum.uniq_by(& &1.app)
      |> Enum.sort_by(& &1.app)
    else
      _ -> []
    end
  end

  defp find_deps_asts(ast) do
    {_ast, deps_asts} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [{:deps, _, _args}, [do: body]]} = node, acc when kind in [:def, :defp] ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    deps_asts
  end

  defp extract_umbrella_deps(deps_ast) do
    {_ast, deps} =
      Macro.prewalk(deps_ast, [], fn node, deps ->
        {node, extract_umbrella_dep(node) ++ deps}
      end)

    deps
  end

  defp extract_umbrella_dep({dep, opts}) when is_atom(dep) and is_list(opts),
    do: umbrella_dep(dep, opts)

  # Quoted tuples are themselves three-element AST nodes; match them before
  # treating a three-element tuple as a dependency literal.
  defp extract_umbrella_dep({:{}, _meta, [dep | elements]}) when is_atom(dep) do
    elements |> Enum.filter(&is_list/1) |> Enum.flat_map(&umbrella_dep(dep, &1))
  end

  defp extract_umbrella_dep({dep, _version, opts}) when is_atom(dep) and is_list(opts),
    do: umbrella_dep(dep, opts)

  defp extract_umbrella_dep(_entry), do: []

  defp umbrella_dep(dep, opts) do
    if keyword_value(opts, :in_umbrella) == true do
      [%{app: dep, test_only?: test_only?(keyword_value(opts, :only))}]
    else
      []
    end
  end

  defp test_only?(:test), do: true
  defp test_only?([:test]), do: true
  defp test_only?(_only), do: false

  defp keyword_value(opts, key) do
    Enum.find_value(opts, fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  # ---------------------------------------------------------------------------
  # Graph rules
  # ---------------------------------------------------------------------------

  defp registry_issues(declared) do
    namespaces = ArchitecturePolicy.app_namespaces()

    unknown =
      for app <- Enum.sort(Map.keys(declared)), not Map.has_key?(namespaces, app) do
        issue(:unknown_app, app, nil, "No namespace ownership configured for app: #{app}")
      end

    missing =
      for app <- Enum.sort(Map.keys(namespaces)), not Map.has_key?(declared, app) do
        issue(:missing_app, app, nil, "Expected app is missing from apps/*/mix.exs scan: #{app}")
      end

    unknown ++ missing
  end

  defp foundation_issues(declared, seams) do
    for app <- ArchitecturePolicy.foundations(),
        target <- Enum.map(Map.get(declared, app, []), & &1.app) ++ Map.get(seams, app, []) do
      issue(
        :foundation_dependency,
        app,
        "apps/#{app}/mix.exs",
        "Foundation #{app} must have no umbrella dependencies, but depends on #{target}"
      )
    end
  end

  defp satellite_issues(declared, seams) do
    satellites = MapSet.new(ArchitecturePolicy.satellites())

    for {app, targets} <- edges(declared, seams),
        target <- targets,
        MapSet.member?(satellites, target) do
      issue(
        :satellite_dependent,
        app,
        "apps/#{app}/mix.exs",
        "#{app} depends on satellite #{target}; satellites register through platform seams and have no dependents"
      )
    end
  end

  defp test_kit_issues(declared) do
    kits = MapSet.new(ArchitecturePolicy.test_kits())

    for {app, deps} <- Enum.sort(declared),
        %{app: dep, test_only?: false} <- deps,
        MapSet.member?(kits, dep) do
      issue(
        :test_kit_runtime_dependency,
        app,
        "apps/#{app}/mix.exs",
        "#{app} depends on test kit #{dep} outside `only: :test`"
      )
    end
  end

  defp edges(declared, seams) do
    declared
    |> Map.new(fn {app, deps} ->
      {app, Enum.uniq(Enum.map(deps, & &1.app) ++ Map.get(seams, app, []))}
    end)
    |> Enum.sort()
  end

  defp cycle_issues(declared, seams) do
    graph = Map.new(edges(declared, seams))

    graph
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({MapSet.new(), []}, fn app, {done, cycles} ->
      {done, found} = find_cycles(app, graph, done, [])
      {done, cycles ++ found}
    end)
    |> elem(1)
    |> Enum.uniq_by(&MapSet.new/1)
    |> Enum.map(fn [app | _] = cycle ->
      issue(
        :dependency_cycle,
        app,
        nil,
        "Dependency cycle through declared edges and reference seams: " <>
          Enum.map_join(cycle ++ [app], " -> ", &to_string/1)
      )
    end)
  end

  defp find_cycles(app, graph, done, path) do
    cond do
      app in path ->
        cycle = path |> Enum.reverse() |> Enum.drop_while(&(&1 != app))
        {done, [cycle]}

      MapSet.member?(done, app) ->
        {done, []}

      true ->
        {done, cycles} =
          graph
          |> Map.get(app, [])
          |> Enum.sort()
          |> Enum.reduce({done, []}, fn target, {done, acc} ->
            {done, found} = find_cycles(target, graph, done, [app | path])
            {done, acc ++ found}
          end)

        {MapSet.put(done, app), cycles}
    end
  end

  # ---------------------------------------------------------------------------
  # Source reference rules
  # ---------------------------------------------------------------------------

  defp reference_issues(references, lib_deps, test_deps, seams) do
    for {app, refs} <- Enum.sort(references),
        ref <- refs,
        ref.owner != app,
        issue = reference_issue(app, ref, lib_deps, test_deps, seams) do
      issue
    end
  end

  defp reference_issue(app, ref, lib_deps, test_deps, seams) do
    lib? = ref.owner in Map.get(lib_deps, app, [])
    seam? = ref.owner in Map.get(seams, app, [])
    hidden? = ref.form in [:quoted_atom, :module_concat]

    cond do
      hidden? and (lib? or seam?) ->
        issue(
          :hidden_module_reference,
          app,
          ref.path,
          "#{describe(ref)} hides an edge from the compiler and xref; reference #{ref.module} by alias"
        )

      lib? or (seam? and ref.form == :alias) ->
        nil

      ref.owner in Map.get(test_deps, app, []) ->
        issue(
          :test_dependency_in_lib,
          app,
          ref.path,
          "#{describe(ref)} reaches #{ref.owner}, an `only: :test` dependency of #{app}"
        )

      true ->
        issue(
          :forbidden_namespace_reference,
          app,
          ref.path,
          "#{describe(ref)} reaches #{ref.owner}, which is not a lib dependency of #{app}. Allowed: #{allowed_list(app, lib_deps, seams)}"
        )
    end
  end

  defp describe(%{form: :alias, module: module}), do: "Reference to #{module}"
  defp describe(%{form: :quoted_atom, module: module}), do: ~s(Quoted atom :"Elixir.#{module}")
  defp describe(%{form: :module_concat, module: module}), do: "Module.concat building #{module}"
  defp describe(%{form: :app_env, module: app}), do: "Application env access to :#{app}"

  defp unreferenced_dependency_issues(references, lib_deps) do
    for {app, deps} <- Enum.sort(lib_deps),
        referenced = references |> Map.get(app, []) |> MapSet.new(& &1.owner),
        dep <- deps,
        not MapSet.member?(referenced, dep) do
      issue(
        :unreferenced_dependency,
        app,
        "apps/#{app}/mix.exs",
        "#{app} declares lib dependency #{dep} but nothing in apps/#{app}/lib references it; remove the edge or make it `only: :test`"
      )
    end
  end

  defp seam_issues(references, declared, seams) do
    for {app, owners} <- Enum.sort(seams),
        owner <- owners,
        issue = seam_issue(app, owner, references, declared) do
      issue
    end
  end

  defp seam_issue(app, owner, references, declared) do
    cond do
      owner in Enum.map(Map.get(declared, app, []), & &1.app) ->
        issue(
          :redundant_reference_exception,
          app,
          nil,
          "#{app} declares #{owner} in mix.exs; remove the reference-only exception"
        )

      not Enum.any?(Map.get(references, app, []), &(&1.owner == owner and &1.form == :alias)) ->
        issue(
          :stale_reference_exception,
          app,
          nil,
          "Reference-only exception #{app} -> #{owner} is unused; remove it"
        )

      true ->
        nil
    end
  end

  defp lib_references(root, known_apps) do
    known = MapSet.new(known_apps)

    known_apps
    |> Enum.sort()
    |> Enum.reduce({%{}, []}, fn app, {refs, issues} ->
      root
      |> Path.join("apps/#{app}/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.reduce({refs, issues}, fn file, {refs, issues} ->
        path = Path.relative_to(file, root)

        case source_references(file, path, known) do
          {:ok, found} ->
            {Map.update(refs, app, found, &(&1 ++ found)), issues}

          {:error, reason} ->
            message = "Failed to parse #{path}: #{inspect(reason)}"
            {refs, issues ++ [issue(:source_parse_error, app, path, message)]}
        end
      end)
    end)
  end

  defp source_references(file, path, known) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: false) do
      {:ok, ast |> collect_references(known) |> Enum.map(&located(&1, path))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp located({owner, module, form, line}, path),
    do: %{owner: owner, module: module, form: form, path: "#{path}:#{line}"}

  @doc false
  # Returns `{owner, module_or_app, form, line}` for every cross-reference form
  # in `ast` that names an owned namespace or a known umbrella app's env.
  @spec collect_references(Macro.t(), MapSet.t(atom())) :: [tuple()]
  def collect_references(ast, known_apps) do
    {_ast, {refs, _line}} =
      Macro.prewalk(ast, {[], 1}, fn node, {refs, line} ->
        line = node_line(node) || line
        {node, {reference(node, line, known_apps) ++ refs, line}}
      end)

    refs |> Enum.uniq() |> Enum.reverse()
  end

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_node), do: nil

  defp reference({:__aliases__, _meta, [_ | _] = parts}, line, _known) do
    if Enum.all?(parts, &is_atom/1) do
      parts = if hd(parts) == Elixir, do: tl(parts), else: parts
      module_reference(Enum.map_join(parts, ".", &Atom.to_string/1), :alias, line)
    else
      []
    end
  end

  defp reference(atom, line, _known) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> module -> module_reference(module, :quoted_atom, line)
      _ -> []
    end
  end

  defp reference({{:., _, [{:__aliases__, _, [:Module]}, fun]}, _meta, args}, line, _known)
       when fun in [:concat, :safe_concat] and is_list(args) do
    segments =
      case args do
        [list] when is_list(list) -> list
        [left, right] -> [left, right]
        _ -> []
      end

    segments
    |> literal_segments()
    |> case do
      [] -> []
      parts -> module_reference(Enum.join(parts, "."), :module_concat, line)
    end
  end

  defp reference({{:., _, [module, fun]}, _meta, [app | _]}, line, known)
       when fun in @app_env_functions and is_atom(app) do
    if app_env_module?(module) and MapSet.member?(known, app) do
      [{app, Atom.to_string(app), :app_env, line}]
    else
      []
    end
  end

  defp reference(_node, _line, _known), do: []

  defp app_env_module?({:__aliases__, _, [:Application]}), do: true
  defp app_env_module?(:application), do: true
  defp app_env_module?(_module), do: false

  # Leading literal segments of a Module.concat argument list; stops at the
  # first segment that is not known at compile time.
  defp literal_segments(segments) do
    Enum.reduce_while(segments, [], fn segment, acc ->
      case literal_string(segment) do
        {:ok, ""} -> {:cont, acc}
        {:ok, string} -> {:cont, acc ++ [string]}
        :error -> {:halt, acc}
      end
    end)
  end

  defp literal_string(binary) when is_binary(binary), do: {:ok, binary}

  defp literal_string(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> module -> {:ok, module}
      string -> {:ok, string}
    end
  end

  defp literal_string({:__aliases__, _, parts}) do
    if Enum.all?(parts, &is_atom/1),
      do: {:ok, Enum.map_join(parts, ".", &Atom.to_string/1)},
      else: :error
  end

  defp literal_string({:<>, _, [left, right]}) do
    with {:ok, left} <- literal_string(left),
         {:ok, right} <- literal_string(right) do
      {:ok, left <> right}
    end
  end

  defp literal_string(_segment), do: :error

  defp module_reference(module, form, line) do
    case owner_for_module(module) do
      nil -> []
      owner -> [{owner, module, form, line}]
    end
  end

  @doc "Returns the app owning `module_name` (dotted, without `Elixir.`), or nil."
  @spec owner_for_module(String.t()) :: atom() | nil
  def owner_for_module(module_name) when is_binary(module_name) do
    Enum.find_value(namespace_prefix_owners(), fn {prefix, owner} ->
      if module_name == prefix or String.starts_with?(module_name, prefix <> "."), do: owner
    end)
  end

  defp namespace_prefix_owners do
    ArchitecturePolicy.app_namespaces()
    |> Enum.flat_map(fn {owner, prefixes} -> Enum.map(prefixes, &{&1, owner}) end)
    |> Enum.sort_by(fn {prefix, _owner} -> -String.length(prefix) end)
  end

  # ---------------------------------------------------------------------------
  # config/*.exs
  # ---------------------------------------------------------------------------

  defp config_issues(root, known_apps, lib_deps, bindings) do
    known = MapSet.new(known_apps)
    reach = Map.new(known_apps, &{&1, reachable(&1, lib_deps)})

    {refs, parse_issues} =
      root
      |> Path.join("config/*.exs")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn file, {refs, issues} ->
        path = Path.relative_to(file, root)

        with {:ok, source} <- File.read(file),
             {:ok, ast} <- Code.string_to_quoted(source, columns: false) do
          found =
            for {app, args} <- config_calls(ast, known),
                {owner, module, form, line} <- collect_references(args, known),
                form != :app_env and owner != app,
                do: %{app: app, owner: owner, module: module, path: "#{path}:#{line}"}

          {refs ++ found, issues}
        else
          {:error, reason} ->
            message = "Failed to parse #{path}: #{inspect(reason)}"
            {refs, issues ++ [issue(:source_parse_error, nil, path, message)]}
        end
      end)

    unrelated =
      for %{app: app, owner: owner} = ref <- refs,
          not MapSet.member?(reach[app], owner),
          not MapSet.member?(Map.get(reach, owner, MapSet.new()), app),
          owner not in Map.get(bindings, app, []) do
        issue(
          :config_module_reference,
          app,
          ref.path,
          "config :#{app} names #{ref.module} (owned by #{owner}); #{app} and #{owner} are unrelated. Declare a dependency or a config binding"
        )
      end

    stale =
      for {app, owners} <- Enum.sort(bindings),
          owner <- owners,
          not Enum.any?(refs, &(&1.app == app and &1.owner == owner)) do
        issue(
          :stale_config_binding,
          app,
          nil,
          "Config binding #{app} -> #{owner} is unused in config/*.exs; remove it"
        )
      end

    parse_issues ++ unrelated ++ stale
  end

  # Apps reachable from `app` through declared lib dependencies.
  defp reachable(app, lib_deps), do: reachable(Map.get(lib_deps, app, []), lib_deps, MapSet.new())

  defp reachable([], _lib_deps, seen), do: seen

  defp reachable([app | rest], lib_deps, seen) do
    if MapSet.member?(seen, app),
      do: reachable(rest, lib_deps, seen),
      else: reachable(Map.get(lib_deps, app, []) ++ rest, lib_deps, MapSet.put(seen, app))
  end

  defp config_calls(ast, known) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:config, _meta, [app | args]} = node, acc when is_atom(app) ->
          if MapSet.member?(known, app), do: {node, [{app, args} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp allowed_list(app, lib_deps, seams) do
    (Map.get(lib_deps, app, []) ++ Map.get(seams, app, []))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> "(none)"
      owners -> Enum.map_join(owners, ", ", &to_string/1)
    end
  end

  defp issue(code, app, path, message), do: %{code: code, message: message, app: app, path: path}
end
