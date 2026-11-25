defmodule LemonCore.Quality.ScriptModulesTest do
  # Every umbrella module a `scripts/*.exs` file names must exist, so a
  # documented manual script cannot silently rot after a module is removed.
  # Runs from the umbrella root, where every umbrella app is on the code path.
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  test "repository scripts reference only existing umbrella modules" do
    scripts = Path.wildcard(Path.join(@repo_root, "scripts/**/*.exs"))
    assert scripts != []

    missing =
      for script <- scripts,
          module <- missing_modules(File.read!(script), script),
          do: {Path.relative_to(script, @repo_root), inspect(module)}

    assert missing == []
  end

  test "flags a removed module started under an alias" do
    source = """
    defmodule LemonScripts.Removed do
      alias LemonControlPlane.RetiredTracker
      alias LemonCore.{Store, MissingModule}

      def main, do: Supervisor.start_link([{RetiredTracker, []}, Store, MissingModule], strategy: :one_for_one)
    end
    """

    assert missing_modules(source, "fixture.exs") == [
             LemonControlPlane.RetiredTracker,
             LemonCore.MissingModule
           ]
  end

  test "accepts modules the script defines, including nested aliases" do
    source = """
    defmodule LemonScripts.Smoke.Client do
      def connect, do: :ok
    end

    defmodule LemonScripts.Smoke do
      alias LemonScripts.Smoke.Client

      defmodule Helper do
        def run, do: Client.connect()
      end

      def main, do: {Helper.run(), __MODULE__, LemonCore.Store, Jason}
    end
    """

    assert missing_modules(source, "fixture.exs") == []
  end

  test "accepts modules defined by a file the script requires and flags a missing one" do
    dir = Path.join(System.tmp_dir!(), "script_modules_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "support"))
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "support/probe.exs"), "defmodule LemonScripts.Probe, do: nil")

    source = """
    Code.require_file("support/probe.exs", __DIR__)
    Code.require_file("support/removed.exs", __DIR__)
    LemonScripts.Probe.run()
    """

    assert missing_modules(source, Path.join(dir, "smoke.exs")) == [
             Path.expand("support/removed.exs", dir)
           ]
  end

  defp missing_modules(source, file) do
    ast = Code.string_to_quoted!(source, file: file)
    {defined, aliases, refs} = scan(ast, nil, {MapSet.new(), %{}, []})
    {required, missing_files} = required_files(ast, file)
    defined = Enum.reduce(required, defined, &MapSet.union(&2, defined_modules(&1)))

    refs
    |> Enum.map(&expand(&1, aliases))
    |> Enum.uniq()
    |> Enum.filter(&umbrella_module?/1)
    |> Enum.reject(&defined_by_script?(&1, defined))
    |> Enum.reject(&Code.ensure_loaded?/1)
    |> Enum.concat(missing_files)
    |> Enum.sort()
  end

  # `Code.require_file("relative.exs", __DIR__)` loads support modules at run time.
  defp required_files(ast, file) do
    {_ast, paths} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, [path, {:__DIR__, _, _}]} =
            node,
        acc
        when is_binary(path) ->
          {node, [Path.expand(path, Path.dirname(file)) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.split_with(paths, &File.regular?/1)
  end

  defp defined_modules(path) do
    {defined, _aliases, _refs} =
      path
      |> File.read!()
      |> Code.string_to_quoted!(file: path)
      |> scan(nil, {MapSet.new(), %{}, []})

    defined
  end

  defp scan({:defmodule, _, [{:__aliases__, _, segments}, body]}, scope, acc) do
    module = if scope, do: Module.concat([scope | segments]), else: Module.concat(segments)
    {defined, aliases, refs} = acc

    aliases =
      if scope,
        do: Map.put(aliases, hd(segments), Module.concat(scope, hd(segments))),
        else: aliases

    scan(body, module, {MapSet.put(defined, module), aliases, refs})
  end

  defp scan(
         {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _]},
         _scope,
         acc
       ) do
    Enum.reduce(children, acc, fn {:__aliases__, _, segments}, {defined, aliases, refs} ->
      full = base ++ segments
      {defined, Map.put(aliases, List.last(segments), Module.concat(full)), [full | refs]}
    end)
  end

  defp scan({:alias, _, [{:__aliases__, _, segments} | opts]}, _scope, {defined, aliases, refs}) do
    short =
      case opts do
        [[as: {:__aliases__, _, [as]}]] -> as
        _ -> List.last(segments)
      end

    {defined, Map.put(aliases, short, Module.concat(segments)), [segments | refs]}
  end

  defp scan({:__aliases__, _, [first | _] = segments}, _scope, {defined, aliases, refs})
       when is_atom(first),
       do: {defined, aliases, [segments | refs]}

  defp scan({form, _, args}, scope, acc) when is_list(args),
    do: scan(args, scope, scan(form, scope, acc))

  defp scan({left, right}, scope, acc), do: scan(right, scope, scan(left, scope, acc))
  defp scan(list, scope, acc) when is_list(list), do: Enum.reduce(list, acc, &scan(&1, scope, &2))
  defp scan(_literal, _scope, acc), do: acc

  # Aliases are file-scoped here: scripts are small and alias each name once.
  defp expand([first | rest], aliases) do
    case Map.fetch(aliases, first) do
      {:ok, module} -> Module.concat([module | rest])
      :error -> Module.concat([first | rest])
    end
  end

  defp umbrella_module?(module) do
    case Module.split(module) do
      ["CodingAgent" | _] -> true
      [root | _] -> String.starts_with?(root, "Lemon")
    end
  end

  defp defined_by_script?(module, defined) do
    name = Atom.to_string(module)
    Enum.any?(defined, &(name == Atom.to_string(&1) or String.starts_with?(name, "#{&1}.")))
  end
end
