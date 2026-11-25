defmodule LemonLsp.WorkspaceRoot do
  @moduledoc """
  Chooses the workspace root a language server is started in for a file.

  Inside the working directory the outermost ancestor that declares a
  multi-project workspace for the server's markers wins, so files in different
  member projects share one server: a Mix umbrella (`mix.exs` with
  `apps_path`), a Cargo `[workspace]`, an npm/yarn workspace (`package.json`
  with `workspaces`) or `pnpm-workspace.yaml`, a Go `go.work`, or a uv
  workspace (`pyproject.toml` with `[tool.uv.workspace]`). Otherwise the
  nearest ancestor holding a root marker wins, else the working directory.
  A file outside the working directory never adopts an enclosing workspace:
  its nearest marker directory, else its own directory, is the root.
  """

  # Manifests are read only to recognise a workspace declaration.
  @max_manifest_bytes 256 * 1024

  @spec detect(Path.t(), Path.t(), [String.t()]) :: Path.t()
  def detect(path, cwd, markers) do
    dir = path |> Path.expand() |> Path.dirname()
    cwd = Path.expand(cwd)

    if dir == cwd or String.starts_with?(dir, cwd <> "/") do
      chain = ancestors(dir, cwd)

      Enum.find(Enum.reverse(chain), &workspace?(&1, markers)) ||
        Enum.find(chain, &marked?(&1, markers)) || cwd
    else
      dir |> ancestors("/") |> Enum.find(dir, &marked?(&1, markers))
    end
  end

  # `dir` and each parent up to and including `stop`, nearest first.
  defp ancestors(dir, stop) do
    parent = Path.dirname(dir)
    if dir == stop or parent == dir, do: [dir], else: [dir | ancestors(parent, stop)]
  end

  defp marked?(dir, markers), do: Enum.any?(markers, &File.exists?(Path.join(dir, &1)))

  defp workspace?(dir, markers), do: Enum.any?(markers, &declares_workspace?(dir, &1))

  defp declares_workspace?(dir, "mix.exs"),
    do: manifest_matches?(Path.join(dir, "mix.exs"), ~r/\bapps_path\s*:/)

  defp declares_workspace?(dir, "Cargo.toml"),
    do: manifest_matches?(Path.join(dir, "Cargo.toml"), ~r/^\s*\[workspace\]/m)

  defp declares_workspace?(dir, "pyproject.toml"),
    do: manifest_matches?(Path.join(dir, "pyproject.toml"), ~r/^\s*\[tool\.uv\.workspace\]/m)

  defp declares_workspace?(dir, "go.mod"), do: File.regular?(Path.join(dir, "go.work"))

  defp declares_workspace?(dir, "package.json") do
    File.regular?(Path.join(dir, "pnpm-workspace.yaml")) or
      case read_manifest(Path.join(dir, "package.json")) do
        {:ok, json} -> match?({:ok, %{"workspaces" => _}}, Jason.decode(json))
        :error -> false
      end
  end

  defp declares_workspace?(_dir, _marker), do: false

  defp manifest_matches?(path, pattern) do
    case read_manifest(path) do
      {:ok, text} -> Regex.match?(pattern, text)
      :error -> false
    end
  end

  defp read_manifest(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, device} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(device, @max_manifest_bytes) do
          data when is_binary(data) -> {:ok, data}
          _eof_or_error -> :error
        end
      after
        File.close(device)
      end
    else
      _ -> :error
    end
  end
end
