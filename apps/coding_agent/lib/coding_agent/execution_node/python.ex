defmodule CodingAgent.ExecutionNode.Python do
  @moduledoc """
  Single resolver for the Python 3 interpreter that runs the worker's helpers
  (`node_fs.py`, `node_process.py`, `node_pty.py`) and the feature probe.

  Resolution order:

  1. The interpreter bundled with the release at `<code root>/python/bin/python3`,
     when it is a regular executable file.
  2. `python3` from `PATH`.

  On darwin, `/usr/bin/python3` is Apple's developer-tools shim: running it
  without the Command Line Tools installed opens the CLT installer. It is
  therefore accepted only when `xcode-select -p` succeeds. The result is cached
  in supervised ETS until explicitly forgotten or the cache owner restarts.
  Pre-boot CLI feature checks probe without caching until that owner is running;
  they never start an unconfigured application or create their own table.

  Test options: `:root` (code root), `:find_executable` (1-arity lookup),
  `:os_type`, `:clt_probe` (0-arity probe), and `:clt?` (skips the probe/cache).
  """

  import Bitwise

  @clt_key {__MODULE__, :command_line_tools?}
  @shim "/usr/bin/python3"

  @spec executable(keyword()) :: {:ok, String.t()} | {:error, :not_installed}
  def executable(opts \\ []) do
    case bundled(opts) do
      {:ok, path} -> {:ok, path}
      :none -> on_path(opts)
    end
  end

  @doc false
  @spec forget_command_line_tools() :: :ok
  def forget_command_line_tools do
    CodingAgent.RuntimeTables.delete(@clt_key)
  end

  defp bundled(opts) do
    root = opts |> Keyword.get_lazy(:root, &:code.root_dir/0) |> to_string()
    candidate = Path.join([root, "python", "bin", "python3"])

    if regular_executable?(candidate), do: {:ok, candidate}, else: :none
  end

  defp on_path(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("python3") do
      path when is_binary(path) ->
        if path == @shim and Keyword.get_lazy(opts, :os_type, &:os.type/0) == {:unix, :darwin} and
             not command_line_tools?(opts) do
          {:error, :not_installed}
        else
          {:ok, path}
        end

      _ ->
        {:error, :not_installed}
    end
  end

  defp command_line_tools?(opts) do
    case Keyword.fetch(opts, :clt?) do
      {:ok, installed?} ->
        installed? == true

      :error ->
        probe = Keyword.get(opts, :clt_probe, &probe_command_line_tools/0)

        if CodingAgent.RuntimeTables.available?() do
          CodingAgent.RuntimeTables.fetch(@clt_key, probe)
        else
          probe.()
        end
    end
  end

  defp probe_command_line_tools do
    case System.cmd("/usr/bin/xcode-select", ["-p"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp regular_executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end
end
