defmodule LemonCore.Quality.ArchitectureDocs do
  @moduledoc """
  Renders and validates the generated dependency-policy section in the
  architecture boundaries document.
  """

  alias LemonCore.Quality.{ArchitectureCheck, ArchitecturePolicy}

  @doc_relative_path "docs/architecture_boundaries.md"
  @section_start "<!-- architecture_policy:start -->"
  @section_end "<!-- architecture_policy:end -->"

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

  @spec doc_relative_path() :: String.t()
  def doc_relative_path, do: @doc_relative_path

  @spec render_dependency_policy_markdown(String.t()) :: String.t()
  def render_dependency_policy_markdown(root \\ File.cwd!()) do
    actual = ArchitectureCheck.actual_direct_deps(root)
    allowed = ArchitecturePolicy.allowed_direct_deps()
    exceptions = ArchitecturePolicy.reference_only_namespace_exceptions()

    header = [
      "| App | Actual direct deps from `mix.exs` | Allowed direct deps | Reference-only exceptions |",
      "| --- | --- | --- | --- |"
    ]

    rows =
      allowed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn app ->
        actual_cell =
          case Map.fetch(actual, app) do
            {:ok, deps} -> dependency_cell(deps)
            :error -> "*(missing app)*"
          end

        allowed_cell = allowed |> Map.fetch!(app) |> dependency_cell()
        exception_cell = exceptions |> Map.get(app, []) |> dependency_cell()

        "| `#{app}` | #{actual_cell} | #{allowed_cell} | #{exception_cell} |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  @spec replace_generated_section(String.t(), String.t()) :: {:ok, String.t()} | {:error, issue()}
  def replace_generated_section(content, rendered_markdown \\ render_dependency_policy_markdown()) do
    replacement =
      Enum.join(
        [
          @section_start,
          rendered_markdown,
          @section_end
        ],
        "\n"
      )

    pattern =
      ~r/#{Regex.escape(@section_start)}\n.*?\n#{Regex.escape(@section_end)}/s

    if Regex.match?(pattern, content) do
      {:ok, Regex.replace(pattern, content, replacement)}
    else
      {:error,
       %{
         code: :missing_architecture_doc_markers,
         message:
           "Architecture boundaries doc is missing generated-section markers: #{@section_start} / #{@section_end}",
         path: @doc_relative_path
       }}
    end
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
    case generate(root) do
      {:ok, existing, generated} ->
        if existing == generated do
          {:ok, report(root, [])}
        else
          {:error,
           report(root, [
             %{
               code: :stale_architecture_doc,
               message:
                 "Architecture boundaries doc is stale. Run `mix lemon.architecture.docs`.",
               path: @doc_relative_path
             }
           ])}
        end

      {:error, issue} ->
        {:error, report(root, [issue])}
    end
  end

  @spec generate(String.t()) :: {:ok, String.t(), String.t()} | {:error, issue()}
  def generate(root) do
    path = doc_path(root)

    rendered_markdown = render_dependency_policy_markdown(root)

    with {:ok, existing} <- File.read(path),
         {:ok, generated} <- replace_generated_section(existing, rendered_markdown) do
      {:ok, existing, generated}
    else
      {:error, %{} = issue} ->
        {:error, issue}

      {:error, reason} ->
        {:error, read_or_write_issue(:read_failed, "read", reason)}
    end
  end

  defp doc_path(root), do: Path.join(root, @doc_relative_path)

  defp dependency_cell([]), do: "*(none)*"
  defp dependency_cell(deps), do: Enum.map_join(deps, ", ", &"`#{&1}`")

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
