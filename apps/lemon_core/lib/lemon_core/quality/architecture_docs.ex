defmodule LemonCore.Quality.ArchitectureDocs do
  @moduledoc """
  Renders and validates the generated sections of the architecture boundaries
  document: the per-app dependency policy and the package map.

  The package map lists each app's `mix.exs` version and whether the app is in
  the Hex publish set. An app is published when its `project/0` declares
  `package:`; that set must equal the `PACKAGES` list in
  `scripts/verify_packages`, which `scripts/release_package` publishes from.
  """

  alias LemonCore.Quality.{ArchitectureCheck, ArchitecturePolicy}

  @doc_relative_path "docs/architecture_boundaries.md"
  @package_list_relative_path "scripts/verify_packages"
  @sections [:architecture_policy, :package_map]

  @type issue :: %{
          code: atom(),
          message: String.t(),
          path: String.t() | nil
        }

  @type report :: %{
          root: String.t(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @type package_entry :: %{version: String.t() | :unreadable | nil, published?: boolean()}

  @spec doc_relative_path() :: String.t()
  def doc_relative_path, do: @doc_relative_path

  @spec render_dependency_policy_markdown(String.t()) :: String.t()
  def render_dependency_policy_markdown(root \\ File.cwd!()) do
    lib_deps = ArchitectureCheck.lib_dependencies(root)
    test_deps = ArchitectureCheck.test_dependencies(root)
    seams = ArchitecturePolicy.reference_only_namespace_exceptions()

    header = [
      "| App | Role | Lib deps from `mix.exs` | `only: :test` deps | Reference-only seams |",
      "| --- | --- | --- | --- | --- |"
    ]

    rows =
      ArchitecturePolicy.app_namespaces()
      |> Map.keys()
      |> Enum.concat(Map.keys(lib_deps))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn app ->
        lib_cell =
          case Map.fetch(lib_deps, app) do
            {:ok, deps} -> dependency_cell(deps)
            :error -> "*(missing app)*"
          end

        test_cell = test_deps |> Map.get(app, []) |> dependency_cell()
        seam_cell = seams |> Map.get(app, []) |> dependency_cell()

        "| `#{app}` | #{role(app)} | #{lib_cell} | #{test_cell} | #{seam_cell} |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  defp role(app) do
    cond do
      app in ArchitecturePolicy.foundations() -> "foundation"
      app in ArchitecturePolicy.satellites() -> "satellite"
      app in ArchitecturePolicy.test_kits() -> "test kit"
      true -> "platform"
    end
  end

  @spec render_package_map_markdown(String.t()) :: String.t()
  def render_package_map_markdown(root \\ File.cwd!()) do
    header = [
      "| App | Version in `mix.exs` | Hex publish set |",
      "| --- | --- | --- |"
    ]

    rows =
      root
      |> package_map()
      |> Enum.sort()
      |> Enum.map(fn {app, entry} ->
        "| `#{app}` | #{version_cell(entry.version)} | #{if entry.published?, do: "yes", else: "no"} |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  @doc """
  Each app's `project/0` version and whether it declares Hex `package:`
  metadata, parsed from `apps/*/mix.exs` without evaluating them.
  """
  @spec package_map(String.t()) :: %{optional(atom()) => package_entry()}
  def package_map(root) do
    root
    |> Path.join("apps/*/mix.exs")
    |> Path.wildcard()
    |> Map.new(fn mix_file ->
      app = mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
      {app, parse_package_entry(mix_file)}
    end)
  end

  @spec replace_generated_sections(String.t(), keyword(String.t())) ::
          {:ok, String.t()} | {:error, issue()}
  def replace_generated_sections(content, rendered) do
    Enum.reduce_while(rendered, {:ok, content}, fn {section, markdown}, {:ok, acc} ->
      {section_start, section_end} = markers(section)
      pattern = ~r/#{Regex.escape(section_start)}\n.*?\n#{Regex.escape(section_end)}/s
      replacement = Enum.join([section_start, markdown, section_end], "\n")

      if Regex.match?(pattern, acc) do
        {:cont, {:ok, Regex.replace(pattern, acc, fn _ -> replacement end)}}
      else
        {:halt,
         {:error,
          %{
            code: :missing_architecture_doc_markers,
            message:
              "Architecture boundaries doc is missing generated-section markers: #{section_start} / #{section_end}",
            path: @doc_relative_path
          }}}
      end
    end)
  end

  @spec write(String.t()) :: :ok | {:error, issue()}
  def write(root) do
    case generate(root) do
      {:ok, _existing, generated} ->
        case File.write(doc_path(root), generated) do
          :ok -> :ok
          {:error, reason} -> {:error, read_or_write_issue(:write_failed, "write", reason)}
        end

      {:error, issue} ->
        {:error, issue}
    end
  end

  @spec check(String.t()) :: {:ok, report()} | {:error, report()}
  def check(root) do
    stale =
      case generate(root) do
        {:ok, existing, existing} ->
          []

        {:ok, _existing, _generated} ->
          [
            %{
              code: :stale_architecture_doc,
              message: "Architecture boundaries doc is stale. Run `mix lemon.architecture.docs`.",
              path: @doc_relative_path
            }
          ]

        {:error, issue} ->
          [issue]
      end

    case stale ++ package_set_issues(root) do
      [] -> {:ok, report(root, [])}
      issues -> {:error, report(root, issues)}
    end
  end

  @spec generate(String.t()) :: {:ok, String.t(), String.t()} | {:error, issue()}
  def generate(root) do
    rendered = Enum.map(@sections, &{&1, render(&1, root)})

    with {:ok, existing} <- File.read(doc_path(root)),
         {:ok, generated} <- replace_generated_sections(existing, rendered) do
      {:ok, existing, generated}
    else
      {:error, %{} = issue} ->
        {:error, issue}

      {:error, reason} ->
        {:error, read_or_write_issue(:read_failed, "read", reason)}
    end
  end

  defp render(:architecture_policy, root), do: render_dependency_policy_markdown(root)
  defp render(:package_map, root), do: render_package_map_markdown(root)

  defp markers(section), do: {"<!-- #{section}:start -->", "<!-- #{section}:end -->"}

  # The release tooling's package list and the apps carrying Hex metadata must
  # name the same set; either one drifting alone publishes the wrong packages.
  defp package_set_issues(root) do
    declared =
      for {app, %{published?: true}} <- package_map(root), into: MapSet.new(), do: app

    case release_package_list(root) do
      {:ok, listed} ->
        only_mix = declared |> MapSet.difference(listed) |> Enum.sort()
        only_script = listed |> MapSet.difference(declared) |> Enum.sort()

        if only_mix == [] and only_script == [] do
          []
        else
          [
            %{
              code: :package_set_mismatch,
              message:
                "Hex publish set differs: `package:` in mix.exs only #{inspect(only_mix)}, " <>
                  "#{@package_list_relative_path} PACKAGES only #{inspect(only_script)}",
              path: @package_list_relative_path
            }
          ]
        end

      {:error, message} ->
        [%{code: :package_list_unreadable, message: message, path: @package_list_relative_path}]
    end
  end

  defp release_package_list(root) do
    with {:ok, source} <- File.read(Path.join(root, @package_list_relative_path)),
         [_, names] <- Regex.run(~r/^PACKAGES=\(([^)]*)\)/m, source) do
      {:ok, names |> String.split() |> MapSet.new(&String.to_atom/1)}
    else
      {:error, reason} ->
        {:error,
         "Failed to read #{@package_list_relative_path}: #{:file.format_error(reason) |> to_string()}"}

      nil ->
        {:error, "#{@package_list_relative_path} has no PACKAGES=(...) list"}
    end
  end

  defp parse_package_entry(mix_file) do
    with {:ok, source} <- File.read(mix_file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      attributes = module_attributes(ast)
      project = project_keywords(ast)

      version =
        case Keyword.get(project, :version) do
          version when is_binary(version) -> version
          {:@, _, [{name, _, _}]} -> Map.get(attributes, name)
          _ -> nil
        end

      %{version: version, published?: Keyword.has_key?(project, :package)}
    else
      _ -> %{version: :unreadable, published?: false}
    end
  end

  defp module_attributes(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) and is_binary(value) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  # Top-level keyword pairs returned by `def project`, including lists joined
  # with `++`; nested option lists are not project keys.
  defp project_keywords(ast) do
    {_ast, pairs} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:project, _, _}, [do: body]]} = node, acc ->
          {node, acc ++ keyword_pairs(body)}

        node, acc ->
          {node, acc}
      end)

    pairs
  end

  defp keyword_pairs({:__block__, _, [_ | _] = exprs}),
    do: exprs |> List.last() |> keyword_pairs()

  defp keyword_pairs({:++, _, [left, right]}), do: keyword_pairs(left) ++ keyword_pairs(right)

  defp keyword_pairs(list) when is_list(list),
    do: Enum.filter(list, &match?({key, _} when is_atom(key), &1))

  defp keyword_pairs(_expression), do: []

  defp doc_path(root), do: Path.join(root, @doc_relative_path)

  defp dependency_cell([]), do: "*(none)*"
  defp dependency_cell(deps), do: Enum.map_join(deps, ", ", &"`#{&1}`")

  defp version_cell(version) when is_binary(version), do: version
  defp version_cell(:unreadable), do: "*(unreadable `mix.exs`)*"
  defp version_cell(nil), do: "*(not a literal)*"

  defp read_or_write_issue(code, action, reason) do
    %{
      code: code,
      message:
        "Failed to #{action} #{@doc_relative_path}: #{:file.format_error(reason) |> to_string()}",
      path: @doc_relative_path
    }
  end

  defp report(root, issues) do
    %{
      root: root,
      issue_count: length(issues),
      issues: issues
    }
  end
end
