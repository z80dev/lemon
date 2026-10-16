defmodule CodingAgent.Tools.Bash.Capture do
  @moduledoc false

  alias CodingAgent.ProcessManager

  # Create the directory before any secret-bearing files, and never reuse an
  # existing path (including a symlink). Shell redirection only opens files that
  # have already been created inside this private directory.
  def start do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-shell-" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      )

    case File.mkdir(path) do
      :ok ->
        try do
          File.chmod!(path, 0o700)

          for name <- ["cwd", "env"] do
            file = Path.join(path, name)
            {:ok, io} = File.open(file, [:write, :exclusive, :binary])
            File.close(io)
            File.chmod!(file, 0o600)
          end

          caller = self()
          guard = spawn(fn -> guard(path, Process.monitor(caller)) end)
          %{path: path, cwd: Path.join(path, "cwd"), env: Path.join(path, "env"), guard: guard}
        rescue
          error ->
            File.rm_rf(path)
            reraise error, __STACKTRACE__
        end

      {:error, :eexist} ->
        start()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create shell capture directory", path: path
    end
  end

  def finish(capture), do: send(capture.guard, :finish)
  def detach(capture, id), do: send(capture.guard, {:detach, id})

  defp guard(path, ref) do
    receive do
      :finish ->
        Process.demonitor(ref, [:flush])
        File.rm_rf(path)

      {:detach, id} ->
        Process.demonitor(ref, [:flush])

        try do
          await_completion(path, id)
        after
          File.rm_rf(path)
        end

      {:DOWN, ^ref, :process, _, _} ->
        # Removing the directory also prevents a late EXIT trap from recreating
        # the files if the invoking tool process dies before handing off.
        File.rm_rf(path)
    end
  end

  defp await_completion(path, id) do
    case ProcessManager.poll(id, lines: 0) do
      {:ok, %{status: status}}
      when status in [:completed, :error, :killed, :lost, :expired, :canceled, :rejected] ->
        File.rm_rf(path)

      {:error, :not_found} ->
        File.rm_rf(path)

      _ ->
        receive do
        after
          50 -> await_completion(path, id)
        end
    end
  end
end
