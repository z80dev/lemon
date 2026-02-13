defmodule LemonCore.Quality.Cleanup do
  @moduledoc """
  Scans and prunes stale agent-loop run artifacts.

  Default mode is dry-run and reports:
  - stale docs from `LemonCore.Quality.DocsCheck`
  - run artifacts older than retention window
  """

  alias LemonCore.Quality.DocsCheck

  @default_retention_days 14

  @type report :: %{
          root: String.t(),
          retention_days: pos_integer(),
          old_run_files: [String.t()],
          stale_docs: [map()],
          deleted_files: [String.t()]
        }

  @spec scan(keyword()) :: report()
  def scan(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    retention_days = Keyword.get(opts, :retention_days, @default_retention_days)
    today = Keyword.get(opts, :today, Date.utc_today())

    old_run_files = find_old_run_files(root, retention_days, today)
    stale_docs = find_stale_docs(root, today)

    %{
      root: root,
      retention_days: retention_days,
      old_run_files: old_run_files,
      stale_docs: stale_docs,
      deleted_files: []
    }
  end

  @spec prune(keyword()) :: report()
  def prune(opts \\ []) do
    report = scan(opts)
    apply_changes = Keyword.get(opts, :apply, false)

    if apply_changes do
      deleted_files =
        report.old_run_files
        |> Enum.filter(&File.exists?/1)
        |> Enum.filter(fn path -> File.rm(path) == :ok end)

      %{report | deleted_files: deleted_files}
    else
      report
    end
  end

  @spec find_stale_docs(String.t(), Date.t()) :: [map()]
  defp find_stale_docs(root, today) do
    case DocsCheck.run(root: root, today: today) do
      {:ok, _report} ->
        []

      {:error, report} ->
        Enum.filter(report.issues, &(&1.code == :stale_doc))
    end
  end

  @spec find_old_run_files(String.t(), pos_integer(), Date.t()) :: [String.t()]
  defp find_old_run_files(root, retention_days, today) do
    cutoff = Date.add(today, -retention_days)

    root
    |> Path.join("docs/agent-loop/runs/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{mtime: mtime}} ->
          mtime
          |> NaiveDateTime.from_erl!()
          |> NaiveDateTime.to_date()
          |> Date.compare(cutoff) == :lt

        _ ->
          false
      end
    end)
    |> Enum.sort()
  end
end
