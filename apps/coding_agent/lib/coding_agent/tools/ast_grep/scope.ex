defmodule CodingAgent.Tools.AstGrep.Scope do
  @moduledoc false

  alias CodingAgent.Tools.IgnoreFilter
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def files(paths, max_files, signal) do
    Enum.reduce_while(paths, {:ok, MapSet.new()}, fn path, {:ok, files} ->
      case collect(path, path, files, max_files, signal, true) do
        {:ok, files} -> {:cont, {:ok, files}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, files |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  defp collect(path, root, files, max_files, signal, explicit?) do
    with :ok <- check_abort(signal), {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :regular ->
          add(path, files, max_files)

        :directory ->
          directory(path, root, files, max_files, signal)

        :symlink when explicit? ->
          if File.regular?(path), do: add(path, files, max_files), else: {:ok, files}

        _ ->
          {:ok, files}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot enumerate AST scope: #{reason}"}
      error -> error
    end
  end

  defp directory(path, root, files, max_files, signal) do
    with {:ok, names} <- File.ls(path) do
      names
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.map(&Path.join(path, &1))
      |> IgnoreFilter.reject_ignored(root)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, files}, fn child, {:ok, files} ->
        case collect(child, root, files, max_files, signal, false) do
          {:ok, files} -> {:cont, {:ok, files}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp add(path, files, max_files) do
    files = MapSet.put(files, path)

    if MapSet.size(files) > max_files,
      do:
        {:error,
         "AST scope exceeds max_files=#{max_files}; narrow paths or raise max_files. No files searched or written."},
      else: {:ok, files}
  end
end
