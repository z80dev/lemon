defmodule LemonSim.Bench.Artifacts.AtomicFile do
  @moduledoc false

  def write!(path, contents) when is_binary(path) and is_binary(contents) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      {:ok, file} = File.open(tmp_path, [:write, :binary])
      :ok = IO.binwrite(file, contents)
      :ok = :file.sync(file)
      :ok = File.close(file)
      :ok = File.rename(tmp_path, path)
      sync_dir(dir)
      :ok
    rescue
      error ->
        _ = File.rm(tmp_path)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        _ = File.rm(tmp_path)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp sync_dir(dir) do
    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:read]),
         :ok <- :file.sync(fd) do
      :file.close(fd)
      :ok
    else
      _ -> :ok
    end
  end
end
