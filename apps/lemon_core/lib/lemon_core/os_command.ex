defmodule LemonCore.OSCommand do
  @moduledoc false

  def run(executable, args, opts, timeout) do
    task =
      Task.async(fn ->
        try do
          System.cmd(executable, args, opts)
        rescue
          _ -> {"", 127}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"", 124}
    end
  end
end
